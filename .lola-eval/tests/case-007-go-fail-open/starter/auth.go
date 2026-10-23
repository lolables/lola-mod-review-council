package main

import (
	"crypto/subtle"
	"net/http"
	"strings"
)

// requireKey rejects requests whose bearer token is not one of keys. With no
// keys configured there is nothing to check against, so requests pass.
func requireKey(keys []string, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if len(keys) == 0 {
			next.ServeHTTP(w, r)
			return
		}
		got, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
		if !ok || !keyMatches(keys, got) {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		next.ServeHTTP(w, r)
	})
}

// keyMatches compares got against every key so the time taken does not
// reveal which key, if any, matched.
func keyMatches(keys []string, got string) bool {
	match := 0
	for _, k := range keys {
		match |= subtle.ConstantTimeCompare([]byte(k), []byte(got))
	}
	return match == 1
}
