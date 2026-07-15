#!/usr/bin/env bash
# scaffold.sh — create a second commit for case-017-route-quick.
# HEAD~1..HEAD needs a non-empty diff. The starter commit has the
# base files; this commit adds a flawed endpoint so the quick-mode
# review has something to find.
set -euo pipefail
workdir="$1"
cd "$workdir"

# Add a new handler with security issues in the HEAD commit
cat >>main.go <<'GO'

func adminHandler(w http.ResponseWriter, r *http.Request) {
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

func init() {
	http.HandleFunc("/admin", adminHandler)
}
GO

git -c user.name="scaffold" -c user.email="scaffold@test" add -A
git -c user.name="scaffold" -c user.email="scaffold@test" -c commit.gpgsign=false \
	commit --quiet -m "Add admin query endpoint"
