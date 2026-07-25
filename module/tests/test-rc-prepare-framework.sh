#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$SCRIPT_DIR/../skills/review-council/scripts/rc-prepare.sh"
# shellcheck source=module/tests/test-helpers.sh
source "$SCRIPT_DIR/test-helpers.sh"

# Framework content-probes (go.mod, requirements.txt, ...) must read the
# materialized clone (review_root), not the launch dir (CWD). In url/PR scope
# review_root is a separate clone directory produced by rc-clone-target.sh, so
# a probe that reads "go.mod" (CWD-relative) silently misses content that only
# exists under review_root.
#
# This test builds a real local "source" git repo containing a go.mod that
# depends on gin, registers a `refs/pull/7/head` ref on it (mirroring a GitHub
# PR head ref), and points a faked `gh repo clone` at that local repo so
# rc-clone-target.sh's real git fetch/checkout machinery materializes it into
# review_root -- no network involved. The launch dir (CWD when rc-prepare.sh
# runs) has no go.mod at all, so a CWD-relative probe can never see "gin".

# Fake gh: answers the PR metadata/diff calls rc-prepare.sh makes, and routes
# `gh repo clone` to a real local `git clone` of our gin fixture instead of
# GitHub, so rc-clone-target.sh's subsequent real `git fetch`/`checkout` of
# `pull/7/head` materializes review_root off-network.
make_fake_gh() {
	local bindir="$1" source_repo="$2"
	cat >"$bindir/gh" <<GH
#!/usr/bin/env bash
case "\$1 \$2" in
"pr view")
	cat <<'JSON'
{"number":7,"title":"Add gin route","body":"Body","baseRefName":"main","headRefName":"feature-head","url":"https://github.com/acme/widgets/pull/7","state":"OPEN","statusCheckRollup":[]}
JSON
	;;
"pr diff")
	cat <<'DIFF'
diff --git a/go.mod b/go.mod
index 0000000..1111111 100644
--- a/go.mod
+++ b/go.mod
@@ -1,1 +1,3 @@
 module foo
+
+require github.com/gin-gonic/gin v1.9.0
DIFF
	;;
"repo clone")
	dest="\$4"
	rm -rf "\$dest"
	git clone -q "$source_repo" "\$dest" >/dev/null 2>&1
	;;
"api "*) echo "[]" ;;
*) exit 0 ;;
esac
GH
	chmod +x "$bindir/gh"
}

# Build the local fixture repo that stands in for the materialized clone: a
# go.mod that depends on gin, with a refs/pull/7/head ref rc-clone-target.sh's
# real `git fetch origin pull/7/head` can resolve locally.
make_source_repo() {
	local dir="$1"
	mkdir -p "$dir"
	(
		cd "$dir"
		git init -q
		git config user.email t@t.local
		git config user.name t
		git checkout -q -b main
		cat >go.mod <<'MOD'
module foo

require github.com/gin-gonic/gin v1.9.0
MOD
		git add go.mod
		git commit -qm "add gin dependency"
		sha=$(git rev-parse HEAD)
		git update-ref refs/pull/7/head "$sha"
	)
}

url="https://github.com/acme/widgets/pull/7"

echo "Test 1: framework probe reads review_root's go.mod, not the launch dir's"
launch_dir=$(mktemp -d) # no go.mod here at all
source_repo=$(mktemp -d)
bindir=$(mktemp -d)
cache=$(mktemp -d)

make_source_repo "$source_repo"
make_fake_gh "$bindir" "$source_repo"

result=$(cd "$launch_dir" && PATH="$bindir:$PATH" XDG_CACHE_HOME="$cache" AGENTS_DIR="$SCRIPT_DIR/../agents" \
	timeout 40 bash "$SCRIPT" --mode code --scope url --scope-value "$url" 2>/dev/null)

assert_json_field "$result" "status" "ok" "prepare reaches status ok"

review_root=$(echo "$result" | jq -r '.review_root // empty')
if [[ -n "$review_root" ]] && [[ "$review_root" != "." ]] && [[ -f "$review_root/go.mod" ]]; then
	echo "  PASS: review_root was materialized with the gin fixture's go.mod"
	PASS=$((PASS + 1))
else
	echo "  FAIL: review_root ('$review_root') was not materialized as expected"
	FAIL=$((FAIL + 1))
fi

if [[ -f "$launch_dir/go.mod" ]]; then
	echo "  FAIL: test setup bug -- launch dir unexpectedly has a go.mod"
	FAIL=$((FAIL + 1))
else
	echo "  PASS: launch dir has no go.mod (a CWD-relative probe can't see gin)"
	PASS=$((PASS + 1))
fi

assert_json_field "$result" "framework" "gin" "framework detected as gin from review_root, not CWD"

rm -rf "$launch_dir" "$source_repo" "$bindir" "$cache"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
