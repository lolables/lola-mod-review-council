#!/usr/bin/env bash
# Unit tests for lib/glab-env.sh: glab's default-host precedence, the
# normalisation that decides which host its environment tokens belong to, and
# the env(1) arguments every glab call is run with. Both the council's
# rc_forge_glab and the operator scripts' _gl hand their calls to these, so
# this table is the one place the policy is pinned on its own.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GLAB_ENV="$SCRIPT_DIR/../skills/review-council/scripts/lib/glab-env.sh"
# shellcheck source=module/tests/helpers.sh
source "$SCRIPT_DIR/helpers.sh"

[[ -f "$GLAB_ENV" ]] || {
	echo "ERROR: library not found: $GLAB_ENV" >&2
	exit 1
}

echo "=== Sourcing is side-effect free ==="
# shellcheck disable=SC2016 # expanded by the inner bash, not here
probe='opts_before="$-|$(set +o)|$(shopt -p)"
out=$(source "$1"; source "$1")
source "$1"
opts_after="$-|$(set +o)|$(shopt -p)"
[[ "$opts_before" == "$opts_after" ]] && echo same-options || echo changed-options
printf "output=[%s]\n" "$out"'
actual=$(bash -c "$probe" _ "$GLAB_ENV")
assert_equals "$actual" "same-options
output=[]" "sourcing (twice) prints nothing and changes no shell option"

# rc-prepare.sh sources the adapter, and so this file, from inside a function.
# shellcheck disable=SC2016 # expanded by the inner bash, not here
probe='load() { source "$1"; }
load "$1"
echo "${GLAB_ENV_HOST_VARS[*]}|${GLAB_ENV_STRIPPED_VARS[*]}|${GLAB_ENV_TOKEN_VARS[*]}"'
actual=$(bash -c "$probe" _ "$GLAB_ENV")
assert_equals "$actual" "GITLAB_API_HOST GITLAB_HOST GITLAB_URI GL_HOST|GITLAB_API_HOST GLAB_ENABLE_CI_AUTOLOGIN|GITLAB_TOKEN GITLAB_ACCESS_TOKEN OAUTH_TOKEN" \
	"sourced inside a function, the lists are still global"

# shellcheck source=module/skills/review-council/scripts/lib/glab-env.sh
source "$GLAB_ENV"

# with_env <assignments> <cmd...> -> runs <cmd> in a subshell where none of
# glab's host variables is set except the ';'-separated NAME=value
# assignments given (an empty value stays set but empty).
with_env() {
	local assignments="$1" assignment
	shift
	(
		unset GITLAB_API_HOST GITLAB_HOST GITLAB_URI GL_HOST
		IFS=';'
		for assignment in $assignments; do
			# shellcheck disable=SC2163 # NAME=value, exported as given
			export "$assignment"
		done
		unset IFS
		"$@"
	)
}

echo "=== glab_env_bound_host: precedence and normalisation ==="
# label|assignments|expected bound host ("" = bound to no host)
while IFS='|' read -r label assignments want; do
	actual=$(with_env "$assignments" glab_env_bound_host)
	assert_equals "$actual" "$want" "$label"
done <<'TABLE'
nothing set: gitlab.com||gitlab.com
every variable empty is skipped: gitlab.com|GITLAB_API_HOST=;GITLAB_HOST=;GITLAB_URI=;GL_HOST=|gitlab.com
GITLAB_HOST bare host|GITLAB_HOST=git.example.org|git.example.org
GITLAB_HOST as a URL, lowercased|GITLAB_HOST=https://Git.Example.org/|git.example.org
GITLAB_HOST URL path dropped|GITLAB_HOST=https://git.example.org/some/path|git.example.org
GITLAB_HOST https default port dropped|GITLAB_HOST=https://git.example.org:443/|git.example.org
GITLAB_URI http default port dropped|GITLAB_URI=http://git.example.org:80|git.example.org
GL_HOST upper-case scheme default port dropped|GL_HOST=HTTPS://git.example.org:443|git.example.org
GITLAB_HOST http with port 443 kept|GITLAB_HOST=http://git.example.org:443|git.example.org:443
GITLAB_HOST https with port 80 kept|GITLAB_HOST=https://git.example.org:80|git.example.org:80
GITLAB_HOST bare host with port 443 kept|GITLAB_HOST=git.example.org:443|git.example.org:443
GITLAB_HOST other port kept|GITLAB_HOST=https://git.example.org:8443/|git.example.org:8443
GITLAB_API_HOST literal host lowercased|GITLAB_API_HOST=Git.Example.org|git.example.org
GITLAB_API_HOST port always kept|GITLAB_API_HOST=git.example.org:443|git.example.org:443
GITLAB_API_HOST outranks GITLAB_HOST|GITLAB_API_HOST=git.example.org;GITLAB_HOST=gitlab.com|git.example.org
empty GITLAB_API_HOST skipped|GITLAB_API_HOST=;GITLAB_HOST=git.example.org|git.example.org
GITLAB_HOST outranks GITLAB_URI|GITLAB_HOST=git.example.org;GITLAB_URI=gitlab.com|git.example.org
GITLAB_URI outranks GL_HOST|GITLAB_URI=git.example.org;GL_HOST=gitlab.com|git.example.org
empty GITLAB_HOST skipped|GITLAB_HOST=;GITLAB_URI=git.example.org|git.example.org
GL_HOST alone|GL_HOST=git.example.org|git.example.org
GITLAB_HOST scheme only: no host, not gitlab.com|GITLAB_HOST=https://|
GITLAB_HOST path only: no host, not gitlab.com|GITLAB_HOST=/x|
GITLAB_HOST default port only: no host, not gitlab.com|GITLAB_HOST=https://:443/|
GITLAB_API_HOST with a path (glab's API prefix): no host|GITLAB_API_HOST=git.example.org/api|
GITLAB_API_HOST with a scheme: no host|GITLAB_API_HOST=https://git.example.org|
GITLAB_API_HOST path only: no host|GITLAB_API_HOST=/x|
GITLAB_HOST URL with port 443 and path|GITLAB_HOST=https://Git.Example.org:443/a|git.example.org
an unusable value decides; a later variable is not consulted|GITLAB_HOST=https://;GITLAB_URI=git.example.org|
an unusable GITLAB_API_HOST does not fall through to GITLAB_HOST|GITLAB_API_HOST=git.example.org/api;GITLAB_HOST=git.example.org|
a label with an underscore is no host|GITLAB_HOST=git_lab.example.org|
a label ending in a hyphen is no host|GITLAB_HOST=git-.example.org|
an empty label is no host|GITLAB_HOST=git..example.org|
a non-numeric port is no host|GITLAB_HOST=git.example.org:https|
userinfo in the URL is no host|GITLAB_HOST=https://user:pw@git.example.org/|
TABLE

echo "=== glab_env_token_bound ==="
# label|assignments|host|expected status
while IFS='|' read -r label assignments host want; do
	rc=0
	# shellcheck disable=SC2310 # the status is captured and asserted on.
	with_env "$assignments" glab_env_token_bound "$host" || rc=$?
	assert_equals "$rc" "$want" "$label"
done <<'TABLE'
nothing set binds gitlab.com||gitlab.com|0
nothing set does not bind a self-managed host||git.example.org|1
GITLAB_HOST binds its own host|GITLAB_HOST=https://git.example.org/|git.example.org|0
GITLAB_HOST elsewhere: gitlab.com is not bound|GITLAB_HOST=git.example.org|gitlab.com|1
a port does not bind the portless host|GITLAB_HOST=git.example.org:8443|git.example.org|1
an unusable GITLAB_HOST binds nothing, gitlab.com included|GITLAB_HOST=https://|gitlab.com|1
an unusable GITLAB_API_HOST binds nothing, its host included|GITLAB_API_HOST=git.example.org/api|git.example.org|1
an empty host is never bound|GITLAB_API_HOST=/x||1
TABLE
rc=0
# shellcheck disable=SC2310 # the status is captured and asserted on.
with_env "" glab_env_token_bound "" || rc=$?
assert_equals "$rc" "1" "an empty host is never bound, even by gitlab.com's default"

echo "=== glab_env_scrub_args ==="
strip_always=$'-u\nGITLAB_API_HOST\n-u\nGLAB_ENABLE_CI_AUTOLOGIN'
strip_tokens=$'-u\nGITLAB_TOKEN\n-u\nGITLAB_ACCESS_TOKEN\n-u\nOAUTH_TOKEN'
actual=$(with_env "GITLAB_HOST=git.example.org" glab_env_scrub_args git.example.org)
assert_equals "$actual" "$strip_always" "bound host: only the redirecting variables go"
actual=$(with_env "GITLAB_HOST=git.example.org" glab_env_scrub_args gitlab.com)
assert_equals "$actual" "${strip_always}"$'\n'"${strip_tokens}" "another host: the tokens go too"
actual=$(with_env "GITLAB_HOST=https://" glab_env_scrub_args gitlab.com)
assert_equals "$actual" "${strip_always}"$'\n'"${strip_tokens}" "no bound host: the tokens go everywhere"
actual=$(with_env "" glab_env_scrub_args "")
assert_equals "$actual" "${strip_always}"$'\n'"${strip_tokens}" "an empty host: the tokens go"

# The arguments are consumed by env(1); prove they do what they say.
# scrub_probe <host> -> what a child of `env <scrub args>` still sees.
scrub_probe() {
	local -a scrub
	# shellcheck disable=SC2312 # glab_env_scrub_args only prints; it has no failure to mask.
	mapfile -t scrub < <(glab_env_scrub_args "$1")
	# shellcheck disable=SC2016 # expanded by the child bash, not here
	GITLAB_API_HOST=x GLAB_ENABLE_CI_AUTOLOGIN=true GITLAB_TOKEN=t GITLAB_ACCESS_TOKEN=t OAUTH_TOKEN=t \
		env "${scrub[@]}" bash -c 'echo "${GITLAB_API_HOST-unset},${GLAB_ENABLE_CI_AUTOLOGIN-unset},${GITLAB_TOKEN-unset},${GITLAB_ACCESS_TOKEN-unset},${OAUTH_TOKEN-unset}"'
}
actual=$(with_env "GITLAB_HOST=git.example.org" scrub_probe gitlab.com)
assert_equals "$actual" "unset,unset,unset,unset,unset" "env(1) given another host's arguments removes every listed variable"
actual=$(with_env "GITLAB_HOST=git.example.org" scrub_probe git.example.org)
assert_equals "$actual" "unset,unset,t,t,t" "env(1) given the bound host's arguments keeps the tokens"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
