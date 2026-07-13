#!/usr/bin/env bash
set -euo pipefail

cd "$1"

# Create a feat branch with multiple files across directories
# to exercise deep mode decomposition
git checkout -b feat -q

mkdir -p pkg/auth pkg/api
cat > pkg/auth/middleware.go << 'EOF'
package auth

import "net/http"

func AuthMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		token := r.Header.Get("Authorization")
		if token == "" {
			http.Error(w, "unauthorized", 401)
			return
		}
		// TODO: validate token
		next.ServeHTTP(w, r)
	})
}
EOF

cat > pkg/auth/session.go << 'EOF'
package auth

import "time"

type Session struct {
	UserID    string
	Token     string
	ExpiresAt time.Time
}

func NewSession(userID string) *Session {
	return &Session{
		UserID:    userID,
		Token:     "hardcoded-session-token",
		ExpiresAt: time.Now().Add(24 * time.Hour),
	}
}
EOF

cat > pkg/api/handlers.go << 'EOF'
package api

import (
	"fmt"
	"net/http"
	"os/exec"
)

func UserHandler(w http.ResponseWriter, r *http.Request) {
	userID := r.URL.Query().Get("id")
	cmd := exec.Command("sh", "-c", fmt.Sprintf("echo %s", userID))
	out, _ := cmd.Output()
	w.Write(out)
}
EOF

git -c user.name="scaffold" -c user.email="scaffold@test" add -A
git -c user.name="scaffold" -c user.email="scaffold@test" commit -m "feat: add auth and API packages" -q

# Return to main so the test starts from main
git checkout main -q
