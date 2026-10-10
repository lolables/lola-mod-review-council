#!/usr/bin/env bash
# Git topology edge cases for rc-prepare.sh: no repository at all, and a
# repository holding a single root commit.
#
# Both states are ordinary — the first day of a project, or a tool run from the
# wrong directory — and both are places where "found nothing to review" and
# "your input could not be resolved" look identical to the caller. A review
# tool that cannot tell those apart reports a clean review of nothing.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$SCRIPT_DIR/../skills/review-council/scripts/rc-prepare.sh"
AGENTS="$SCRIPT_DIR/../agents"
# shellcheck source=module/tests/helpers.sh
source "$SCRIPT_DIR/helpers.sh"

# Run rc-prepare.sh in <dir> with the agents dir wired up, print its JSON.
prepare_in() { # dir [args...]
	local dir="$1"
	shift
	(cd "$dir" && AGENTS_DIR="$AGENTS" bash "$SCRIPT" "$@" 2>/dev/null)
}

assert_message_matches() { # json regex label
	local msg
	msg=$(echo "$1" | jq -r '.message // empty')
	if [[ "$msg" =~ $2 ]]; then
		echo "  PASS: $3"
		PASS=$((PASS + 1))
	else
		echo "  FAIL: $3 (got: $msg)"
		FAIL=$((FAIL + 1))
	fi
}

assert_message_lacks() { # json regex label
	local msg
	msg=$(echo "$1" | jq -r '.message // empty')
	if [[ "$msg" =~ $2 ]]; then
		echo "  FAIL: $3 (got: $msg)"
		FAIL=$((FAIL + 1))
	else
		echo "  PASS: $3"
		PASS=$((PASS + 1))
	fi
}

# ---------------------------------------------------------------------------
echo "Test 1: no git repository — default scope refuses cleanly"
work=$(mktemp -d)
result=$(prepare_in "$work")
assert_json_field "$result" "status" "skip" "status is skip, not ok"
assert_message_matches "$result" '[Nn]ot a git repository' "message names the missing repository"
# A refused run must leave nothing behind for a later phase to pick up.
if [[ ! -e "$work/.review-council" ]]; then
	echo "  PASS: no partial session written into the working directory"
	PASS=$((PASS + 1))
else
	echo "  FAIL: refused run left state behind"
	FAIL=$((FAIL + 1))
fi
rm -rf "$work"

echo "Test 2: no git repository — the suggested remedy must actually work"
# The refusal message advertises a way out. `--scope url` genuinely bypasses
# the gate; `--scope pr` does not, because PR scope still derives the forge
# owner/repo from the local git remote. Naming it as a remedy sends the user
# into the identical failure.
work=$(mktemp -d)
result=$(prepare_in "$work" --scope pr --scope-value 42)
assert_json_field "$result" "status" "skip" "pr scope outside a repo still refuses"
result_default=$(prepare_in "$work")
assert_message_lacks "$result_default" 'scope pr' \
	"refusal does not advertise --scope pr, which hits the same gate"
assert_message_matches "$result_default" 'scope url' \
	"refusal points at --scope url, which does bypass the gate"
rm -rf "$work"

echo "Test 3: a directory inside an unrelated repository is not silently reviewed"
# `git rev-parse` walks upward, so a plain subdirectory of some other checkout
# looks like a repository. The run is allowed, but it must resolve the
# enclosing repo rather than inventing one — the danger is reviewing a
# different project than the user meant without saying so.
outer=$(mktemp -d)
setup_repo "$outer" >/dev/null 2>&1
mkdir -p "$outer/subdir"
result=$(prepare_in "$outer/subdir")
status=$(echo "$result" | jq -r '.status')
if [[ "$status" != "skip" ]]; then
	echo "  PASS: subdirectory of a repo is treated as inside that repo (status=$status)"
	PASS=$((PASS + 1))
else
	msg=$(echo "$result" | jq -r '.message')
	if [[ "$msg" =~ [Nn]ot\ a\ git\ repository ]]; then
		echo "  FAIL: subdirectory of a real repo reported as not a repository"
		FAIL=$((FAIL + 1))
	else
		echo "  PASS: subdirectory refused for a reason other than the git gate ($msg)"
		PASS=$((PASS + 1))
	fi
fi
rm -rf "$outer"

# ---------------------------------------------------------------------------
echo "Test 4: single-commit repo, clean tree — reports empty, not ok"
work=$(mktemp -d)
setup_single_commit_repo "$work" main
result=$(prepare_in "$work")
assert_json_field "$result" "status" "empty" "clean single-commit repo is empty"
assert_message_matches "$result" '[Nn]o changes' "message says there is nothing to review"
rm -rf "$work"

echo "Test 5: single-commit repo with uncommitted work — that work is reviewable"
# The first commit is not a dead end: edits on top of it are a legitimate
# changeset, and refusing them would make the tool useless on a new project.
work=$(mktemp -d)
setup_single_commit_repo "$work" main
echo "// uncommitted change" >>"$work/a.go"
result=$(prepare_in "$work")
assert_json_field "$result" "status" "ok" "dirty single-commit repo prepares a session"
rm -rf "$work"

echo "Test 6: single-commit repo on a branch that is neither main nor master"
work=$(mktemp -d)
setup_single_commit_repo "$work" topic
result=$(prepare_in "$work")
assert_json_field "$result" "status" "skip" "unresolvable base refuses"
assert_message_matches "$result" '[Bb]ase branch' "message names the base-branch problem"
rm -rf "$work"

echo "Test 7: an unresolvable ref range is an error, never 'no changes'"
# On a root commit HEAD~1 does not exist, so `git diff HEAD~1..HEAD` is fatal.
# Swallowing that into an empty changeset tells the user their branch is clean
# when in fact nothing was ever compared — the worst possible direction for a
# review tool to be wrong in.
work=$(mktemp -d)
setup_single_commit_repo "$work" main
result=$(prepare_in "$work" --scope range --scope-value 'HEAD~1..HEAD')
status=$(echo "$result" | jq -r '.status')
if [[ "$status" != "empty" ]]; then
	echo "  PASS: unresolvable range does not report empty (status=$status)"
	PASS=$((PASS + 1))
else
	echo "  FAIL: unresolvable range reported as 'no changes to review'"
	FAIL=$((FAIL + 1))
fi
assert_message_matches "$result" 'HEAD~1\.\.HEAD|[Rr]ange|[Rr]esolve' \
	"message names the range that could not be resolved"
rm -rf "$work"

echo "Test 8: a garbage ref range is rejected the same way"
work=$(mktemp -d)
setup_repo "$work" >/dev/null 2>&1
result=$(prepare_in "$work" --scope range --scope-value 'no-such-ref..HEAD')
status=$(echo "$result" | jq -r '.status')
if [[ "$status" != "empty" && "$status" != "ok" ]]; then
	echo "  PASS: nonexistent ref rejected (status=$status)"
	PASS=$((PASS + 1))
else
	echo "  FAIL: nonexistent ref produced status=$status instead of an error"
	FAIL=$((FAIL + 1))
fi
rm -rf "$work"

echo "Test 8b: an explicit mode still rejects a garbage ref range"
# Auto mode refuses the range while classifying it. An explicit --mode skips
# classification, so the changeset builders' own check is the only one left.
work=$(mktemp -d)
setup_repo "$work" >/dev/null 2>&1
for m in code specs; do
	result=$(prepare_in "$work" --mode "$m" --scope range --scope-value 'no-such-ref..HEAD')
	assert_json_field "$result" "status" "skip" "--mode $m rejects a nonexistent ref"
done
rm -rf "$work"

echo "Test 9: a valid ref range on a multi-commit repo still works"
# Regression guard for Tests 7 and 8: the new validation must not reject
# ranges that do resolve.
work=$(mktemp -d)
setup_repo "$work" >/dev/null 2>&1
result=$(prepare_in "$work" --scope range --scope-value 'main..feature-head')
assert_json_field "$result" "status" "ok" "valid range prepares a session"
rm -rf "$work"

echo "Test 10: an explicit range needs no main or master (RC-063)"
# A range names both of its own ends, so nothing is diffed against a base
# branch. Refusing it for a missing `main` stopped a live review of
# HEAD~1..HEAD in a single-branch clone. Test 6 keeps `changed` refusing,
# because base...HEAD is exactly what that scope diffs.
work=$(mktemp -d)
setup_single_commit_repo "$work" topic
(cd "$work" && echo "// second" >>a.go && git commit -qam second)
for m in auto code; do
	args=(--scope range --scope-value 'HEAD~1..HEAD')
	[[ "$m" == code ]] && args=(--mode code "${args[@]}")
	result=$(prepare_in "$work" "${args[@]}")
	assert_json_field "$result" "status" "ok" "mode $m: range prepares without a base branch"
	session=$(jq -r '.session_dir' <<<"$result")
	if grep -qE '^Base: +none \(explicit range\)$' "$session/session.txt"; then
		echo "  PASS: mode $m: session.txt says the range has no base"
		PASS=$((PASS + 1))
	else
		base_line=$(grep '^Base:' "$session/session.txt" || echo "no Base line")
		echo "  FAIL: mode $m: session.txt Base line is '$base_line'"
		FAIL=$((FAIL + 1))
	fi
done
result=$(prepare_in "$work" --scope range --scope-value 'no-such-ref..HEAD')
assert_json_field "$result" "status" "skip" "an unresolvable range is still refused"
assert_message_lacks "$result" '[Bb]ase branch' "refused for the range, not the base branch"
rm -rf "$work"
# Other scopes also leave the base empty; only a range may be labelled one.
work=$(mktemp -d)
echo "package main" >"$work/a.go"
result=$(prepare_in "$work" --scope paths --scope-value a.go)
session=$(jq -r '.session_dir' <<<"$result")
if [[ -f "$session/session.txt" ]] && ! grep -q 'explicit range' "$session/session.txt"; then
	echo "  PASS: a no-git paths review is not labelled a range"
	PASS=$((PASS + 1))
else
	echo "  FAIL: no-git paths session mislabelled or missing ($result)"
	FAIL=$((FAIL + 1))
fi
rm -rf "$work"

echo "Test 11: a range value cannot smuggle a git option (RC-064)"
# The range is passed to `git diff` as its first argument, so `--output=<path>`
# was read as an option: git wrote the diff over any file the user could write,
# and the run then reported "No changes to review". No ref name may begin with
# `-`, so refusing that prefix costs nothing legitimate.
work=$(mktemp -d)
setup_single_commit_repo "$work" main
(cd "$work" && echo "// second" >>a.go && git commit -qam second)
target="$work/clobbered"
for v in "--output=$target" "-p"; do
	result=$(prepare_in "$work" --scope range --scope-value "$v")
	assert_json_field "$result" "status" "skip" "range '$v' is refused"
	assert_message_matches "$result" '[Oo]ption' "refusal for '$v' says it reads as an option"
done
if [[ -e "$target" ]]; then
	echo "  FAIL: git wrote $target through the range value"
	FAIL=$((FAIL + 1))
else
	echo "  PASS: no file was written through the range value"
	PASS=$((PASS + 1))
fi
rm -rf "$work"

echo "Test: preparation files a symlink leaving the repository (RC-076)"
work=$(mktemp -d)
(
	cd "$work"
	git_init_sandbox
	echo base >README
	git add README
	git commit -qm base
	ln -s /etc/passwd leak
	git add leak
	git commit -qm link
)
result=$(prepare_in "$work" --scope range --scope-value "HEAD~1..HEAD")
assert_json_field "$result" "status" "ok" "status is ok"
sess=$(jq -r '.session_dir // empty' <<<"$result")
if [[ -n "$sess" ]] && jq -e '.findings[0].file == "leak"' "$sess/verdicts/rc-check-symlinks.json" >/dev/null 2>&1; then
	echo "  PASS: the script verdict is in the session"
	PASS=$((PASS + 1))
else
	echo "  FAIL: no script verdict after preparation"
	FAIL=$((FAIL + 1))
fi
rm -rf "$work"

echo "Test: the operator's diff configuration cannot hide a symlink (RC-076)"
# diff.patch is built with the operator's git, and plain `git diff` honours
# their config: color.diff=always put escape codes before every header, so the
# link was never seen, and diff.mnemonicPrefix filed it as w/leak. The staged
# link makes the diff index-to-commit, where the mnemonic prefixes apply.
work=$(mktemp -d)
(
	cd "$work"
	git_init_sandbox
	echo base >README
	git add README
	git commit -qm base
	git config color.diff always
	git config diff.mnemonicPrefix true
	ln -s /etc/passwd leak
	git add leak
)
result=$(prepare_in "$work")
assert_json_field "$result" "status" "ok" "status is ok"
sess=$(jq -r '.session_dir // empty' <<<"$result")
if [[ -n "$sess" ]] && jq -e '[.findings[].file] == ["leak"]' "$sess/verdicts/rc-check-symlinks.json" >/dev/null 2>&1; then
	echo "  PASS: the link is filed at its real path"
	PASS=$((PASS + 1))
else
	echo "  FAIL: the link was missed or filed at the wrong path"
	FAIL=$((FAIL + 1))
fi
rm -rf "$work"

echo "Test: preparation judges a new link against links the change does not touch (RC-078)"
# sub/up -> .. is on the base and stays inside; x -> sub/up/.. resolves to the
# repository's parent. Only the index listing preparation writes as
# head-links.json shows the check where sub/up points.
work=$(mktemp -d)
(
	cd "$work"
	git_init_sandbox
	echo base >README
	mkdir sub
	ln -s .. sub/up
	git add README sub/up
	git commit -qm base
	ln -s sub/up/.. x
	git add x
	git commit -qm link
)
result=$(prepare_in "$work" --scope range --scope-value "HEAD~1..HEAD")
assert_json_field "$result" "status" "ok" "status is ok"
sess=$(jq -r '.session_dir // empty' <<<"$result")
if [[ -n "$sess" ]] && jq -e '[.findings[] | "\(.severity) \(.file)"] == ["HIGH x"]' \
	"$sess/verdicts/rc-check-symlinks.json" >/dev/null 2>&1; then
	echo "  PASS: x is filed as a HIGH finding"
	PASS=$((PASS + 1))
else
	echo "  FAIL: the chain through sub/up was not reported"
	FAIL=$((FAIL + 1))
fi
rm -rf "$work"

echo "Test: a symlink check that fails stops preparation (RC-076)"
# Reviewing on without the check would drop the one finding no reviewer is
# relied on for. A copy of the skill whose check crashes stands in for any
# failure inside it.
work=$(mktemp -d)
skill=$(mktemp -d)
cp -R "$SCRIPT_DIR/../skills/review-council"/. "$skill"/
printf '#!/usr/bin/env bash\nexit 1\n' >"$skill/scripts/rc-check-symlinks.sh"
(
	cd "$work"
	git_init_sandbox
	echo base >README
	git add README
	git commit -qm base
	ln -s /etc/passwd leak
	git add leak
	git commit -qm link
)
result=$(cd "$work" && AGENTS_DIR="$AGENTS" bash "$skill/scripts/rc-prepare.sh" --scope range --scope-value "HEAD~1..HEAD" 2>/dev/null)
assert_json_field "$result" "status" "skip" "status is skip"
assert_message_matches "$result" 'symlink check could not run' "the message names the check"
rm -rf "$work" "$skill"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
