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

	mux.Handle("PUT /admin/flags/{name}", requireKey([]string{cfg.AdminKey}, http.HandlerFunc(store.set)))
	return mux
}
