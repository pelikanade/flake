package config

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"strings"

	"github.com/spf13/viper"
)

// Load reads defaultPath as YAML with AVALANCHE_* environment overrides.
// AVALANCHE_CONFIG replaces defaultPath.
func Load(defaultPath string, defaults map[string]any) (*viper.Viper, string, error) {
	path := os.Getenv("AVALANCHE_CONFIG")
	if path == "" {
		path = defaultPath
	}

	loader := viper.New()
	loader.SetConfigFile(path)
	loader.SetConfigType("yaml")
	loader.SetEnvPrefix("AVALANCHE")
	loader.SetEnvKeyReplacer(strings.NewReplacer(".", "_"))
	loader.AutomaticEnv()

	for key, value := range defaults {
		loader.SetDefault(key, value)
	}

	if err := loader.ReadInConfig(); err != nil {
		var notFound viper.ConfigFileNotFoundError
		if !errors.Is(err, fs.ErrNotExist) && !errors.As(err, &notFound) {
			return nil, "", fmt.Errorf("read %s: %w", path, err)
		}
	}
	return loader, path, nil
}
