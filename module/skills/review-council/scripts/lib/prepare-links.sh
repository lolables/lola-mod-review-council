# prepare-links.sh — the head tree's symlinks, for rc-check-symlinks.sh.
#
# Sourced by rc-prepare.sh between changeset capture and the symlink check.
# Not executable on its own: straight-line statements over the globals the
# caller and the earlier fragments set. An `exit` would end the whole program,
# because `source` runs in the same shell, and nothing here ever needs one.
#
# Writes ${session_dir}/head-links.json, `[{"path", "target"}]` for every
# symlink in the state under review, target null when it could not be read or
# holds a NUL byte. The check seeds its link map from it, so a pure rename and
# a chain through a link the change does not touch are judged too; diff.patch
# alone shows neither. The list comes from the same place the diff did:
#   - a PR or MR diff fetched from the forge: the adapter's optional
#     rc_forge_fetch_links, at the head commit the adapter reported. A diff-only
#     run, with no materialised tree, is covered the same way;
#   - a local diff: the operator's index, the state a local review reads.
# When the list cannot be had whole (no adapter capability, no head commit, an
# API failure, a cap exceeded, no repository) no file is written, and the check
# judges from the diff alone and says so. A stale file from an earlier run of
# this session is removed first, so it can never stand in for a missing one.
#
# shellcheck shell=bash
# shellcheck disable=SC2154 # A fragment reads globals its predecessors set;
# standalone that looks like a mistake. `shellcheck -x` resolves them through
# rc-prepare.sh but reports nothing from a sourced file, so each fragment is
# linted standalone too.

# Restating the caller's options: a no-op at runtime, since rc-prepare.sh
# sets them before sourcing anything, here so this file is analysed under the
# options it actually runs with. `-e` stays off deliberately; see the note in
# rc-prepare.sh.
set -uo pipefail

# ============================================================================
# SECTION 11b: List the Head Tree's Symlinks
# ============================================================================

# [{path, target}] for every symlink in the operator's index, or no output and
# a non-zero status. Listed from the top level: `git ls-files` names paths
# relative to the working directory and lists only those below it. A target is
# read into a file rather than a variable, which would drop a NUL byte and a
# trailing newline; jq's --rawfile keeps both.
rc_index_links() {
	local top listing blob_file rec meta mode obj path fetched entry entries=""
	top=$(git rev-parse --show-toplevel 2>/dev/null) || return 1
	listing=$(mktemp "${session_dir}/.index-links.XXXXXX") || return 1
	blob_file=$(mktemp "${session_dir}/.index-blob.XXXXXX") || {
		rm -f "$listing"
		return 1
	}
	if ! git -C "$top" ls-files -s -z >"$listing" 2>/dev/null; then
		rm -f "$listing" "$blob_file"
		return 1
	fi
	# shellcheck disable=SC2094 # the rm inside runs only on the path that
	# returns at once, so nothing reads the listing after it is removed.
	while IFS= read -r -d '' rec; do
		meta="${rec%%$'\t'*}"
		path="${rec#*$'\t'}"
		read -r mode obj _ <<<"$meta"
		[[ "$mode" == 120000 ]] || continue
		fetched=true
		git -C "$top" cat-file blob "$obj" >"$blob_file" 2>/dev/null || fetched=false
		entry=$(jq -nc --arg path "$path" --rawfile target "$blob_file" --argjson fetched "$fetched" \
			'{path: $path, target: (if $fetched and ($target | explode | all(. != 0)) then $target else null end)}') || {
			rm -f "$listing" "$blob_file"
			return 1
		}
		entries+="$entry"$'\n'
	done <"$listing"
	rm -f "$listing" "$blob_file"
	jq -sc '.' <<<"$entries"
}

rm -f "${session_dir}/head-links.json"
head_links_json=""
# No diff, nothing for the check to judge: spare the forge the requests.
if [[ -s "${session_dir}/diff.patch" ]]; then
	# The condition Section 9 used to take diff.patch from the forge.
	if [[ -f "${session_dir}/pr-metadata.txt" ]] && [[ "$forge_tool" != "none" ]]; then
		if [[ -n "$pr_head_sha" ]] && declare -F rc_forge_fetch_links >/dev/null; then
			head_links_json=$(rc_forge_fetch_links "$pr_number" "$forge_owner" "$forge_repo" "$pr_head_sha") ||
				head_links_json=""
		fi
	elif ! $rc_no_git; then
		head_links_json=$(rc_index_links) || head_links_json=""
	fi
fi
# Written whole or not at all: a half-written list would stop the check as
# malformed, where a missing one is a disclosed degradation.
if [[ -n "$head_links_json" ]] && head_links_tmp=$(mktemp "${session_dir}/.head-links.XXXXXX"); then
	if printf '%s\n' "$head_links_json" >"$head_links_tmp"; then
		mv "$head_links_tmp" "${session_dir}/head-links.json"
	else
		rm -f "$head_links_tmp"
	fi
fi
