// Package auth handles admin authentication for the internal API.
package auth

import (
	"net/http"
	"os"
)

// RequireAdmin rejects requests whose Authorization header does not match
// the admin token loaded from the ADMIN_TOKEN environment variable.
func RequireAdmin(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != os.Getenv("ADMIN_TOKEN") {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		next(w, r)
	}
}
