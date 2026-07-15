#!/usr/bin/env bash
# scaffold.sh — create git history for case-020-recovery-range.
# Creates a feature branch where HEAD is an empty commit (no files
# changed), but the branch diff vs main has code changes with flaws.
# This forces --scope range HEAD~1..HEAD to return empty while
# --scope changed (main...HEAD) finds the code.
set -euo pipefail
workdir="$1"
cd "$workdir"

# Create feature branch
git -c user.name="scaffold" -c user.email="scaffold@test" \
	checkout -b feat/user-lookup

# Add flawed user lookup code (SQL injection, hardcoded secret)
cat >user.go <<'GO'
package main

import (
	"database/sql"
	"fmt"
	"net/http"

	_ "github.com/mattn/go-sqlite3"
)

const dbPassword = "supersecret123"

func userHandler(w http.ResponseWriter, r *http.Request) {
	db, _ := sql.Open("sqlite3", "users.db")
	defer db.Close()

	id := r.URL.Query().Get("id")
	query := fmt.Sprintf("SELECT name FROM users WHERE id = '%s'", id)
	row := db.QueryRow(query)

	var name string
	if err := row.Scan(&name); err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	w.Write([]byte(name))
}

func init() {
	http.HandleFunc("/user", userHandler)
}
GO

# Update go.mod to add sqlite dependency
cat >go.mod <<'GO'
module github.com/example/userapi

go 1.22

require github.com/mattn/go-sqlite3 v1.14.47
GO

git -c user.name="scaffold" -c user.email="scaffold@test" add -A
git -c user.name="scaffold" -c user.email="scaffold@test" -c commit.gpgsign=false \
	commit --quiet -m "Add user lookup endpoint"

# Add an empty commit as HEAD. HEAD~1..HEAD will have zero changed files,
# but main...HEAD still includes the code changes from the previous commit.
git -c user.name="scaffold" -c user.email="scaffold@test" -c commit.gpgsign=false \
	commit --quiet --allow-empty -m "Trigger CI rebuild"
