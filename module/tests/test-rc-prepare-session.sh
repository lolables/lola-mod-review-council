#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$SCRIPT_DIR/../skills/review-council/scripts/rc-prepare.sh"
# shellcheck source=module/tests/test-helpers.sh
source "$SCRIPT_DIR/test-helpers.sh"

# In url scope, $PWD is a throwaway launch dir unrelated to the repo
# under review, so hashing it fragments the per-repo learnings/prior-reviews
# cache across runs. project_id must instead derive from forge_owner/repo.

# Fake gh: answers the calls rc-prepare.sh makes for a PR/url review. The
# clone step is kept off the network by the fake `gh`'s catch-all `exit 0`,
# same as test-rc-prepare-mode.sh.
make_fake_gh() {
	local bindir="$1"
	cat >"$bindir/gh" <<'GH'
#!/usr/bin/env bash
case "$1 $2" in
"pr view")
	cat <<'JSON'
{"number":7,"title":"Add feature","body":"Body","baseRefName":"main","headRefName":"feature-head","url":"https://github.com/acme/widgets/pull/7","state":"OPEN","statusCheckRollup":[]}
JSON
	;;
"pr diff")
	cat <<'DIFF'
diff --git a/foo.go b/foo.go
index 0000000..1111111 100644
--- a/foo.go
+++ b/foo.go
@@ -0,0 +1,2 @@
+package main
+func main() {}
DIFF
	;;
"api "*) echo "[]" ;;
*) exit 0 ;;
esac
GH
	chmod +x "$bindir/gh"
}

# Extract the project_id path component from a session_dir:
# .../review-council/<project_id>/<run_id>
project_id_of() {
	basename "$(dirname "$1")"
}

# Hash a directory's resolved $PWD through the same pipeline rc-prepare.sh
# uses for its pwd-based project_id, to prove url-scope no longer produces it.
pwd_project_id() {
	(cd "$1" && pwd) | (sha256sum 2>/dev/null || shasum -a 256 2>/dev/null || md5sum 2>/dev/null) | head -c 12
}

url="https://github.com/acme/widgets/pull/7"

run_url_scope() {
	local launch_dir="$1" bindir="$2"
	(cd "$launch_dir" && PATH="$bindir:$PATH" AGENTS_DIR="$SCRIPT_DIR/../agents" \
		timeout 40 bash "$SCRIPT" --mode code --scope url --scope-value "$url" 2>/dev/null)
}

echo "Test 1: two url-scope runs of the same PR from different non-git dirs"
echo "  share the same project_id (stable per-repo cache key)"
launch_a=$(mktemp -d)
launch_b=$(mktemp -d)
bindir=$(mktemp -d)
make_fake_gh "$bindir"

result_a=$(run_url_scope "$launch_a" "$bindir")
result_b=$(run_url_scope "$launch_b" "$bindir")

sess_a=$(echo "$result_a" | jq -r '.session_dir // empty')
sess_b=$(echo "$result_b" | jq -r '.session_dir // empty')

if [[ -z "$sess_a" ]] || [[ -z "$sess_b" ]]; then
	echo "  FAIL: one or both runs did not produce a session_dir"
	echo "    run A: $result_a"
	echo "    run B: $result_b"
	FAIL=$((FAIL + 1))
else
	pid_a=$(project_id_of "$sess_a")
	pid_b=$(project_id_of "$sess_b")
	if [[ "$pid_a" == "$pid_b" ]]; then
		echo "  PASS: project_id stable across launch dirs ($pid_a)"
		PASS=$((PASS + 1))
	else
		echo "  FAIL: project_id differs across launch dirs ($pid_a vs $pid_b)"
		FAIL=$((FAIL + 1))
	fi

	echo ""
	echo "Test 2: url-scope project_id is derived from forge owner/repo, not \$PWD"
	expected_pid=$(echo "acme/widgets" | (sha256sum 2>/dev/null || shasum -a 256 2>/dev/null || md5sum 2>/dev/null) | head -c 12)
	pwd_pid_a=$(pwd_project_id "$launch_a")
	pwd_pid_b=$(pwd_project_id "$launch_b")

	if [[ "$pid_a" == "$expected_pid" ]]; then
		echo "  PASS: project_id matches hash of owner/repo ($expected_pid)"
		PASS=$((PASS + 1))
	else
		echo "  FAIL: project_id does not match hash of owner/repo (got $pid_a, expected $expected_pid)"
		FAIL=$((FAIL + 1))
	fi

	if [[ "$pid_a" != "$pwd_pid_a" ]] && [[ "$pid_a" != "$pwd_pid_b" ]]; then
		echo "  PASS: project_id does not match a hash of either launch dir's \$PWD"
		PASS=$((PASS + 1))
	else
		echo "  FAIL: project_id matches a hash of \$PWD instead of owner/repo"
		FAIL=$((FAIL + 1))
	fi
fi

rm -rf "$launch_a" "$launch_b" "$bindir"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
