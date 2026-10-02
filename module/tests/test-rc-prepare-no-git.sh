#!/usr/bin/env bash
# Reviewing files outside any git repository.
#
# A file on disk is reviewable whether or not git knows about it: the reviewers
# read bytes, not history. `--scope paths` and `--scope all` therefore run in a
# plain directory, reviewing what is there — a named file whole, a named
# directory as every file under it — and say in the result message that there
# is no diff, base branch or forge context behind the review.
#
# The scopes that are defined BY git history — changed, range, pr — still
# refuse: there is no honest answer to "what changed" without a repository, and
# inventing one (a scratch repo whose only commit is the file itself) would
# report a diff that never happened.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$SCRIPT_DIR/../skills/review-council/scripts/rc-prepare.sh"
AGENTS="$SCRIPT_DIR/../agents"
# shellcheck source=module/tests/helpers.sh
source "$SCRIPT_DIR/helpers.sh"

# Everything this suite makes lives under one root removed on exit, sessions
# included: rc-prepare.sh writes them under XDG_CACHE_HOME, which would
# otherwise be the caller's real cache. GIT_CEILING_DIRECTORIES stops git's
# upward search at that root, so the fixtures are non-git even when TMPDIR sits
# inside a checkout — the suite never has to skip.
suite_root=$(mktemp -d)
trap 'rm -rf "$suite_root"' EXIT
export XDG_CACHE_HOME="$suite_root/cache"
export GIT_CEILING_DIRECTORIES="$suite_root"

prepare_in() { # dir [args...]
	local dir="$1"
	shift
	(cd "$dir" && AGENTS_DIR="$AGENTS" bash "$SCRIPT" "$@" 2>/dev/null)
}

changeset_of() { # <result json> -> prints changeset.txt, or nothing
	local sess
	sess=$(jq -r '.session_dir // empty' <<<"$1")
	if [[ -n "$sess" && -f "$sess/changeset.txt" ]]; then
		cat "$sess/changeset.txt"
	fi
	return 0
}

assert_message_matches() { # json regex label
	local msg
	msg=$(jq -r '.message // empty' <<<"$1")
	if [[ "$msg" =~ $2 ]]; then
		echo "  PASS: $3"
		PASS=$((PASS + 1))
	else
		echo "  FAIL: $3 (got: $msg)"
		FAIL=$((FAIL + 1))
	fi
}

assert_changeset_has() { # changeset path label
	if grep -qxF -- "$2" <<<"$1"; then
		echo "  PASS: $3"
		PASS=$((PASS + 1))
	else
		echo "  FAIL: $3 (changeset: ${1//$'\n'/ })"
		FAIL=$((FAIL + 1))
	fi
}

assert_changeset_lacks() { # changeset path label
	if grep -qxF -- "$2" <<<"$1"; then
		echo "  FAIL: $3 (changeset: ${1//$'\n'/ })"
		FAIL=$((FAIL + 1))
	else
		echo "  PASS: $3"
		PASS=$((PASS + 1))
	fi
}

# A plain directory: source, a vendored tree the smart excludes drop, a binary,
# and a spec. No `git init` anywhere — mktemp lands under /tmp, outside any
# checkout, so `git rev-parse` walking upward finds nothing.
make_plain_dir() {
	local work
	work=$(mktemp -d "$suite_root/work.XXXXXX")
	mkdir -p "$work/src" "$work/src/node_modules/dep" "$work/docs/specs"
	echo "package main" >"$work/src/app.go"
	echo "package main" >"$work/src/util.go"
	echo "module.exports = {}" >"$work/src/node_modules/dep/index.js"
	printf '\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00' >"$work/src/tool.bin"
	echo "# Spec" >"$work/docs/specs/feature.md"
	printf '%s' "$work"
}

# ---------------------------------------------------------------------------
echo "Test 1: a named file outside git is reviewed whole"
work=$(make_plain_dir)
result=$(prepare_in "$work" --mode code --scope paths --scope-value src/app.go)
assert_json_field "$result" "status" "ok" "paths scope on a file prepares a session"
changeset=$(changeset_of "$result")
assert_changeset_has "$changeset" "src/app.go" "the named file is the changeset"
assert_changeset_lacks "$changeset" "src/util.go" "an unnamed sibling is not reviewed"
assert_message_matches "$result" 'Warning: not a git repository' "message carries the warning SKILL.md relays"
sess=$(jq -r '.session_dir // empty' <<<"$result")
if [[ -n "$sess" && ! -s "$sess/diff.patch" ]]; then
	echo "  PASS: no diff is fabricated for a file with no history"
	PASS=$((PASS + 1))
else
	echo "  FAIL: a diff.patch was written for a non-git review"
	FAIL=$((FAIL + 1))
fi
rm -rf "$work"

echo "Test 2: a named directory outside git is reviewed as every file under it"
# Inside a repo a directory filters the changeset. With no repo there is no
# changeset to filter, so the only meaning left is the directory's contents.
work=$(make_plain_dir)
result=$(prepare_in "$work" --mode code --scope paths --scope-value src)
assert_json_field "$result" "status" "ok" "paths scope on a directory prepares a session"
changeset=$(changeset_of "$result")
assert_changeset_has "$changeset" "src/app.go" "first file under the directory is reviewed"
assert_changeset_has "$changeset" "src/util.go" "second file under the directory is reviewed"
assert_changeset_lacks "$changeset" "src/node_modules/dep/index.js" "smart excludes still drop vendored trees"
assert_changeset_lacks "$changeset" "src/tool.bin" "binary files are still dropped"
rm -rf "$work"

echo "Test 3: a mistyped path outside git is refused, never 'no changes'"
work=$(make_plain_dir)
result=$(prepare_in "$work" --mode code --scope paths --scope-value src/nope.go)
assert_json_field "$result" "status" "skip" "missing target refuses"
assert_message_matches "$result" 'Target not found: src/nope.go' "refusal names the missing path"
rm -rf "$work"

echo "Test 4: --scope all outside git reviews the whole tree"
work=$(make_plain_dir)
result=$(prepare_in "$work" --mode code --scope all)
assert_json_field "$result" "status" "ok" "all scope prepares a session"
changeset=$(changeset_of "$result")
assert_changeset_has "$changeset" "src/app.go" "files are listed relative to the directory"
assert_changeset_lacks "$changeset" "src/node_modules/dep/index.js" "smart excludes apply to the whole tree"
assert_message_matches "$result" 'Warning: not a git repository' "message carries the warning SKILL.md relays"
rm -rf "$work"

echo "Test 5: auto mode classifies a named directory outside git by its contents"
work=$(make_plain_dir)
result=$(prepare_in "$work" --scope paths --scope-value src)
assert_json_field "$result" "mode" "code" "a directory of Go source is code mode"
result=$(prepare_in "$work" --scope paths --scope-value docs/specs)
assert_json_field "$result" "mode" "spec" "a directory of specs is spec mode"
rm -rf "$work"

echo "Test 6: history scopes still refuse outside git, and point at what works"
work=$(make_plain_dir)
for scope_args in "" "--scope changed" "--scope range --scope-value HEAD~1..HEAD" "--scope pr --scope-value 42"; do
	# shellcheck disable=SC2086 # word-splitting the flag string is the point
	result=$(prepare_in "$work" $scope_args)
	assert_json_field "$result" "status" "skip" "'${scope_args:-default scope}' refuses"
	assert_message_matches "$result" 'scope paths' "'${scope_args:-default scope}' refusal points at --scope paths"
done
rm -rf "$work"

echo "Test 7: a path beginning with '-' is a path, never a find option"
# find reads a leading-dash start point as an expression: `-delete` named as a
# target erased the working directory before the missing-target refusal ran.
work=$(make_plain_dir)
mkdir -p "$work/keep" "$work/-d"
echo "precious" >"$work/keep/data.txt"
echo "package main" >"$work/-x.go"
echo "package main" >"$work/-d/f.go"
result=$(prepare_in "$work" --mode code --scope paths --scope-value -delete)
assert_json_field "$result" "status" "skip" "'-delete' is a missing target, refused"
if [[ -f "$work/keep/data.txt" && -f "$work/src/app.go" ]]; then
	echo "  PASS: nothing was deleted"
	PASS=$((PASS + 1))
else
	echo "  FAIL: files were deleted by a target named -delete"
	FAIL=$((FAIL + 1))
fi
result=$(prepare_in "$work" --scope paths --scope-value -delete)
if [[ -f "$work/keep/data.txt" ]]; then
	echo "  PASS: auto-mode detection deleted nothing either"
	PASS=$((PASS + 1))
else
	echo "  FAIL: mode detection ran find on -delete"
	FAIL=$((FAIL + 1))
fi
result=$(prepare_in "$work" --mode code --scope paths --scope-value -x.go)
assert_json_field "$result" "status" "ok" "a file named -x.go is reviewable"
changeset=$(changeset_of "$result")
assert_changeset_has "$changeset" "-x.go" "-x.go is the changeset"
result=$(prepare_in "$work" --mode code --scope paths --scope-value -d)
changeset=$(changeset_of "$result")
assert_changeset_has "$changeset" "-d/f.go" "a directory named -d reviews its files"
assert_changeset_lacks "$changeset" "src/app.go" "-d is not read as -depth over the whole tree"
rm -rf "$work"

echo "Test 8: a target outside the working directory is refused, never silently stripped"
# Evidence verification strips every finding on a file outside the review root,
# so preparing such a target produces a review that reads clean.
work=$(make_plain_dir)
other=$(mktemp -d "$suite_root/other.XXXXXX")
echo "package main" >"$other/o.go"
result=$(prepare_in "$work" --mode code --scope paths --scope-value "$other/o.go")
assert_json_field "$result" "status" "skip" "absolute path outside the directory refused"
assert_message_matches "$result" '[Oo]utside' "refusal says why"
mkdir -p "$work/sub"
result=$(prepare_in "$work/sub" --mode code --scope paths --scope-value ../src/app.go)
assert_json_field "$result" "status" "skip" "'..' escaping the directory refused"
ln -s "$other" "$work/link"
result=$(prepare_in "$work" --mode code --scope paths --scope-value link)
assert_json_field "$result" "status" "skip" "a symlink leading outside is refused"
result=$(prepare_in "$work" --mode code --scope paths --scope-value "$work/src/app.go")
assert_json_field "$result" "status" "ok" "an absolute path inside the directory is fine"
changeset=$(changeset_of "$result")
assert_changeset_has "$changeset" "src/app.go" "and is recorded relative to it"
ln -s src "$work/srclink"
result=$(prepare_in "$work" --mode code --scope paths --scope-value srclink)
changeset=$(changeset_of "$result")
assert_changeset_has "$changeset" "src/app.go" "a symlink inside the directory reviews its target"
rm -rf "$work" "$other"

echo "Test 9: --base outside git is refused, not ignored"
work=$(make_plain_dir)
result=$(prepare_in "$work" --mode code --scope all --base main)
assert_json_field "$result" "status" "skip" "--base outside git refuses"
assert_message_matches "$result" 'base' "refusal names --base"
rm -rf "$work"

echo "Test 10: --scope all in auto mode outside git classifies the tree, not an empty diff"
work=$(make_plain_dir)
mkdir -p "$work/src/more"
for n in 1 2 3; do echo "package main" >"$work/src/more/f$n.go"; done
mkdir -p "$work/specs" && echo "# Spec" >"$work/specs/x.md"
result=$(prepare_in "$work" --scope all)
assert_json_field "$result" "mode" "code" "a mostly-source tree is code mode"
rm -rf "$work"

echo "Test 11: a mistyped secondary filter is refused, never 'no changes'"
work=$(make_plain_dir)
result=$(prepare_in "$work" --mode code --scope all --scope paths --scope-value srcx)
assert_json_field "$result" "status" "skip" "unknown filter path refused"
assert_message_matches "$result" 'Target not found: srcx' "refusal names it"
result=$(prepare_in "$work" --mode code --scope all --scope paths --scope-value src)
changeset=$(changeset_of "$result")
assert_changeset_has "$changeset" "src/app.go" "a real filter still narrows the tree"
assert_changeset_lacks "$changeset" "docs/specs/feature.md" "and drops what is outside it"
rm -rf "$work"

echo "Test 12: the skill's directory routing (changed + paths) works outside git"
# SKILL.md routes a named directory to `--scope changed --scope paths <dir>`.
# Outside git there are no changes to filter, so that must mean the directory's
# contents, or the skill can never reach the directory review at all.
work=$(make_plain_dir)
result=$(prepare_in "$work" --mode code --scope changed --scope paths --scope-value src)
assert_json_field "$result" "status" "ok" "changed + paths outside git prepares a session"
changeset=$(changeset_of "$result")
assert_changeset_has "$changeset" "src/app.go" "the directory's files are reviewed"
assert_changeset_lacks "$changeset" "docs/specs/feature.md" "nothing outside the directory is"
result=$(prepare_in "$work" --mode code --scope changed)
assert_json_field "$result" "status" "skip" "changed alone outside git still refuses"
rm -rf "$work"

echo "Test 13: walked trees outside git leave credential-looking files out"
# With no ignore list, a directory walk would hand .env files and private keys
# to the reviewers. Walked files that look like credentials are dropped and
# counted; a file named explicitly is still reviewed, because naming it is the
# intent.
work=$(make_plain_dir)
mkdir -p "$work/src/.ssh"
echo "TOKEN=x" >"$work/src/.env"
echo "TOKEN=y" >"$work/src/.env.production"
echo "-----BEGIN PRIVATE KEY-----" >"$work/src/deploy.pem"
echo "-----BEGIN OPENSSH PRIVATE KEY-----" >"$work/src/.ssh/id_ed25519"
result=$(prepare_in "$work" --mode code --scope all)
changeset=$(changeset_of "$result")
for secret in src/.env src/.env.production src/deploy.pem src/.ssh/id_ed25519; do
	assert_changeset_lacks "$changeset" "$secret" "--scope all leaves $secret out"
done
assert_changeset_has "$changeset" "src/app.go" "ordinary source is still reviewed"
assert_message_matches "$result" '4 file\(s\) that look like credentials' "the message counts what was left out"
result=$(prepare_in "$work" --mode code --scope paths --scope-value src)
changeset=$(changeset_of "$result")
assert_changeset_lacks "$changeset" "src/.env" "a directory walk leaves .env out too"
result=$(prepare_in "$work" --mode code --scope paths --scope-value src/.env)
changeset=$(changeset_of "$result")
assert_changeset_has "$changeset" "src/.env" "a credential file named explicitly is reviewed"
rm -rf "$work"

echo "Test 14: a comma-separated list outside git reviews every entry, and refuses a partly missing one"
work=$(make_plain_dir)
result=$(prepare_in "$work" --mode code --scope paths --scope-value src/app.go,docs/specs)
changeset=$(changeset_of "$result")
assert_changeset_has "$changeset" "src/app.go" "the named file is reviewed"
assert_changeset_has "$changeset" "docs/specs/feature.md" "and so is the named directory's file"
assert_changeset_lacks "$changeset" "src/util.go" "an unnamed sibling is not"
result=$(prepare_in "$work" --mode code --scope paths --scope-value src/app.go,src/nope.go)
assert_json_field "$result" "status" "skip" "one missing entry refuses the whole list"
assert_message_matches "$result" 'Target not found: src/nope.go$|Target not found: src/nope.go\.' "and names only the missing one"
rm -rf "$work"

echo "Test 15: spec mode outside git reviews the named spec directory"
work=$(make_plain_dir)
result=$(prepare_in "$work" --mode specs --scope paths --scope-value docs/specs)
assert_json_field "$result" "mode" "spec" "spec mode"
changeset=$(changeset_of "$result")
assert_changeset_has "$changeset" "docs/specs/feature.md" "the spec is the changeset"
assert_changeset_lacks "$changeset" "src/app.go" "source is not"
rm -rf "$work"

echo "Test 16: a directory holding only excluded files is empty, not an error"
work=$(make_plain_dir)
result=$(prepare_in "$work" --mode code --scope paths --scope-value src/node_modules)
assert_json_field "$result" "status" "empty" "nothing reviewable under it"
rm -rf "$work"

echo "Test 17: a file named explicitly outside git skips every exclusion, as inside a repo"
work=$(make_plain_dir)
echo '{}' >"$work/src/package-lock.json"
result=$(prepare_in "$work" --mode code --scope paths --scope-value src/package-lock.json,src/tool.bin)
changeset=$(changeset_of "$result")
assert_changeset_has "$changeset" "src/package-lock.json" "a smart-excluded name is reviewed when named"
assert_changeset_has "$changeset" "src/tool.bin" "a binary is reviewed when named"
result=$(prepare_in "$work" --mode code --scope paths --scope-value src)
changeset=$(changeset_of "$result")
assert_changeset_lacks "$changeset" "src/package-lock.json" "the same name is still dropped from a walk"
rm -rf "$work"

echo "Test 18: tracking.md records the scope outside git without inventing a ref range"
work=$(make_plain_dir)
result=$(prepare_in "$work" --mode code --scope all)
sess=$(jq -r '.session_dir // empty' <<<"$result")
scope_line=$(grep -m1 '^- Scope value:' "$sess/tracking.md" || true)
assert_equals "$scope_line" "- Scope value: whole directory (no git repository)" "scope value names the directory, not ...HEAD"
rm -rf "$work"

echo "Test 19: walks outside git never descend into excluded trees"
# A vendored tree is dropped from the changeset either way, but walking it first
# is slow (a 3000-file tree took 80s) and let it outvote the real contents when
# auto mode classifies: one spec beside a vendored JS dependency came back code.
work=$(mktemp -d "$suite_root/work.XXXXXX")
mkdir -p "$work/specs" "$work/node_modules/dep/lib"
echo "# Spec" >"$work/specs/feature.md"
for n in 1 2 3 4 5; do echo "module.exports = $n" >"$work/node_modules/dep/lib/f$n.js"; done
result=$(prepare_in "$work" --scope all)
assert_json_field "$result" "mode" "spec" "vendored files do not vote in auto mode"
result=$(prepare_in "$work" --scope paths --scope-value .)
assert_json_field "$result" "mode" "spec" "nor when the directory is named"
rm -rf "$work"

echo "Test 20: an unreadable directory in a walk is reported, not silently skipped"
work=$(make_plain_dir)
mkdir -p "$work/src/locked"
echo "package main" >"$work/src/locked/b.go"
chmod 000 "$work/src/locked"
if [[ -r "$work/src/locked" ]]; then
	echo "  SKIP: running with privileges that read a mode-000 directory"
else
	stderr_log="$suite_root/walk.err"
	result=$(cd "$work" && AGENTS_DIR="$AGENTS" bash "$SCRIPT" --mode code --scope paths --scope-value src 2>"$stderr_log")
	assert_json_field "$result" "status" "ok" "the readable part is still reviewed"
	assert_message_matches "$result" 'could not be read' "the message says part of the tree was not"
	if grep -q 'rc-error' "$stderr_log"; then
		echo "  FAIL: the walk tripped the error trap"
		FAIL=$((FAIL + 1))
	else
		echo "  PASS: no spurious rc-error on stderr"
		PASS=$((PASS + 1))
	fi
fi
chmod 755 "$work/src/locked"
rm -rf "$work"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
