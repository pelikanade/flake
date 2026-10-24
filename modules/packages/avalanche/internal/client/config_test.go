package client

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestLoadConfigYAMLAndEnvironment(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "client.yaml")
	if err := os.WriteFile(path, []byte(`
client:
  local: neko-sphere
  tailnet: example.ts.net
  token_file: /tmp/token
  port: 8080
  targets:
    - edge
    - neko-sphere
  flake: .
  timeout: 2h
`), 0o644); err != nil {
		t.Fatal(err)
	}

	t.Setenv("AVALANCHE_CONFIG", path)
	cfg, err := LoadConfig()
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Local != "neko-sphere" || cfg.Tailnet != "example.ts.net" {
		t.Fatalf("unexpected config: %+v", cfg)
	}
	if len(cfg.Targets) != 2 || cfg.Targets[0] != "edge" || cfg.Targets[1] != "neko-sphere" {
		t.Fatalf("unexpected targets: %v", cfg.Targets)
	}
	if cfg.Timeout != 2*time.Hour {
		t.Fatalf("unexpected timeout: %s", cfg.Timeout)
	}

	t.Setenv("AVALANCHE_CLIENT_TAILNET", "override.ts.net")
	t.Setenv("AVALANCHE_CLIENT_TARGETS", "alpha,beta")
	t.Setenv("AVALANCHE_CLIENT_TIMEOUT", "30m")
	cfg, err = LoadConfig()
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Tailnet != "override.ts.net" {
		t.Fatalf("environment did not override tailnet: %s", cfg.Tailnet)
	}
	if len(cfg.Targets) != 2 || cfg.Targets[0] != "alpha" || cfg.Targets[1] != "beta" {
		t.Fatalf("environment did not override targets: %v", cfg.Targets)
	}
	if cfg.Timeout != 30*time.Minute {
		t.Fatalf("environment did not override timeout: %s", cfg.Timeout)
	}
}

func TestLoadConfigEnvironmentOnly(t *testing.T) {
	t.Setenv("AVALANCHE_CONFIG", filepath.Join(t.TempDir(), "missing.yaml"))
	t.Setenv("AVALANCHE_CLIENT_LOCAL", "neko-sphere")
	t.Setenv("AVALANCHE_CLIENT_TAILNET", "example.ts.net")
	t.Setenv("AVALANCHE_CLIENT_TOKEN_FILE", "/tmp/token")
	t.Setenv("AVALANCHE_CLIENT_PORT", "8080")
	t.Setenv("AVALANCHE_CLIENT_TARGETS", "edge,neko-sphere")
	t.Setenv("AVALANCHE_CLIENT_FLAKE", ".")
	t.Setenv("AVALANCHE_CLIENT_TIMEOUT", "2h")

	cfg, err := LoadConfig()
	if err != nil {
		t.Fatal(err)
	}
	if len(cfg.Targets) != 2 || cfg.Targets[0] != "edge" || cfg.Targets[1] != "neko-sphere" {
		t.Fatalf("unexpected targets: %v", cfg.Targets)
	}
}
