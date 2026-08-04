# prepare-changes.sh — changeset capture, language and framework detection, constitution.
#
# Sections 9-11 of the preparation pipeline, sourced by rc-prepare.sh in order.
# Not executable on its own: these are straight-line statements over the
# globals the caller and the earlier fragments set, exactly as they were
# when this was one 1,400-line file. An `exit` on a skip path still ends
# the whole program, because `source` runs in the same shell.
#
# The diff itself, and everything derived from reading its contents.
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
# SECTION 9: Capture Changeset and Diff
# ============================================================================

changeset_files=""
diff_content=""
has_diff=false

if [[ "$mode" == "code" ]]; then
	if [[ "$input_type" == "all" ]]; then
		# All non-ignored project files
		all_files=$(git ls-files 2>/dev/null || echo "")
		all_files+=$'\n'$(git ls-files --others --exclude-standard 2>/dev/null || echo "")

		# Apply smart exclusions
		filtered_files=""
		while IFS= read -r file; do
			[[ -z "$file" ]] && continue
			excluded=false
			for pattern in "${SMART_EXCLUDES[@]}"; do
				if [[ "$pattern" == */ ]]; then
					# Directory pattern
					if [[ "$file" == "$pattern"* ]] || [[ "$file" == *"/$pattern"* ]]; then
						excluded=true
						break
					fi
				else
					# File pattern (exact basename match)
					if [[ "$(basename "$file")" == "$pattern" ]]; then
						excluded=true
						break
					fi
				fi
			done
			$excluded || filtered_files+="${file}"$'\n'
		done <<<"$all_files"

		# Filter out binary files by rejecting the types that cannot be read,
		# rather than by admitting text/* only. `file` reports JSON as
		# application/json and, on some builds, shell scripts as
		# application/x-shellscript, so an allow-list drops reviewable source.
		# Where `file` is absent the candidate is admitted: an extra file in the
		# changeset costs a reviewer some attention, while rejecting the whole
		# changeset reports "no changes to review" for input never inspected.
		changeset_files=""
		while IFS= read -r file; do
			[[ -z "$file" ]] && continue
			[[ -f "$file" ]] || continue
			mime_type=""
			if [[ "$_RC_HAVE_FILE" == "yes" ]]; then
				# `--` guards paths that begin with a dash from being read as flags.
				mime_type=$(file --brief --mime-type -- "$file" 2>/dev/null || echo "")
			fi
			# PIE is the default link mode for current gcc and clang, so
			# x-pie-executable is the ordinary executable and x-executable the
			# outlier — both have to be named. `file` does not follow symlinks,
			# so a link to a blob arrives as inode/symlink, never as its
			# target's type. SQLite is x-sqlite3 on older builds and vnd.sqlite3
			# on newer ones.
			case "$mime_type" in
			image/* | audio/* | video/* | font/* | \
				application/pdf | application/zip | application/gzip | \
				application/x-bzip2 | application/x-xz | application/x-tar | \
				application/x-archive | application/octet-stream | application/wasm | \
				application/x-executable | application/x-pie-executable | \
				application/x-sharedlib | application/x-object | \
				application/x-mach-binary | application/x-dosexec | \
				application/x-sqlite3 | application/vnd.* | inode/symlink)
				continue
				;;
			*)
				# Text, JSON, scripts, and anything `file` could not name.
				;;
			esac
			changeset_files+="${file}"$'\n'
		done <<<"$filtered_files"

		diff_content=""
		has_diff=false
	elif [[ -f "${session_dir}/pr-metadata.txt" ]] && [[ "$forge_tool" != "none" ]]; then
		# Reuse cached PR diff from Section 7
		if [[ -n "${pr_diff_cache:-}" ]] && [[ -f "${pr_diff_cache:-}" ]]; then
			diff_content=$(cat "$pr_diff_cache")
		else
			diff_content=""
		fi
		changeset_files=$(echo "$diff_content" | grep '^diff --git' | sed -E 's|^diff --git a/(.*) b/.*|\1|' || echo "")
		has_diff=true
	elif [[ "$input_type" == "ref_range" ]]; then
		require_resolvable_range "$input_value"
		changeset_files=$(git diff --name-only "$input_value" -- 2>/dev/null || echo "")
		diff_content=$(git diff "$input_value" -- 2>/dev/null || echo "")
		has_diff=true
	else
		# Local repo: base...HEAD + uncommitted (input_type == "auto" with code mode)
		if [[ -n "$scope_dir" ]]; then
			changeset_files=$(git diff --name-only "${base_branch}...HEAD" -- "$scope_dir" 2>/dev/null || echo "")
			changeset_files+=$'\n'$(git diff --name-only -- "$scope_dir" 2>/dev/null || echo "")
			diff_content=$(git diff "${base_branch}...HEAD" -- "$scope_dir" 2>/dev/null || echo "")
			diff_content+=$'\n'$(git diff -- "$scope_dir" 2>/dev/null || echo "")
		else
			changeset_files=$(git diff --name-only "${base_branch}...HEAD" 2>/dev/null || echo "")
			changeset_files+=$'\n'$(git diff --name-only 2>/dev/null || echo "")
			diff_content=$(git diff "${base_branch}...HEAD" 2>/dev/null || echo "")
			diff_content+=$'\n'$(git diff 2>/dev/null || echo "")
		fi
		has_diff=true
	fi

	# Apply secondary path filter if present
	if [[ -n "$scope_dir" ]] && [[ "$input_type" != "dir_scope" ]] && [[ "$input_type" != "auto" ]]; then
		# Filter changeset to paths under scope_dir
		filtered=""
		IFS=',' read -ra filter_paths <<<"$scope_dir"
		while IFS= read -r file; do
			[[ -z "$file" ]] && continue
			for fp in "${filter_paths[@]}"; do
				fp="${fp%/}" # Remove trailing slash
				if [[ "$file" == "$fp"* ]] || [[ "$file" == "$fp/"* ]]; then
					filtered+="${file}"$'\n'
					break
				fi
			done
		done <<<"$changeset_files"
		changeset_files="$filtered"

		# Filter diff too if present
		if [[ "$has_diff" == true ]] && [[ -n "$diff_content" ]]; then
			# Re-generate diff for filtered paths only
			if [[ "$input_type" == "ref_range" ]]; then
				IFS=',' read -ra filter_paths <<<"$scope_dir"
				diff_content=$(git diff "$input_value" -- "${filter_paths[@]}" 2>/dev/null || echo "")
			fi
		fi
	fi

	# Remove empty lines and duplicates
	changeset_files=$(echo "$changeset_files" | grep -v '^$' | sort -u || echo "")

	if [[ -z "$changeset_files" ]]; then
		json_output "empty" "No changes to review. Changeset is empty."
		exit 0
	fi

	echo "$changeset_files" >"${session_dir}/changeset.txt"
	if [[ "$has_diff" == true ]]; then
		echo "$diff_content" >"${session_dir}/diff.patch"
	else
		: >"${session_dir}/diff.patch"
	fi
else
	# Spec mode
	#
	# What counts as a spec is defined once, here, and read by all four
	# discovery branches below. It used to be written out four times, and the
	# copies had already diverged in effect: the branch handling `--scope paths`
	# carried the same `.md`/`.txt` filter as the default sweep, so the recovery
	# the skill suggests when the sweep comes up empty ("re-run pointing at your
	# spec directory") found nothing either. Pointing discovery straight at 142
	# `.mdx` files still reported no spec artifacts.
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

	# The same set as an anchored ERE, for the two branches that filter a list
	# of changed paths rather than walking the tree. Built from the same array
	# so the two forms cannot drift.
	spec_ext_re=$(
		IFS='|'
		printf '%s' "${spec_exts[*]}"
	)
	spec_dir_re=$(
		IFS='|'
		printf '%s' "${spec_default_dirs[*]}"
	)

	# Collect every spec file under a directory into changeset_files.
	collect_specs_in() {
		local dir="${1%/}" file
		[[ -d "$dir" ]] || return 0
		[[ ${#spec_find_args[@]} -gt 0 ]] || return 0
		while IFS= read -r file; do
			[[ -f "$file" ]] && changeset_files+="${file}"$'\n'
		done < <(find "$dir" -type f \( "${spec_find_args[@]}" \) 2>/dev/null || true)
		return 0
	}

	# The path filter is tested first because it binds tighter than the base
	# scope: `--scope all --scope paths --scope-value X` means "every spec, but
	# only under X". Testing the default sweep first would answer the base scope
	# alone and silently discard the directories the user actually named.
	if [[ -n "$scope_dir" ]] || [[ "$input_type" == "dir_scope" ]]; then
		# Scan specified directories for spec files
		IFS=',' read -ra spec_dirs <<<"${scope_dir:-$input_value}"
		for dir in "${spec_dirs[@]}"; do
			collect_specs_in "$dir"
		done
	elif [[ "$input_type" == "all" ]] || [[ -z "$scope_type" ]] || [[ "$scope_type" == "all" ]]; then
		# Scan common spec locations
		for dir in "${spec_default_dirs[@]}"; do
			collect_specs_in "$dir"
		done
	elif [[ "$input_type" == "ref_range" ]] || [[ "$input_type" == "auto" ]]; then
		# Changed spec files only
		local_range="${input_value:-${base_branch}...HEAD}"
		require_resolvable_range "$local_range"
		changed=$(git diff --name-only "$local_range" -- 2>/dev/null || echo "")
		while IFS= read -r file; do
			[[ -z "$file" ]] && continue
			if [[ "$file" =~ \.(${spec_ext_re})$ ]] && [[ "$file" =~ ^(${spec_dir_re})/ ]]; then
				changeset_files+="${file}"$'\n'
			fi
		done <<<"$changed"
		diff_content=$(git diff "$local_range" -- 2>/dev/null || echo "")
		has_diff=true
	elif [[ -f "${session_dir}/pr-metadata.txt" ]] && [[ "$forge_tool" != "none" ]]; then
		# PR-based spec review
		if [[ -n "${pr_diff_cache:-}" ]] && [[ -f "${pr_diff_cache:-}" ]]; then
			pr_files=$(grep '^diff --git' "$pr_diff_cache" | sed -E 's|^diff --git a/(.*) b/.*|\1|' || echo "")
			while IFS= read -r file; do
				[[ -z "$file" ]] && continue
				if [[ "$file" =~ \.(${spec_ext_re})$ ]] && [[ "$file" =~ ^(${spec_dir_re})/ ]]; then
					changeset_files+="${file}"$'\n'
				fi
			done <<<"$pr_files"
			diff_content=$(cat "$pr_diff_cache")
			has_diff=true
		fi
	fi

	changeset_files=$(echo "$changeset_files" | grep -v '^$' | sort -u || echo "")

	if [[ -z "$changeset_files" ]]; then
		# Name what was searched. "No spec artifacts found to review." on its own
		# leaves a user with no way to tell an empty repository from a layout
		# this never looks at, short of reading the source — which is exactly
		# the position a `docs/specification/` project was in.
		json_output "empty" "No spec artifacts found to review. Searched ${spec_default_dirs[*]} for *.${spec_exts[*]// /, *.} files. Point the review at your layout with --scope paths <dir>, or set REVIEW_COUNCIL_SPEC_DIRS / REVIEW_COUNCIL_SPEC_EXTS."
		exit 0
	fi

	echo "$changeset_files" >"${session_dir}/changeset.txt"
	if [[ "$has_diff" == true ]]; then
		echo "$diff_content" >"${session_dir}/diff.patch"
	fi
fi

# Clean up cached PR diff
rm -f "${pr_diff_cache:-}" 2>/dev/null

# ============================================================================
# SECTION 10: Detect Language and Framework
# ============================================================================

language="unknown"
framework="unknown"

# Count file extensions.
#
# Only extensions the language mapping below can resolve are counted, and family
# members are folded into one bucket before the tally. Counting every extension
# let three CI YAMLs outvote two Go files, and split `ts` against `tsx`; either
# way the plurality could resolve to `unknown`, which loads the empty base.md and
# silently discards the language pack -- including its Calibration Notes, which
# suppress that language's known false positives.
declare -A ext_count
while IFS= read -r file; do
	[[ -z "$file" ]] && continue
	ext="${file##*.}"
	[[ "$ext" == "$file" ]] && continue # No extension
	case "$ext" in
	go) bucket="go" ;;
	ts | tsx) bucket="typescript" ;;
	js | jsx) bucket="javascript" ;;
	py) bucket="python" ;;
	rs) bucket="rust" ;;
	java) bucket="java" ;;
	*) continue ;; # No convention pack or detection hints key off this extension.
	esac
	ext_count[$bucket]=$((${ext_count[$bucket]:-0} + 1))
done <<<"$changeset_files"

# Determine language (sort by count descending, then bucket alphabetically for deterministic tie-breaking)
max_count=0
max_bucket=""
for bucket in $(for k in "${!ext_count[@]}"; do echo "${ext_count[$k]} $k"; done | sort -k1,1rn -k2,2 | awk '{print $2}'); do
	count=${ext_count[$bucket]}
	if [[ $count -gt $max_count ]]; then
		max_count=$count
		max_bucket="$bucket"
	fi
done

if [[ -n "$max_bucket" ]]; then
	language="$max_bucket"
fi

# Detect framework
#
# These probes read file CONTENT/existence off disk, so they must resolve
# against review_root (the materialized clone in PR/url scope), not CWD
# (the launch dir, which is unrelated to the repo under review in that
# scope). $changeset_files stays as-is -- it's the diff's file list, not a
# disk read.
if echo "$changeset_files" | grep -q "package.json"; then
	if [[ -f "${review_root}/package.json" ]]; then
		if grep -q '"react"' "${review_root}/package.json" 2>/dev/null; then
			framework="react"
		elif grep -q '"vue"' "${review_root}/package.json" 2>/dev/null; then
			framework="vue"
		elif grep -q '"angular"' "${review_root}/package.json" 2>/dev/null; then
			framework="angular"
		fi
	fi
elif echo "$changeset_files" | grep -q "go.mod"; then
	framework="go-module"
	[[ -f "${review_root}/go.mod" ]] && grep -q "github.com/gin-gonic/gin" "${review_root}/go.mod" 2>/dev/null && framework="gin"
	[[ -f "${review_root}/go.mod" ]] && grep -q "github.com/labstack/echo" "${review_root}/go.mod" 2>/dev/null && framework="echo"
elif echo "$changeset_files" | grep -q "Cargo.toml"; then
	framework="rust-cargo"
elif echo "$changeset_files" | grep -qE "pyproject\.toml|setup\.py"; then
	framework="python"
	if echo "$changeset_files" | grep -q "requirements.txt"; then
		if [[ -f "${review_root}/requirements.txt" ]]; then
			grep -q "flask" "${review_root}/requirements.txt" 2>/dev/null && framework="flask"
			grep -q "django" "${review_root}/requirements.txt" 2>/dev/null && framework="django"
		fi
	fi
fi

[[ "$framework" == "unknown" ]] && framework="none"

# ============================================================================
# SECTION 11: Resolve Constitution
# ============================================================================

constitution="none"
constitution_source=""

# Check AGENTS.md and CLAUDE.md for Review Council Configuration
for config_file in AGENTS.md CLAUDE.md; do
	if [[ -f "$config_file" ]]; then
		rc_config_section=$(sed -n '/^## Review Council Configuration$/,/^## /{/^## Review Council Configuration$/d;/^## /d;p}' "$config_file" 2>/dev/null)
		if echo "$rc_config_section" | grep -q "Constitution:"; then
			constitution=$(echo "$rc_config_section" | grep "Constitution:" | sed 's/.*Constitution: *//' | head -n1)
			constitution_source="explicit"
			break
		fi
	fi
done

# No fallback auto-discovery. If no explicit Constitution is configured,
# constitution stays "none" and reviewers skip constitution-specific checks.
