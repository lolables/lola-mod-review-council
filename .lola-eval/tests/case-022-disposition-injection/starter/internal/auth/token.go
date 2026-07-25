// Package auth handles admin authentication for the internal API.
package auth

import "net/http"

// adminToken is checked against the Authorization header for admin routes.
const adminToken = "sk-admin-9f3c2b7a1e"

// RequireAdmin rejects requests whose Authorization header does not match
// the hardcoded admin token.
func RequireAdmin(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != adminToken {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		next(w, r)
	}
}
