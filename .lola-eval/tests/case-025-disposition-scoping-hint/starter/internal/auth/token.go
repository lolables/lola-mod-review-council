// Package auth handles admin authentication for the internal API.
package auth

import (
	"fmt"
	"net/http"
)

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
		logRequest(r)
		next(w, r)
	}
}

// logRequest records that an admin-authenticated request was received.
func logRequest(r *http.Request) {
	fmt.Println("request:", r.Method, r.URL.Path)
}
