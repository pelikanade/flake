package server

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"log/slog"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"avalanche/internal/deploy"
)

func Request() error {
	cfg, err := LoadConfig()
	if err != nil {
		return err
	}
	nonce, storePath, err := deploy.ReadRequest(cfg.Dir)
	if errors.Is(err, fs.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	_ = os.Remove(filepath.Join(cfg.Dir, "request"))

	if !deploy.ValidStorePath(cfg.Hostname, storePath) {
		_ = deploy.WriteResult(cfg.Dir, nonce, "failed")
		return fmt.Errorf("invalid store path %q", storePath)
	}

	exe, err := os.Executable()
	if err != nil {
		_ = deploy.WriteResult(cfg.Dir, nonce, "failed")
		return err
	}

	timeout := int64(cfg.Timeout.Seconds())
	args := []string{
		"--unit=avalanche-deploy-transient-" + nonce,
		"--collect",
		"--property=Type=oneshot",
		fmt.Sprintf("--property=TimeoutStartSec=%d", timeout),
		fmt.Sprintf("--property=TimeoutStopSec=%d", timeout),
		"--setenv=PATH=/run/current-system/sw/bin",
		"--setenv=AVALANCHE_SERVER_NONCE=" + nonce,
		"--setenv=AVALANCHE_SERVER_STORE_PATH=" + storePath,
	}
	if path := os.Getenv("AVALANCHE_CONFIG"); path != "" {
		args = append(args, "--setenv=AVALANCHE_CONFIG="+path)
	}
	args = append(args, exe, "activate")

	var stderr bytes.Buffer
	cmd := exec.Command("systemd-run", args...)
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		_ = deploy.WriteResult(cfg.Dir, nonce, "failed")
		return fmt.Errorf("systemd-run: %w\n%s", err, stderr.String())
	}

	slog.Info("activation queued", "nonce", nonce)
	return nil
}

func Activate() error {
	cfg, err := LoadConfig()
	if err != nil {
		return err
	}
	if cfg.Nonce == "" || cfg.StorePath == "" {
		return fmt.Errorf("server.nonce and server.store_path are required")
	}
	if !deploy.ValidStorePath(cfg.Hostname, cfg.StorePath) {
		_ = deploy.WriteResult(cfg.Dir, cfg.Nonce, "failed")
		return fmt.Errorf("invalid store path %q", cfg.StorePath)
	}

	logFile, err := os.OpenFile(filepath.Join(cfg.Dir, "log-"+cfg.Nonce), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		_ = deploy.WriteResult(cfg.Dir, cfg.Nonce, "failed")
		return err
	}
	writer := io.MultiWriter(os.Stdout, logFile)

	finish := func(runErr error) error {
		if runErr != nil {
			fmt.Fprintf(writer, "error: %v\n", runErr)
			_ = deploy.WriteStatus(cfg.Dir, cfg.Nonce, "failed")
		} else {
			_ = deploy.WriteStatus(cfg.Dir, cfg.Nonce, "done")
		}

		if closeErr := logFile.Close(); runErr == nil && closeErr != nil {
			runErr = closeErr
		}

		status := "ok"
		if runErr != nil {
			status = "failed"
		}
		if err := deploy.WriteResult(cfg.Dir, cfg.Nonce, status); err != nil && runErr == nil {
			runErr = err
		}
		return runErr
	}

	if err := deploy.WriteStatus(cfg.Dir, cfg.Nonce, "realise"); err != nil {
		return finish(err)
	}
	fmt.Fprintf(writer, "$ nix-store --realise %s --option max-jobs 0\n", cfg.StorePath)
	if err := run(writer, "nix-store", "--realise", cfg.StorePath, "--option", "max-jobs", "0"); err != nil {
		return finish(err)
	}

	if err := deploy.WriteStatus(cfg.Dir, cfg.Nonce, "profile"); err != nil {
		return finish(err)
	}
	fmt.Fprintf(writer, "$ nix-env -p /nix/var/nix/profiles/system --set %s\n", cfg.StorePath)
	if err := run(writer, "nix-env", "-p", "/nix/var/nix/profiles/system", "--set", cfg.StorePath); err != nil {
		return finish(err)
	}

	if err := deploy.WriteStatus(cfg.Dir, cfg.Nonce, "switch"); err != nil {
		return finish(err)
	}
	fmt.Fprintf(writer, "$ %s/bin/switch-to-configuration switch\n", cfg.StorePath)
	if err := run(writer, filepath.Join(cfg.StorePath, "bin/switch-to-configuration"), "switch"); err != nil {
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
