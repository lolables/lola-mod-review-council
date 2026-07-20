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
# Usage: make_review_session <dir> [forge=github] [pr=42]
make_review_session() {
	local s="$1" forge="${2:-github}" pr="${3:-42}"
	mkdir -p "$s/verdicts"
	local repo="$s/checkout"
	mkdir -p "$repo"
	(
		cd "$repo" || return
		git init -q
		git config user.email t@t.local
		git config user.name t
		git remote add origin https://github.example.com/acme/widgets.git
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
	cat >"$s/verdicts/evidence-check.json" <<'EJ'
{
  "verified": [
    {"agent":"divisor-adversary-code","severity":"HIGH","title":"expiry uses < not <=","file":"auth/token.go","line":"1","evidence":"if exp < now","detail":"**File**: `auth/token.go:1`\n**Evidence**:\n```go\nif exp < now\n```\n\n**Description**: The expiry check rejects tokens at the exact boundary.\n**Recommendation**: Use `<=` so a token expiring exactly now is still valid:\n```go\nif exp <= now {\n```"}
  ],
  "correctable": [], "stripped": [],
  "total_findings": 1, "duplicates_consolidated": 0
}
EJ
	cat >"$s/verdicts/divisor-adversary-code.md" <<'V'
### [HIGH] expiry uses < not <=
**File**: `auth/token.go:1`
**Evidence**: `if exp < now`
**Verdict**: REQUEST CHANGES
V
	echo "REQUEST CHANGES" >"$s/verdict.txt"
	echo "One high-severity boundary bug in token expiry." >"$s/comment-summary.md"
}
