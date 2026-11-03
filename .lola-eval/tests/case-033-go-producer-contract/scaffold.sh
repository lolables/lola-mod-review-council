#!/usr/bin/env bash
# scaffold.sh — create git history for case-033-go-producer-contract.
#
# The starter's initial code becomes the first commit (handled by reset.sh).
# In it Validate refuses only command substitution, and `Spec` in
# internal/newjob/spec.go renders a starter job spec whose archive step is
# `archive "$OUT_DIR/result.json"`: a plain parameter expansion.
#
# This script creates a `feat` branch whose single commit hardens Validate to
# refuse any `$` at all, with tests for the new denials, so the change looks
# complete and `go test` passes. internal/newjob/spec.go is untouched and outside the
# diff, and nothing in the repo runs Spec's output through Validate, yet
# every job created by `gate new` now fails at its archive step.
#
# The defect is a producer of the restricted input. It has no call edge to
# Validate: Spec only builds a string, and the runner parses that string
# at runtime. A reviewer finds it only by asking what emits commands that
# Validate now rejects, for example by searching the repo for `archive`.
set -euo pipefail
workdir="$1"
cd "$workdir"

git -c user.name="scaffold" -c user.email="scaffold@test" branch -m main
git checkout -b feat --quiet

cat >gate.go <<'GO'
// Package gate decides which job steps the runner may execute.
package gate

import (
	"fmt"
	"strings"
)

// allowed is the set of binaries a job step may invoke.
var allowed = map[string]bool{
	"archive": true,
	"lint":    true,
	"notify":  true,
}

// Validate reports whether the runner may execute cmd. The first word must be
// an allowed binary, and any `$` or backtick is refused: parameter expansion
// would let a step read environment values the spec never names.
func Validate(cmd string) error {
	fields := strings.Fields(cmd)
	if len(fields) == 0 {
		return fmt.Errorf("empty command")
	}
	if !allowed[fields[0]] {
		return fmt.Errorf("command %q: %s is not an allowed binary", cmd, fields[0])
	}
	if strings.ContainsAny(cmd, "$`") {
		return fmt.Errorf("command %q: expansion is not allowed", cmd)
	}
	return nil
}
GO

cat >gate_test.go <<'GO'
package gate

import "testing"

func TestValidate(t *testing.T) {
	ok := []string{
		"lint ./...",
		"notify --channel ops",
		"archive result.json",
	}
	for _, cmd := range ok {
		if err := Validate(cmd); err != nil {
			t.Errorf("Validate(%q) = %v, want nil", cmd, err)
		}
	}

	denied := []string{
		"",
		"rm -rf /",
		"lint $(whoami)",
		"notify `id`",
		"notify --token $TOKEN",
		"archive ${HOME}/out.json",
		`lint \$HOME`,
	}
	for _, cmd := range denied {
		if err := Validate(cmd); err == nil {
			t.Errorf("Validate(%q): want error, got nil", cmd)
		}
	}
}
GO

git -c user.name="scaffold" -c user.email="scaffold@test" add gate.go gate_test.go
git -c user.name="scaffold" -c user.email="scaffold@test" -c commit.gpgsign=false \
	commit --quiet -F - <<'MSG'
Refuse parameter expansion in job steps

A step like `notify --token $TOKEN` could read an environment value the
spec never names. Validate now refuses any `$` or backtick instead of only
command substitution, and the tests cover the new denials.
MSG
