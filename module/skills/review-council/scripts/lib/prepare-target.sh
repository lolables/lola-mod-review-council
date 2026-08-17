# prepare-target.sh — PR metadata, target materialization, review mode, agent discovery.
#
# Sections 6-8b of the preparation pipeline, sourced by rc-prepare.sh in order.
# Not executable on its own: these are straight-line statements over the
# globals the caller and the earlier fragments set, exactly as they were
# when this was one 1,400-line file. An `exit` on a skip path still ends
# the whole program, because `source` runs in the same shell.
#
# Resolves WHAT is reviewed and WHO reviews it. Mode detection belongs here
# rather than with the changeset because agent discovery depends on it —
# the -code/-spec suffix is chosen from the mode.
#
# shellcheck shell=bash
# shellcheck disable=SC2154,SC2034 # A fragment reads globals its
# predecessors set (SC2154) and sets globals its successors read (SC2034);
# standalone both look like mistakes. `shellcheck -x` resolves them through
# rc-prepare.sh but reports nothing from a sourced file, so each fragment is
# linted standalone too — these two codes are the price, and every other
# check still runs over this file.

# Restating the caller's options: a no-op at runtime, since rc-prepare.sh
# sets them before sourcing anything. It is here so this file is analysed
# under the options it actually runs with — without it shellcheck assumes
# defaults and reports 22 SC2312 command-substitution warnings that do not
# apply. `-e` stays off deliberately; see the note in rc-prepare.sh.
set -uo pipefail

# ============================================================================
# SECTION 6: Fetch PR Metadata (if applicable)
# ============================================================================

pr_number=""
pr_title=""
pr_base=""
pr_head=""
pr_url=""
pr_state=""
pr_body=""
pr_status_checks=""

if [[ "$input_type" == "pr_number" ]] || [[ "$input_type" == "url" ]]; then
	pr_number="$input_value"

	if [[ "$forge_tool" != "none" ]]; then
		# The adapter for the detected forge, if any, was sourced by
		# rc-prepare.sh. Testing for the function rather than for the forge name
		# is what keeps this stage forge-agnostic: a forge whose adapter is not
		# installed falls through to the no-metadata path instead of needing a
		# branch here.
		if declare -F rc_forge_fetch_pr >/dev/null; then
			rc_forge_fetch_pr "$pr_number" "$forge_owner" "$forge_repo"
		fi

		# Write pr-metadata.txt
		if [[ -n "$pr_title" ]]; then
			{
				echo "number: $pr_number"
				echo "title: $pr_title"
				echo "base: $pr_base"
				echo "head: $pr_head"
				echo "url: $pr_url"
				echo "state: $pr_state"
				echo ""
				echo "--- BODY ---"
				echo "$pr_body"
				echo "--- END BODY ---"

				if [[ -n "$pr_status_checks" ]]; then
					echo ""
					echo "--- STATUS CHECKS ---"
					echo "$pr_status_checks"
					echo "--- END STATUS CHECKS ---"
				fi
			} >"${session_dir}/pr-metadata.txt"
		fi
	fi
fi

# ============================================================================
# SECTION 6b: Materialize Target Repo (PR/URL scope, github only)
# ============================================================================

review_root="."

if [[ "$input_type" == "pr_number" ]] || [[ "$input_type" == "url" ]]; then
	if [[ "$forge" == "github" ]] && [[ -n "$pr_number" ]]; then
		clone_head="${pr_head:-}"
		clone_json=$(AGENTS_DIR="${AGENTS_DIR:-}" bash "$(dirname "$0")/rc-clone-target.sh" \
			--forge "$forge" --owner "$forge_owner" --repo "$forge_repo" \
			--pr "$pr_number" --head "$clone_head" 2>/dev/null || echo '{}')
		rr=$(echo "$clone_json" | jq -r '.review_root // "."' 2>/dev/null || echo ".")
		[[ -n "$rr" && "$rr" != "null" ]] && review_root="$rr"
	fi
fi

# ============================================================================
# SECTION 6c: Fetch PR Diff (PR/url scope) — used by mode detection and Section 9
# ============================================================================

# Fetch the PR diff once, independent of mode. Section 7 auto-detect and
# Section 9 changeset capture both reuse this cache. Fetching here (not inside
# the auto-detect branch) keeps explicit --mode runs from yielding an empty
# changeset on PR/url scope.
pr_diff_cache=""
if [[ -f "${session_dir}/pr-metadata.txt" ]] && [[ "$forge_tool" != "none" ]]; then
	pr_diff_cache=$(mktemp "${session_dir}/pr-diff-cache.XXXXXX")
	if declare -F rc_forge_fetch_diff >/dev/null; then
		rc_forge_fetch_diff "$pr_number" "$forge_owner" "$forge_repo" "$pr_diff_cache"
	fi
fi

# ============================================================================
# SECTION 7: Determine Review Mode
# ============================================================================

mode="code"
mode_reason="default"

# The flag parser admits only code, specs or auto, so this branch is
# exhaustive rather than a catch-all: reaching the else means "code".
if [[ -n "$mode_override" ]] && [[ "$mode_override" != "auto" ]]; then
	if [[ "$mode_override" == "specs" ]]; then
		mode="spec"
		mode_reason="explicit override"
	else
		mode="code"
		mode_reason="explicit override"
	fi
else
	# Auto-detect mode
	changeset_for_mode_detection=""

	if [[ -n "${pr_diff_cache:-}" ]] && [[ -f "${pr_diff_cache:-}" ]]; then
		# Reuse the PR diff fetched in Section 6c
		changeset_for_mode_detection=$(grep '^diff --git' "$pr_diff_cache" |
			sed -E 's|^diff --git a/(.*) b/.*|\1|' || echo "")
	elif [[ -n "${scope_dir:-}" ]]; then
		# Classify what is actually under review, not the branch it sits on.
		# Detection read the whole branch diff regardless of scope, so naming a
		# single Go file on a branch that had otherwise touched only docs came
		# back mode=spec: the spec council reviewing source, the code personas
		# and every code convention pack never dispatched. The file the user
		# named is the strongest statement of intent available here.
		#
		# A named file classifies as itself; a named directory contributes what
		# changed under it, which is what that scope reviews. Both use the same
		# comma-separated split the changeset builder does, so the two cannot
		# disagree about what was named.
		IFS=',' read -ra mode_scope_paths <<<"$scope_dir"
		for mode_scope_path in "${mode_scope_paths[@]}"; do
			if [[ -f "$mode_scope_path" ]]; then
				changeset_for_mode_detection+="${mode_scope_path}"$'\n'
			else
				# Appended only when it found something. An unconditional
				# `+=$(...)$'\n'` leaves a lone newline behind for a directory
				# with no changes under it, which is not the empty string: the
				# no-changes branch below is skipped, classification counts zero
				# files of either kind, and the run silently resolves to spec
				# mode.
				mode_scope_diff=$(git diff --name-only "${base_branch}...HEAD" -- "$mode_scope_path" 2>/dev/null || echo "")
				[[ -n "$mode_scope_diff" ]] && changeset_for_mode_detection+="${mode_scope_diff}"$'\n'
			fi
		done
	else
		# Use local git diff
		changeset_for_mode_detection=$(git diff --name-only "${base_branch}...HEAD" 2>/dev/null || echo "")
	fi

	# Check if changeset is empty first
	if [[ -z "$changeset_for_mode_detection" ]]; then
		# Empty changeset - check for spec artifacts to decide mode
		has_specs=false
		for dir in specs docs/specs docs/design docs/superpowers design; do
			if [[ -d "$dir" ]] && find "$dir" -type f \( -name "*.md" -o -name "*.txt" \) -print -quit 2>/dev/null | grep -q .; then
				has_specs=true
				break
			fi
		done

		if $has_specs; then
			mode="spec"
			mode_reason="no changes, spec artifacts present"
		else
			mode="code"
			mode_reason="no changes, no spec artifacts"
		fi
	else
		# Classify files
		spec_files=0
		code_files=0

		while IFS= read -r file; do
			[[ -z "$file" ]] && continue

			if [[ "$file" =~ ^(specs|docs/specs|docs/design|docs/superpowers|design)/ ]] ||
				[[ "$file" =~ (spec|plan|tasks|design|research)\.md$ ]]; then
				spec_files=$((spec_files + 1))
			else
				code_files=$((code_files + 1))
			fi
		done <<<"$changeset_for_mode_detection"

		if [[ $code_files -gt 0 ]]; then
			mode="code"
			mode_reason="code files changed"
		else
			mode="spec"
			mode_reason="only spec files changed"
		fi
	fi
fi

# ============================================================================
# SECTION 8: Discover Agents
# ============================================================================

if [[ -z "${AGENTS_DIR:-}" ]]; then
	json_output "skip" "AGENTS_DIR environment variable not set."
	exit 0
fi

agents=()
suffix="code"
[[ "$mode" == "spec" ]] && suffix="spec"

for agent_file in "${AGENTS_DIR}"/divisor-*-"${suffix}".md; do
	[[ -f "$agent_file" ]] || continue
	agent_name=$(basename "$agent_file" ".md")
	agents+=("$agent_name")
done

if [[ ${#agents[@]} -eq 0 ]]; then
	json_output "skip" "No ${mode} reviewer agents found in ${AGENTS_DIR}."
	exit 0
fi

# The council the module ships, as base names. Discovery above stays the sole
# source of truth for who is DISPATCHED — this roster only answers the separate
# question of who is MISSING, so a partial install cannot publish a report that
# reads as full coverage. Before this existed, tracking.md carried the literal
# string "none" and no phase ever updated it: a host with two of five personas
# produced a review whose Discovery Summary claimed nothing was absent.
#
# The list mirrors the persona table in phases/delegate.md, and
# test-rc-doc-guards.sh diffs the two so neither can drift — the same guard the
# module already puts on RC_TOP_KEYS vs verdict-schema.json and on the severity
# list shared across five scripts. Keep it on one line: the test extracts it
# with sed.
RC_PERSONAS=(adversary curator guard sre testing)

agents_absent=()
for persona in "${RC_PERSONAS[@]}"; do
	[[ -f "${AGENTS_DIR}/divisor-${persona}-${suffix}.md" ]] && continue
	agents_absent+=("divisor-${persona}-${suffix}")
done
# Joined with ", " for the tracking line; "none" when the roster is complete.
# A persona present on disk but outside the roster is not reported here — it is
# discovered, dispatched, and counted, and calling an extra reviewer "absent"
# would invert the field's meaning.
# Joined with printf rather than IFS: "${array[*]}" separates on the FIRST
# character of IFS only, so IFS=', ' yields a comma with no space.
if [[ ${#agents_absent[@]} -eq 0 ]]; then
	agents_absent_line="none"
else
	agents_absent_line=$(printf '%s, ' "${agents_absent[@]}")
	agents_absent_line="${agents_absent_line%, }"
fi

# ============================================================================
# SECTION 8b: Smart Exclusions (for --scope all)
# ============================================================================

SMART_EXCLUDES=(
	"node_modules/"
	"vendor/"
	".git/"
	".next/"
	".nuxt/"
	"dist/"
	"build/"
	"out/"
	"__pycache__/"
	".pytest_cache/"
	"target/"
	"coverage/"
	".nyc_output/"
	"package-lock.json"
	"go.sum"
	"yarn.lock"
	"pnpm-lock.yaml"
	"Gemfile.lock"
	"poetry.lock"
	"Cargo.lock"
	"composer.lock"
)
