package avalanche

import (
	"bytes"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

type targetConfig struct {
	hostname string
	token    string
	dir      string
	port     int
	timeout  time.Duration
}

func targetConfigFromEnv() (*targetConfig, error) {
	hostname := os.Getenv("AVALANCHE_TARGET_HOSTNAME")
	if hostname == "" {
		return nil, fmt.Errorf("AVALANCHE_TARGET_HOSTNAME is required")
	}

	tokenFile := os.Getenv("AVALANCHE_TRIGGER_TOKEN_FILE")
	if tokenFile == "" {
		return nil, fmt.Errorf("AVALANCHE_TRIGGER_TOKEN_FILE is required")
	}
	token, err := readToken(tokenFile)
	if err != nil {
		return nil, err
	}

	dir := os.Getenv("AVALANCHE_TRIGGER_DIR")
	if dir == "" {
		dir = TriggerDir
	}

	port := 8080
	if value := os.Getenv("AVALANCHE_TRIGGER_PORT"); value != "" {
		port, err = strconv.Atoi(value)
		if err != nil {
			return nil, fmt.Errorf("invalid AVALANCHE_TRIGGER_PORT %q", value)
		}
	}

	timeout := 2 * time.Hour
	if value := os.Getenv("AVALANCHE_TRIGGER_TIMEOUT"); value != "" {
		seconds, err := strconv.Atoi(value)
		if err != nil {
			return nil, fmt.Errorf("invalid AVALANCHE_TRIGGER_TIMEOUT %q", value)
		}
		timeout = time.Duration(seconds) * time.Second
	}

	return &targetConfig{
		hostname: hostname,
		token:    token,
		dir:      dir,
		port:     port,
		timeout:  timeout,
	}, nil
}

// Serve runs the non-root HTTP trigger on loopback.
func Serve() error {
	cfg, err := targetConfigFromEnv()
	if err != nil {
		return err
	}
	if err := os.MkdirAll(cfg.dir, 0o700); err != nil {
		return err
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/deploy", func(w http.ResponseWriter, r *http.Request) {
		handleDeploy(w, r, cfg)
	})

	server := &http.Server{
		Addr:              fmt.Sprintf("127.0.0.1:%d", cfg.port),
		Handler:           mux,
		ReadHeaderTimeout: 10 * time.Second,
		IdleTimeout:       2 * time.Minute,
	}
	return server.ListenAndServe()
}

func handleDeploy(w http.ResponseWriter, r *http.Request, cfg *targetConfig) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	defer r.Body.Close()

	expected := "Bearer " + cfg.token
	if subtle.ConstantTimeCompare([]byte(r.Header.Get("Authorization")), []byte(expected)) != 1 {
		http.Error(w, "forbidden", http.StatusForbidden)
		return
	}

	body, err := io.ReadAll(io.LimitReader(r.Body, 4096))
	if err != nil {
		http.Error(w, "invalid body", http.StatusBadRequest)
		return
	}
	storePath := strings.TrimSpace(string(body))
	if !ValidStorePath(cfg.hostname, storePath) {
		http.Error(w, "invalid store path", http.StatusBadRequest)
		return
	}

	nonce, err := Nonce()
	if err != nil {
		http.Error(w, "cannot allocate request", http.StatusInternalServerError)
		return
	}
	if err := writeRequest(cfg.dir, nonce, storePath); err != nil {
		http.Error(w, "cannot write request", http.StatusInternalServerError)
		return
	}

	streamDeploy(w, cfg, nonce)
}

// streamDeploy follows the activation log and status files and relays them as
// NDJSON events until the transient unit publishes its result.
func streamDeploy(w http.ResponseWriter, cfg *targetConfig, nonce string) {
	flusher, ok := w.(http.Flusher)
	if !ok {
		http.Error(w, "streaming unsupported", http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "application/x-ndjson")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(http.StatusOK)

	encoder := json.NewEncoder(w)
	send := func(event Event) bool {
		if err := encoder.Encode(event); err != nil {
			return false
		}
		flusher.Flush()
		return true
	}

	logPath := filepath.Join(cfg.dir, "log-"+nonce)
	statusPath := filepath.Join(cfg.dir, "status-"+nonce)
	resultPath := filepath.Join(cfg.dir, "result-"+nonce)
	defer func() {
		_ = os.Remove(logPath)
		_ = os.Remove(statusPath)
		_ = os.Remove(resultPath)
	}()

	if !send(Event{Type: "phase", Phase: "queued"}) {
		return
	}

	var logFile *os.File
	var pending []byte
	readLog := func() bool {
		if logFile == nil {
			file, err := os.Open(logPath)
			if err != nil {
				return true
			}
			logFile = file
		}

		buffer := make([]byte, 4096)
		for {
			n, err := logFile.Read(buffer)
			if n > 0 {
				pending = append(pending, buffer[:n]...)
				for {
					index := bytes.IndexByte(pending, '\n')
					if index < 0 {
						break
					}
					line := string(pending[:index])
					pending = pending[index+1:]
					if !send(Event{Type: "log", Line: line}) {
						return false
					}
				}
			}
			if err != nil {
				break
			}
		}
		return true
	}
	defer func() {
		if logFile != nil {
			_ = logFile.Close()
		}
	}()

	lastPhase := ""
	deadline := time.Now().Add(cfg.timeout)
	for {
		if !readLog() {
			return
		}

		if data, err := os.ReadFile(statusPath); err == nil {
			phase := strings.TrimSpace(string(data))
			if phase != "" && phase != lastPhase {
				lastPhase = phase
				if !send(Event{Type: "phase", Phase: phase}) {
					return
				}
			}
		}

		if data, err := os.ReadFile(resultPath); err == nil {
			if !readLog() {
				return
			}
			if len(pending) > 0 {
				if !send(Event{Type: "log", Line: string(pending)}) {
					return
				}
				pending = nil
			}
			if strings.TrimSpace(string(data)) == "ok" {
				send(Event{Type: "done", OK: true})
			} else {
				send(Event{Type: "done", Error: "deployment failed"})
			}
			return
		}

		if time.Now().After(deadline) {
			send(Event{Type: "done", Error: "deployment timed out"})
			return
		}
		time.Sleep(200 * time.Millisecond)
	}
}

func writeRequest(dir, nonce, storePath string) error {
	file, err := os.CreateTemp(dir, ".request-")
	if err != nil {
		return err
	}
	name := file.Name()
	defer os.Remove(name)

	if _, err := fmt.Fprintf(file, "%s %s\n", nonce, storePath); err != nil {
		file.Close()
		return err
	}
	if err := file.Close(); err != nil {
		return err
	}
	return os.Rename(name, filepath.Join(dir, "request"))
}

// Request starts the transient root activation unit for the pending request.
func Request() error {
	dir := os.Getenv("AVALANCHE_TRIGGER_DIR")
	if dir == "" {
		dir = TriggerDir
	}
	hostname := os.Getenv("AVALANCHE_TARGET_HOSTNAME")
	if hostname == "" {
		return fmt.Errorf("AVALANCHE_TARGET_HOSTNAME is required")
	}

	nonce, storePath, err := ReadRequest(dir)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	_ = os.Remove(filepath.Join(dir, "request"))

	if !ValidStorePath(hostname, storePath) {
		_ = WriteResult(dir, nonce, "failed")
		return fmt.Errorf("invalid store path %q", storePath)
	}

	exe, err := os.Executable()
	if err != nil {
		_ = WriteResult(dir, nonce, "failed")
		return err
	}

	args := []string{
		"--unit=avalanche-deploy-" + nonce,
		"--collect",
		"--property=Type=oneshot",
		"--property=TimeoutStartSec=2h",
		"--property=TimeoutStopSec=2h",
		"--setenv=PATH=/run/current-system/sw/bin",
		exe,
		"activate",
		nonce,
		storePath,
		dir,
		hostname,
	}

	var stderr bytes.Buffer
	cmd := exec.Command("systemd-run", args...)
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		_ = WriteResult(dir, nonce, "failed")
		return fmt.Errorf("systemd-run: %w\n%s", err, stderr.String())
	}
	return nil
}

// Activate realizes a signed closure from the cache and switches to it, while
// teeing the command output to the per-request log the trigger streams.
func Activate(nonce, storePath, dir, hostname string) error {
	if !ValidStorePath(hostname, storePath) {
		_ = WriteResult(dir, nonce, "failed")
		return fmt.Errorf("invalid store path %q", storePath)
	}

	logFile, err := os.OpenFile(filepath.Join(dir, "log-"+nonce), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		_ = WriteResult(dir, nonce, "failed")
		return err
	}
	writer := io.MultiWriter(os.Stdout, logFile)

	finish := func(runErr error) error {
		if runErr != nil {
			fmt.Fprintf(writer, "error: %v\n", runErr)
			_ = WriteStatus(dir, nonce, "failed")
		} else {
			_ = WriteStatus(dir, nonce, "done")
		}

		if closeErr := logFile.Close(); runErr == nil && closeErr != nil {
			runErr = closeErr
		}

		status := "ok"
		if runErr != nil {
			status = "failed"
		}
		if err := WriteResult(dir, nonce, status); err != nil && runErr == nil {
			runErr = err
		}
		return runErr
	}

	if err := WriteStatus(dir, nonce, "realise"); err != nil {
		return finish(err)
	}
	fmt.Fprintf(writer, "$ nix-store --realise %s --option max-jobs 0\n", storePath)
	if err := run(writer, "nix-store", "--realise", storePath, "--option", "max-jobs", "0"); err != nil {
		return finish(err)
	}

	if err := WriteStatus(dir, nonce, "profile"); err != nil {
		return finish(err)
	}
	fmt.Fprintf(writer, "$ nix-env -p /nix/var/nix/profiles/system --set %s\n", storePath)
	if err := run(writer, "nix-env", "-p", "/nix/var/nix/profiles/system", "--set", storePath); err != nil {
		return finish(err)
	}

	if err := WriteStatus(dir, nonce, "switch"); err != nil {
		return finish(err)
	}
	fmt.Fprintf(writer, "$ %s/bin/switch-to-configuration switch\n", storePath)
	if err := run(writer, filepath.Join(storePath, "bin/switch-to-configuration"), "switch"); err != nil {
		return finish(err)
	}

	return finish(nil)
}

func run(writer io.Writer, name string, args ...string) error {
	cmd := exec.Command(name, args...)
	cmd.Stdout = writer
	cmd.Stderr = writer
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("%s %s: %w", name, strings.Join(args, " "), err)
	}
	return nil
}
