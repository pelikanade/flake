package client

import (
	"fmt"
	"strings"
	"time"

	configutil "avalanche/internal/config"
)

const DefaultConfigPath = "/etc/avalanche/client.yaml"

type Config struct {
	Local     string        `mapstructure:"local"`
	Tailnet   string        `mapstructure:"tailnet"`
	TokenFile string        `mapstructure:"token_file"`
	Port      int           `mapstructure:"port"`
	Targets   []string      `mapstructure:"targets"`
	Flake     string        `mapstructure:"flake"`
	Timeout   time.Duration `mapstructure:"timeout"`
}

// LoadConfig reads client.yaml, then lets AVALANCHE_CLIENT_* environment
// variables override every key.
func LoadConfig() (*Config, error) {
	loader, path, err := configutil.Load(DefaultConfigPath, map[string]any{
		"client.local":      "",
		"client.tailnet":    "",
		"client.token_file": "/run/secrets/deploy_trigger_token",
		"client.port":       8080,
		"client.targets":    []string{},
		"client.flake":      ".",
		"client.timeout":    "2h",
	})
	if err != nil {
		return nil, err
	}

	var root struct {
		Client Config `mapstructure:"client"`
	}
	if err := loader.Unmarshal(&root); err != nil {
		return nil, fmt.Errorf("decode %s: %w", path, err)
	}
	cfg := root.Client

	cfg.Targets = normalizeTargets(cfg.Targets)
	if cfg.Local == "" || cfg.Tailnet == "" {
		return nil, fmt.Errorf("%s: client.local and client.tailnet are required", path)
	}
	if cfg.TokenFile == "" {
		return nil, fmt.Errorf("%s: client.token_file is required", path)
	}
	if cfg.Flake == "" {
		return nil, fmt.Errorf("%s: client.flake is required", path)
	}
	if cfg.Port < 1 || cfg.Port > 65535 {
		return nil, fmt.Errorf("%s: client.port %d is out of range", path, cfg.Port)
	}
	if cfg.Timeout <= 0 {
		return nil, fmt.Errorf("%s: client.timeout must be positive", path)
	}
	if len(cfg.Targets) == 0 {
		return nil, fmt.Errorf("%s: client.targets is empty", path)
	}
	return &cfg, nil
}

func normalizeTargets(values []string) []string {
	var targets []string
	for _, value := range values {
		for _, part := range strings.Split(value, ",") {
			targets = append(targets, strings.Fields(part)...)
		}
	}
	return targets
}
