package client

import (
	"fmt"
	"time"

	configutil "avalanche/internal/config"
)

const DefaultConfigPath = "/etc/avalanche/client.yaml"

type Config struct {
	Tailnet   string        `mapstructure:"tailnet"`
	TokenFile string        `mapstructure:"token_file"`
	Port      int           `mapstructure:"port"`
	Flake     string        `mapstructure:"flake"`
	Timeout   time.Duration `mapstructure:"timeout"`
}

// LoadConfig reads client.yaml, then lets AVALANCHE_CLIENT_* environment
// variables override every key. The target is supplied on the command line.
func LoadConfig() (*Config, error) {
	loader, path, err := configutil.Load(DefaultConfigPath, map[string]any{
		"client.tailnet":    "",
		"client.token_file": "/run/secrets/avalanche_token",
		"client.port":       8080,
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

	if cfg.Tailnet == "" {
		return nil, fmt.Errorf("%s: client.tailnet is required", path)
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
	return &cfg, nil
}
