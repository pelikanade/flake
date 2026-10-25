package deploy

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

const DefaultDir = "/run/avalanche"

func ValidStorePath(hostname, path string) bool {
	const prefix = "/nix/store/"
	if !strings.HasPrefix(path, prefix) {
		return false
	}

	rest := strings.TrimPrefix(path, prefix)
	if strings.Contains(rest, "/") || len(rest) < 34 || rest[32] != '-' {
		return false
	}

	for _, c := range rest[:32] {
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'z') {
			return false
		}
	}

	name := rest[33:]
	want := "nixos-system-" + hostname
	return name == want || strings.HasPrefix(name, want+"-")
}

func writeAtomic(dir, prefix, name string, data []byte, mode os.FileMode) error {
	file, err := os.CreateTemp(dir, prefix)
	if err != nil {
		return err
	}
	temp := file.Name()
	defer os.Remove(temp)

	if _, err := file.Write(data); err != nil {
		file.Close()
		return err
	}
	if err := file.Close(); err != nil {
		return err
	}
	if err := os.Chmod(temp, mode); err != nil {
		return err
	}
	return os.Rename(temp, filepath.Join(dir, name))
}

func WriteRequest(dir, nonce, storePath string) error {
	data := fmt.Sprintf("%s %s\n", nonce, storePath)
	return writeAtomic(dir, ".request-", "request", []byte(data), 0o600)
}

func ReadRequest(dir string) (nonce, storePath string, err error) {
	data, err := os.ReadFile(filepath.Join(dir, "request"))
	if err != nil {
		return "", "", err
	}

	fields := strings.Fields(string(data))
	if len(fields) != 2 {
		return "", "", fmt.Errorf("malformed deployment request")
	}
	return fields[0], fields[1], nil
}

func WriteStatus(dir, nonce, status string) error {
	return writeAtomic(dir, ".status-", "status-"+nonce, []byte(status+"\n"), 0o644)
}

func WriteResult(dir, nonce, status string) error {
	return writeAtomic(dir, ".result-", "result-"+nonce, []byte(status+"\n"), 0o644)
}

func ReadToken(path string) (string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return "", fmt.Errorf("read token %s: %w", path, err)
	}
	token := strings.TrimSpace(string(data))
	if token == "" {
		return "", fmt.Errorf("token file %s is empty", path)
	}
	return token, nil
}
