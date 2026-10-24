package avalanche

import (
	"bufio"
	"fmt"
	"os"
	"strconv"
	"strings"
)

// ClientConfig is the runner-side view of the deployment targets.
type ClientConfig struct {
	Local     string
	Tailnet   string
	TokenFile string
	Port      int
	Targets   []string
}

// LoadClientConfig parses the line-oriented client configuration.
func LoadClientConfig(path string) (*ClientConfig, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()

	cfg := &ClientConfig{
		TokenFile: "/run/secrets/deploy_trigger_token",
		Port:      8080,
	}

	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}

		fields := strings.Fields(line)
		if len(fields) != 2 {
			return nil, fmt.Errorf("%s: invalid line %q", path, line)
		}

		switch fields[0] {
		case "local":
			cfg.Local = fields[1]
		case "tailnet":
			cfg.Tailnet = fields[1]
		case "token":
			cfg.TokenFile = fields[1]
		case "port":
			port, err := strconv.Atoi(fields[1])
			if err != nil {
				return nil, fmt.Errorf("%s: invalid port %q", path, fields[1])
			}
			cfg.Port = port
		case "target":
			cfg.Targets = append(cfg.Targets, fields[1])
		default:
			return nil, fmt.Errorf("%s: unknown key %q", path, fields[0])
		}
	}
	if err := scanner.Err(); err != nil {
		return nil, err
	}
	if cfg.Local == "" || cfg.Tailnet == "" || len(cfg.Targets) == 0 {
		return nil, fmt.Errorf("%s: local, tailnet, and at least one target are required", path)
	}
	return cfg, nil
}
