#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$SCRIPT_DIR/../skills/review-council/scripts/rc-clone-target.sh"
# shellcheck source=module/tests/test-helpers.sh
source "$SCRIPT_DIR/test-helpers.sh"

# Build a temp bin dir with mock git/gh, prepended to PATH per-test.
make_mockbin() {
	local dir="$1" mode="$2"
	mkdir -p "$dir"
	cat >"$dir/git" <<MOCKGIT
#!/usr/bin/env bash
# mode=$mode drives behavior; log invocations for assertions.
echo "git \$*" >>"$dir/git.log"
# Detect the checkout subcommand among args (real calls use \`git -C DEST checkout\`).
if [[ "$mode" == "checkoutfail" ]] && printf '%s\n' "\$@" | grep -qx 'checkout'; then exit 1; fi
case "\$1" in
	remote) echo "https://github.com/acme/widgets.git" ;;
	rev-parse)
		if [[ "\$2" == "--abbrev-ref" ]]; then echo "$MOCK_BRANCH"; else echo "deadbeef"; fi ;;
	clone)
		if [[ "$mode" == "partialfail" ]] && printf '%s\n' "\$@" | grep -q 'blob:none'; then
			exit 1
		fi
		# Create the destination dir (last non-flag arg).
		for a in "\$@"; do dest="\$a"; done
		mkdir -p "\$dest/.git" ;;
	fetch) : ;;
	checkout) : ;;
	*) : ;;
esac
exit 0
MOCKGIT
	chmod +x "$dir/git"
}

# Test 1: already in the target repo on the PR branch -> in_place
echo "Test 1: in-place detection"
bin=$(mktemp -d); MOCK_BRANCH="feature-x" make_mockbin "$bin" ok
result=$(PATH="$bin:$PATH" bash "$SCRIPT" --forge github --owner acme --repo widgets --pr 7 --head feature-x 2>/dev/null)
assert_json_field "$result" "status" "in_place" "status is in_place"
assert_json_field "$result" "review_root" "." "review_root is ."
rm -rf "$bin"

# Test 2: different branch -> materialize into cache, review_root = dest
echo "Test 2: materialize into cache"
bin=$(mktemp -d); MOCK_BRANCH="main" make_mockbin "$bin" ok
cache=$(mktemp -d)
result=$(PATH="$bin:$PATH" XDG_CACHE_HOME="$cache" bash "$SCRIPT" \
	--forge github --owner acme --repo widgets --pr 7 --head feature-x 2>/dev/null)
assert_json_field "$result" "status" "ok" "status is ok"
root=$(echo "$result" | jq -r '.review_root')
if [[ "$root" == "$cache/review-council/clones/acme-widgets" ]]; then
	echo "  PASS: review_root points at cache clone"; PASS=$((PASS+1))
else
	echo "  FAIL: got '$root'"; FAIL=$((FAIL+1))
fi
if grep -q 'blob:none' "$bin/git.log"; then
	echo "  PASS: attempted blobless partial clone"; PASS=$((PASS+1))
else
	echo "  FAIL: no partial clone attempted"; FAIL=$((FAIL+1))
fi
if grep -q 'pull/7/head' "$bin/git.log"; then
	echo "  PASS: fetched PR head ref"; PASS=$((PASS+1))
else
	echo "  FAIL: PR head not fetched"; FAIL=$((FAIL+1))
fi
rm -rf "$bin" "$cache"

# Test 3: partial clone fails -> shallow fallback
echo "Test 3: shallow fallback"
bin=$(mktemp -d); MOCK_BRANCH="main" make_mockbin "$bin" partialfail
cache=$(mktemp -d)
result=$(PATH="$bin:$PATH" XDG_CACHE_HOME="$cache" bash "$SCRIPT" \
	--forge github --owner acme --repo widgets --pr 7 --head feature-x 2>/dev/null)
assert_json_field "$result" "status" "ok" "status is ok after fallback"
if grep -q 'depth 50' "$bin/git.log"; then
	echo "  PASS: shallow fallback used"; PASS=$((PASS+1))
else
	echo "  FAIL: no shallow fallback"; FAIL=$((FAIL+1))
fi
rm -rf "$bin" "$cache"

# Test 4: non-github forge -> skip (generic fallback), review_root = .
echo "Test 4: non-github skip"
bin=$(mktemp -d); MOCK_BRANCH="main" make_mockbin "$bin" ok
result=$(PATH="$bin:$PATH" bash "$SCRIPT" --forge gitlab --owner acme --repo widgets --pr 7 --head feature-x 2>/dev/null)
assert_json_field "$result" "status" "skip" "status is skip"
assert_json_field "$result" "review_root" "." "review_root stays ."
rm -rf "$bin"

# Test 5: LRU prune keeps newest N, removes older clones
echo "Test 5: LRU prune"
bin=$(mktemp -d); MOCK_BRANCH="main" make_mockbin "$bin" ok
cache=$(mktemp -d)
clones="$cache/review-council/clones"; mkdir -p "$clones"
# Seed 3 stale clones older than the new one; cap = 2.
for n in old1 old2 old3; do mkdir -p "$clones/$n"; touch -d '2020-01-01' "$clones/$n"; done
PATH="$bin:$PATH" XDG_CACHE_HOME="$cache" REVIEW_COUNCIL_CLONE_CACHE_MAX=2 \
	bash "$SCRIPT" --forge github --owner acme --repo widgets --pr 7 --head feature-x >/dev/null 2>&1
remaining=$(find "$clones" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
if [[ "$remaining" -eq 2 ]]; then
	echo "  PASS: cache pruned to cap (2)"; PASS=$((PASS+1))
else
	echo "  FAIL: expected 2 clones, got $remaining"; FAIL=$((FAIL+1))
fi
if [[ -d "$clones/acme-widgets" ]]; then
	echo "  PASS: fresh clone retained"; PASS=$((PASS+1))
else
	echo "  FAIL: fresh clone was pruned"; FAIL=$((FAIL+1))
fi
rm -rf "$bin" "$cache"

# Test 6: checkout of the PR head fails -> skip (no false-clean empty tree)
echo "Test 6: checkout failure falls back to skip"
bin=$(mktemp -d); MOCK_BRANCH="main" make_mockbin "$bin" checkoutfail
cache=$(mktemp -d)
result=$(PATH="$bin:$PATH" XDG_CACHE_HOME="$cache" bash "$SCRIPT" \
	--forge github --owner acme --repo widgets --pr 7 --head feature-x 2>/dev/null)
assert_json_field "$result" "status" "skip" "status is skip on checkout failure"
assert_json_field "$result" "review_root" "." "review_root falls back to ."
rm -rf "$bin" "$cache"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
