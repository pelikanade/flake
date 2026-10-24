package avalanche

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"strings"
	"sync"
	"time"
)

// reporter serializes interleaved output from concurrent deployments.
type reporter struct {
	mu sync.Mutex
}

func (r *reporter) printf(format string, args ...any) {
	r.mu.Lock()
	defer r.mu.Unlock()
	fmt.Printf(format, args...)
}

type deployResult struct {
	target string
	err    error
}

// deployFailedError means the target reported a failed deployment, as opposed
// to a connection error caused by the local switch restarting the runner.
type deployFailedError struct {
	target  string
	message string
}

func (e *deployFailedError) Error() string {
	return fmt.Sprintf("%s: %s", e.target, e.message)
}

// RunClient builds every target concurrently, then triggers all remote targets
// concurrently. The local target starts after every remote request has been
// dispatched, because activating it may restart the runner running this client.
func RunClient(configPath, flake string, dryRun bool) error {
	cfg, err := LoadClientConfig(configPath)
	if err != nil {
		return err
	}
	token, err := readToken(cfg.TokenFile)
	if err != nil {
		return err
	}

	if dryRun {
		fmt.Printf("local %s\ntailnet %s\nflake %s\ntargets %s\n",
			cfg.Local, cfg.Tailnet, flake, strings.Join(cfg.Targets, " "))
		return nil
	}

	report := &reporter{}
	paths, err := buildAll(flake, cfg.Targets, report)
	if err != nil {
		return err
	}

	client := &http.Client{Timeout: 2 * time.Hour}
	remote := make([]string, 0, len(cfg.Targets))
	for _, target := range cfg.Targets {
		if target != cfg.Local {
			remote = append(remote, target)
		}
	}

	started := make(chan struct{}, len(remote))
	results := make(chan deployResult, len(cfg.Targets))
	for _, target := range remote {
		go func(target string) {
			results <- deployResult{
				target: target,
				err:    postDeploy(client, cfg, token, target, paths[target], report, started),
			}
		}(target)
	}

	for range remote {
		<-started
	}

	if path, ok := paths[cfg.Local]; ok {
		go func() {
			results <- deployResult{
				target: cfg.Local,
				err:    postDeploy(client, cfg, token, cfg.Local, path, report, nil),
			}
		}()
	}

	var remoteErrors []error
	for range cfg.Targets {
		result := <-results
		if result.err == nil {
			continue
		}
		var failed *deployFailedError
		if result.target == cfg.Local && !errors.As(result.err, &failed) {
			// A lost connection usually means the local switch restarted the
			// runner; the transient activation unit keeps going.
			fmt.Fprintf(os.Stderr, "warning: local trigger failed: %v\n", result.err)
		} else {
			remoteErrors = append(remoteErrors, result.err)
		}
	}

	return errors.Join(remoteErrors...)
}

func buildAll(flake string, targets []string, report *reporter) (map[string]string, error) {
	type buildResult struct {
		target string
		path   string
		err    error
	}

	results := make(chan buildResult, len(targets))
	for _, target := range targets {
		go func(target string) {
			path, err := buildTarget(flake, target)
			results <- buildResult{target: target, path: path, err: err}
		}(target)
	}

	paths := make(map[string]string, len(targets))
	var buildErrors []error
	for range targets {
		result := <-results
		if result.err != nil {
			buildErrors = append(buildErrors, result.err)
			continue
		}
		paths[result.target] = result.path
		report.printf("built %s: %s\n", result.target, result.path)
	}

	if len(buildErrors) > 0 {
		return nil, errors.Join(buildErrors...)
	}
	return paths, nil
}

func buildTarget(flake, target string) (string, error) {
	attr := fmt.Sprintf("%s#nixosConfigurations.%s.config.system.build.toplevel", flake, target)
	cmd := exec.Command("nix", "build", "--no-link", "--print-out-paths", attr)

	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		return "", fmt.Errorf("nix build %s: %w\n%s", target, err, stderr.String())
	}

	path := strings.TrimSpace(stdout.String())
	if path == "" || strings.ContainsAny(path, " \n") {
		return "", fmt.Errorf("unexpected nix build output for %s: %q", target, path)
	}
	return path, nil
}

func postDeploy(client *http.Client, cfg *ClientConfig, token, target, storePath string, report *reporter, started chan<- struct{}) error {
	url := fmt.Sprintf("http://%s.%s:%d/deploy", target, cfg.Tailnet, cfg.Port)
	req, err := http.NewRequest(http.MethodPost, url, strings.NewReader(storePath))
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Content-Type", "text/plain")

	startedOnce := false
	signalStarted := func() {
		if started != nil && !startedOnce {
			started <- struct{}{}
			startedOnce = true
		}
	}
	defer signalStarted()

	resp, err := client.Do(req)
	signalStarted()
	if err != nil {
		return fmt.Errorf("%s: %w", target, err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		return &deployFailedError{
			target:  target,
			message: fmt.Sprintf("HTTP %d: %s", resp.StatusCode, strings.TrimSpace(string(body))),
		}
	}

	decoder := json.NewDecoder(resp.Body)
	for {
		var event Event
		if err := decoder.Decode(&event); err != nil {
			if errors.Is(err, io.EOF) {
				return fmt.Errorf("%s: deployment stream ended without completion", target)
			}
			return fmt.Errorf("%s: read deployment stream: %w", target, err)
		}

		switch event.Type {
		case "log":
			report.printf("[%s] %s\n", target, event.Line)
		case "phase":
			report.printf("[%s] phase: %s\n", target, event.Phase)
		case "done":
			if !event.OK {
				message := event.Error
				if message == "" {
					message = "deployment failed"
				}
				return &deployFailedError{target: target, message: message}
			}
			report.printf("[%s] done\n", target)
			return nil
		}
	}
}

func readToken(path string) (string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return "", fmt.Errorf("read token %s: %w", path, err)
	}
	token := strings.TrimSpace(string(data))
	if token == "" {
		return "", fmt.Errorf("token file %s is empty", path)
	}
	return token, nil
}
