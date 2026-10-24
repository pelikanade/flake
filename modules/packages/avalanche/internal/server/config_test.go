package server

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestLoadConfigYAMLAndEnvironment(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "server.yaml")
	if err := os.WriteFile(path, []byte(`
server:
  hostname: neko-sphere
  token_file: /tmp/token
  dir: /run/avalanche
  port: 28250
  timeout: 2h
`), 0o644); err != nil {
		t.Fatal(err)
	}

	t.Setenv("AVALANCHE_CONFIG", path)
	cfg, err := LoadConfig()
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Hostname != "neko-sphere" || cfg.Port != 28250 {
		t.Fatalf("unexpected config: %+v", cfg)
	}
	if cfg.Timeout != 2*time.Hour {
		t.Fatalf("unexpected timeout: %s", cfg.Timeout)
	}

	t.Setenv("AVALANCHE_SERVER_HOSTNAME", "edge")
	t.Setenv("AVALANCHE_SERVER_TIMEOUT", "45m")
	t.Setenv("AVALANCHE_SERVER_NONCE", "test-nonce")
	t.Setenv("AVALANCHE_SERVER_STORE_PATH", "/nix/store/00000000000000000000000000000000-nixos-system-edge-26.05")
	cfg, err = LoadConfig()
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Hostname != "edge" {
		t.Fatalf("environment did not override hostname: %s", cfg.Hostname)
	}
	if cfg.Timeout != 45*time.Minute {
		t.Fatalf("environment did not override timeout: %s", cfg.Timeout)
	}
	if cfg.Nonce != "test-nonce" || cfg.StorePath == "" {
		t.Fatalf("environment did not provide activation fields: %+v", cfg)
	}
}

func TestLoadConfigEnvironmentOnly(t *testing.T) {
	t.Setenv("AVALANCHE_CONFIG", filepath.Join(t.TempDir(), "missing.yaml"))
	t.Setenv("AVALANCHE_SERVER_HOSTNAME", "edge")
	t.Setenv("AVALANCHE_SERVER_TOKEN_FILE", "/tmp/token")
	t.Setenv("AVALANCHE_SERVER_DIR", "/run/avalanche")
	t.Setenv("AVALANCHE_SERVER_PORT", "28250")
	t.Setenv("AVALANCHE_SERVER_TIMEOUT", "2h")

	cfg, err := LoadConfig()
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Hostname != "edge" || cfg.Dir != "/run/avalanche" {
		t.Fatalf("unexpected config: %+v", cfg)
	}
}
