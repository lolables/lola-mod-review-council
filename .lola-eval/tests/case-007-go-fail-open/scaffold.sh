#!/usr/bin/env bash
# scaffold.sh — create git history for case-007-go-fail-open.
#
# The starter's initial code becomes the first commit (handled by reset.sh).
# In it the admin endpoint takes a single `admin_key`, and Load refuses to
# start without one. requireKey in auth.go passes every request through when
# it has no keys, but the required key keeps that branch unreachable.
#
# This script creates a `feat` branch whose single commit replaces `admin_key`
# with an `admin_keys` list so keys can be rotated. The diff looks secure:
# requireKey is wired unconditionally and each key's length is validated.
# But Load no longer requires the list to be present, so a config without
# `admin_keys`, or with `"admin_keys": null` or `[]`, hands requireKey an
# empty list and the existing pass-through in auth.go — which the diff does
# not touch — serves unauthenticated writes.
#
# A reviewer working from the diff alone sees a stricter-looking change. It
# finds the flaw only by asking what happens when the list is absent and
# reading requireKey outside the changeset.
set -euo pipefail
workdir="$1"
cd "$workdir"

git -c user.name="scaffold" -c user.email="scaffold@test" branch -m main
git checkout -b feat --quiet

cat >config.go <<'GO'
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
	AdminKeys      []string `json:"admin_keys"`
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

	for i, k := range cfg.AdminKeys {
		if len(k) < minKeyLen {
			return Config{}, fmt.Errorf("admin_keys[%d]: shorter than %d bytes", i, minKeyLen)
		}
	}
	return cfg, nil
}
GO

cat >handlers.go <<'GO'
package main

import (
	"encoding/json"
	"log"
	"net/http"
	"regexp"
	"slices"
	"sync"
)

var flagName = regexp.MustCompile(`^[a-z0-9-]{1,64}$`)

// FlagStore holds flag state in memory.
type FlagStore struct {
	mu    sync.RWMutex
	flags map[string]bool
}

// NewFlagStore returns an empty store.
func NewFlagStore() *FlagStore {
	return &FlagStore{flags: make(map[string]bool)}
}

func (s *FlagStore) list(w http.ResponseWriter, _ *http.Request) {
	s.mu.RLock()
	snapshot := make(map[string]bool, len(s.flags))
	for k, v := range s.flags {
		snapshot[k] = v
	}
	s.mu.RUnlock()

	w.Header().Set("Content-Type", "application/json")
	if err := json.NewEncoder(w).Encode(snapshot); err != nil {
		log.Printf("list flags: encode response: %v", err)
	}
}

func (s *FlagStore) set(w http.ResponseWriter, r *http.Request) {
	name := r.PathValue("name")
	if !flagName.MatchString(name) {
		http.Error(w, "invalid flag name", http.StatusBadRequest)
		return
	}

	var body struct {
		Enabled *bool `json:"enabled"`
	}
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1024))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&body); err != nil || body.Enabled == nil {
		http.Error(w, `body must be {"enabled": true|false}`, http.StatusBadRequest)
		return
	}

	s.mu.Lock()
	s.flags[name] = *body.Enabled
	s.mu.Unlock()
	w.WriteHeader(http.StatusNoContent)
}

// withCORS lets the listed browser origins read the response. An origin not
// in the list gets no CORS header, so the browser withholds the response.
func withCORS(origins []string, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Add("Vary", "Origin")
		if origin := r.Header.Get("Origin"); origin != "" && slices.Contains(origins, origin) {
			w.Header().Set("Access-Control-Allow-Origin", origin)
		}
		next.ServeHTTP(w, r)
	})
}

func newMux(cfg Config, store *FlagStore) http.Handler {
	mux := http.NewServeMux()
	mux.Handle("GET /flags", withCORS(cfg.AllowedOrigins, http.HandlerFunc(store.list)))

	mux.Handle("PUT /admin/flags/{name}", requireKey(cfg.AdminKeys, http.HandlerFunc(store.set)))
	return mux
}
GO

cat >README.md <<'MD'
# flagsvc

A small feature-flag service. Clients read flags; operators change them.

## Endpoints

- `GET /flags` — list every flag and whether it is enabled. Public.
- `PUT /admin/flags/{name}` — set a flag. Body: `{"enabled": true}`.
  Admin endpoints require `Authorization: Bearer <key>`, where `<key>` is
  one of the entries in `admin_keys`.

## Configuration

`flagsvc -config config.json` reads a JSON file:

| Key               | Meaning                                                         |
|-------------------|-----------------------------------------------------------------|
| `listen_addr`     | Address to listen on. Defaults to `127.0.0.1:8080`.             |
| `admin_keys`      | API keys accepted on admin endpoints, each at least 32 bytes.   |
| `allowed_origins` | Browser origins allowed to read `GET /flags` cross-origin.      |

See `config.example.json` for a starting point.
MD

git -c user.name="scaffold" -c user.email="scaffold@test" add config.go handlers.go README.md
git -c user.name="scaffold" -c user.email="scaffold@test" -c commit.gpgsign=false \
	commit --quiet -m "Accept several admin keys so a key can be rotated"
