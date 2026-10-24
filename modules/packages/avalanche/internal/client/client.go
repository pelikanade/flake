package client

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"os/exec"
	"strings"
	"sync"

	"golang.org/x/sync/errgroup"

	"avalanche/internal/deploy"
	"avalanche/internal/protocol"
)

type deployFailedError struct {
	target  string
	message string
}

func (e *deployFailedError) Error() string {
	return fmt.Sprintf("%s: %s", e.target, e.message)
}

// Run builds every target concurrently, then triggers all remote targets
// concurrently. The local target starts after every remote request has been
// dispatched, because activating it may restart the runner running this client.
func Run() error {
	cfg, err := LoadConfig()
	if err != nil {
		return err
	}
	token, err := deploy.ReadToken(cfg.TokenFile)
	if err != nil {
		return err
	}

	paths, err := buildAll(cfg.Flake, cfg.Targets)
	if err != nil {
		return err
	}
	return deployAll(cfg, token, paths)
}

func buildAll(flake string, targets []string) (map[string]string, error) {
	paths := make(map[string]string, len(targets))
	var mutex sync.Mutex
	var buildErrors []error
	var group errgroup.Group

	for _, target := range targets {
		target := target
		group.Go(func() error {
			path, err := buildTarget(flake, target)
			if err != nil {
				mutex.Lock()
				buildErrors = append(buildErrors, err)
				mutex.Unlock()
				return nil
			}
			mutex.Lock()
			paths[target] = path
			mutex.Unlock()
			slog.Info("built target", "target", target, "path", path)
			return nil
		})
	}

	_ = group.Wait()
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

func deployAll(cfg *Config, token string, paths map[string]string) error {
	httpClient := &http.Client{Timeout: cfg.Timeout}
	remote := make([]string, 0, len(cfg.Targets))
	for _, target := range cfg.Targets {
		if target != cfg.Local {
			remote = append(remote, target)
		}
	}

	started := make(chan struct{}, len(remote))
	var group errgroup.Group
	var mutex sync.Mutex
	var remoteErrors []error
	var localErr error

	for _, target := range remote {
		target := target
		group.Go(func() error {
			err := postDeploy(httpClient, cfg, token, target, paths[target], started)
			if err != nil {
				mutex.Lock()
				remoteErrors = append(remoteErrors, err)
				mutex.Unlock()
			}
			return nil
		})
	}

	for range remote {
		<-started
	}

	if path, ok := paths[cfg.Local]; ok {
		group.Go(func() error {
			localErr = postDeploy(httpClient, cfg, token, cfg.Local, path, nil)
			return nil
		})
	}

	_ = group.Wait()

	if localErr != nil {
		var failed *deployFailedError
		if errors.As(localErr, &failed) {
			remoteErrors = append(remoteErrors, localErr)
		} else {
			// A lost connection usually means the local switch restarted the
			// runner; the transient activation unit keeps going.
			slog.Warn("local trigger lost", "error", localErr)
		}
	}
	return errors.Join(remoteErrors...)
}

func postDeploy(httpClient *http.Client, cfg *Config, token, target, storePath string, started chan<- struct{}) error {
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

	resp, err := httpClient.Do(req)
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
		var event protocol.Event
		if err := decoder.Decode(&event); err != nil {
			if errors.Is(err, io.EOF) {
				return fmt.Errorf("%s: deployment stream ended without completion", target)
			}
			return fmt.Errorf("%s: read deployment stream: %w", target, err)
		}

		switch event.Type {
		case "log":
			slog.Info("deployment log", "target", target, "line", event.Line)
		case "phase":
			slog.Info("deployment phase", "target", target, "phase", event.Phase)
		case "done":
			if !event.OK {
				message := event.Error
				if message == "" {
					message = "deployment failed"
				}
				return &deployFailedError{target: target, message: message}
			}
			slog.Info("deployment complete", "target", target)
			return nil
		}
	}
}
