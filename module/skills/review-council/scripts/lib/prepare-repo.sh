# prepare-repo.sh — repository, forge, tooling, base branch, session directory.
#
# Sections 1-5 of the preparation pipeline, sourced by rc-prepare.sh in order.
# Not executable on its own: these are straight-line statements over the
# globals the caller and the earlier fragments set, exactly as they were
# when this was one 1,400-line file. An `exit` on a skip path still ends
# the whole program, because `source` runs in the same shell.
#
# Everything settled before the target is known: whether this is a git repo
# at all, which forge it belongs to, what CLI can talk to that forge, what
# the diff is against, and where the session lives.
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
# SECTION 1: Verify Git Repository
# ============================================================================

# URL scope is forge-materialized: the target repo is fully specified by the
# URL and cloned separately by rc-clone-target.sh (Section 6b) — the launch
# directory plays no part, so it need not be a git repo. PR-number scope, by
# contrast, still derives forge_owner/forge_repo from the *local* git remote
# (Section 2, the `else` branch below) and so still requires a local checkout.
if [[ "$input_type" != "url" ]] && ! git rev-parse --git-dir >/dev/null 2>&1; then
	# Only `--scope url` genuinely bypasses this gate. `--scope pr` does not:
	# it still derives forge_owner/forge_repo from the local git remote (see
	# the comment above), so naming it here would send the user straight back
	# into this same refusal.
	json_output "skip" "Not a git repository. Use --scope url to review a pull request without a local checkout, or run 'git init' first."
	exit 0
fi

# Abort unless <range> resolves. `git diff` on an unresolvable ref is fatal,
# and swallowing that into an empty changeset reports "no changes to review"
# for input that was never compared at all — a clean review of nothing, in the
# one direction a review tool must never be wrong. A repository holding a
# single root commit has no `HEAD~1`, so `HEAD~1..HEAD` lands here.
# Both the code-mode and spec-mode changeset builders call this before
# diffing; keeping it in one place stops the two paths from drifting.
require_resolvable_range() { # range
	git diff --name-only "$1" -- >/dev/null 2>&1 && return 0
	json_output "skip" "Cannot resolve ref range '$1'. Check that both endpoints exist (a repository with a single root commit has no HEAD~1)."
	exit 0
}

# ============================================================================
# SECTION 2: Detect Forge
# ============================================================================

forge="local"
forge_owner=""
forge_repo=""

if [[ "$input_type" == "url" ]]; then
	parse_remote "$input_value"
	# The same exact-host rule the local-remote branch below applies, and the
	# reachable half of it: `--scope url` is a user-facing entry point, and the
	# host it names goes straight into `gh api repos/OWNER/REPO/...`. Read
	# `mygithub.com` or `github.company.com` as `github.com` and the review asks
	# an unrelated service for a pull request, then reviews whatever it answers
	# with.
	pr_path_segment=""
	case "${rc_remote_host,,}" in
	github.com)
		forge="github"
		pr_path_segment="pull"
		;;
	gitlab.com)
		forge="gitlab"
		pr_path_segment="merge_requests"
		;;
	*) ;;
	esac

	# An unrecognized host is terminal HERE, unlike on the local-remote branch
	# below, where degrading to `forge=local` is the right answer (a checkout
	# whose remote is a GHES install is still a reviewable checkout). Under
	# `--scope url` the user named a pull request and nothing else, so there is
	# no second thing to review. Falling through produced an empty changeset and
	# `status: empty` — true, and misleading in the one direction a review tool
	# must never be wrong: SKILL.md routes a non-terminal `--scope url` outcome
	# into "re-run with --scope all", which returns a full council review of the
	# local checkout as the answer about a PR that was never fetched. `skip` is
	# terminal by SKILL.md's own definition: report the message and stop.
	if [[ "$forge" == "local" ]]; then
		json_output "skip" "Unsupported forge host '${rc_remote_host:-unparsable}' in '${scope_value}'. --scope url can fetch a pull request from github.com or gitlab.com only; a GitHub Enterprise or other self-hosted install is not a supported forge."
		exit 0
	fi

	# Owner/repo come from the URL's own path, which parse_remote does not
	# reduce — a PR URL carries more segments than the two it can express, so it
	# reports the host and stops.
	case "$forge" in
	github)
		# GitHub has no subgroups: the project path is exactly OWNER/REPO.
		if [[ "$input_value" =~ ^[a-zA-Z][a-zA-Z0-9+.-]*://[^/]+/([^/]+)/([^/]+)/ ]]; then
			forge_owner="${BASH_REMATCH[1]}"
			forge_repo="${BASH_REMATCH[2]}"
		fi
		;;
	gitlab)
		# GitLab nests projects under arbitrarily deep subgroups, so the first
		# two path segments are not owner/repo — and taking them anyway passed
		# the character-class guard below, silently naming a *different*
		# project. project_id is a hash of "${forge_owner}/${forge_repo}" and
		# keys the learnings/prior-reviews cache, so every project under
		# gitlab.com/group/subgroup/ collided into one cache entry and a review
		# of one could surface prior findings recorded against a sibling.
		# GitLab emits the `/-/` route separator precisely to disambiguate the
		# project path from the route that follows it: everything before it is
		# the project path, whose last segment is the repo and whose remainder
		# is the owner.
		if [[ "$input_value" =~ ^[a-zA-Z][a-zA-Z0-9+.-]*://[^/]+/(.+)/-/merge_requests/[0-9]+ ]]; then
			gitlab_project_path="${BASH_REMATCH[1]}"
			# A GitLab project always sits in a namespace, so a single-segment
			# path is malformed; leaving the pair blank rejects it below.
			if [[ "$gitlab_project_path" == */* ]]; then
				forge_owner="${gitlab_project_path%/*}"
				forge_repo="${gitlab_project_path##*/}"
			fi
		fi
		;;
	# Unreachable while the host case above recognises exactly these two: any
	# other value has already exited with `skip`. A third forge added there
	# without a project-path rule here leaves the pair blank, which the
	# validator below then rejects — a degrade, never a guessed project.
	*) ;;
	esac

	# Validate every path segment on its own. The character class alone admits
	# `.` and `..`, and forge_owner may now legitimately carry `/` (a GitLab
	# subgroup), so checking the pair as two flat strings would let a traversal
	# segment through. This is a security control, not a tidiness check:
	# build_repo_flag's output is expanded UNQUOTED at four `gh` call sites, so
	# a segment carrying whitespace or a shell metacharacter would land as extra
	# argv words.
	url_path_ok=true
	if [[ -z "$forge_owner" ]] || [[ -z "$forge_repo" ]]; then
		url_path_ok=false
	else
		IFS='/' read -r -a url_path_segments <<<"${forge_owner}/${forge_repo}"
		for url_path_segment in "${url_path_segments[@]}"; do
			if [[ ! "$url_path_segment" =~ ^[a-zA-Z0-9._-]+$ ]] ||
				[[ "$url_path_segment" == "." ]] || [[ "$url_path_segment" == ".." ]]; then
				url_path_ok=false
				break
			fi
		done
	fi
	if [[ "$url_path_ok" != true ]]; then
		forge_owner=""
		forge_repo=""
		# Only the github paths consume owner/repo (build_repo_flag, the gh api
		# paths, the clone URL), so blanking them is the whole remedy on gitlab
		# — glab is invoked with no --repo and project_id falls back to hashing
		# $PWD. On github, blank owner/repo cannot address a PR at all, so the
		# forge degrades with them, exactly as the local-remote branch does.
		if [[ "$forge" == "github" ]]; then
			forge="local"
		fi
	fi

	# Extract the PR/MR number from the URL
	input_value=$(echo "$input_value" | sed -E "s|.*/${pr_path_segment}/([0-9]+).*|\1|")
else
	remote_url=$(git remote get-url origin 2>/dev/null || echo "")
	parse_remote "$remote_url"
	# The whole host, never a substring of it: `mygithub.com` contains
	# `github.com` outright, and matching it with an unescaped dot makes
	# `github.company.com` a hit too (`github` + any char + `com`). Either one
	# would aim `gh api repos/OWNER/REPO/...` calls and a constructed
	# https://github.com/OWNER/REPO.git clone URL at an unrelated service.
	case "${rc_remote_host,,}" in
	github.com) forge="github" ;;
	gitlab.com) forge="gitlab" ;;
	# An unrecognized host stays `local` on purpose, a GitHub Enterprise
	# install (github.example.com) included: that is a safe degrade, not an
	# oversight to repair by loosening the match. `gh` resolves OWNER/REPO
	# against its own default host, so reaching an enterprise install means
	# handling GH_HOST / `gh auth login --hostname` — a feature, not a
	# hostname pattern.
	*) ;;
	esac
	if [[ "$forge" != "local" ]]; then
		forge_owner="$rc_remote_owner"
		forge_repo="$rc_remote_repo"
		# Same character-class guard the URL branch applies. A remote that parses
		# to something unsafe — or that parse_remote could not reduce to a
		# two-segment owner/repo at all — must not reach a forge API path or a
		# constructed clone URL.
		if [[ ! "$forge_owner" =~ ^[a-zA-Z0-9._-]+$ ]] || [[ ! "$forge_repo" =~ ^[a-zA-Z0-9._-]+$ ]]; then
			forge_owner=""
			forge_repo=""
			# Only the github paths consume owner/repo (build_repo_flag, the gh
			# api paths, the clone URL); glab infers the project from the local
			# remote. Demoting the forge here would turn a nested GitLab
			# subgroup — an everyday legitimate remote this two-segment parser
			# cannot express — into a confident review of the branch diff
			# instead of the requested merge request.
			if [[ "$forge" == "github" ]]; then
				forge="local"
			fi
		fi
	fi
fi

# ============================================================================
# SECTION 3: Detect Forge Tooling
# ============================================================================

forge_tool="none"
if [[ "$forge" == "github" ]] && command -v gh >/dev/null 2>&1; then
	forge_tool="gh"
elif [[ "$forge" == "gitlab" ]] && command -v glab >/dev/null 2>&1; then
	forge_tool="glab"
fi

# ============================================================================
# SECTION 4: Determine Base Branch
# ============================================================================

base_branch=""
if [[ "$input_type" == "url" ]]; then
	: # base is PR-derived (pr_base / the forge diff) — no local ref needed
elif [[ -n "${base_override:-}" ]]; then
	if git rev-parse --verify "$base_override" >/dev/null 2>&1; then
		base_branch="$base_override"
	else
		json_output "skip" "Specified base branch '$base_override' does not exist."
		exit 0
	fi
elif git rev-parse --verify main >/dev/null 2>&1; then
	base_branch="main"
elif git rev-parse --verify master >/dev/null 2>&1; then
	base_branch="master"
else
	json_output "skip" "Cannot determine base branch (main and master both not found)."
	exit 0
fi

# ============================================================================
# SECTION 5: Create Session Directory
# ============================================================================

# Non-security use: hash of $PWD (or, in url scope, of the target repo) is a
# short cache-directory name, not a credential or integrity check.
if [[ "$input_type" == "url" ]] && [[ -n "$forge_owner" ]] && [[ -n "$forge_repo" ]]; then
	# Url scope: the launch dir is a throwaway unrelated to what's being
	# reviewed, so hashing $PWD would fragment the per-repo learnings/
	# prior-reviews cache across runs. Key on the forge repo instead.
	project_id=$(echo "${forge_owner}/${forge_repo}" 2>/dev/null | (sha256sum 2>/dev/null || shasum -a 256 2>/dev/null || md5sum 2>/dev/null) | head -c 12) || project_id="unknown" # DevSkim: ignore DS126858
else
	project_id=$(pwd 2>/dev/null | (sha256sum 2>/dev/null || shasum -a 256 2>/dev/null || md5sum 2>/dev/null) | head -c 12) || project_id="unknown" # DevSkim: ignore DS126858
fi
run_id=$(date +%Y%m%d-%H%M%S 2>/dev/null) || run_id="unknown"
session_dir="${XDG_CACHE_HOME:-$HOME/.cache}/review-council/${project_id}/${run_id}"

# verdicts/ holds per-agent verdict artifacts; verdicts/_meta/ holds the
# pipeline state the orchestrator writes between phases. Splitting them is
# what stops a phase artifact landing where a verdict glob will find it —
# RC-4 was exactly that, clusters.json parsed as an agent verdict.
if ! mkdir -p "${session_dir}/verdicts/_meta" 2>/dev/null; then
	json_output "skip" "Cannot create session directory at ${session_dir}. Check permissions and disk space."
	exit 0
fi
