// Package config loads keyrelay's settings from the XDG config search path.
package config

import (
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
)

const appName = "keyrelay"

// Config is everything a user can set in config.json.
type Config struct {
	Listen string `json:"listen"`
}

// Default is the configuration used when no config file is found.
func Default() Config { return Config{Listen: "127.0.0.1:8443"} }

// Paths returns the config files Load tries, highest precedence first:
// $XDG_CONFIG_HOME/keyrelay/config.json (default ~/.config), then the same
// name under each entry of $XDG_CONFIG_DIRS (default /etc/xdg).
func Paths() []string {
	var out []string
	home := os.Getenv("XDG_CONFIG_HOME")
	if home == "" {
		if h, err := os.UserHomeDir(); err == nil {
			home = filepath.Join(h, ".config")
		}
	}
	if filepath.IsAbs(home) {
		out = append(out, filepath.Join(home, appName, "config.json"))
	}
	dirs := os.Getenv("XDG_CONFIG_DIRS")
	if dirs == "" {
		dirs = "/etc/xdg"
	}
	for _, d := range filepath.SplitList(dirs) {
		if filepath.IsAbs(d) {
			out = append(out, filepath.Join(d, appName, "config.json"))
		}
	}
	return out
}

// Load applies one config file over Default. $KEYRELAY_CONFIG names that
// file outright and must exist; otherwise the first file on Paths wins.
func Load() (Config, error) {
	if p := os.Getenv("KEYRELAY_CONFIG"); p != "" {
		return read(p)
	}
	for _, p := range Paths() {
		c, err := read(p)
		if errors.Is(err, fs.ErrNotExist) {
			continue
		}
		return c, err
	}
	return Default(), nil
}

func read(path string) (Config, error) {
	c := Default()
	data, err := os.ReadFile(path)
	if err != nil {
		return c, err
	}
	if err := json.Unmarshal(data, &c); err != nil {
		return c, fmt.Errorf("%s: %w", path, err)
	}
	return c, nil
}
