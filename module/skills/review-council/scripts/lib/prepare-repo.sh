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
#
# `paths` and `all` need no repository either: a file is reviewable from its
# bytes alone, so outside git they review what is on disk — a named file whole,
# a named directory as every file under it — with no diff, base branch or forge.
# rc_no_git carries that to the later stages, and the result message says so.
# The scopes defined BY history (changed, range, pr) still refuse: there is no
# honest answer to "what changed" without one, and a scratch repo would only
# invent a diff that never happened.
rc_no_git=false
if [[ "$input_type" != "url" ]] && ! git rev-parse --git-dir >/dev/null 2>&1; then
	if [[ "$input_type" == "dir_scope" || "$input_type" == "all" ]]; then
		rc_no_git=true
	elif [[ "$input_type" == "auto" && -n "$scope_dir" ]]; then
		# `--scope changed --scope paths <dir>` is how SKILL.md routes a named
		# directory. Outside git there are no changes for it to filter, so the
		# only meaning left is the directory review `--scope paths` gives;
		# refusing it made that review unreachable from the skill.
		rc_no_git=true
		input_type="dir_scope"
		input_value="$scope_dir"
		scope_type="paths"
	else
		# `--scope pr` is not offered as a way out: it still derives
		# forge_owner/forge_repo from the local git remote (see the comment
		# above), so naming it here would send the user straight back into this
		# same refusal.
		json_output "skip" "Not a git repository, so there is no history to compare. Use --scope paths <file-or-dir> or --scope all to review files as they are on disk, --scope url to review a pull request without a local checkout, or run 'git init' first."
		exit 0
	fi
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
# The host every later forge call is aimed at — recorded in session.txt as
# `Host:` because the adapter, the clone, permalinks and the poster all run
# where no checkout can tell them, and a self-hosted GitLab is not gitlab.com.
# Blank whenever forge is `local`: there is no forge to address.
forge_host=""

if [[ "$input_type" == "url" ]]; then
	parse_remote "$input_value"
	# GitHub: the same exact-host rule the local-remote branch below applies, and
	# the reachable half of it: `--scope url` is a user-facing entry point, and
	# the host it names goes straight into `gh api repos/OWNER/REPO/...`. Read
	# `mygithub.com` or `github.company.com` as `github.com` and the review asks
	# an unrelated service for a pull request, then reviews whatever it answers
	# with. GitHub's `/pull/N` route says nothing about the host, so nothing but
	# the exact host can identify it.
	#
	# GitLab: the `/-/merge_requests/N` route is GitLab's own, so it identifies
	# the forge on any host — gitlab.com and self-hosted alike, but never
	# github.com, whatever route its URL carries. The host is read from this
	# match rather than from parse_remote, which blanks any host carrying a port,
	# and must be a plain DNS name: userinfo, a hyphen-led label or an empty
	# label never reaches glab. A port is refused outright (see below). Reaching
	# this branch does not make the host trusted: rc-prepare.sh still asks the
	# adapter whether glab may talk to it before any glab call is made.
	#
	# Each pattern captures the project path AND the number in one match,
	# anchored at both ends. A second, looser pass for the number read the LAST
	# `/merge_requests/N` anywhere in the URL, so a query string could swap in a
	# different MR. The tail admits only a `/`, `?` or `#` suffix with no
	# whitespace, so a newline payload fails the match.
	github_pr_url_re='^[a-zA-Z][a-zA-Z0-9+.-]*://[^/]+/([^/]+)/([^/]+)/pull/([0-9]+)([/?#][^[:space:]]*)?$'
	gitlab_mr_url_re='^[Hh][Tt][Tt][Pp][Ss]?://([A-Za-z0-9.-]+)(:[0-9]+)?/(.+)/-/merge_requests/([0-9]+)([/?#][^[:space:]]*)?$'
	gitlab_host_re='^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)*$'
	url_authority=""
	url_pr_number=""
	url_unreadable_message="Cannot read a project and pull/merge request number from '${scope_value}'. Expected https://github.com/OWNER/REPO/pull/N or https://HOST/GROUP/PROJECT/-/merge_requests/N."
	if [[ "${rc_remote_host,,}" == "github.com" ]]; then
		forge="github"
		forge_host="github.com"
		# GitHub has no subgroups: the project path is exactly OWNER/REPO.
		if [[ "$input_value" =~ $github_pr_url_re ]]; then
			forge_owner="${BASH_REMATCH[1]}"
			forge_repo="${BASH_REMATCH[2]}"
			url_pr_number="${BASH_REMATCH[3]}"
		fi
	elif [[ "$input_value" =~ $gitlab_mr_url_re ]]; then
		# Read every group out before the next `=~`, which overwrites BASH_REMATCH.
		gitlab_url_name="${BASH_REMATCH[1],,}"
		gitlab_url_port="${BASH_REMATCH[2]}"
		gitlab_project_path="${BASH_REMATCH[3]}"
		url_pr_number="${BASH_REMATCH[4]}"
		url_authority="${gitlab_url_name}${gitlab_url_port}"
		if [[ "$gitlab_url_name" =~ $gitlab_host_re ]] && [[ "$gitlab_url_name" != "github.com" ]]; then
			# glab addresses a host by name only — it rejects `--hostname
			# host:port` — and takes a non-default port from that host's
			# api_host setting. Honouring the port here would mean dropping it,
			# which aims every call at a different service.
			if [[ -n "$gitlab_url_port" ]]; then
				json_output "skip" "GitLab hosts with a port are not supported: the GitLab CLI addresses a host by name. Configure glab's api_host for ${gitlab_url_name} and use the URL without the port."
				exit 0
			fi
			forge="gitlab"
			forge_host="$gitlab_url_name"
			# GitLab nests projects under arbitrarily deep subgroups, so the
			# first two path segments are not owner/repo — and taking them
			# anyway passed the segment gate below, silently naming a
			# *different* project. project_id is a hash of
			# "${forge_owner}/${forge_repo}" and keys the learnings/prior-reviews
			# cache, so every project under gitlab.com/group/subgroup/ collided
			# into one cache entry. GitLab emits the `/-/` route separator
			# precisely to disambiguate the project path from the route that
			# follows it: everything before it is the project path, whose last
			# segment is the repo and whose remainder is the owner. A
			# single-segment path is malformed (a project always sits in a
			# namespace); leaving the pair blank refuses it below.
			if [[ "$gitlab_project_path" == */* ]]; then
				forge_owner="${gitlab_project_path%/*}"
				forge_repo="${gitlab_project_path##*/}"
			fi
		fi
	fi

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
	#
	# A URL that carries GitLab's `/-/merge_requests/` route but fails the
	# anchored match above is a malformed MR URL, not an unknown forge: say what
	# could not be read rather than blaming the host.
	if [[ "$forge" == "local" ]] && [[ -z "$url_authority" ]] &&
		[[ "$input_value" == */-/merge_requests/* ]]; then
		json_output "skip" "$url_unreadable_message"
		exit 0
	fi
	if [[ "$forge" == "local" ]]; then
		json_output "skip" "Unsupported forge host '${rc_remote_host:-${url_authority:-unparsable}}' in '${scope_value}'. --scope url can fetch github.com pull requests, or a GitLab merge-request URL (.../-/merge_requests/N) on any host; a GitHub Enterprise or other self-hosted GitHub install is not a supported forge."
		exit 0
	fi

	# Terminal on both forges, for the reason the unsupported-host skip above
	# is. Blank owner/repo cannot address a PR or an MR at all: the GitLab
	# adapter makes no call without a project, and letting glab resolve one from
	# the launch directory's remote would fetch whatever MR carries that number
	# there — a confident review of the wrong change.
	if ! project_path_ok "$forge_owner" "$forge_repo" || [[ -z "$url_pr_number" ]]; then
		json_output "skip" "$url_unreadable_message"
		exit 0
	fi

	input_value="$url_pr_number"
else
	remote_url=$(git remote get-url origin 2>/dev/null || echo "")
	parse_remote "$remote_url"
	# The whole host, never a substring of it: `mygithub.com` contains
	# `github.com` outright, and matching it with an unescaped dot makes
	# `github.company.com` a hit too (`github` + any char + `com`). Either one
	# would aim `gh api repos/OWNER/REPO/...` calls and a constructed
	# https://github.com/OWNER/REPO.git clone URL at an unrelated service.
	case "${rc_remote_host,,}" in
	github.com) forge="github" forge_host="github.com" ;;
	gitlab.com) forge="gitlab" forge_host="gitlab.com" ;;
	# An unrecognized host stays `local` on purpose, a GitHub Enterprise
	# install (github.example.com) included: that is a safe degrade, not an
	# oversight to repair by loosening the match. `gh` resolves OWNER/REPO
	# against its own default host, so reaching an enterprise install means
	# handling GH_HOST / `gh auth login --hostname` — a feature, not a
	# hostname pattern.
	*) ;;
	esac
	if [[ "$forge" == "github" ]]; then
		forge_owner="$rc_remote_owner"
		forge_repo="$rc_remote_repo"
		# Same character-class guard the URL branch applies. A remote that parses
		# to something unsafe — or that parse_remote could not reduce to a
		# two-segment owner/repo at all — must not reach a forge API path or a
		# constructed clone URL.
		if [[ ! "$forge_owner" =~ ^[a-zA-Z0-9._-]+$ ]] || [[ ! "$forge_repo" =~ ^[a-zA-Z0-9._-]+$ ]]; then
			forge_owner=""
			forge_repo=""
			forge="local"
			forge_host=""
		fi
	elif [[ "$forge" == "gitlab" ]]; then
		# A GitLab project is every path segment, nested subgroups included:
		# the last is the repo, the rest the owner — the split the URL branch
		# makes at `/-/`. parse_remote's two-segment owner/repo cannot express
		# a subgroup, and leaving the pair blank once meant glab resolved the
		# project from the checkout's remotes, preferring `upstream` over
		# origin. A path failing the URL branch's per-segment gate leaves the
		# pair blank, and the adapter then makes no forge call at all. The
		# forge stays gitlab: the checkout still names its host, which is what
		# permalinks and the poster are aimed at.
		if [[ "$rc_remote_path" == */* ]] &&
			project_path_ok "${rc_remote_path%/*}" "${rc_remote_path##*/}"; then
			forge_owner="${rc_remote_path%/*}"
			forge_repo="${rc_remote_path##*/}"
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
elif $rc_no_git; then
	# No repository, so no base: files are reviewed whole (see Section 1). A
	# --base given anyway is refused rather than dropped, so nobody reads the
	# result as a review against that branch.
	if [[ -n "${base_override:-}" ]]; then
		json_output "skip" "--base has no meaning outside a git repository: there is no branch to compare against. Drop --base to review the files as they are on disk."
		exit 0
	fi
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
elif [[ "$input_type" == "ref_range" ]]; then
	: # a range names both of its own ends; nothing is diffed against a base
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
project_dir="${XDG_CACHE_HOME:-$HOME/.cache}/review-council/${project_id}"

# verdicts/ holds per-agent verdict artifacts; verdicts/_meta/ holds the
# pipeline state the orchestrator writes between phases. Splitting them is
# what stops a phase artifact landing where a verdict glob will find it —
# RC-4 was exactly that, clusters.json parsed as an agent verdict.
#
# The directory is made by mktemp, not mkdir -p: the run id has one-second
# resolution and mkdir -p accepts an existing directory, so two preparations of
# one project in the same second (two PR reviews launched together) shared a
# session and the second overwrote the first's PR metadata (RC-080). mktemp -d
# creates exclusively, and the timestamp prefix keeps names sorting by age.
if ! mkdir -p "$project_dir" 2>/dev/null ||
	! session_dir=$(mktemp -d "${project_dir}/${run_id}-XXXXXX" 2>/dev/null) ||
	! mkdir -p "${session_dir}/verdicts/_meta" 2>/dev/null; then
	json_output "skip" "Cannot create session directory under ${project_dir}. Check permissions and disk space."
	exit 0
fi

# --- LRU prune: keep the newest N session dirs for this project ---
#
# Clones have been capped since rc-clone-target.sh gained its LRU. Sessions had
# no cap at all, so every review ever run left a directory behind permanently —
# and so did every run that produced nothing, because this directory is created
# here, before the changeset scan below decides whether there is anything to
# review at all. A no-op review is therefore exactly the kind that accumulates.
# Under per-PR CI use that is unbounded growth in a cache nobody inspects.
#
# Pruning happens HERE rather than at the end of preparation so it runs on every
# path out of this script, including the `skip` and `empty` exits that abandon
# the session moments from now.
#
# The rules mirror rc-clone-target.sh deliberately — same env-var shape, same
# ordering primitive, same "never evict what was just created" guarantee. Two
# eviction disciplines in one cache directory would be two things to learn and
# two things to get wrong. A cap of 0 still leaves this session: the run that
# owns it has to be able to finish.
session_cap="${REVIEW_COUNCIL_SESSION_CACHE_MAX:-20}"
[[ "$session_cap" =~ ^[0-9]+$ ]] || session_cap=20
# shellcheck disable=SC2012,SC2312 # `find -printf` sorting is GNU-only and this
# cap has to hold on macOS too, exactly as the clone LRU does. Entry names are
# `date +%Y%m%d-%H%M%S` run ids plus a mktemp suffix of [A-Za-z0-9], so the
# whitespace-in-filename hazard SC2012 warns about cannot arise, and mapfile
# splits on newlines. A project directory
# holding only this session legitimately yields one entry.
mapfile -t rc_sessions_by_age < <(ls -dt "$(dirname "${session_dir}")"/*/ 2>/dev/null | sed 's:/*$::')
if [[ ${#rc_sessions_by_age[@]} -gt $session_cap ]]; then
	for ((rc_k = session_cap; rc_k < ${#rc_sessions_by_age[@]}; rc_k++)); do
		[[ "${rc_sessions_by_age[$rc_k]}" == "${session_dir}" ]] && continue
		rm -rf "${rc_sessions_by_age[$rc_k]}" 2>/dev/null || true
	done
fi
