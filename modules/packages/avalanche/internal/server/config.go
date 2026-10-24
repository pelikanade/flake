package server

import (
	"fmt"
	"time"

	"avalanche/internal/config"
	"avalanche/internal/deploy"
)

const DefaultConfigPath = "/etc/avalanche/server.yaml"

type Config struct {
	Hostname  string        `mapstructure:"hostname"`
	TokenFile string        `mapstructure:"token_file"`
	Dir       string        `mapstructure:"dir"`
	Port      int           `mapstructure:"port"`
	Timeout   time.Duration `mapstructure:"timeout"`
	Nonce     string        `mapstructure:"nonce"`
	StorePath string        `mapstructure:"store_path"`
}

// LoadConfig reads server.yaml, then lets AVALANCHE_SERVER_* environment
// variables override every key.
func LoadConfig() (*Config, error) {
	loader, path, err := config.Load(DefaultConfigPath, map[string]any{
		"server.hostname":   "",
		"server.token_file": "/run/secrets/avalanche_token",
		"server.dir":        deploy.DefaultDir,
		"server.port":       28250,
		"server.timeout":    "2h",
		"server.nonce":      "",
		"server.store_path": "",
	})
	if err != nil {
		return nil, err
	}

	var root struct {
		Server Config `mapstructure:"server"`
	}
	if err := loader.Unmarshal(&root); err != nil {
		return nil, fmt.Errorf("decode %s: %w", path, err)
	}
	cfg := root.Server

	if cfg.Hostname == "" {
		return nil, fmt.Errorf("%s: server.hostname is required", path)
	}
	if cfg.Dir == "" {
		return nil, fmt.Errorf("%s: server.dir is required", path)
	}
	if cfg.Port < 1 || cfg.Port > 65535 {
		return nil, fmt.Errorf("%s: server.port %d is out of range", path, cfg.Port)
	}
	if cfg.Timeout <= 0 {
		return nil, fmt.Errorf("%s: server.timeout must be positive", path)
	}
	return &cfg, nil
}
