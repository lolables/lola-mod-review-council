#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$SCRIPT_DIR/../skills/review-council/scripts/rc-prepare.sh"
# shellcheck source=module/tests/helpers.sh
source "$SCRIPT_DIR/helpers.sh"

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
echo "Test 2: --mode code outside a git repo reports the missing repo, not the mode"
work=$(mktemp -d)
result=$(cd "$work" && AGENTS_DIR="$SCRIPT_DIR/../agents" \
	bash "$SCRIPT" --mode code --scope changed 2>/dev/null)
message=$(echo "$result" | jq -r '.message // empty')
if [[ "$message" =~ [Nn]ot\ a\ git\ repository ]]; then
	echo "  PASS: message names the missing git repository"
	PASS=$((PASS + 1))
else
	echo "  FAIL: message does not mention the missing git repository (got: $message)"
	FAIL=$((FAIL + 1))
fi
if [[ "$message" =~ [Ss]pecify\ the\ review\ mode ]]; then
	echo "  FAIL: message tells the user to specify the mode, but --mode was already given (got: $message)"
	FAIL=$((FAIL + 1))
else
	echo "  PASS: message does not ask the user to specify a mode they already gave"
	PASS=$((PASS + 1))
fi
rm -rf "$work"

echo ""
echo "Test 3: --scope url from a non-git dir runs end-to-end (git-dir gate"
echo "  and base-branch gate must both be skipped for url scope)"
work=$(mktemp -d)
bindir=$(mktemp -d)
make_fake_gh "$bindir"
# Deliberately no setup_repo: $work is never a git repo. Materialization
# (rc-clone-target.sh) still degrades gracefully off-network because the fake
# gh's catch-all `exit 0` satisfies `gh repo clone` without creating a real
# checkout, so the follow-up `git fetch` fails fast and falls back to
# diff-only review instead of hanging on a real clone.
result=$(cd "$work" && PATH="$bindir:$PATH" AGENTS_DIR="$SCRIPT_DIR/../agents" \
	"$RC_TIMEOUT_BIN" 40 bash "$SCRIPT" --mode code --scope url --scope-value "$url" 2>/dev/null)
message=$(echo "$result" | jq -r '.message // empty')
assert_json_field "$result" "status" "ok" "url scope from a non-git dir reaches status ok"
if [[ "$message" =~ [Nn]ot\ a\ git\ repository ]]; then
	echo "  FAIL: url scope aborted at the git-repo gate outside a git repo (got: $message)"
	FAIL=$((FAIL + 1))
else
	echo "  PASS: url scope proceeded past the git-repo gate outside a git repo"
	PASS=$((PASS + 1))
fi
if [[ "$message" =~ [Cc]annot\ determine\ base\ branch ]]; then
	echo "  FAIL: url scope aborted at the base-branch gate outside a git repo (got: $message)"
	FAIL=$((FAIL + 1))
else
	echo "  PASS: url scope proceeded past the base-branch gate outside a git repo"
	PASS=$((PASS + 1))
fi
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
echo "Test 4: spec mode honours a secondary --scope paths filter over --scope all"
# Regression: the secondary path filter binds tighter than the base scope. The
# spec-location sweep used to be tested first, so `--scope all --scope paths`
# swept specs/ and docs/ and never looked at the directories the user named.
work=$(mktemp -d)
(
	cd "$work" || exit 1
	git_init_sandbox
	git checkout -q -b main
	mkdir -p specs docs/design mymod
	echo "# Default-location spec" >specs/ignored.md
	echo "# Default-location design" >docs/design/ignored.md
	echo "# Requested spec" >mymod/wanted.md
	git add specs docs mymod
	git commit -qm init
)
result=$(cd "$work" && AGENTS_DIR="$SCRIPT_DIR/../agents" \
	bash "$SCRIPT" --mode specs --scope all --scope paths --scope-value "mymod/" 2>/dev/null)
assert_json_field "$result" "status" "ok" "status is ok"
sess=$(echo "$result" | jq -r '.session_dir // empty')
if [[ -n "$sess" ]] && grep -q '^mymod/wanted.md$' "$sess/changeset.txt" 2>/dev/null; then
	echo "  PASS: changeset.txt contains the requested path"
	PASS=$((PASS + 1))
else
	echo "  FAIL: changeset.txt missing mymod/wanted.md"
	FAIL=$((FAIL + 1))
fi
if [[ -n "$sess" ]] && grep -qE '^(specs|docs/design)/' "$sess/changeset.txt" 2>/dev/null; then
	echo "  FAIL: changeset.txt still holds default spec locations the filter excluded"
	FAIL=$((FAIL + 1))
else
	echo "  PASS: changeset.txt excludes the default spec locations"
	PASS=$((PASS + 1))
fi
rm -rf "$work"

echo "Test 5: an unrecognised --mode value is refused, not silently run as code"
# --mode accepted any string and fell through to code. The accepted token is
# `specs`, but the mode is called `spec` everywhere else — in --help's output
# field, in the JSON `mode` field, in the divisor-*-spec.md filenames — so
# `--mode spec` is the natural typo, and it silently ran a CODE review: wrong
# personas, wrong changeset default, and a report that names a mode the caller
# never asked for. --effort has rejected its junk values from the start; this
# closes the same hole on the flag where the wrong value is most guessable.
work=$(mktemp -d)
cd "$work"
# Built inline rather than with setup_repo: all three documented modes have to
# resolve against the same repo. The spec artifact is committed on main BEFORE
# the topic branch exists, so it is in feature-head's tree — spec mode scopes to
# all project files and reports `empty` without one. The topic branch changes
# only a.go, so base...HEAD stays code-only and auto-detect still yields code.
git_init_sandbox
git checkout -q -b main
echo "package main" >a.go
mkdir -p specs && echo "# Feature spec" >specs/feature.md
git add a.go specs/feature.md
git commit -qm init
git checkout -q -b feature-head
echo "// change" >>a.go
git commit -qam change
for bad in spec Code SPECS code-review banana ""; do
	result=$(AGENTS_DIR="$SCRIPT_DIR/../agents" bash "$SCRIPT" --mode "$bad" 2>/dev/null)
	status=$(jq -r '.status // "none"' <<<"$result")
	assert_equals "$status" "skip" "--mode '$bad' is refused"
	msg=$(jq -r '.message // ""' <<<"$result")
	if grep -qF -- "code, specs, auto" <<<"$msg"; then
		echo "  PASS: --mode '$bad' names the valid values"
		PASS=$((PASS + 1))
	else
		echo "  FAIL: --mode '$bad' message does not name the valid values: $msg"
		FAIL=$((FAIL + 1))
	fi
done

# The three documented values must still work, in both directions.
for good in code:code specs:spec auto:code; do
	result=$(AGENTS_DIR="$SCRIPT_DIR/../agents" bash "$SCRIPT" --mode "${good%%:*}" 2>/dev/null)
	# Assigned before asserting, not nested inside the call: a command
	# substitution inside another command has its exit status discarded, so a
	# jq that errored would silently assert against the empty string.
	status=$(jq -r '.status // "none"' <<<"$result")
	resolved=$(jq -r '.mode // "none"' <<<"$result")
	assert_equals "$status" "ok" "--mode ${good%%:*} is accepted"
	assert_equals "$resolved" "${good##*:}" "--mode ${good%%:*} resolves to ${good##*:}"
done
rm -rf "$work"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
