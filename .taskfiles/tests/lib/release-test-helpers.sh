#!/usr/bin/env bash
# Shared helpers for the release tooling suite (.taskfiles/tests/release.venom.yml).
#
# Every case runs against a throw-away repository, never this checkout. The git
# identity and config isolation below match module/tests/helpers.sh, so a case
# run outside `task test:release` is still hermetic: no caller identity,
# signing config or hooks reach the fixture repositories.
set -euo pipefail

export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME="Review Council Test"
export GIT_AUTHOR_EMAIL="review-council@test.invalid"
export GIT_COMMITTER_NAME="Review Council Test"
export GIT_COMMITTER_EMAIL="review-council@test.invalid"

# Build a scratch checkout that release-bump.sh can operate on: a git repo
# carrying a VERSION file and the project's cliff.toml.
#
# The real cliff.toml is copied rather than a fixture written inline. The
# suggestion levels and changelog grouping these tests assert are properties
# of the shipped config; a fixture copy would let the two drift and the suite
# would keep passing against a config nobody releases with.
#
# Usage: init_release_repo <checkout> <version>
# Sets: TEST_DIR, REPO_DIR, RELEASE_BUMP. Leaves one seed commit on main.
init_release_repo() {
	local source_root="${1}" version="${2}"
	TEST_DIR="$(mktemp -d)"
	REPO_DIR="${TEST_DIR}/project"
	RELEASE_BUMP="${source_root}/.taskfiles/scripts/release-bump.sh"

	git init -q --initial-branch=main "${REPO_DIR}"
	cp "${source_root}/cliff.toml" "${REPO_DIR}/cliff.toml"
	printf '%s\n' "${version}" >"${REPO_DIR}/VERSION"
	git -C "${REPO_DIR}" add VERSION cliff.toml
	git -C "${REPO_DIR}" commit -qm "chore: seed the scratch checkout"
}

# Commit a message against a unique file so every call changes the tree.
# Multi-line messages (a BREAKING CHANGE footer) pass through unchanged.
# Usage: commit_in <repo> <message>
commit_in() {
	local repo="${1}" message="${2}"
	local n
	n="$(git -C "${repo}" rev-list --count HEAD)"
	printf '%s\n' "${message}" >"${repo}/file-${n}"
	git -C "${repo}" add "file-${n}"
	git -C "${repo}" commit -qm "${message}"
}

# Run release-bump.sh against REPO_DIR, answering the prompt with <input>.
# An empty <input> is a bare Enter, which accepts the suggested version.
# stderr is folded into stdout so assertions can read the prompt and any
# diagnostics; the script's exit code is preserved.
# Usage: run_bump <input> [script-args...]
run_bump() {
	local input="${1}"
	shift
	printf '%s\n' "${input}" | ROOT_DIR="${REPO_DIR}" bash "${RELEASE_BUMP}" "$@" 2>&1
}
