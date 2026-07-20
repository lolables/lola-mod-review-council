#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$SCRIPT_DIR/../skills/review-council/scripts/rc-prepare.sh"
# shellcheck source=module/tests/test-helpers.sh
source "$SCRIPT_DIR/test-helpers.sh"

# Regression: explicit --mode on a PR/url scope must still capture the PR
# changeset. The PR diff fetch used to live only inside the mode auto-detect
# branch, so passing --mode code (or specs) skipped it and produced an empty
# changeset for every PR review.

# Fake gh: answers the calls rc-prepare.sh makes for a PR review. The clone
# step is kept off the network by matching origin owner/repo/branch so
# rc-clone-target.sh takes its in_place path.
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

setup_repo() {
	local work="$1"
	(
		cd "$work"
		git init -q
		git config user.email t@t.local
		git config user.name t
		git remote add origin https://github.com/acme/widgets.git
		git checkout -q -b main
		echo "package main" >a.go
		git add a.go
		git commit -qm init
		git checkout -q -b feature-head
		echo "// change" >>a.go
		git commit -qam change
	)
}

url="https://github.com/acme/widgets/pull/7"

echo "Test 1: explicit --mode code on url scope captures a non-empty changeset"
work=$(mktemp -d)
bindir=$(mktemp -d)
make_fake_gh "$bindir"
setup_repo "$work"
result=$(cd "$work" && PATH="$bindir:$PATH" AGENTS_DIR="$SCRIPT_DIR/../agents" \
	bash "$SCRIPT" --mode code --scope url --scope-value "$url" 2>/dev/null)
assert_json_field "$result" "status" "ok" "status is ok (not empty)"
sess=$(echo "$result" | jq -r '.session_dir // empty')
if [[ -n "$sess" ]] && grep -q '^foo.go$' "$sess/changeset.txt" 2>/dev/null; then
	echo "  PASS: changeset.txt contains PR file"
	PASS=$((PASS + 1))
else
	echo "  FAIL: changeset.txt missing PR file"
	FAIL=$((FAIL + 1))
fi
rm -rf "$work" "$bindir"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
