#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=module/tests/helpers.sh
source "$SCRIPT_DIR/helpers.sh"
# shellcheck source=module/skills/review-council/scripts/rc-lib.sh
source "$SCRIPT_DIR/../skills/review-council/scripts/rc-lib.sh"

echo "Test 1: rc_parse_kv reads a trimmed value"
f=$(mktemp)
printf -- '- Forge: github\n- PR: 42\n- Mode: code (default)\n' >"$f"
val=$(rc_parse_kv "$f" "Forge")
if [[ "$val" == "github" ]]; then
	echo "  PASS: Forge=github"
	PASS=$((PASS + 1))
else
	echo "  FAIL: got '$val'"
	FAIL=$((FAIL + 1))
fi

echo "Test 2: rc_parse_kv returns empty for a missing key"
val=$(rc_parse_kv "$f" "Nope")
if [[ -z "$val" ]]; then
	echo "  PASS: missing key empty"
	PASS=$((PASS + 1))
else
	echo "  FAIL: got '$val'"
	FAIL=$((FAIL + 1))
fi

echo "Test 3: rc_parse_kv keeps only the first line's value"
val=$(rc_parse_kv "$f" "Mode")
if [[ "$val" == "code (default)" ]]; then
	echo "  PASS: Mode value intact"
	PASS=$((PASS + 1))
else
	echo "  FAIL: got '$val'"
	FAIL=$((FAIL + 1))
fi
rm -f "$f"

# parse_remote is the one git-remote parser rc-prepare.sh (forge detection) and
# rc-clone-target.sh (target identity) both depend on, and each caller only ever
# exercises the forms it happens to receive. The forms neither reaches today are
# where a silent parse change hides — a dropped port made two different
# endpoints on one hostname compare equal — so every form the function claims to
# handle, and every form it deliberately refuses, is asserted here directly.
echo "Test 4: parse_remote splits every remote form it claims to handle"
while IFS='|' read -r label remote want_host want_owner want_repo; do
	[[ -z "$label" ]] && continue
	parse_remote "$remote"
	assert_equals "$rc_remote_host" "$want_host" "$label — host"
	assert_equals "$rc_remote_owner" "$want_owner" "$label — owner"
	assert_equals "$rc_remote_repo" "$want_repo" "$label — repo"
done <<'CASES'
https|https://github.com/acme/widgets|github.com|acme|widgets
https + .git|https://github.com/acme/widgets.git|github.com|acme|widgets
scp-style|git@github.com:acme/widgets.git|github.com|acme|widgets
ssh://|ssh://git@github.com/acme/widgets.git|github.com|acme|widgets
uppercase host|https://GitHub.COM/acme/widgets.git|GitHub.COM|acme|widgets
CASES

# A remote whose path this parser cannot reduce still names its host: forge
# detection needs it, and blanking it would demote an everyday GitLab subgroup
# remote to a branch-diff review of the wrong thing.
echo "Test 5: extra path segments blank owner/repo but keep the host"
while IFS='|' read -r label remote want_host want_owner want_repo; do
	[[ -z "$label" ]] && continue
	parse_remote "$remote"
	assert_equals "$rc_remote_host" "$want_host" "$label — host"
	assert_equals "$rc_remote_owner" "$want_owner" "$label — owner"
	assert_equals "$rc_remote_repo" "$want_repo" "$label — repo"
done <<'CASES'
gitlab subgroup|https://gitlab.com/group/subgroup/project.git|gitlab.com||
deep subgroup|https://gitlab.com/a/b/c/d.git|gitlab.com||
CASES

# A port is refused outright rather than parsed away. Two services on one
# hostname at different ports are two different endpoints, and a parse that
# drops the port makes them compare equal — which is how a ported --url came to
# match a portless origin and review the local working tree as the PR. Blanking
# the host is the conservative reading: it can only ever cost a fast path.
# Telling `host:8443/o/r` apart from scp-style `host:1234/repo` (an owner that
# happens to be digits) is the reason this is refused rather than guessed.
echo "Test 6: a ported remote yields no host at all"
while IFS='|' read -r label remote want_host want_owner want_repo; do
	[[ -z "$label" ]] && continue
	parse_remote "$remote"
	assert_equals "$rc_remote_host" "$want_host" "$label — host"
	assert_equals "$rc_remote_owner" "$want_owner" "$label — owner"
	assert_equals "$rc_remote_repo" "$want_repo" "$label — repo"
done <<'CASES'
https + port|https://ghe.corp.net:8443/acme/widgets.git|||
ssh:// + port|ssh://git@ghe.corp.net:2222/acme/widgets.git|||
port, no path|https://ghe.corp.net:8443|||
scp-style, digit owner|git@ghe.corp.net:1234/widgets.git|||
CASES

# Remotes with no host shape at all. `file://` keeps whatever the URL's first
# path segment is, which is junk as a hostname and harmless as one: it is
# never github.com or gitlab.com, so rc-prepare.sh reviews the branch diff, and
# it never equals a caller-named target host, so rc-clone-target.sh clones
# rather than reusing the working tree.
echo "Test 7: hostless remotes degrade rather than inventing a forge"
while IFS='|' read -r label remote want_host want_owner want_repo; do
	[[ -z "$label" ]] && continue
	parse_remote "$remote"
	assert_equals "$rc_remote_host" "$want_host" "$label — host"
	assert_equals "$rc_remote_owner" "$want_owner" "$label — owner"
	assert_equals "$rc_remote_repo" "$want_repo" "$label — repo"
done <<'CASES'
absolute path|/srv/git/widgets.git|||
file:// deep path|file:///srv/git/acme/widgets.git|file||
file:// two segments|file:///srv/widgets.git|file|srv|widgets
empty remote||||
bare hostname|github.com|||
CASES

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
