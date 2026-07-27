#!/usr/bin/env bash
# Shared test helpers for review-council tests.
# Source this file; do not execute it directly.

# Guard: skip if already loaded
[[ -n "${_TEST_HELPERS_LOADED:-}" ]] && return 0
_TEST_HELPERS_LOADED=1

PASS=0
FAIL=0

# GNU timeout, used by tests as a hang guard around scripts that may reach the
# network. Resolved here rather than by sourcing rc-lib.sh: that library reports
# a missing prerequisite by printing skip-JSON and calling `exit 0`, which in a
# test would read as a pass. A test must fail loudly instead. Homebrew's
# coreutils installs GNU timeout as `gtimeout`, so accept either name.
RC_TIMEOUT_BIN="$(command -v timeout || command -v gtimeout || true)"
if [[ -z "$RC_TIMEOUT_BIN" ]]; then
	echo "ERROR: GNU timeout not found. Install it: brew install coreutils | apt-get install coreutils | dnf install coreutils" >&2
	exit 1
fi

assert_json_field() {
	local json="$1" field="$2" expected="$3" test_name="$4"
	local actual
	actual=$(echo "$json" | jq -r ".$field // empty")
	if [[ "$actual" == "$expected" ]]; then
		echo "  PASS: $test_name"
		PASS=$((PASS + 1))
	else
		echo "  FAIL: $test_name (expected '$expected', got '$actual')"
		FAIL=$((FAIL + 1))
	fi
}

# Print a copy of $PATH in which <command> cannot be resolved, leaving every
# other command (bash, jq, git, ...) exactly where the caller's PATH found it.
# Each PATH entry that provides <command> is replaced by a symlink mirror of
# that entry minus <command>; entries that do not provide it are kept verbatim.
# Mirrors are created under <workdir>, which the caller owns and removes.
#
# The tempting shortcut — build a PATH out of one system directory's contents,
# skipping <command> — is Linux-only. macOS has no /usr/bin/bash (bash lives in
# /bin) and no system jq (Homebrew installs it outside the system directories),
# so the script under test dies with exit 127 before it runs, taking the whole
# suite down with it rather than reporting a failed assertion.
#
# Empty PATH entries (the implicit current directory) are dropped: a test's
# working directory is not a credible source of the command being hidden.
# Usage: masked=$(path_without_command gh "$workdir")
path_without_command() {
	local cmd="$1" workdir="$2"
	local masked="" entry mirror f name n=0
	while IFS= read -r entry; do
		[[ -n "$entry" ]] || continue
		if [[ -f "$entry/$cmd" && -x "$entry/$cmd" ]]; then
			n=$((n + 1))
			mirror="$workdir/mask-$n"
			mkdir -p "$mirror"
			for f in "$entry"/*; do
				# An empty directory leaves the glob unexpanded.
				[[ -e "$f" || -L "$f" ]] || continue
				name="${f##*/}"
				[[ "$name" == "$cmd" ]] && continue
				ln -s "$f" "$mirror/$name"
			done
			entry="$mirror"
		fi
		masked="${masked:+$masked:}$entry"
	done < <(printf '%s\n' "${PATH//:/$'\n'}")
	printf '%s' "$masked"
}

# Build a fixture review session under <dir>: a git checkout at a known commit
# (origin set to an enterprise host to exercise host derivation), tracking.md
# (Forge/PR), session.txt (Owner/Repo/Effort/Review root), one verified finding,
# a REQUEST CHANGES verdict, and a one-line TL;DR.
# Usage: make_review_session <dir> [forge=github] [pr=42] [origin=https://github.example.com/acme/widgets.git]
# Pass origin="" to build a checkout with NO origin remote (exercises the
# missing/unparseable-host degrade path).
make_review_session() {
	local s="$1" forge="${2:-github}" pr="${3:-42}" origin="${4-https://github.example.com/acme/widgets.git}"
	mkdir -p "$s/verdicts"
	local repo="$s/checkout"
	mkdir -p "$repo"
	(
		cd "$repo" || return
		git init -q
		git config user.email t@t.local
		git config user.name t
		[[ -n "$origin" ]] && git remote add origin "$origin"
		mkdir -p auth
		echo 'if exp < now' >auth/token.go
		git add auth/token.go
		git commit -qm init
	)
	cat >"$s/tracking.md" <<TRK
# Review Council Session Tracking

## Phase: Preparation

- Forge: ${forge}
- Tooling: gh
- PR: ${pr}
- Mode: code (code files changed)
TRK
	cat >"$s/session.txt" <<SES
Review Council Session
Owner:        acme
Repo:         widgets
Effort:       high
Review root:  ${repo}
SES
	cat >"$s/verdicts/findings.json" <<'FJ'
{
  "verified": [
    {"agent":"divisor-adversary-code","severity":"HIGH","file":"auth/token.go","line":1,
     "evidence":"if exp < now",
     "description":"The expiry check rejects tokens at the exact boundary.",
     "recommendation":"Use `<=` so a token expiring exactly now is still valid.",
     "status":"verified","verdict":"REQUEST CHANGES","provenance":{}}
  ],
  "correctable": [], "stripped": [],
  "total_findings": 1, "duplicates_consolidated": 0,
  "verdicts": {"divisor-adversary-code": "REQUEST CHANGES"}
}
FJ
	echo "REQUEST CHANGES" >"$s/verdict.txt"
	echo "One high-severity boundary bug in token expiry." >"$s/comment-summary.md"
}

# Build a minimal two-branch git repo under <dir>: an origin remote, a `main`
# baseline commit and a topic branch with one change on top, so a test can
# exercise diff/branch resolution without touching the network.
# Usage: setup_repo <dir> [branch=feature-head] [origin=https://github.com/acme/widgets.git]
# Pass origin="" to build a checkout with NO origin remote (exercises the
# paths that must not depend on a remote being present).
setup_repo() {
	local work="$1" branch="${2:-feature-head}" origin="${3-https://github.com/acme/widgets.git}"
	(
		cd "$work" || {
			echo "ERROR: setup_repo cannot enter $work" >&2
			exit 1
		}
		git init -q
		git config user.email t@t.local
		git config user.name t
		if [[ -n "$origin" ]]; then
			git remote add origin "$origin"
		fi
		git checkout -q -b main
		echo "package main" >a.go
		git add a.go
		git commit -qm init
		git checkout -q -b "$branch"
		echo "// change" >>a.go
		git commit -qam change
	)
}
