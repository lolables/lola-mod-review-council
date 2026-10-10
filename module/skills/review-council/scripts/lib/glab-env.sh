# glab-env.sh — which host glab's environment tokens belong to, and which
# variables to strip from a glab call so they reach no other host.
#
# The one copy of this policy. Sourced by lib/forge/gitlab.sh (the council's
# rc_forge_glab) and by the repository's scripts/lib/common.sh (the operator
# scripts' _gl and the driver's agent environment). Defines functions and
# arrays only: sourcing it runs nothing, sets no shell option and needs no
# other file.
#
# glab prefers GITLAB_TOKEN, GITLAB_ACCESS_TOKEN and OAUTH_TOKEN over the token
# it stores per host, and sends them to whichever host a call targets, so a
# token minted for one instance would ride along to another. An environment
# token belongs to glab's default host. Verified against glab 1.102 in an
# isolated GLAB_CONFIG_DIR, by setting two variables to distinct unresolvable
# hosts and reading which one the DNS error named: the default host is the
# first non-empty of GITLAB_API_HOST, GITLAB_HOST, GITLAB_URI, GL_HOST, else
# gitlab.com (GITLAB_BASE_URL, GITLAB_URL and CI_SERVER_* are not read).
#
# shellcheck shell=bash
# shellcheck disable=SC2250 # Bare $var, as every other shell source here writes
# it. Enabling the braces-always style in these files would make them the only
# ones of their kind in the tree; consistency is worth more than the check.

[[ -n "${_GLAB_ENV_LOADED:-}" ]] && return 0
# Global, like the arrays below, so a file sourced from inside a function
# (rc-prepare.sh sources the adapter that way) still defines them for its caller.
declare -g _GLAB_ENV_LOADED=1

# glab's default-host variables, highest precedence first.
declare -ga GLAB_ENV_HOST_VARS=(GITLAB_API_HOST GITLAB_HOST GITLAB_URI GL_HOST)

# Removed from every glab call, whatever host it names.
#
# GITLAB_API_HOST redirected every request in the experiment above — an explicit
# `--hostname`, an `-R host/...` and `auth status --hostname` alike — so left in
# place it would aim each addressed call, and the auth-status gate, at a
# different instance. GITLAB_HOST, GITLAB_URI and GL_HOST do not override
# explicit addressing.
#
# GLAB_ENABLE_CI_AUTOLOGIN: inside a GitLab CI job it makes glab log in with the
# job's CI_JOB_TOKEN and aim at the job's own instance (CI_SERVER_*). An
# explicitly addressed call has been seen redirected to that instance, and in
# one measurement the job token was sent to the gitlab.com host the call named
# (an unauthenticated 404 became a 401). Either way a credential bound to one
# instance reaches another.
declare -ga GLAB_ENV_STRIPPED_VARS=(GITLAB_API_HOST GLAB_ENABLE_CI_AUTOLOGIN)

# glab's environment tokens: kept only for a call to the host they are bound to.
declare -ga GLAB_ENV_TOKEN_VARS=(GITLAB_TOKEN GITLAB_ACCESS_TOKEN OAUTH_TOKEN)

# glab_env_bound_host -> the host glab's environment tokens belong to,
# lowercased host[:port]; empty when they belong to no usable host.
#
# gitlab.com only when none of GLAB_ENV_HOST_VARS is set. The first non-empty
# one decides, as it does for glab, and is normalised the same way for every
# caller so that all of them bind a token alike:
#
# - GITLAB_HOST, GITLAB_URI and GL_HOST may be URLs: scheme and path are
#   dropped. A port is kept, since host:8443 is not the portless host a call
#   addresses, except the scheme's own default (https 443, http 80), which names
#   the same service as no port.
# - GITLAB_API_HOST is taken literally. glab reads a path there as an API path
#   prefix (`host/api` sent requests to https://host/api/api/v4/...) and a
#   scheme as part of the host, so such a value does not name a host a call
#   could be addressed to.
#
# A result that is not a valid hostname[:port] — empty after normalising,
# still carrying a `/`, a scheme left in GITLAB_API_HOST — binds the tokens to
# nothing rather than falling back to gitlab.com: glab itself would send them
# to whatever that value spells (`GITLAB_HOST=https://` reached a host named
# "https"), never to gitlab.com.
glab_env_bound_host() {
	local var value default_port
	local label='[a-z0-9]([a-z0-9-]*[a-z0-9])?'
	for var in "${GLAB_ENV_HOST_VARS[@]}"; do
		value="${!var:-}"
		[[ -n "$value" ]] || continue
		if [[ "$var" != "GITLAB_API_HOST" ]]; then
			case "${value,,}" in
			https://*) default_port=":443" ;;
			http://*) default_port=":80" ;;
			*) default_port="" ;;
			esac
			value="${value#*://}"
			value="${value%%/*}"
			[[ -z "$default_port" ]] || value="${value%"$default_port"}"
		fi
		value="${value,,}"
		[[ "$value" =~ ^${label}(\.${label})*(:[0-9]+)?$ ]] || value=""
		printf '%s\n' "$value"
		return 0
	done
	printf 'gitlab.com\n'
}

# glab_env_token_bound <host> -> status 0 when glab's environment tokens belong
# to <host> (lowercase, as every caller holds it): it is the bound host. An
# empty <host> or an empty bound host binds nothing.
glab_env_token_bound() {
	local host="$1" bound
	bound="$(glab_env_bound_host)"
	[[ -n "$host" ]] && [[ "$bound" = "$host" ]]
}

# glab_env_scrub_args <host> -> the env(1) arguments for a glab call to <host>,
# one per line: `-u VAR` for each of GLAB_ENV_STRIPPED_VARS, and for each of
# GLAB_ENV_TOKEN_VARS unless the tokens are bound to <host>. Read it with
# `mapfile -t`; every element is an option or a variable name, never a value.
glab_env_scrub_args() {
	local host="$1" var
	for var in "${GLAB_ENV_STRIPPED_VARS[@]}"; do
		printf -- '-u\n%s\n' "$var"
	done
	glab_env_token_bound "$host" && return 0
	for var in "${GLAB_ENV_TOKEN_VARS[@]}"; do
		printf -- '-u\n%s\n' "$var"
	done
}
