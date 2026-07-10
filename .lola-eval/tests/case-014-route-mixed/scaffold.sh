#!/usr/bin/env bash
# scaffold.sh — create git history for case-014-route-mixed.
# Adds a commit with poor error handling so the review-instructions
# "focus on error handling" has something to find.
set -euo pipefail
workdir="$1"
cd "$workdir"

cat >errors.go <<'GO'
package main

import (
	"encoding/json"
	"io"
	"net/http"
	"os"
)

func loadConfigHandler(w http.ResponseWriter, r *http.Request) {
	path := r.URL.Query().Get("path")

	f, _ := os.Open(path)
	data, _ := io.ReadAll(f)

	var config map[string]interface{}
	json.Unmarshal(data, &config)

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(config)
}

func init() {
	http.HandleFunc("/config", loadConfigHandler)
}
GO

git -c user.name="scaffold" -c user.email="scaffold@test" add errors.go
git -c user.name="scaffold" -c user.email="scaffold@test" -c commit.gpgsign=false \
	commit --quiet -m "Add config loader endpoint"
