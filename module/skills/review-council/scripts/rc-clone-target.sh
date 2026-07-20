#!/usr/bin/env bash
set -uo pipefail

# shellcheck source=module/skills/review-council/scripts/rc-lib.sh
source "$(dirname "$0")/rc-lib.sh"
rc_trap_errors # report script:line on any unhandled failure (never silent)

# rc-clone-target.sh — materialize a target repo for PR review when we are
# not already in it. Emits JSON with review_root for downstream reads.
#
# Usage:
#   rc-clone-target.sh --forge github --owner O --repo R --pr N --head REF [--url URL]
#
# Output JSON:
#   {"status":"in_place|ok|skip","review_root":"<path|.>","message":"..."}
#     in_place  -> current working tree is the target at PR head; review_root "."
#     ok        -> materialized into cache; review_root is the checkout path
#     skip      -> not materialized (non-github forge / clone failure); review_root "."

forge="" owner="" repo="" pr="" head="" url=""
while [[ $# -gt 0 ]]; do
	case "$1" in
	--forge) forge="$2"; shift 2 ;;
	--owner) owner="$2"; shift 2 ;;
	--repo) repo="$2"; shift 2 ;;
	--pr) pr="$2"; shift 2 ;;
	--head) head="$2"; shift 2 ;;
	--url) url="$2"; shift 2 ;;
	*) json_output "skip" "Unknown flag: $1" '{"review_root":"."}'; exit 0 ;;
	esac
done

emit() { # status message
	json_output "$1" "$2" "$(jq -n --arg r "${review_root:-.}" '{review_root:$r}')"
}

# Validate identifiers (defense in depth; prepare.sh already validates).
if [[ ! "$owner" =~ ^[a-zA-Z0-9._-]+$ ]] || [[ ! "$repo" =~ ^[a-zA-Z0-9._-]+$ ]] || [[ ! "$pr" =~ ^[0-9]+$ ]]; then
	review_root="."; emit "skip" "Invalid or missing owner/repo/pr; reviewing from diff only."; exit 0
fi

# Only GitHub is implemented. Other forges fall back to diff-only review.
if [[ "$forge" != "github" ]]; then
	review_root="."; emit "skip" "Cloning not implemented for forge '${forge}'; reviewing from diff only."; exit 0
fi

# --- Already in it? Same origin owner/repo AND current branch == PR head ---
origin_url=$(git remote get-url origin 2>/dev/null || echo "")
cur_owner=$(echo "$origin_url" | sed -E 's|.*github\.com[:/]([^/]+)/([^/]+)(\.git)?$|\1|')
cur_repo=$(echo "$origin_url" | sed -E 's|.*github\.com[:/]([^/]+)/([^/]+)(\.git)?$|\2|' | sed -E 's/\.git$//')
cur_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
if [[ "${cur_owner,,}" == "${owner,,}" ]] && [[ "${cur_repo,,}" == "${repo,,}" ]] && [[ -n "$head" ]] && [[ "$cur_branch" == "$head" ]]; then
	review_root="."; emit "in_place" "Already in ${owner}/${repo} at ${head}; using working tree."; exit 0
fi

# --- Materialize into per-repo cache ---
cache_root="${XDG_CACHE_HOME:-$HOME/.cache}/review-council/clones"
dest="${cache_root}/${owner}-${repo}"
clone_url="${url:-https://github.com/${owner}/${repo}.git}"

mkdir -p "$cache_root" 2>/dev/null || { review_root="."; emit "skip" "Cannot create clone cache; reviewing from diff only."; exit 0; }

clone_ok=false
if [[ -d "$dest/.git" ]]; then
	# Reuse existing clone.
	clone_ok=true
else
	# Prefer gh (auth); flags after -- are passed to git clone.
	if command -v gh >/dev/null 2>&1; then
		if timeout 120 gh repo clone "${owner}/${repo}" "$dest" -- --filter=blob:none --no-checkout >/dev/null 2>&1; then
			clone_ok=true
		fi
	fi
	# Plain blobless partial clone. Clear any partial dest a failed gh clone
	# may have left behind, or this clone aborts with "destination exists".
	if [[ "$clone_ok" != true ]]; then
		rm -rf "$dest" 2>/dev/null
		if timeout 120 git clone --filter=blob:none --no-checkout "$clone_url" "$dest" >/dev/null 2>&1; then
			clone_ok=true
		fi
	fi
	# Shallow fallback.
	if [[ "$clone_ok" != true ]]; then
		rm -rf "$dest" 2>/dev/null
		if timeout 120 git clone --depth 50 "$clone_url" "$dest" >/dev/null 2>&1; then
			clone_ok=true
		fi
	fi
fi

if [[ "$clone_ok" != true ]]; then
	review_root="."; emit "skip" "Clone of ${owner}/${repo} failed; reviewing from diff only."; exit 0
fi

# Fetch the PR head ref (works for fork PRs on the base repo) and check it out.
if ! timeout 120 git -C "$dest" fetch origin "pull/${pr}/head" >/dev/null 2>&1; then
	review_root="."; emit "skip" "Fetch of pull/${pr}/head failed; reviewing from diff only."; exit 0
fi
# Checkout populates the working tree; a blobless --no-checkout clone has no
# files until this runs. If it fails, the tree is empty and every finding
# would be stripped FILE_NOT_FOUND (a false-clean review), so fall back to
# diff-only review instead of emitting a misleading "ok".
if ! git -C "$dest" checkout -q FETCH_HEAD >/dev/null 2>&1; then
	review_root="."; emit "skip" "Checkout of pull/${pr}/head failed; reviewing from diff only."; exit 0
fi

# Mark as most-recently-used for LRU.
touch "$dest" 2>/dev/null || true

# --- LRU prune: keep newest N clone dirs (by mtime), remove the rest ---
# Use `ls -dt` (POSIX) rather than `find -printf` (GNU-only) so the cap is
# enforced on macOS too — rc-lib.sh explicitly accommodates non-GNU hosts.
cap="${REVIEW_COUNCIL_CLONE_CACHE_MAX:-10}"
[[ "$cap" =~ ^[0-9]+$ ]] || cap=10
mapfile -t by_age < <(ls -dt "$cache_root"/*/ 2>/dev/null | sed 's:/*$::')
if [[ ${#by_age[@]} -gt $cap ]]; then
	for ((k = cap; k < ${#by_age[@]}; k++)); do
		# Never prune the just-created destination.
		[[ "${by_age[$k]}" == "$dest" ]] && continue
		rm -rf "${by_age[$k]}" 2>/dev/null || true
	done
fi

review_root="$dest"
emit "ok" "Materialized ${owner}/${repo} at pull/${pr}/head into cache."
exit 0
