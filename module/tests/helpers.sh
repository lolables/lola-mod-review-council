#!/usr/bin/env bash
# Shared test helpers for review-council tests.
# Source this file; do not execute it directly.

# Guard: skip if already loaded
[[ -n "${_TEST_HELPERS_LOADED:-}" ]] && return 0
_TEST_HELPERS_LOADED=1

PASS=0
FAIL=0

# Git behaviour in this suite must be a function of the repository, not of
# whoever is running it. Neutralising the config files wholesale is the only
# way to get that: `core.hooksPath` would run a contributor's own hooks against
# every fixture commit, `init.templateDir` is applied by `git init` itself —
# before any `git config` line in a helper could undo it — and an `includeIf`
# can pull in settings nobody can enumerate, let alone override key by key.
# Identity is supplied here too, from the environment, so it lives in exactly
# one place; git honours GIT_AUTHOR_* and GIT_COMMITTER_* on every version.
# The config-file suppression does not degrade as gracefully. GIT_CONFIG_GLOBAL
# and GIT_CONFIG_SYSTEM arrived in git 2.32, and GIT_CONFIG_NOSYSTEM suppresses
# SYSTEM config only — so on an older git the caller's ~/.gitconfig is still
# read and the hooksPath/includeIf/templateDir hole stays open. 2.32 is
# therefore the floor for this suite's hermeticity, not merely for its tidiness.
# Exported at source time rather than inside a helper so that the scripts under
# test, and any git call a suite makes outside a helper, inherit them too.
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME="Review Council Test"
export GIT_AUTHOR_EMAIL="review-council@test.invalid"
export GIT_COMMITTER_NAME="Review Council Test"
export GIT_COMMITTER_EMAIL="review-council@test.invalid"

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

# Copy a fixture from tests/fixtures/<name> into a fresh writable temp dir and
# print its path. Scripts mutate the session they are given, so tests must
# never run against the fixture in the source tree.
# Usage: work=$(copy_fixture session-golden)
copy_fixture() {
	local name="$1" src dest
	src="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fixtures/$name"
	[[ -d "$src" ]] || {
		echo "ERROR: fixture not found: $src" >&2
		exit 1
	}
	dest=$(mktemp -d)
	cp -R "$src"/. "$dest"/
	printf '%s' "$dest"
}

# Assert that a finding-dropping transform removed exactly the expected number
# of items and nothing else.
#
# This is the assertion the suite was missing. Every consolidation fixture used
# to consist entirely of cluster members, so `assert length == 1` held whether
# the reducer merged correctly or deleted the whole array — which is how a jq
# scoping bug that destroyed unrelated findings, including a HIGH, passed the
# tests for as long as it did. A conservation check needs bystanders in the
# fixture to have any power, so it fails loudly when there are none.
# Usage: assert_conserved <before> <after> <expected_removals> <label>
assert_conserved() {
	local before="$1" after="$2" removals="$3" label="$4" expected
	expected=$((before - removals))
	if [[ "$removals" -ge "$before" ]]; then
		echo "  FAIL: $label — fixture has no bystanders ($before in, $removals removed);"
		echo "        a conservation check cannot detect collateral loss without them"
		FAIL=$((FAIL + 1))
		return
	fi
	if [[ "$after" -eq "$expected" ]]; then
		echo "  PASS: $label ($before − $removals = $after)"
		PASS=$((PASS + 1))
	else
		echo "  FAIL: $label — expected $expected surviving ($before − $removals), got $after"
		FAIL=$((FAIL + 1))
	fi
}

# Compare two values and record the result.
# Usage: assert_equals <actual> <expected> <label>
assert_equals() {
	if [[ "$1" == "$2" ]]; then
		echo "  PASS: $3"
		PASS=$((PASS + 1))
	else
		echo "  FAIL: $3 (expected '$2', got '$1')"
		FAIL=$((FAIL + 1))
	fi
}

# Assert that a jq expression over <file> produces <expected>.
#
# Running jq here rather than inline at the call site is what keeps `set -e`
# meaningful: a command substitution nested inside another command has its exit
# status discarded (shellcheck SC2312), so a jq that errors out would silently
# yield an empty string. As a plain assignment it aborts the suite instead.
# Usage: assert_jq <file> <filter> <expected> <label>
assert_jq() {
	local actual
	actual=$(jq -r "$2" "$1")
	assert_equals "$actual" "$3" "$4"
}

# Create an empty session directory with its verdicts/ subdirectory and print
# the path. Callers own it and remove it.
# Usage: s=$(new_session)
new_session() {
	local s
	s=$(mktemp -d)
	mkdir -p "$s/verdicts"
	printf '%s' "$s"
}

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

# Initialise a git repo in the CURRENT directory. Every fixture repo in this
# suite goes through here. Identity, hooks and inherited settings are handled
# by the GIT_* exports at the top of this file; there is no per-repo identity
# here to disagree with them.
#
# Signing is still disabled per-repo, as the one setting with no environment
# equivalent to fall back on. A contributor whose global config sets
# `commit.gpgsign = true` (common, and near-universal with a `gpg.format = ssh`
# setup) would otherwise have every fixture commit fail on a git older than the
# 2.32 that GIT_CONFIG_GLOBAL needs — and because these helpers run inside
# command substitutions with stderr discarded, the failure does not surface as
# "cannot sign", it surfaces as an unrelated assertion failing much later
# against a repo that has no commits in it.
git_init_sandbox() {
	git init -q
	git config commit.gpgsign false
	git config tag.gpgsign false
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
		git_init_sandbox
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

# Build a git repo containing exactly ONE commit under <dir>. The root commit
# has no parent, so `HEAD~1` does not resolve and there is no prior state to
# diff against — the state every repository passes through on its first day,
# and the one where "no changes found" and "your ref range is invalid" are
# easiest to confuse.
# Usage: setup_single_commit_repo <dir> [branch=main] [origin=""]
setup_single_commit_repo() {
	local work="$1" branch="${2:-main}" origin="${3-}"
	(
		cd "$work" || {
			echo "ERROR: setup_single_commit_repo cannot enter $work" >&2
			exit 1
		}
		git_init_sandbox
		[[ -n "$origin" ]] && git remote add origin "$origin"
		git checkout -q -b "$branch"
		echo "package main" >a.go
		git add a.go
		git commit -qm init
	)
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
		git_init_sandbox
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
