package server

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"strings"
	"time"

	"github.com/spf13/viper"

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
	path := os.Getenv("AVALANCHE_CONFIG")
	if path == "" {
		path = DefaultConfigPath
	}

	loader := viper.New()
	loader.SetConfigFile(path)
	loader.SetConfigType("yaml")
	loader.SetEnvPrefix("AVALANCHE")
	loader.SetEnvKeyReplacer(strings.NewReplacer(".", "_"))
	loader.AutomaticEnv()

	loader.SetDefault("server.hostname", "")
	loader.SetDefault("server.token_file", "/run/secrets/deploy_trigger_token")
	loader.SetDefault("server.dir", deploy.DefaultDir)
	loader.SetDefault("server.port", 8080)
	loader.SetDefault("server.timeout", "2h")
	loader.SetDefault("server.nonce", "")
	loader.SetDefault("server.store_path", "")

	if err := loader.ReadInConfig(); err != nil {
		var notFound viper.ConfigFileNotFoundError
		if !errors.Is(err, fs.ErrNotExist) && !errors.As(err, &notFound) {
			return nil, fmt.Errorf("read %s: %w", path, err)
		}
	}

	var root struct {
		Server Config `mapstructure:"server"`
	}
	if err := loader.Unmarshal(&root); err != nil {
		return nil, fmt.Errorf("decode %s: %w", path, err)
	}
	cfg := root.Server

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
