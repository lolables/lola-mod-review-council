# prepare-target.sh — PR metadata, target materialization, review mode, agent discovery.
#
# Sections 6-8 of the preparation pipeline, sourced by rc-prepare.sh in order.
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
pr_head_sha=""
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
		# Every one-line value the forge supplied is the PR author's to write
		# and lands in line-oriented files (pr-metadata.txt, session.txt,
		# tracking.md) that are read first match wins, so none may carry a
		# line break or other control character. Done here, once, rather than
		# in each adapter or at each writer: this is the one point every forge's
		# values pass before any of them is written. pr_body and
		# pr_status_checks are multi-line by design and go only into their own
		# delimited sections of pr-metadata.txt; pr_head_sha is already
		# validated as 40-hex by the adapter.
		pr_title=$(rc_single_line "$pr_title")
		pr_base=$(rc_single_line "$pr_base")
		pr_head=$(rc_single_line "$pr_head")
		pr_url=$(rc_single_line "$pr_url")
		pr_state=$(rc_single_line "$pr_state")

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
# SECTION 6b: Materialize Target Repo (PR/URL scope, github and gitlab)
# ============================================================================

review_root="."

if [[ "$input_type" == "pr_number" ]] || [[ "$input_type" == "url" ]]; then
	if [[ "$forge" == "github" || "$forge" == "gitlab" ]] && [[ -n "$pr_number" ]]; then
		clone_head="${pr_head:-}"
		# The host travels as --url whenever it is known. Without it the clone
		# script falls back to the forge's canonical host, and a self-hosted
		# GitLab project would be cloned from a same-named one on gitlab.com.
		# forge_host is a validated hostname and owner/repo are segment-gated
		# by prepare-repo.sh, so the URL holds nothing they did not. The `.git`
		# suffix keeps it the URL the clone script builds by default.
		clone_url_args=()
		[[ -n "$forge_host" ]] &&
			clone_url_args=(--url "https://${forge_host}/${forge_owner}/${forge_repo}.git")
		# The adapter has already read (and validated) the head commit. GitLab
		# materializes the archive at it, so the clone script need not ask;
		# GitHub checks it out, so the tree is the commit the diff was read at
		# even when the pull request moves on before the fetch.
		[[ -n "${pr_head_sha:-}" ]] &&
			clone_url_args+=(--head-sha "$pr_head_sha")
		clone_json=$(AGENTS_DIR="${AGENTS_DIR:-}" bash "$(dirname "$0")/rc-clone-target.sh" \
			--forge "$forge" --owner "$forge_owner" --repo "$forge_repo" \
			--pr "$pr_number" --head "$clone_head" "${clone_url_args[@]}" 2>/dev/null || echo '{}')
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
# SECTION 6d: Exclusion Lists, and the Walk That Honours Them
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

# Basename globs for files that commonly hold credentials. Applied only to trees
# walked outside a git repository, where no ignore list exists: inside one,
# untracked files already honour .gitignore, which is where .env and keys live.
# A file named explicitly in --scope paths is never dropped — naming it is the
# intent. Matched as globs (unquoted on the right of ==), unlike SMART_EXCLUDES.
CREDENTIAL_EXCLUDES=(
	".env"
	".env.*"
	"*.pem"
	"*.key"
	"*.p12"
	"*.pfx"
	"*.jks"
	"*.kdbx"
	"id_rsa"
	"id_dsa"
	"id_ecdsa"
	"id_ed25519"
	".netrc"
	".pgpass"
	".npmrc"
	".pypirc"
	"credentials"
	"credentials.json"
)

# Every regular file under the start points, relative to the current
# directory, without descending into an excluded directory. The four walks
# outside git (both changeset builders and both mode-detection branches) share
# it. Pruning during the walk rather than filtering after it is what keeps a
# vendored tree from costing a full traversal (a 3000-file node_modules took
# 80s) and from voting when auto mode classifies the files. The directory
# patterns are the same SMART_EXCLUDES the changeset builder filters with, so
# a pruned path is one it would have dropped anyway. A leading `-` becomes
# `./-`: find reads a dash-first start point as part of its expression, so a
# target named `-delete` deleted the working directory.
#
# Returns non-zero when find could not read part of the tree (the output is
# still every file it could). Callers record that with
# `|| rc_walk_incomplete=true` rather than discarding it, so the result message
# can say part of the tree went unreviewed; a bare assignment would also trip
# the error trap under pipefail.
rc_walk_incomplete=false
rc_walk_files() { # start...
	local pattern
	local prune=()
	for pattern in "${SMART_EXCLUDES[@]}"; do
		[[ "$pattern" == */ ]] && prune+=(-name "${pattern%/}" -o)
	done
	unset 'prune[${#prune[@]}-1]'
	find "${@/#-/./-}" \( -type d \( "${prune[@]}" \) -prune \) -o -type f -print 2>/dev/null |
		sed 's|^\./||'
}

# Print the lines of stdin that are one of the given scope paths or lie under
# one — never merely something starting with one. `$file == $fp*` admitted
# `src/auth.go.bak` for a filter of `src/auth.go`, and `src/quiet.go` for a
# filter of `src/q`: a review that quietly covers files nobody named. Mode
# detection and changeset capture both filter through this, so the files that
# decide the mode are the files that get reviewed.
rc_filter_to_scope() { # path...
	local file fp
	while IFS= read -r file; do
		[[ -z "$file" ]] && continue
		for fp in "$@"; do
			fp="${fp%/}"
			if [[ "$file" == "$fp" ]] || [[ "$file" == "$fp/"* ]]; then
				printf '%s\n' "$file"
				break
			fi
		done
	done
}

# What counts as a spec is defined once, here, and read by mode detection and
# by every spec-mode discovery branch in prepare-changes.sh. Detection used to
# carry its own shorter list, so a file could select spec mode and then fail
# spec capture's filter — the run reported "No spec artifacts found" for the
# very file that chose the mode.
#
# Extensions. `.mdx` is what Mintlify, Docusaurus and Nextra publish, and
# what the MCP specification itself is written in; `.rst` is Sphinx and
# `.adoc` is AsciiDoc. Excluding them made spec mode unusable on most modern
# documentation sites for no reason a user could discover.
#
# Directories. This list can only ever be a guess at someone else's layout,
# so both it and the extension list are overridable. Bare `docs/` is
# deliberately absent: it is where projects keep tutorials, blog posts and
# release notes as well as specs, and sweeping all of it turns a spec review
# into a review of the whole site. A project that does want that says so
# with REVIEW_COUNCIL_SPEC_DIRS.
IFS=', ' read -ra spec_exts <<<"${REVIEW_COUNCIL_SPEC_EXTS:-md mdx markdown txt rst adoc}"
IFS=', ' read -ra spec_default_dirs <<<"${REVIEW_COUNCIL_SPEC_DIRS:-specs docs/specs docs/specification docs/design docs/superpowers docs/rfcs docs/adr rfcs adr design}"

# find(1) predicate for the extension set: `\( -name "*.md" -o … \)`.
spec_find_args=()
for ext in "${spec_exts[@]}"; do
	[[ -z "$ext" ]] && continue
	[[ ${#spec_find_args[@]} -gt 0 ]] && spec_find_args+=(-o)
	spec_find_args+=(-name "*.${ext}")
done

# The same set as an anchored ERE, for filtering a list of changed paths
# rather than walking the tree. Built from the same array so the two forms
# cannot drift.
spec_ext_re=$(
	IFS='|'
	printf '%s' "${spec_exts[*]}"
)
spec_dir_re=$(
	IFS='|'
	printf '%s' "${spec_default_dirs[*]}"
)

# A changed path is a spec when it has a spec extension under a spec
# directory, or is one of the planning documents a spec workflow writes
# wherever it keeps them (feature-spec.md, plan.md, tasks.md, ...). The name
# must be a whole word: unanchored, respec.md and redesign.md were specs too.
rc_is_spec_path() { # path
	{ [[ "$1" =~ \.(${spec_ext_re})$ ]] && [[ "$1" =~ ^(${spec_dir_re})/ ]]; } ||
		[[ "$1" =~ (^|/|[-_.])(spec|plan|tasks|design|research)\.md$ ]]
}

# ============================================================================
# SECTION 7: Determine Review Mode
# ============================================================================

mode="code"
mode_reason="default"
mode_from_changeset=false

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
	# Auto-detect mode, from the same file set the changeset builder will
	# capture for this scope. Detection once read `base...HEAD` for every git
	# scope it had no branch for, so `--scope range HEAD~1..HEAD` on a merged
	# commit classified an empty list, found a gitignored spec directory on
	# disk, and resolved to spec mode — and spec capture then dropped every
	# Terraform file the range actually changed. Nothing was reviewed.
	changeset_for_mode_detection=""
	# A range or a PR names its changeset outright. Documents outside it say
	# nothing about what it is, so an empty one stays empty rather than being
	# classified by whatever spec directories happen to be on disk.
	mode_scope_explicit=false
	IFS=',' read -ra mode_filter_paths <<<"${scope_dir:-}"

	if [[ -n "${pr_diff_cache:-}" ]] && [[ -f "${pr_diff_cache:-}" ]]; then
		# Reuse the PR diff fetched in Section 6c
		changeset_for_mode_detection=$(grep '^diff --git' "$pr_diff_cache" |
			sed -E 's|^diff --git a/(.*) b/.*|\1|' || echo "")
		if [[ -n "${scope_dir:-}" ]]; then
			changeset_for_mode_detection=$(rc_filter_to_scope "${mode_filter_paths[@]}" <<<"$changeset_for_mode_detection")
		fi
		mode_scope_explicit=true
	elif [[ "$input_type" == "ref_range" ]]; then
		require_resolvable_range "$input_value"
		changeset_for_mode_detection=$(git diff --name-only "$input_value" -- 2>/dev/null || echo "")
		if [[ -n "${scope_dir:-}" ]]; then
			changeset_for_mode_detection=$(rc_filter_to_scope "${mode_filter_paths[@]}" <<<"$changeset_for_mode_detection")
		fi
		mode_scope_explicit=true
	elif [[ "$input_type" == "all" ]] && ! $rc_no_git; then
		# `--scope all` reviews every tracked and untracked non-ignored file, so
		# that is what it classifies as — not a branch diff that is empty on a
		# clean main.
		changeset_for_mode_detection=$(git ls-files 2>/dev/null || echo "")
		changeset_for_mode_detection+=$'\n'$(git ls-files --others --exclude-standard 2>/dev/null || echo "")
		if [[ -n "${scope_dir:-}" ]]; then
			changeset_for_mode_detection=$(rc_filter_to_scope "${mode_filter_paths[@]}" <<<"$changeset_for_mode_detection")
		fi
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
			elif $rc_no_git; then
				# Outside git a directory reviews every file under it, so that
				# is what it classifies as.
				mode_scope_files=$(rc_walk_files "$mode_scope_path") || rc_walk_incomplete=true
				[[ -n "$mode_scope_files" ]] && changeset_for_mode_detection+="${mode_scope_files}"$'\n'
			else
				# Committed, staged and unstaged changes under the directory: what
				# the changeset builder captures for it. A directory with none
				# contributes only blank lines, which the normalisation after this
				# chain removes.
				changeset_for_mode_detection+=$(git diff --name-only "${base_branch}...HEAD" -- "$mode_scope_path" 2>/dev/null || echo "")$'\n'
				changeset_for_mode_detection+=$(git diff --name-only HEAD -- "$mode_scope_path" 2>/dev/null || echo "")$'\n'
			fi
		done
	elif $rc_no_git; then
		# Outside git `--scope all` reviews the whole tree, so the tree is what
		# it classifies as. A git diff here is always empty, which sent any
		# plain directory holding a specs/ folder to spec mode.
		changeset_for_mode_detection=$(rc_walk_files .) || rc_walk_incomplete=true
	else
		# The branch plus staged and unstaged work: what `--scope changed`
		# captures. Committed-only detection sent a staged code change on a
		# clean branch to the on-disk spec search below.
		changeset_for_mode_detection=$(git diff --name-only "${base_branch}...HEAD" 2>/dev/null || echo "")
		changeset_for_mode_detection+=$'\n'$(git diff --name-only HEAD 2>/dev/null || echo "")
	fi
	# Blank lines are not files. Left in, a scope with no changes is not the
	# empty string: the no-changes branch below is skipped, classification
	# counts zero files of either kind, and the run silently resolves to spec.
	changeset_for_mode_detection=$(sed '/^$/d' <<<"$changeset_for_mode_detection")

	# Check if changeset is empty first
	if [[ -z "$changeset_for_mode_detection" ]] && $mode_scope_explicit; then
		# Code mode's capture reports the empty changeset truthfully; spec mode
		# would report missing spec directories the request never asked about.
		mode="code"
		mode_reason="requested changeset is empty"
	elif [[ -z "$changeset_for_mode_detection" ]]; then
		# Empty changeset - check for spec artifacts to decide mode
		has_specs=false
		for dir in "${spec_default_dirs[@]}"; do
			if [[ -d "$dir" ]] && [[ ${#spec_find_args[@]} -gt 0 ]] &&
				find "${dir/#-/./-}" -type f \( "${spec_find_args[@]}" \) -print -quit 2>/dev/null | grep -q .; then
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
		# Spec capture reads this: a mode chosen from changed files must review
		# those files, not sweep the spec directories as a scopeless run does.
		mode_from_changeset=true
		# Classify files
		spec_files=0
		code_files=0

		while IFS= read -r file; do
			[[ -z "$file" ]] && continue

			if rc_is_spec_path "$file"; then
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
