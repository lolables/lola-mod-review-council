#!/usr/bin/env bash
# scaffold.sh — create git history for case-011-route-range.
# Creates a "feat" branch off main with a flawed file, so
# main..feat scopes to only the branch's changes.
set -euo pipefail
workdir="$1"
cd "$workdir"

# Tag the current commit as the main branch point
git -c user.name="scaffold" -c user.email="scaffold@test" branch -m main

# Create feat branch with a new file containing a flaw
git checkout -b feat --quiet

cat >auth.go <<'GO'
package main

import (
	"net/http"
	"os"
)

var adminToken = "hardcoded-admin-token-12345"

func authMiddleware(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		token := r.Header.Get("Authorization")
		if token == adminToken {
			next(w, r)
			return
		}
		// Fallback: check environment but compare with ==
		if token == os.Getenv("AUTH_TOKEN") {
			next(w, r)
			return
		}
		http.Error(w, "unauthorized", http.StatusUnauthorized)
	}
}
GO

git -c user.name="scaffold" -c user.email="scaffold@test" add auth.go
git -c user.name="scaffold" -c user.email="scaffold@test" -c commit.gpgsign=false \
	commit --quiet -m "Add auth middleware"
