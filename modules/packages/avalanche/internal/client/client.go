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

	"avalanche/internal/protocol"
)

// Run builds and deploys one target supplied by the workflow matrix.
func Run(target string) error {
	if target == "" {
		return fmt.Errorf("target is required")
	}

	cfg, err := LoadConfig()
	if err != nil {
		return err
	}
	path, err := buildTarget(cfg.Flake, target)
	if err != nil {
		return err
	}
	slog.Info("built target", "target", target, "path", path)

	httpClient := &http.Client{Timeout: cfg.Timeout}
	return postDeploy(httpClient, cfg, cfg.Token, target, path)
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

func postDeploy(httpClient *http.Client, cfg *Config, token, target, storePath string) error {
	url := fmt.Sprintf("http://%s.%s:%d/deploy", target, cfg.Tailnet, cfg.Port)
	req, err := http.NewRequest(http.MethodPost, url, strings.NewReader(storePath))
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Content-Type", "text/plain")

	resp, err := httpClient.Do(req)
	if err != nil {
		return fmt.Errorf("%s: %w", target, err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		return fmt.Errorf("%s: HTTP %d: %s", target, resp.StatusCode, strings.TrimSpace(string(body)))
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
				return fmt.Errorf("%s: %s", target, message)
			}
			slog.Info("deployment complete", "target", target)
			return nil
		}
	}
}
