#!/usr/bin/env bash
# scaffold.sh — create git history for case-012-route-dir.
# Adds changes on a feature branch so --scope changed (base...HEAD)
# finds a non-empty changeset. Both module/ and cmd/ get flawed files
# so the directory filter can be verified — only module/ should be in scope.
set -euo pipefail
workdir="$1"
cd "$workdir"

# Create a feature branch off main so --scope changed has a diff
git -c user.name="scaffold" -c user.email="scaffold@test" checkout -b feat/admin-debug

# Add a flawed file outside module/ (should be OUT of scope)
cat >cmd/debug.go <<'GO'
package main

import (
	"fmt"
	"net/http"
	"os/exec"
)

func debugHandler(w http.ResponseWriter, r *http.Request) {
	name := r.URL.Query().Get("run")
	out, _ := exec.Command(name).CombinedOutput()
	fmt.Fprintf(w, "%s", out)
}

func init() {
	http.HandleFunc("/debug", debugHandler)
}
GO

# Add a flawed file inside module/ (should be IN scope)
cat >module/admin.go <<'GO'
package module

import (
	"database/sql"
	"fmt"
	"net/http"
)

const dbPassword = "admin123!"

func AdminQuery(w http.ResponseWriter, r *http.Request, db *sql.DB) {
	q := r.URL.Query().Get("q")
	query := fmt.Sprintf("SELECT * FROM admin WHERE name = '%s'", q)
	rows, err := db.Query(query)
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	defer rows.Close()
	w.Write([]byte("ok"))
}
GO

git -c user.name="scaffold" -c user.email="scaffold@test" add -A
git -c user.name="scaffold" -c user.email="scaffold@test" -c commit.gpgsign=false \
	commit --quiet -m "Add admin and debug endpoints"
