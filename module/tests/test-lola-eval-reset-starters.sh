#!/usr/bin/env bash
# Guards .lola-eval/reset-starters.sh, the step every `task lola-eval:*`
# target runs before the harness does.
#
# The harness installs review-council into each cell with a real `lola
# install` and refuses to run while any starter still ships module artifacts
# (.lola/modules). The old provision.sh wrote exactly those, so a checkout that
# ran it, or a compare-commits leg at an older commit, would stop every eval at
# the harness's own check. The script has to remove all of them, and only them:
# a starter's real files (source, .gitignore) are the fixture the eval scores,
# and deleting one silently changes what is being measured.
#
# Cases are built in a scratch tests dir passed as the script's argument, so
# nothing here touches the real .lola-eval/tests.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$SCRIPT_DIR/../../.lola-eval/reset-starters.sh"
# shellcheck source=module/tests/helpers.sh
source "$SCRIPT_DIR/helpers.sh"

[[ -f "$SCRIPT" ]] || {
	echo "ERROR: script not found: $SCRIPT" >&2
	exit 1
}

# Create <tests_dir>/<case> with a starter holding real files plus every
# artifact the old provisioning could leave behind.
make_case() { # tests_dir case
	local dir="$1/$2"
	mkdir -p "$dir/starter/.lola/modules/review-council/module/agents" \
		"$dir/starter/.claude/agents" "$dir/starter/.opencode/agents" \
		"$dir/starter-clean"
	printf 'package main' >"$dir/starter/main.go"
	printf 'bin/' >"$dir/starter/.gitignore"
	printf 'a' >"$dir/starter/.lola/modules/review-council/module/agents/a.md"
	printf 'a' >"$dir/starter/.claude/agents/a.md"
	printf 'a' >"$dir/starter/.opencode/agents/a.md"
	printf '[user]' >"$dir/starter/.gitconfig"
	printf 'package main' >"$dir/starter-clean/main.go"
	printf 'id: x' >"$dir/task.yaml"
}

presence() { # path
	if [[ -e "$1" ]]; then echo present; else echo absent; fi
}

echo "Test 1: strips every artifact, keeps real files"
tests=$(mktemp -d)
make_case "$tests" case-a
make_case "$tests" case-b
rc=0
out=$(bash "$SCRIPT" "$tests" 2>&1) || rc=$?
assert_equals "$rc" "0" "exit 0"
[[ "$out" == *"2 starter(s)"* ]] && found=yes || found=no
assert_equals "$found" "yes" "stdout counts 2 starter(s)"
for c in case-a case-b; do
	for artifact in .lola .claude .opencode .gitconfig; do
		state=$(presence "$tests/$c/starter/$artifact")
		assert_equals "$state" "absent" "$c starter/$artifact removed"
	done
	state=$(presence "$tests/$c/starter-clean")
	assert_equals "$state" "absent" "$c starter-clean removed"
	assert_equals "$(<"$tests/$c/starter/main.go")" "package main" "$c main.go kept"
	assert_equals "$(<"$tests/$c/starter/.gitignore")" "bin/" "$c .gitignore kept"
	assert_equals "$(<"$tests/$c/task.yaml")" "id: x" "$c task.yaml kept"
done
discard_fixture "$tests"

echo "Test 2: idempotent"
tests=$(mktemp -d)
make_case "$tests" case-a
assert_idempotent "second run changes nothing" "$tests" bash "$SCRIPT" "$tests"
discard_fixture "$tests"

echo "Test 3: case dir without starter/ is untouched and not counted"
tests=$(mktemp -d)
make_case "$tests" case-a
mkdir "$tests/notes"
printf 'keep' >"$tests/notes/notes.md"
rc=0
out=$(bash "$SCRIPT" "$tests" 2>&1) || rc=$?
assert_equals "$rc" "0" "exit 0"
[[ "$out" == *"1 starter(s)"* ]] && found=yes || found=no
assert_equals "$found" "yes" "stdout counts 1 starter(s)"
assert_equals "$(<"$tests/notes/notes.md")" "keep" "notes.md untouched"
discard_fixture "$tests"

echo "Test 4: missing tests dir fails"
tests=$(mktemp -d)
rc=0
err=$(bash "$SCRIPT" "$tests/absent" 2>&1 >/dev/null) || rc=$?
[[ "$rc" -ne 0 ]] && failed=yes || failed=no
assert_equals "$failed" "yes" "non-zero exit"
[[ "$err" == *"tests dir not found"* ]] && found=yes || found=no
assert_equals "$found" "yes" "stderr says tests dir not found"
discard_fixture "$tests"

echo "Test 5: tests dir without any starter fails"
tests=$(mktemp -d)
mkdir "$tests/case-a"
rc=0
err=$(bash "$SCRIPT" "$tests" 2>&1 >/dev/null) || rc=$?
[[ "$rc" -ne 0 ]] && failed=yes || failed=no
assert_equals "$failed" "yes" "non-zero exit"
[[ "$err" == *"no starter"* ]] && found=yes || found=no
assert_equals "$found" "yes" "stderr says no starter"
discard_fixture "$tests"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
