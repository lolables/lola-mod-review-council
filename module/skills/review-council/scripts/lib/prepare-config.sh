# prepare-config.sh — the configuration the review obeys, and where it came from.
#
# Section 11 of the preparation pipeline, sourced by rc-prepare.sh after
# prepare-changes.sh (it needs the changeset and review_root). Not executable
# on its own.
#
# The rule this file exists to keep: the change under review never configures
# its own review. Inside a git repository the working tree is, in every
# in-place scope, the head of the change — so the "Review Council
# Configuration" block, the Constitution and the project packs are read from a
# base revision the change cannot write, never from disk. This is the model
# `pull_request_target` uses for workflow files. Outside git there is no
# change, only the operator's own files, and the working tree is the source.
#
# What the review obeys is copied into ${session_dir}/review-config/ and
# reviewers read only that copy, so nothing later can reach back into the tree.
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
# under the options it actually runs with. `-e` stays off deliberately; see
# the note in rc-prepare.sh.
set -uo pipefail

# ============================================================================
# SECTION 11: Resolve the configuration source
# ============================================================================

config_kind="none" # rev | worktree | none
config_rev=""
config_how=""
config_failure="" # overrides "<config_how> did not resolve" when set
config_source=""
config_dir="${session_dir}/review-config"
mkdir -p "$config_dir"

# The commit <ref> names, or nothing. Every ref reaches git through this or
# through a sha it returned, and `--end-of-options` keeps one that begins with
# `-` from being read as an option.
rc_config_commit() { # ref
	git rev-parse --verify --quiet --end-of-options "${1}^{commit}" 2>/dev/null || true
}

rc_config_merge_base() { # ref ref
	local a b
	a=$(rc_config_commit "$1")
	b=$(rc_config_commit "$2")
	[[ -n "$a" && -n "$b" ]] || return 0
	git merge-base "$a" "$b" 2>/dev/null || true
}

if $rc_no_git; then
	config_kind="worktree"
	config_source="working tree (no git repository)"
	config_root=$(pwd -P)
else
	case "$input_type" in
	ref_range)
		# `...` before `..`: "a...b" also contains "..". An empty end is HEAD,
		# as it is to git.
		if [[ "$input_value" == *...* ]]; then
			range_a="${input_value%%...*}"
			range_b="${input_value#*...}"
			config_how="merge-base of ${range_a:-HEAD} and ${range_b:-HEAD}"
			config_rev=$(rc_config_merge_base "${range_a:-HEAD}" "${range_b:-HEAD}")
		elif [[ "$input_value" == *..* ]]; then
			range_a="${input_value%%..*}"
			config_how="start of range ${input_value}"
			config_rev=$(rc_config_commit "${range_a:-HEAD}")
		else
			config_how="range base ${input_value}"
			config_rev=$(rc_config_commit "$input_value")
		fi
		;;
	*)
		if [[ "${clone_status:-}" == "in_place" ]]; then
			# The tree is the PR head. Its base is a branch name from the forge;
			# the remote-tracking ref is preferred because the operator's local
			# branch of that name may be anywhere.
			config_how="merge-base of the pull request base and HEAD"
			if [[ -n "${pr_base:-}" ]]; then
				for config_ref in "refs/remotes/origin/${pr_base}" "refs/heads/${pr_base}"; do
					config_rev=$(rc_config_merge_base "$config_ref" HEAD)
					if [[ -n "$config_rev" ]]; then
						config_how="merge-base of ${config_ref#refs/*/} and HEAD"
						break
					fi
				done
			fi
		else
			# Every other scope inside git: changed, all, paths, and a PR or url
			# materialised elsewhere (the working tree is then the invoking
			# repository, and may itself be a contributor's checkout). Section 4
			# leaves base_branch empty for url scope, so main/master is found here.
			config_base="${base_branch:-}"
			if [[ -z "$config_base" ]]; then
				for config_ref in main master; do
					config_probe=$(rc_config_commit "$config_ref")
					if [[ -n "$config_probe" ]]; then
						config_base="$config_ref"
						break
					fi
				done
			fi
			if [[ -n "$config_base" ]]; then
				config_how="merge-base of ${config_base} and HEAD"
			else
				config_how="merge-base of main and HEAD"
				config_failure="no main or master branch"
			fi
			[[ -n "$config_base" ]] && config_rev=$(rc_config_merge_base "$config_base" HEAD)
		fi
		;;
	esac

	if [[ -n "$config_rev" ]]; then
		config_kind="rev"
		config_source="${config_rev:0:12} (${config_how})"
	else
		config_source="none (${config_failure:-${config_how} did not resolve})"
		# A shallow clone is the usual reason a real base is missing; say so on
		# stderr only, since tracking.md records what was decided, not advice.
		config_hint=""
		config_shallow=$(git rev-parse --is-shallow-repository 2>/dev/null) || config_shallow=""
		if [[ "$config_shallow" == "true" ]]; then
			config_hint=" (shallow clone: fetch the base branch history)"
		fi
		echo "rc-prepare: no base revision for the review configuration (${config_failure:-${config_how} did not resolve}); using built-in defaults${config_hint}" >&2
	fi
fi

# Content of <path> at the configuration source, on stdout. Fails, printing
# nothing, when the path is absent there or is not a regular file. A symlink is
# refused at a revision (mode 120000) and on disk alike: following one reads a
# file the source does not contain. On disk, a regular file reached through a
# symlinked directory is refused too, by its physical location.
#
# <path> is relative to the directory the review runs from, as it was when this
# read the disk. Git resolves that itself: an `ls-tree` pathspec and a
# `rev:./path` object name are both taken relative to the current directory,
# and tolerate a leading `./`, so no repository-root prefix is computed.
# `ls-tree` also honours pathspec magic (`:(top)x`, globs) that `rev:path`
# does not, so the mode check could vouch for a different path than the one
# read; `--literal-pathspecs` makes both mean the same path.
rc_config_read() { # path relative to the review's directory
	local path="$1" mode oid entry dir_abs
	case "$config_kind" in
	rev)
		# The object that will be read, and the one entry `ls-tree` reports for
		# the same path, must be one and the same. A directory path (`.`,
		# `docs/`) makes `ls-tree` list its children, whose regular-file mode
		# would otherwise vouch for the tree that `cat-file` then prints.
		oid=$(git rev-parse --verify --quiet "${config_rev}:./${path#./}" 2>/dev/null) || return 1
		entry=$(git --literal-pathspecs ls-tree "$config_rev" -- "$path" 2>/dev/null) || return 1
		# `<mode> SP <type> SP <oid> TAB <path>`: past the first two fields the
		# entry starts with the oid.
		[[ "$entry" != *$'\n'* && "${entry#* * }" == "${oid}"$'\t'* ]] || return 1
		mode="${entry%% *}"
		[[ "$mode" == 100644 || "$mode" == 100755 ]] || return 1
		git cat-file blob "$oid" 2>/dev/null
		;;
	worktree)
		[[ -f "$path" && ! -L "$path" ]] || return 1
		dir_abs=$(CDPATH='' cd -- "$(dirname -- "$path")" 2>/dev/null && pwd -P) || return 1
		[[ "$dir_abs" == "$config_root" || "$dir_abs" == "$config_root"/* ]] || return 1
		cat -- "$path"
		;;
	*) return 1 ;;
	esac
}

# The body of the "## Review Council Configuration" section on stdin, without
# its heading and without the heading that ends it.
rc_config_block() {
	sed -n '/^## Review Council Configuration$/,/^## /{/^## Review Council Configuration$/d;/^## /d;p;}'
}

# Both AGENTS.md and CLAUDE.md may carry the block. They are concatenated in
# that order and then read key by key, so a key defined in both resolves to the
# AGENTS.md value.
rc_config_section=""
for config_file in AGENTS.md CLAUDE.md; do
	config_text=$(rc_config_read "$config_file") || continue
	rc_config_section+=$(rc_config_block <<<"$config_text")$'\n'
done

# First value for <key> in the collected block, trimmed. Anchored at the start
# of the line, matching rc_parse_kv, so prose that happens to mention a key name
# mid-sentence cannot be read as configuration.
rc_config_value() { # key
	printf '%s\n' "$rc_config_section" |
		grep -m1 -E "^[-[:space:]]*${1}:" 2>/dev/null |
		sed -E "s/^[-[:space:]]*${1}:[[:space:]]*//" |
		sed -E 's/[[:space:]]+$//' || true
}

# --- Constitution ---
#
# The guard treats the file this names as governing, so it is confined to the
# repository: an absolute path or a `..` segment is refused outright rather
# than resolved, and the reader refuses symlinks. A refusal is reported and
# recorded, never silently dropped — "no constitution" and "a constitution
# that was refused" are different facts about the review. The accepted file is
# copied into the session; reviewers read the copy.
constitution="none"
constitution_source=""
constitution_value=$(rc_config_value "Constitution")
constitution_value=$(rc_single_line "$constitution_value")
if [[ -n "$constitution_value" ]]; then
	constitution_refusal=""
	constitution_path="${constitution_value#./}"
	if [[ "$constitution_value" == /* ]]; then
		constitution_refusal="'${constitution_value}' is absolute; give a path inside the repository"
	elif [[ "$constitution_path" == /* || "$constitution_path" == *//* || "$constitution_path" == */ ]]; then
		# `.//x` loses its `./` and would be read as `/x`, an absolute path on
		# disk outside git. `a//b` and `a/` name the same file as their clean
		# forms to the filesystem but not to every reader, so no empty segment
		# is accepted.
		constitution_refusal="'${constitution_value}' has an empty path segment; give a path inside the repository"
	elif [[ "/${constitution_path}/" == */../* ]]; then
		constitution_refusal="'${constitution_value}' has a '..' segment; give a path inside the repository"
	elif ! rc_config_read "$constitution_path" >"${config_dir}/constitution.md"; then
		constitution_refusal="'${constitution_value}' is not a regular file at ${config_source}"
	fi
	if [[ -n "$constitution_refusal" ]]; then
		rm -f "${config_dir}/constitution.md"
		constitution_source="refused: ${constitution_refusal}"
		echo "rc-prepare: Constitution refused: ${constitution_refusal}" >&2
	else
		constitution="${config_dir}/constitution.md"
		constitution_source="explicit: ${constitution_value}"
	fi
fi

# --- Project packs ---
#
# `.review-council/packs/*.md` at the source, copied into the session. Only
# regular files directly in that directory, with a name that is safe to write
# into the session, are taken; anything else is reported and skipped.
project_pack_count=0
mkdir -p "${config_dir}/packs"
# NUL-separated entries. At a revision `ls-tree` prints each as the
# cwd-relative path it was given plus the name; the loop below takes the
# basename, so the prefix does not matter.
rc_config_pack_paths() {
	local f
	case "$config_kind" in
	rev)
		git --literal-pathspecs ls-tree -z --name-only "$config_rev" -- .review-council/packs/ 2>/dev/null || true
		;;
	worktree)
		for f in .review-council/packs/*.md; do
			[[ -e "$f" || -L "$f" ]] && printf '%s\0' "$f"
		done
		;;
	*) ;;
	esac
}
while IFS= read -r -d '' pack_path; do
	pack_name="${pack_path##*/}"
	[[ "$pack_name" == *.md ]] || continue
	if [[ ! "$pack_name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*\.md$ ]]; then
		echo "rc-prepare: project pack '${pack_name}' skipped: name is not [A-Za-z0-9._-]" >&2
		continue
	fi
	if rc_config_read ".review-council/packs/${pack_name}" >"${config_dir}/packs/${pack_name}"; then
		project_pack_count=$((project_pack_count + 1))
	else
		rm -f "${config_dir}/packs/${pack_name}"
		echo "rc-prepare: project pack '${pack_name}' skipped: not a regular file at ${config_source}" >&2
	fi
done < <(rc_config_pack_paths || true)
if ((project_pack_count > 0)); then
	project_packs="${config_dir}/packs (${project_pack_count})"
else
	rmdir "${config_dir}/packs" 2>/dev/null || true
	project_packs="none"
fi

# --- Integrations the orchestrator and reviewers act on ---
#
# Carried through tracking.md so no reviewer reads them out of a context file
# the change may have written. Single-lined: tracking.md is read first match
# wins, so a value must not carry a line of its own.
docs_repo=$(rc_config_value "Docs repo")
docs_repo=$(rc_single_line "$docs_repo")
[[ -n "$docs_repo" ]] || docs_repo="none"
knowledge_tool=$(rc_config_value "Knowledge tool")
knowledge_tool=$(rc_single_line "$knowledge_tool")
[[ -n "$knowledge_tool" ]] || knowledge_tool="none"

# --- Comment size policy ---
#
# `Comment limit` is the forge's per-comment character cap. It is normally
# supplied by the per-forge post script and needs configuring only when the
# effective limit is smaller than the forge's own — self-hosted GitLab, or GHE
# behind a proxy that truncates bodies. `Max comments` is policy, not a fact
# about the API: it is how many comments the council may spend on one verdict.
#
# Both are validated here rather than at the point of use. A value that is not a
# positive integer is dropped, not clamped: a typo that silently became "1" would
# change what gets posted while reading as if it had been honoured.
comment_limit=$(rc_config_value "Comment limit")
[[ "$comment_limit" =~ ^[1-9][0-9]*$ ]] || comment_limit=""
max_comments=$(rc_config_value "Max comments")
[[ "$max_comments" =~ ^[1-9][0-9]*$ ]] || max_comments="$RC_DEFAULT_MAX_COMMENTS"

# --- Delegation batching budgets ---
#
# What a single delegation round may carry: diff bytes first, file count as the
# cap that bytes cannot express. Resolved here and carried into tracking.md
# because rc-plan-batches.sh runs as a later stage in a different process, the
# same route `Comment limit` takes to rc-render-comment.sh. The defaults live in
# rc-lib.sh, where the planner reads them too.
#
# Validated the same way as the two above, and dropped rather than clamped for
# the same reason: a `Batch size: 0` read as 1 would dispatch a reviewer per
# file, at council-sized cost, while reading as though it had been honoured.
batch_bytes=$(rc_config_value "Batch bytes")
[[ "$batch_bytes" =~ ^[1-9][0-9]*$ ]] || batch_bytes="$RC_DEFAULT_BATCH_BYTES"
batch_size=$(rc_config_value "Batch size")
[[ "$batch_size" =~ ^[1-9][0-9]*$ ]] || batch_size="$RC_DEFAULT_BATCH_FILES"

# --- Council-shaping policy ---
#
# Read here and carried into tracking.md, because rc-select-council.sh and
# rc-apply-triage.sh run as later stages in different processes and this block
# is the only place the project's configuration is parsed. Same route
# `Comment limit` takes to rc-render-comment.sh.
#
# Values are resolved but not interpreted: what a change shape licenses
# dropping, and what a triage matrix may narrow, belong to those two scripts,
# and duplicating any part of either rule here would give it two homes.

# An on/off switch across four layers, in this order:
#
#   1. the CLI flag      — this run, stated explicitly, outranks everything
#   2. the environment   — this shell or this CI job
#   3. the config block  — this project's standing preference
#   4. the built-in      — what the module does when nobody has said anything
#
# An unusable value at any layer is reported and skipped rather than treated as
# "off": a typo that silently disabled a reviewer-selection policy would change
# what gets reviewed while reading as though the configuration had been
# honoured, which is the same failure `Max comments` guards against by dropping
# a non-numeric value instead of clamping it.
rc_resolve_switch() { # cli_value env_name config_key default
	local cli="$1" env_name="$2" key="$3" default="$4"
	local env_value="${!env_name:-}" config_value candidate
	config_value=$(rc_config_value "$key")
	for candidate in "$cli" "$env_value" "$config_value"; do
		candidate="${candidate,,}"
		case "$candidate" in
		on | off)
			printf '%s' "$candidate"
			return 0
			;;
		"") ;;
		*)
			echo "rc-prepare: ignoring '${candidate}' for ${key} (expected on or off)" >&2
			;;
		esac
	done
	printf '%s' "$default"
}

persona_selection=$(rc_resolve_switch "${persona_selection_cli:-}" \
	REVIEW_COUNCIL_PERSONA_SELECTION "Persona selection" "on")

# Triage defaults OFF. It trades recall for cost on the strength of a cheap
# model's judgement, and unlike change-shape selection it has no measured recall
# behind it yet — `.lola-eval/tests/case-026-triage-recall/` is the case that
# would justify flipping this, and it has not been run. Shipping it on by
# default would put an unmeasured recall risk in the default path of the one
# mode people reach for when they most want thoroughness.
subsystem_triage=$(rc_resolve_switch "${triage_cli:-}" \
	REVIEW_COUNCIL_TRIAGE "Subsystem triage" "off")

# Persona base names that must never be deselected, comma- or space-separated.
# Normalised to a comma-joined lowercase list, with anything that cannot be a
# persona base name dropped — the selector reports a name that matches no
# discovered reviewer, which it can do and this cannot, having no roster yet.
pin_personas=$(rc_config_value "Pin personas")
if [[ -n "$pin_personas" ]]; then
	pin_personas=$(printf '%s' "${pin_personas,,}" | tr ',' ' ' | tr -s '[:space:]' '\n' |
		grep -E '^[a-z][a-z0-9-]*$' | paste -sd ',' - || true)
fi
[[ -n "$pin_personas" ]] || pin_personas="none"
