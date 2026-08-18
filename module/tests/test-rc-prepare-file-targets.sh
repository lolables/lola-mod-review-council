#!/usr/bin/env bash
# Explicit file targets: `--scope paths` naming a FILE rather than a directory.
#
# The bug this suite was written for: `--scope paths` was a filter over a git
# diff and nothing else, so it could only ever surface a path that already had
# changes in it. Naming a file to review it — the most obvious thing to ask of a
# review tool — returned "No changes to review" whenever that file was
# untracked, gitignored, or simply committed and unmodified. The file was on
# disk the whole time; discovery never looked there.
#
# The rule these tests pin: an entry of --scope-value that resolves to an
# existing FILE is a target, taken from disk regardless of what git thinks of
# it. An entry that resolves to a DIRECTORY keeps its old meaning — a filter
# over the changeset — because that is what the routing table has always sent
# here and widening it would turn "review my changes under src/" into a review
# of all of src/.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$SCRIPT_DIR/../skills/review-council/scripts/rc-prepare.sh"
AGENTS="$SCRIPT_DIR/../agents"
# shellcheck source=module/tests/helpers.sh
source "$SCRIPT_DIR/helpers.sh"

# A repo holding one file of every git status a target can have: committed and
# unmodified, committed and modified, untracked, and ignored. Every case below
# names a file whose content is on disk and whose git status is the only thing
# that differs.
make_target_repo() {
	local work
	work=$(mktemp -d)
	(
		cd "$work" || exit 1
		git_init_sandbox
		git checkout -q -b main
		mkdir -p src docs build
		echo "package main" >src/quiet.go   # committed, never touched again
		echo "package main" >src/changed.go # committed, modified below
		echo "quiet" >.gitignore            # so build/ is ignored
		echo "# Plan" >docs/plan.md
		git add src docs .gitignore
		git commit -qm init
		printf 'build/\n' >>.gitignore
		echo "// edit" >>src/changed.go   # unstaged modification
		echo "package main" >src/fresh.go # untracked
		echo "package main" >build/gen.go # ignored
	)
	printf '%s' "$work"
}

run_prepare() { # <workdir> <args...> -> prints the JSON result
	local work="$1"
	shift
	(cd "$work" && AGENTS_DIR="$AGENTS" bash "$SCRIPT" "$@" 2>/dev/null)
}

changeset_of() { # <result json> -> prints changeset.txt, or nothing
	# Always succeeds: an empty result is a normal outcome here (two cases
	# assert on it), and under `set -e` a non-zero return would abort the suite
	# at the first such case instead of reporting it.
	local sess
	sess=$(jq -r '.session_dir // empty' <<<"$1")
	if [[ -n "$sess" && -f "$sess/changeset.txt" ]]; then
		cat "$sess/changeset.txt"
	fi
	return 0
}

# The changeset is flattened into a variable before it reaches the message
# rather than inline: a command substitution nested inside another command has
# its exit status discarded (SC2312), and every suite here is linted with the
# optional checks on.
assert_in_changeset() { # <changeset> <path> <label>
	local flattened
	if grep -qxF "$2" <<<"$1"; then
		echo "  PASS: $3"
		PASS=$((PASS + 1))
	else
		flattened=$(tr '\n' ' ' <<<"$1")
		echo "  FAIL: $3 (changeset: $flattened)"
		FAIL=$((FAIL + 1))
	fi
}

assert_not_in_changeset() { # <changeset> <path> <label>
	local flattened
	if grep -qxF "$2" <<<"$1"; then
		flattened=$(tr '\n' ' ' <<<"$1")
		echo "  FAIL: $3 (changeset: $flattened)"
		FAIL=$((FAIL + 1))
	else
		echo "  PASS: $3"
		PASS=$((PASS + 1))
	fi
}

echo "Test 1: an untracked file is reviewable when named"
work=$(make_target_repo)
result=$(run_prepare "$work" --scope paths --scope-value src/fresh.go)
assert_json_field "$result" "status" "ok" "status is ok for an untracked file target"
changeset=$(changeset_of "$result")
assert_in_changeset "$changeset" "src/fresh.go" "untracked file is in the changeset"
assert_not_in_changeset "$changeset" "src/changed.go" "an unnamed changed file stays out"
rm -rf "$work"

echo "Test 2: a committed, unmodified file is reviewable when named"
# The everyday case: reviewing code that is already merged. It has no diff
# against any base, so a diff-only discovery can never find it.
work=$(make_target_repo)
result=$(run_prepare "$work" --scope paths --scope-value src/quiet.go)
assert_json_field "$result" "status" "ok" "status is ok for an unmodified file target"
changeset=$(changeset_of "$result")
assert_in_changeset "$changeset" "src/quiet.go" "unmodified tracked file is in the changeset"
rm -rf "$work"

echo "Test 3: a gitignored file is reviewable when named"
# .gitignore says "do not commit this", not "do not review this". Naming the
# path IS the intent; a generated or vendored file a user points at explicitly
# has to be reachable, or the tool cannot review it at all.
work=$(make_target_repo)
result=$(run_prepare "$work" --scope paths --scope-value build/gen.go)
assert_json_field "$result" "status" "ok" "status is ok for an ignored file target"
changeset=$(changeset_of "$result")
assert_in_changeset "$changeset" "build/gen.go" "ignored file is in the changeset"
rm -rf "$work"

echo "Test 4: several targets in one --scope-value are all resolved"
# The comma-separated form the secondary filter already accepts. The primary
# branch passed the whole string to git as ONE pathspec, so "a.go,b.go" matched
# nothing at all.
work=$(make_target_repo)
result=$(run_prepare "$work" --scope paths --scope-value "src/fresh.go,src/quiet.go")
assert_json_field "$result" "status" "ok" "status is ok for two file targets"
changeset=$(changeset_of "$result")
assert_in_changeset "$changeset" "src/fresh.go" "first named file is in the changeset"
assert_in_changeset "$changeset" "src/quiet.go" "second named file is in the changeset"
rm -rf "$work"

echo "Test 5: a file target and a directory filter can be mixed"
# The directory half keeps its old meaning — changed files under it — while the
# file half is taken from disk. Both in one run, because a user reviewing a
# feature names the directory they touched and the one config file they did not.
work=$(make_target_repo)
result=$(run_prepare "$work" --scope paths --scope-value "src/,build/gen.go")
assert_json_field "$result" "status" "ok" "status is ok for a mixed target list"
changeset=$(changeset_of "$result")
assert_in_changeset "$changeset" "src/changed.go" "changed file under the named directory"
assert_in_changeset "$changeset" "build/gen.go" "explicitly named file outside it"
assert_not_in_changeset "$changeset" "src/quiet.go" "directory filter stays a filter, not a sweep"
rm -rf "$work"

echo "Test 6: naming a file does not drag in its neighbours by prefix"
# The filter matched with `$file == $fp*`, so a target of `src/changed.go`
# also admitted `src/changed.go.bak` — and a target of `src/q` would have
# admitted `src/quiet.go`. A path is a path, not a prefix.
work=$(make_target_repo)
(cd "$work" && echo "package main" >src/fresh.go.bak)
result=$(run_prepare "$work" --scope paths --scope-value src/fresh.go)
changeset=$(changeset_of "$result")
assert_in_changeset "$changeset" "src/fresh.go" "the named file is in the changeset"
assert_not_in_changeset "$changeset" "src/fresh.go.bak" "the prefix neighbour is not"
rm -rf "$work"

echo "Test 7: --scope all with a file filter admits exactly that file"
# The recovery path SKILL.md sends an empty `--scope changed` run down. It
# already reached untracked files; the prefix bug applied here too.
work=$(make_target_repo)
(cd "$work" && echo "package main" >src/fresh.go.bak)
result=$(run_prepare "$work" --scope all --scope paths --scope-value src/fresh.go)
assert_json_field "$result" "status" "ok" "status is ok for --scope all with a file filter"
changeset=$(changeset_of "$result")
assert_in_changeset "$changeset" "src/fresh.go" "the named file survives the filter"
assert_not_in_changeset "$changeset" "src/fresh.go.bak" "the prefix neighbour does not"
rm -rf "$work"

echo "Test 8: spec mode accepts a single spec file as a target"
# collect_specs_in returned early unless its argument was a directory, so
# --mode specs --scope paths <file> reported "No spec artifacts found" for a
# spec file sitting right there on disk.
work=$(make_target_repo)
result=$(run_prepare "$work" --mode specs --scope paths --scope-value docs/plan.md)
assert_json_field "$result" "status" "ok" "status is ok for a single spec file target"
changeset=$(changeset_of "$result")
assert_in_changeset "$changeset" "docs/plan.md" "named spec file is in the changeset"
# Spec mode normalises its entries in its own loop, so the trailing slash Test
# 12 pins for code mode has to be pinned here too or that half goes unguarded.
result=$(run_prepare "$work" --mode specs --scope paths --scope-value docs/plan.md/)
assert_json_field "$result" "status" "ok" "a spec file target survives a trailing slash"
rm -rf "$work"

echo "Test 9: a target that does not exist is refused, not reported as clean"
# Reported as "No changes to review. Changeset is empty." — indistinguishable
# from a clean tree, so a mistyped path read as a passing review of nothing, in
# the one direction a review tool must never be wrong. It is `skip` rather than
# `empty` for the same reason an unresolvable --base or ref range is: `empty`
# buys a recovery re-run under --scope all, and no scope widening will conjure
# up a path that is not there. Terminal, and naming the path, matches what the
# script already does for the other two unusable arguments.
work=$(make_target_repo)
result=$(run_prepare "$work" --scope paths --scope-value src/nosuch.go)
assert_json_field "$result" "status" "skip" "status is skip for a nonexistent target"
message=$(jq -r '.message // ""' <<<"$result")
if grep -qF 'src/nosuch.go' <<<"$message"; then
	echo "  PASS: the message names the path it could not find"
	PASS=$((PASS + 1))
else
	echo "  FAIL: the message does not name the missing path (got: $message)"
	FAIL=$((FAIL + 1))
fi
rm -rf "$work"

echo "Test 9b: one bad path in a list does not pass as a partial review"
# The subset failure: name two targets, mistype one, and a check that fires only
# on an empty changeset stays quiet because the other target filled it. The
# review then covers half of what was asked for and says nothing about it.
work=$(make_target_repo)
result=$(run_prepare "$work" --scope paths --scope-value "src/fresh.go,src/nosuch.go")
assert_json_field "$result" "status" "skip" "status is skip when one of two targets is missing"
rm -rf "$work"

echo "Test 9c: a file deleted in the changeset is still a valid target"
# The counter-case that keeps the check above honest. A path deleted on this
# branch is absent from disk and present in the diff — a legitimate thing to
# review, and indistinguishable from a typo by an existence test alone.
work=$(make_target_repo)
(cd "$work" && git checkout -q -b drop-quiet && git rm -q src/quiet.go && git commit -qm "drop quiet")
result=$(run_prepare "$work" --scope paths --scope-value src/quiet.go)
assert_json_field "$result" "status" "ok" "a deleted-in-diff target is not refused"
changeset=$(changeset_of "$result")
assert_in_changeset "$changeset" "src/quiet.go" "the deleted file is in the changeset"
rm -rf "$work"

echo "Test 10: a directory target with no changes under it stays empty"
# The regression that matters most. Directory scope is a FILTER, and widening it
# to "every file under here" would silently turn the routing table's
# `--scope changed --scope paths src/` into a full sweep of src/ — a much
# larger, slower, and differently-scoped review than the one asked for.
work=$(make_target_repo)
result=$(run_prepare "$work" --scope paths --scope-value docs/)
assert_json_field "$result" "status" "empty" "an unchanged directory is still empty"
rm -rf "$work"

echo "Test 11: the named target decides the mode, not the rest of the branch"
# Auto-detection classified the whole branch diff and never looked at what was
# actually being reviewed. Name one Go file while the branch happens to have
# touched only documentation and the run came back mode=spec: the spec council
# reviewing source, with the code personas — and every code convention pack —
# never dispatched. The reverse costs as much, so both directions are pinned.
work=$(mktemp -d)
(
	cd "$work" || exit 1
	git_init_sandbox
	git checkout -q -b main
	mkdir -p src docs
	echo "package main" >src/app.go
	echo "# Plan" >docs/plan.md
	git add src docs
	git commit -qm init
	git checkout -q -b docs-only
	echo "more" >>docs/plan.md
	git commit -qam docs
)
result=$(run_prepare "$work" --scope paths --scope-value src/app.go)
assert_json_field "$result" "mode" "code" "a Go target on a docs-only branch is a code review"
agents=$(jq -r '.agents | join(",")' <<<"$result")
if grep -qF -- '-code' <<<"$agents"; then
	echo "  PASS: the code council was dispatched"
	PASS=$((PASS + 1))
else
	echo "  FAIL: wrong council for a code target (got: $agents)"
	FAIL=$((FAIL + 1))
fi
result=$(run_prepare "$work" --scope paths --scope-value docs/plan.md)
assert_json_field "$result" "mode" "spec" "a spec target is a spec review"
rm -rf "$work"

echo "Test 11b: mode detection reads the same normalised targets as the changeset"
# Normalising inside the changeset builder alone leaves mode detection looking
# at the raw string. `src/app.go/` is not a file to `-f`, so detection falls
# through to its no-changes branch, finds a specs/ directory in the repo and
# resolves to spec — while the changeset builder, having normalised, hands the
# spec council a Go file. One list, normalised once, or the two stages disagree
# about what is being reviewed.
work=$(mktemp -d)
(
	cd "$work" || exit 1
	git_init_sandbox
	git checkout -q -b main
	mkdir -p src specs
	echo "package main" >src/app.go
	echo "# Overview" >specs/overview.md
	git add src specs
	git commit -qm init
)
result=$(run_prepare "$work" --scope paths --scope-value src/app.go/)
assert_json_field "$result" "mode" "code" "a trailing-slash Go target is still a code review"
rm -rf "$work"

echo "Test 12: a trailing slash on a target does not lose it"
# `-e path/` is false for a regular file, so `src/fresh.go/` was refused with
# "Target not found: src/fresh.go" — naming, as the path it could not find, a
# path that is plainly there. Whatever the answer is, it cannot be that.
work=$(make_target_repo)
result=$(run_prepare "$work" --scope paths --scope-value src/fresh.go/)
assert_json_field "$result" "status" "ok" "a file target survives a trailing slash"
changeset=$(changeset_of "$result")
assert_in_changeset "$changeset" "src/fresh.go" "the target is recorded without the slash"
rm -rf "$work"

echo "Test 13: an empty entry in the list is not a missing target"
# A doubled comma is what a generated flag string produces on its own when one
# of the paths it was assembling came out blank. `read -ra` drops a TRAILING
# empty field but keeps an interior one, so this is the form that reaches the
# loop — a path that exists nowhere, taking the whole run down with a
# "Target not found: " that names nothing at all.
work=$(make_target_repo)
result=$(run_prepare "$work" --scope paths --scope-value "src/fresh.go,,src/quiet.go")
assert_json_field "$result" "status" "ok" "an empty entry does not refuse the run"
changeset=$(changeset_of "$result")
assert_in_changeset "$changeset" "src/fresh.go" "the first real target is still reviewed"
assert_in_changeset "$changeset" "src/quiet.go" "the second real target is still reviewed"
rm -rf "$work"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
