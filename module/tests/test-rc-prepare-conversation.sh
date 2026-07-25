#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$SCRIPT_DIR/../skills/review-council/scripts/rc-prepare.sh"
# shellcheck source=module/tests/test-helpers.sh
source "$SCRIPT_DIR/test-helpers.sh"

# On RE-review (the PR already carries the council's marker
# comment from a prior verdict), rc-prepare.sh must fetch the issue-comments
# timeline, locate the council's most recent marker comment, and write only
# the replies posted at/after it to session_dir/pr-conversation.txt as
# UNTRUSTED data. First-review (no marker yet) and empty-timeline runs must
# not write the file at all.

# Fake gh: answers the calls rc-prepare.sh makes for a PR review. The
# issues/<n>/comments endpoint reads its fixture from $bindir/issues-comments.json
# so each test case can drop in its own conversation before invoking prepare.
# All other `gh api ...` calls (pulls/reviews, pulls/comments) fall through
# to the "[]" catch-all, matching the sibling mode/clone tests' harness.
make_fake_gh() {
	local bindir="$1"
	cat >"$bindir/gh" <<GH
#!/usr/bin/env bash
case "\$1 \$2" in
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
"api repos/acme/widgets/issues/7/comments")
	cat "$bindir/issues-comments.json"
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

echo "Test 1: re-review (marker present) writes only replies at/after the marker"
work=$(mktemp -d)
bindir=$(mktemp -d)
make_fake_gh "$bindir"
cat >"$bindir/issues-comments.json" <<'JSON'
[
  {"user":{"login":"alice"},"created_at":"2026-01-01T00:00:00Z","body":"OLDER_REPLY_MARKER filed before the council ever weighed in"},
  {"user":{"login":"review-council-bot"},"created_at":"2026-01-02T00:00:00Z","body":"<!-- review-council:marker sha=abc123 -->\n\nAPPROVE"},
  {"user":{"login":"bob"},"created_at":"2026-01-03T00:00:00Z","body":"REPLY_A_MARKER can you also check the retry path"},
  {"user":{"login":"carol"},"created_at":"2026-01-04T00:00:00Z","body":"REPLY_B_MARKER agreed, please recheck that"}
]
JSON
setup_repo "$work"
result=$(cd "$work" && PATH="$bindir:$PATH" AGENTS_DIR="$SCRIPT_DIR/../agents" \
	bash "$SCRIPT" --mode code --scope url --scope-value "$url" 2>/dev/null)
assert_json_field "$result" "status" "ok" "status is ok"
sess=$(echo "$result" | jq -r '.session_dir // empty')
convo="$sess/pr-conversation.txt"
if [[ -n "$sess" ]] && [[ -f "$convo" ]]; then
	echo "  PASS: pr-conversation.txt exists"
	PASS=$((PASS + 1))
else
	echo "  FAIL: pr-conversation.txt missing (session_dir='$sess')"
	FAIL=$((FAIL + 1))
fi
if [[ -f "$convo" ]] && grep -q "REPLY_A_MARKER" "$convo" && grep -q "REPLY_B_MARKER" "$convo"; then
	echo "  PASS: contains both post-marker replies"
	PASS=$((PASS + 1))
else
	echo "  FAIL: missing one or both post-marker replies"
	FAIL=$((FAIL + 1))
fi
if [[ -f "$convo" ]] && ! grep -q "OLDER_REPLY_MARKER" "$convo"; then
	echo "  PASS: excludes the pre-marker reply"
	PASS=$((PASS + 1))
else
	echo "  FAIL: pre-marker reply leaked into the untrusted file"
	FAIL=$((FAIL + 1))
fi
if [[ -f "$convo" ]] && head -n1 "$convo" | grep -qi "untrusted"; then
	echo "  PASS: file opens with an UNTRUSTED data header"
	PASS=$((PASS + 1))
else
	echo "  FAIL: file does not open with an UNTRUSTED data header"
	FAIL=$((FAIL + 1))
fi
# session_dir is keyed by second-resolution timestamp + repo hash, so it can
# collide with the next test case's session if both run within the same
# wall-clock second against the same fake owner/repo. Clean up eagerly so a
# leftover pr-conversation.txt from this test can never leak into the next.
rm -rf "$work" "$bindir" "$sess"

echo ""
echo "Test 2: first review (no marker yet) writes no conversation file"
work=$(mktemp -d)
bindir=$(mktemp -d)
make_fake_gh "$bindir"
cat >"$bindir/issues-comments.json" <<'JSON'
[
  {"user":{"login":"alice"},"created_at":"2026-01-01T00:00:00Z","body":"NO_MARKER_REPLY_ONE"},
  {"user":{"login":"bob"},"created_at":"2026-01-02T00:00:00Z","body":"NO_MARKER_REPLY_TWO"}
]
JSON
setup_repo "$work"
result=$(cd "$work" && PATH="$bindir:$PATH" AGENTS_DIR="$SCRIPT_DIR/../agents" \
	bash "$SCRIPT" --mode code --scope url --scope-value "$url" 2>/dev/null)
assert_json_field "$result" "status" "ok" "status is ok"
sess=$(echo "$result" | jq -r '.session_dir // empty')
if [[ -n "$sess" ]] && [[ ! -f "$sess/pr-conversation.txt" ]]; then
	echo "  PASS: no pr-conversation.txt without a marker comment"
	PASS=$((PASS + 1))
else
	echo "  FAIL: pr-conversation.txt written despite no marker comment"
	FAIL=$((FAIL + 1))
fi
rm -rf "$work" "$bindir" "$sess"

echo ""
echo "Test 3: empty comment timeline writes no conversation file"
work=$(mktemp -d)
bindir=$(mktemp -d)
make_fake_gh "$bindir"
echo "[]" >"$bindir/issues-comments.json"
setup_repo "$work"
result=$(cd "$work" && PATH="$bindir:$PATH" AGENTS_DIR="$SCRIPT_DIR/../agents" \
	bash "$SCRIPT" --mode code --scope url --scope-value "$url" 2>/dev/null)
assert_json_field "$result" "status" "ok" "status is ok"
sess=$(echo "$result" | jq -r '.session_dir // empty')
if [[ -n "$sess" ]] && [[ ! -f "$sess/pr-conversation.txt" ]]; then
	echo "  PASS: no pr-conversation.txt for an empty timeline"
	PASS=$((PASS + 1))
else
	echo "  FAIL: pr-conversation.txt written for an empty timeline"
	FAIL=$((FAIL + 1))
fi
rm -rf "$work" "$bindir"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
