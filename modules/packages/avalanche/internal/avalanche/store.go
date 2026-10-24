package avalanche

import (
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// TriggerDir is the runtime directory shared by the trigger and root units.
const TriggerDir = "/run/deploy-trigger"

// ValidStorePath accepts a NixOS system toplevel for the given hostname.
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

// Nonce returns a random identifier for one deployment request.
func Nonce() (string, error) {
	var raw [8]byte
	if _, err := rand.Read(raw[:]); err != nil {
		return "", err
	}
	return hex.EncodeToString(raw[:]), nil
}

// WriteStatus publishes the current activation phase.
func WriteStatus(dir, nonce, status string) error {
	file, err := os.CreateTemp(dir, ".status-")
	if err != nil {
		return err
	}
	name := file.Name()
	defer os.Remove(name)

	if _, err := file.WriteString(status + "\n"); err != nil {
		file.Close()
		return err
	}
	if err := file.Close(); err != nil {
		return err
	}
	if err := os.Chmod(name, 0o644); err != nil {
		return err
	}
	return os.Rename(name, filepath.Join(dir, "status-"+nonce))
}

// WriteResult publishes the outcome of the transient activation unit.
func WriteResult(dir, nonce, status string) error {
	path := filepath.Join(dir, "result-"+nonce)
	if err := os.WriteFile(path, []byte(status+"\n"), 0o644); err != nil {
		return err
	}
	return os.Chmod(path, 0o644)
}

// ReadRequest reads the single pending request written by the trigger.
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
