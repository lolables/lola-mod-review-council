package main

import (
	"encoding/json"
	"fmt"
	"os"
)

const minKeyLen = 32

// Config is the service configuration, read from a JSON file.
type Config struct {
	ListenAddr     string   `json:"listen_addr"`
	AdminKey       string   `json:"admin_key"`
	AllowedOrigins []string `json:"allowed_origins"`
}

// Load reads and validates the configuration at path.
func Load(path string) (Config, error) {
	f, err := os.Open(path)
	if err != nil {
		return Config{}, fmt.Errorf("open config: %w", err)
	}
	defer f.Close()

	cfg := Config{ListenAddr: "127.0.0.1:8080"}
	dec := json.NewDecoder(f)
	dec.DisallowUnknownFields()
	if err := dec.Decode(&cfg); err != nil {
		return Config{}, fmt.Errorf("decode config %s: %w", path, err)
	}

	if len(cfg.AdminKey) < minKeyLen {
		return Config{}, fmt.Errorf("admin_key: shorter than %d bytes", minKeyLen)
	}
	return cfg, nil
}
