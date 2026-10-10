#!/usr/bin/env bash
# Works out which forge, host, project and (optionally) single PR or MR a run
# is aimed at. Source this file; do not execute it.
#
# Requires common.sh to be sourced first, for require_commands.
#
# Globals resolve_target reads (the entry script's flags, each possibly empty):
#
#   FORGE        --forge: "github" or "gitlab".
#   FORGE_HOST   --host: a GitLab hostname, without a port.
#   REPO         --repo: "owner/name" on GitHub, "group/.../project" on GitLab.
#   GITLAB_API_HOST, GITLAB_HOST, GITLAB_URI, GL_HOST
#                the environment's GitLab instance, read through
#                glab_env_bound_host in glab's own precedence; only its host is
#                used, a port on it is refused, and so is a value that names no
#                usable host.
#
# and the globals it sets, which every forge adapter and prs.sh then read:
#
#   FORGE, FORGE_HOST  as above, filled in and validated.
#   REPO         as above when a flag, URL or checkout names it; otherwise left
#                empty for resolve_project, which then validates it either way.
#   TARGET_PR    the single PR/MR named on the command line, or empty for
#                "every open one".
#
# The entry scripts run resolve_target, require and source the forge's
# adapter, run its auth check, and only then resolve_project.
#
# shellcheck shell=bash
# shellcheck disable=SC2250 # Bare $var, as every other shell source here writes
# it. Enabling the braces-always style in these files would make them the only
# ones of their kind in the tree; consistency is worth more than the check.
#
# shellcheck disable=SC2034 # TARGET_PR is this file's output, read by prs.sh
# and the entry scripts, never here. `shellcheck -x` sees those readers through
# the entry scripts, but `task lint` also checks this file standalone, where the
# assignment looks dead.

[[ -n "${_RC_TARGET_LOADED:-}" ]] && return 0
_RC_TARGET_LOADED=1

# resolve_target <target> -> sets FORGE, FORGE_HOST and TARGET_PR, and REPO
# where it can (see resolve_project for the rest).
#
# <target> may be empty (every open PR), a bare PR/MR number, a GitHub PR URL
# or a GitLab MR URL. A URL also fixes the forge, host and project, and
# disagreeing with an explicit --forge, --host or --repo is an error rather
# than a silent winner: the two spellings name different projects and there is
# no reading of the command that wants one of them discarded.
#
# The host is anchored at the start of the string, and the project is then
# checked against the forge's own naming rules. Both matter, because whatever
# comes out of here is the project this tool reviews and comments on publicly,
# and is interpolated into API paths. Unanchored, `github.com/o/r/pull/1`
# matched anywhere in the string, so a mirror (mygithub.com/...), a redirector
# (evil.com/github.com/...), a non-web scheme (ftp://github.com/...) and a
# sentence with a link in it all resolved to a github.com repository the
# operator never named. Unvalidated, `github.com/../../pull/4` captured
# `..`/`..`, which requester_authorised would then interpolate into the API
# path `repos/../../collaborators/...`.
#
# A GitLab MR URL cannot be anchored to one host, because self-managed
# instances live anywhere; what anchors it instead is the `/-/merge_requests/N`
# route GitLab puts after every project path, and the host it names is then
# held to a bare hostname. A host carrying credentials (user@host) or anything
# else is refused, as is a project path with an empty, dot-only or
# metacharacter-bearing segment: `gitlab.com/../x/-/merge_requests/1` must not
# become the API path `projects/..%2Fx`. The same checks apply to --repo and
# --host, which reach the same API paths. (The project checks live in
# resolve_project, which every project passes through.)
#
# With no URL the forge comes from --forge, from --host (which only GitLab
# takes), or from the origin remote's host. A checkout on a host that is
# neither github.com, gitlab.com nor glab's default host is refused rather than
# guessed at, even when --repo is given: guessing GitHub would send a
# self-managed GitLab project's path to github.com, where someone else may own
# it, and --run would comment there publicly. Only --forge settles it (that is
# also how a GitHub Enterprise checkout targets github.com), or gh placing an
# SSH host alias on github.com, which is evidence rather than a guess. A --repo
# given outside any checkout, with no other hint, stays GitHub, as it was
# before GitLab was supported.
resolve_target() {
	local target="$1" url_forge="" url_host="" url_project=""
	local remote="" remote_host="" remote_path="" gitlab_default_host=""
	local gitlab_default_name="" probe="" probe_url="" probe_repo="" probed host_label
	FORGE="${FORGE:-}"
	FORGE_HOST="${FORGE_HOST:-}"
	REPO="${REPO:-}"
	TARGET_PR=""

	if [[ -n "$target" ]]; then
		if [[ "$target" =~ ^[0-9]+$ ]]; then
			TARGET_PR="$target"
		elif [[ "$target" =~ ^(https?://)?(www\.)?github\.com/([^/?#]+)/([^/?#]+)/pull/([0-9]+) ]]; then
			url_forge="github"
			url_host="github.com"
			url_project="${BASH_REMATCH[3]}/${BASH_REMATCH[4]%.git}"
			TARGET_PR="${BASH_REMATCH[5]}"
			# GitHub logins are alphanumeric with hyphens; repository names add
			# `.` and `_`. A name of nothing but dots is a path traversal
			# wearing a repository's clothes, and GitHub reserves it anyway.
			if [[ ! "${BASH_REMATCH[3]}" =~ ^[A-Za-z0-9-]+$ ]] ||
				[[ ! "${url_project#*/}" =~ ^[A-Za-z0-9._-]+$ ]] || [[ "${url_project#*/}" =~ ^\.+$ ]]; then
				echo "Not a usable owner/name in that PR URL: '${url_project}'." >&2
				exit 2
			fi
		elif [[ "$target" =~ ^(https?://)?([^/?#]+)/(.+)/-/merge_requests/([0-9]+)([/?#].*)?$ ]]; then
			url_forge="gitlab"
			url_host="${BASH_REMATCH[2]}"
			url_project="${BASH_REMATCH[3]%.git}"
			TARGET_PR="${BASH_REMATCH[4]}"
		else
			echo "Target must be a PR/MR number or a GitHub PR / GitLab MR URL, got: ${target}" >&2
			exit 2
		fi
	fi

	if [[ -n "$url_forge" ]]; then
		if [[ -n "$FORGE" ]] && [[ "$FORGE" != "$url_forge" ]]; then
			echo "Conflicting forge: --forge ${FORGE} vs URL ${url_forge}." >&2
			exit 2
		fi
		# A --host on a GitHub URL falls through to the GitHub-only check below,
		# which says what is actually wrong with it.
		if [[ "$url_forge" = "gitlab" ]] && [[ -n "$FORGE_HOST" ]] &&
			[[ "${FORGE_HOST,,}" != "${url_host,,}" ]]; then
			echo "Conflicting host: --host ${FORGE_HOST} vs URL ${url_host}." >&2
			exit 2
		fi
		if [[ -n "$REPO" ]] && [[ "$REPO" != "$url_project" ]]; then
			echo "Conflicting repository: --repo '${REPO}' vs URL '${url_project}'." >&2
			exit 2
		fi
		FORGE="$url_forge"
		REPO="$url_project"
	fi

	# The host glab itself defaults to, in glab's own precedence (see
	# glab_env_bound_host): gitlab.com unless one of its host variables names
	# another, empty when the one set names no usable host. A port on it is
	# refused below, once it is the host in use.
	gitlab_default_host="$(glab_env_bound_host)"
	gitlab_default_name="${gitlab_default_host%%:*}"

	# The origin remote, in scp form (git@host:path) or URL form
	# (scheme://[userinfo@]host[:port]/path). The port is dropped: it is git's
	# transport port (ssh 2222, https 443), not the API's, and glab takes a
	# non-default API port from the host's api_host setting, by name. The
	# userinfo match runs to the LAST @ before the path, since a password may
	# itself contain one, and splitting at the first would turn the rest of the
	# password into the "host" quoted back in an error.
	remote="$(git remote get-url origin 2>/dev/null || true)"
	if [[ "$remote" =~ ^[A-Za-z0-9._-]+@([^:/]+):(.+)$ ]]; then
		remote_host="${BASH_REMATCH[1]}"
		remote_path="${BASH_REMATCH[2]}"
	elif [[ "$remote" =~ ^[a-z+]+://([^/]*@)?([^/:]+)(:[0-9]+)?/(.+)$ ]]; then
		remote_host="${BASH_REMATCH[2]}"
		remote_path="${BASH_REMATCH[4]}"
	fi
	while [[ "$remote_path" == */ ]]; do remote_path="${remote_path%/}"; done
	while [[ "$remote_path" == /* ]]; do remote_path="${remote_path#/}"; done
	remote_path="${remote_path%.git}"

	if [[ -z "$FORGE" ]]; then
		if [[ -n "$FORGE_HOST" ]]; then
			FORGE="gitlab"
		elif [[ "${remote_host,,}" = "github.com" ]]; then
			FORGE="github"
		elif [[ -n "$remote_host" ]] && { [[ "${remote_host,,}" = "gitlab.com" ]] ||
			[[ "${remote_host,,}" = "${gitlab_default_name,,}" ]]; }; then
			FORGE="gitlab"
		elif [[ -n "$remote_host" ]]; then
			# Not a host this recognises, but possibly an SSH alias
			# (git@github-work:o/r.git) that only ~/.ssh/config can expand.
			# gh expands such aliases itself, so if it places this checkout on
			# github.com that is evidence, not a guess. Anything else it says,
			# including a GitHub Enterprise host, or no answer at all, leaves
			# the forge unknown.
			#
			# But gh repo view does not answer about origin: it prefers an
			# upstream or github remote, or `gh repo set-default`. So its answer
			# counts only when the repository it names IS origin's path, and a
			# --repo must name that same repository; otherwise a corp-hosted
			# origin could be resolved to whatever github.com repository some
			# other remote points at, and commented on there.
			probed=0
			if command -v gh >/dev/null 2>&1; then
				probed=1
				probe="$(gh repo view --json url,nameWithOwner --jq '.url, .nameWithOwner' 2>/dev/null || true)"
			fi
			probe_url="${probe%%$'\n'*}"
			probe_repo="${probe#*$'\n'}"
			if [[ "$probe" == *$'\n'* ]] && [[ "$probe_url" =~ ^https?://([^/]+)/ ]] &&
				[[ "${BASH_REMATCH[1],,}" = "github.com" ]] &&
				[[ "${probe_repo,,}" = "${remote_path,,}" ]] &&
				{ [[ -z "$REPO" ]] || [[ "${REPO,,}" = "${probe_repo,,}" ]]; }; then
				FORGE="github"
				[[ -n "$REPO" ]] || REPO="$probe_repo"
			else
				echo "Cannot tell which forge ${remote_host} is." >&2
				echo "Pass --forge gitlab --host ${remote_host}, or --forge github to target github.com (GitHub Enterprise is not supported)." >&2
				if [[ "$probed" -eq 1 ]]; then
					echo "If this is a GitHub SSH alias, check 'gh auth status' — gh could not confirm it." >&2
				fi
				exit 2
			fi
		else
			FORGE="github"
		fi
	fi

	if [[ "$FORGE" = "github" ]]; then
		if [[ -n "$FORGE_HOST" ]]; then
			echo "--host applies to GitLab only." >&2
			exit 2
		fi
		FORGE_HOST="github.com"
	elif [[ -z "$FORGE_HOST" ]]; then
		# A github.com remote says nothing about where a --forge gitlab run's
		# instance is, so it is skipped rather than taken as a GitLab host.
		# A remote on glab's default host takes that host whole, so a port
		# it carries is refused below rather than lost with the remote's.
		if [[ -n "$url_host" ]]; then
			FORGE_HOST="$url_host"
		elif [[ -n "$remote_host" ]] && [[ "${remote_host,,}" = "${gitlab_default_name,,}" ]]; then
			FORGE_HOST="$gitlab_default_host"
		elif [[ -n "$remote_host" ]] && [[ "${remote_host,,}" != "github.com" ]]; then
			FORGE_HOST="$remote_host"
		elif [[ -n "$gitlab_default_host" ]]; then
			FORGE_HOST="$gitlab_default_host"
		else
			echo "glab's host variables (first non-empty of GITLAB_API_HOST, GITLAB_HOST, GITLAB_URI, GL_HOST) name no usable GitLab host; fix that variable or pass --host." >&2
			exit 2
		fi
	fi

	# glab keys its per-host configuration by lowercase hostname.
	FORGE_HOST="${FORGE_HOST,,}"
	# Each dot-separated label starts and ends with a letter or digit, so `..`,
	# `-` and `a..b` are refused along with anything carrying credentials.
	host_label='[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?'
	# glab rejects `--hostname host:port` and reads a non-default port from the
	# host's api_host setting instead (`glab auth login --api-host`), so a port named here cannot be honoured
	# and is refused with that fix. (Only GitLab gets this far with a host of
	# its own; GitHub's is always github.com.)
	if [[ "$FORGE_HOST" =~ ^(${host_label}(\.${host_label})*):[0-9]+$ ]]; then
		echo "GitLab hosts with a port are not supported: glab addresses a host by name. Run 'glab auth login --hostname ${BASH_REMATCH[1]} --api-host ${FORGE_HOST}' and use ${BASH_REMATCH[1]} without the port." >&2
		exit 2
	fi
	if [[ ! "$FORGE_HOST" =~ ^${host_label}(\.${host_label})*$ ]]; then
		echo "Not a usable host: '${FORGE_HOST}'." >&2
		exit 2
	fi

	# A GitLab checkout names its own project. A GitHub one is asked of gh by
	# resolve_project instead, once gh is known to be logged in.
	if [[ -z "$REPO" ]] && [[ "$FORGE" = "gitlab" ]] && [[ -n "$remote_host" ]] &&
		[[ "${remote_host,,}" = "$FORGE_HOST" ]]; then
		REPO="$remote_path"
	fi
}

# resolve_project -> fills in REPO for a GitHub checkout and validates it.
#
# Separate from resolve_target because its fallback calls gh, and that must
# wait for the adapter's auth check: a logged-out gh answers the lookup with
# nothing, and the operator would be told the repository is unknown when the
# fix is to log in. Run it after forge_auth_check.
resolve_project() {
	local segment
	local -a segments

	# No explicit project? Fall back to the one the current directory is a
	# checkout of. GitHub asks gh, as it always has, so a checkout cloned from
	# a fork still resolves the way gh resolves it.
	if [[ -z "$REPO" ]] && [[ "$FORGE" = "github" ]]; then
		REPO="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)"
	fi
	if [[ -z "$REPO" ]]; then
		echo "Could not determine the target repository." >&2
		echo "Pass --repo owner/name, give a PR URL, or run inside a checkout of the repo." >&2
		exit 1
	fi

	# Split by hand rather than with `read -a`, which would merge the empty
	# segments of `g//p` or `/g/p` that this check exists to catch. A segment
	# may not start with `-`: GitLab reserves a bare `-` for the routes after a
	# project path, so a greedy URL match that swallowed one
	# (g/x/-/merge_requests/1) stops here, and a leading `-` reads as an option
	# to whatever CLI the path is handed to.
	segments=()
	segment="$REPO/"
	while [[ -n "$segment" ]]; do
		segments+=("${segment%%/*}")
		segment="${segment#*/}"
	done
	for segment in "${segments[@]}"; do
		if [[ ! "$segment" =~ ^[A-Za-z0-9._-]+$ ]] || [[ "$segment" =~ ^\.+$ ]] || [[ "$segment" == -* ]]; then
			echo "Not a usable project path: '${REPO}'." >&2
			exit 2
		fi
	done
	if { [[ "$FORGE" = "github" ]] && { [[ "${#segments[@]}" -ne 2 ]] || [[ ! "${segments[0]}" =~ ^[A-Za-z0-9-]+$ ]]; }; } ||
		{ [[ "$FORGE" = "gitlab" ]] && [[ "${#segments[@]}" -lt 2 ]]; }; then
		echo "Not a usable project path: '${REPO}'." >&2
		exit 2
	fi
}
