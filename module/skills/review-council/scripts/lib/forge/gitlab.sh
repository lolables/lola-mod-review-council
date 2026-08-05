# gitlab.sh — GitLab adapter for the preparation stages.
#
# Sourced by rc-prepare.sh when prepare-repo.sh detects `forge=gitlab`.
# Implements the same contract as github.sh; see that file and
# references/forge-adapters.md for what each function owes its caller.
#
# `glab` resolves the project from the current directory's remote, so owner and
# repo arrive for contract symmetry and are unused here. They are named rather
# than dropped so a future `--repo`-style flag has somewhere obvious to go.
#
# Pipeline status is NOT reported yet: `rc_forge_fetch_pr` leaves
# pr_status_checks empty, so no STATUS CHECKS section is written and the
# Quality Gates phase degrades to "no CI data" — the same path a repository
# with no CI takes. Wiring it up means populating that one variable with
# `<name>: <grade>` lines whose grades use the vocabulary in
# prepare-emit.sh Section 16; nothing outside this file changes.
#
# shellcheck shell=bash
# shellcheck disable=SC2034 # Sets globals the sourcing stage reads; standalone
# they look unused.

rc_forge_fetch_pr() {
	local mr_number="$1" _owner="$2" _repo="$3"
	local mr_json

	mr_json=$(rc_timeout 30 glab mr view "$mr_number" --output json 2>/dev/null || echo "")

	[[ -n "$mr_json" ]] || return 0

	pr_title=$(echo "$mr_json" | jq -r '.title // ""')
	pr_body=$(echo "$mr_json" | jq -r '.description // ""')
	pr_base=$(echo "$mr_json" | jq -r '.target_branch // ""')
	pr_head=$(echo "$mr_json" | jq -r '.source_branch // ""')
	pr_url=$(echo "$mr_json" | jq -r '.web_url // ""')
	pr_state=$(echo "$mr_json" | jq -r '.state // ""')
}

rc_forge_fetch_diff() {
	local mr_number="$1" _owner="$2" _repo="$3" out_file="$4"

	rc_timeout 30 glab mr diff "$mr_number" 2>/dev/null >"$out_file" || true
}
