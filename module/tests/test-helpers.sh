#!/usr/bin/env bash
# Shared test helpers for review-council tests.
# Source this file; do not execute it directly.

# Guard: skip if already loaded
[[ -n "${_TEST_HELPERS_LOADED:-}" ]] && return 0
_TEST_HELPERS_LOADED=1

PASS=0
FAIL=0

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
