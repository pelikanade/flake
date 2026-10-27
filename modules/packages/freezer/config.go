package main

import (
	"fmt"
	"io"
	"net/url"
	"os"
	"path"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"

	"gopkg.in/yaml.v3"
)

type Config struct {
	Cache          *CacheConfig  `yaml:"cache"`
	GlobCap        int           `yaml:"glob_cap"`
	JobTimeout     time.Duration `yaml:"job_timeout"`
	Listen         string        `yaml:"listen"`
	PollInterval   time.Duration `yaml:"poll_interval"`
	StateDir       string        `yaml:"state_dir"`
	GlobalBuildCap int           `yaml:"global_build_cap"`
	Retention      int           `yaml:"retention"`
	GitHubAPIBase  string        `yaml:"github_api_base"`
	GitHubToken    string        `yaml:"github_token"`
	PublicURL      string        `yaml:"public_url"`
	Repositories   []Repository  `yaml:"repositories"`
}

type Repository struct {
	Name   string `yaml:"name"`
	URL    string `yaml:"url"`
	GitHub string `yaml:"github"`
}

type CacheConfig struct {
	Bucket     string `yaml:"bucket"`
	Endpoint   string `yaml:"endpoint"`
	SigningKey string `yaml:"signing_key"`
}

func (c CacheConfig) StoreURL() string {
	values := url.Values{
		"endpoint": {c.Endpoint}, "region": {"auto"}, "addressing-style": {"path"},
		"compression": {"zstd"}, "secret-key": {c.SigningKey}, "multipart-upload": {"true"},
	}
	return "s3://" + c.Bucket + "?" + values.Encode()
}

func decodeYAML(filename string, value any) error {
	file, err := os.Open(filename)
	if err != nil {
		return err
	}
	defer file.Close()
	decoder := yaml.NewDecoder(file)
	decoder.KnownFields(true)
	if err := decoder.Decode(value); err != nil {
		return fmt.Errorf("%s: %w", filename, err)
	}
	var extra any
	if err := decoder.Decode(&extra); err != io.EOF {
		return fmt.Errorf("%s: expected one YAML document", filename)
	}
	return nil
}

func LoadConfig(filename string) (Config, error) {
	cfg := Config{GlobCap: 200, JobTimeout: time.Hour, Listen: "127.0.0.1:8080", StateDir: "state", GlobalBuildCap: 3, Retention: 1000, GitHubAPIBase: "https://api.github.com"}
	if err := decodeYAML(filename, &cfg); err != nil {
		return cfg, err
	}
	if cfg.GlobCap < 1 || cfg.JobTimeout <= 0 {
		return cfg, fmt.Errorf("glob_cap and job_timeout must be positive")
	}
	if cfg.PollInterval <= 0 {
		return cfg, fmt.Errorf("poll_interval must be positive: polling is the only trigger")
	}
	if cfg.Cache != nil {
		if cfg.Cache.Bucket == "" || strings.ContainsAny(cfg.Cache.Bucket, "/?#@:") {
			return cfg, fmt.Errorf("cache.bucket must be one bucket name without a prefix")
		}
		endpoint, parseErr := url.Parse(cfg.Cache.Endpoint)
		if parseErr != nil || endpoint.Host == "" || (endpoint.Scheme != "http" && endpoint.Scheme != "https") || endpoint.User != nil || endpoint.RawQuery != "" || endpoint.Fragment != "" {
			return cfg, fmt.Errorf("cache.endpoint must be an HTTP(S) endpoint without credentials, query or fragment")
		}
		if cfg.Cache.SigningKey == "" {
			return cfg, fmt.Errorf("cache.signing_key is required")
		}
	}
	var err error
	paths := []*string{&cfg.StateDir}
	if cfg.Cache != nil {
		paths = append(paths, &cfg.Cache.SigningKey)
	}
	for _, filenamePath := range paths {
		if !filepath.IsAbs(*filenamePath) {
			*filenamePath, err = filepath.Abs(filepath.Join(filepath.Dir(filename), *filenamePath))
			if err != nil {
				return cfg, err
			}
		}
	}
	if cfg.GitHubToken == "" {
		cfg.GitHubToken = os.Getenv("GITHUB_TOKEN")
	}
	cfg.GitHubAPIBase = strings.TrimRight(cfg.GitHubAPIBase, "/")
	if cfg.GlobalBuildCap < 1 || cfg.Retention < 1 {
		return cfg, fmt.Errorf("global_build_cap and retention must be positive")
	}
	for name, value := range map[string]string{"github_api_base": cfg.GitHubAPIBase, "public_url": cfg.PublicURL} {
		if name == "public_url" && value == "" {
			continue
		}
		u, e := url.Parse(value)
		if e != nil || u.Host == "" || (u.Scheme != "http" && u.Scheme != "https") || u.User != nil || u.RawQuery != "" || u.Fragment != "" {
			return cfg, fmt.Errorf("%s must be an HTTP(S) URL without credentials, query or fragment", name)
		}
	}
	names := make(map[string]bool)
	for _, repo := range cfg.Repositories {
		if !repositoryName.MatchString(repo.Name) || names[repo.Name] {
			return cfg, fmt.Errorf("repository names must be unique safe path components")
		}
		names[repo.Name] = true
		if repo.URL == "" || !githubSlug.MatchString(repo.GitHub) {
			return cfg, fmt.Errorf("repository %s requires url and github (owner/name)", repo.Name)
		}
	}
	return cfg, nil
}

var repositoryName = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9_-]*$`)
var githubSlug = regexp.MustCompile(`^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$`)

func LoadBuildList(directory string) ([]string, error) {
	filename := filepath.Join(directory, ".freezer.yaml")
	info, err := os.Lstat(filename)
	if err != nil {
		return nil, err
	}
	if !info.Mode().IsRegular() {
		return nil, fmt.Errorf(".freezer.yaml must be a regular file")
	}
	var list struct {
		Entries []string `yaml:"entries"`
	}
	if err := decodeYAML(filename, &list); err != nil {
		return nil, err
	}
	if list.Entries == nil {
		return nil, fmt.Errorf(".freezer.yaml must declare entries")
	}
	for _, entry := range list.Entries {
		if _, _, _, err := parseEntry(entry); err != nil {
			return nil, err
		}
	}
	return list.Entries, nil
}

var attributeName = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_'-]*$`)

func parseEntry(entry string) (prefix, pattern string, glob bool, err error) {
	invalid := func() (string, string, bool, error) {
		return "", "", false, fmt.Errorf("invalid entry %q: use an attribute path with an optional final-component glob; output selectors are unsupported", entry)
	}
	var parts []string
	start := 0
	quoted, escaped := false, false
	for i, r := range entry {
		if escaped {
			escaped = false
			continue
		}
		if quoted && r == '\\' {
			escaped = true
			continue
		}
		if r == '"' {
			quoted = !quoted
			continue
		}
		if r == '.' && !quoted {
			parts = append(parts, entry[start:i])
			start = i + 1
		}
	}
	if quoted || escaped {
		return invalid()
	}
	parts = append(parts, entry[start:])
	for i, part := range parts {
		if strings.HasPrefix(part, "\"") {
			name, e := strconv.Unquote(part)
			if e != nil || name == "" || strings.ContainsAny(name, "\n\r") {
				return invalid()
			}
			continue
		}
		if strings.ContainsAny(part, "*?[") {
			if i != len(parts)-1 || i == 0 || strings.ContainsAny(part, "/^#\"\\\n\r") {
				return invalid()
			}
			if _, e := path.Match(part, ""); e != nil {
				return invalid()
			}
			glob = true
		} else if !attributeName.MatchString(part) {
			return invalid()
		}
	}
	if glob {
		return strings.Join(parts[:len(parts)-1], "."), parts[len(parts)-1], true, nil
	}
	return "", "", false, nil
}
