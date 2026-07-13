#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$SCRIPT_DIR/../skills/review-council/scripts/rc-prepare.sh"
TEST_OUTPUT="${SCRIPT_DIR}/../../.test-output/rc-prepare"
rm -rf "$TEST_OUTPUT"
mkdir -p "$TEST_OUTPUT"

# shellcheck source=module/tests/test-helpers.sh
source "$SCRIPT_DIR/test-helpers.sh"

assert_json_status() {
	local json="$1" expected="$2" test_name="$3"
	assert_json_field "$json" "status" "$expected" "$test_name"
}

assert_file_exists() {
	local path="$1" test_name="$2"
	if [[ -f "$path" ]]; then
		echo "  PASS: $test_name"
		PASS=$((PASS + 1))
	else
		echo "  FAIL: $test_name (file not found: $path)"
		FAIL=$((FAIL + 1))
	fi
}

# Test 1: Non-git directory
echo "Test 1: Non-git directory"
tmpdir=$(mktemp -d)
result=$(cd "$tmpdir" && AGENTS_DIR="$SCRIPT_DIR/../agents" GIT_CONFIG_NOSYSTEM=1 bash "$SCRIPT" 2>/dev/null)
assert_json_status "$result" "skip" "status is skip"
if echo "$result" | jq -r '.message' | grep -qi "git"; then
	echo "  PASS: message mentions git"
	PASS=$((PASS + 1))
else
	echo "  FAIL: message doesn't mention git"
	FAIL=$((FAIL + 1))
fi
rm -rf "$tmpdir"

# Test 2: Git repo with no changes (empty changeset)
echo "Test 2: Empty changeset"
tmpdir=$(mktemp -d)
cd "$tmpdir" && git -c init.defaultBranch=main init -q && git commit --allow-empty -m "init" -q
result=$(AGENTS_DIR="$SCRIPT_DIR/../agents" bash "$SCRIPT" 2>/dev/null)
assert_json_status "$result" "empty" "status is empty"
rm -rf "$tmpdir"

# Test 3: Git repo with changes
echo "Test 3: Normal git repo with changes"
tmpdir=$(mktemp -d)
cd "$tmpdir" && git -c init.defaultBranch=main init -q && git commit --allow-empty -m "init" -q
git checkout -b feature -q
echo "package main" >main.go && git add main.go && git commit -m "add main" -q
result=$(AGENTS_DIR="$SCRIPT_DIR/../agents" bash "$SCRIPT" 2>/dev/null)
assert_json_status "$result" "ok" "status is ok"
session_dir=$(echo "$result" | jq -r '.session_dir')
assert_file_exists "$session_dir/changeset.txt" "changeset.txt created"
assert_file_exists "$session_dir/diff.patch" "diff.patch created"
assert_file_exists "$session_dir/tracking.md" "tracking.md created"
assert_file_exists "$session_dir/session.txt" "session.txt created"
assert_json_field "$result" "language" "go" "detected Go language"
rm -rf "$tmpdir"

# Test 4: Explicit mode override
echo "Test 4: Explicit mode override"
tmpdir=$(mktemp -d)
cd "$tmpdir" && git -c init.defaultBranch=main init -q && git commit --allow-empty -m "init" -q
mkdir -p specs && echo "# Spec" >specs/feature.md
result=$(AGENTS_DIR="$SCRIPT_DIR/../agents" bash "$SCRIPT" --mode specs 2>/dev/null)
assert_json_status "$result" "ok" "status is ok"
assert_json_field "$result" "mode" "spec" "mode is spec"
rm -rf "$tmpdir"

# Test 5: Agent discovery
echo "Test 5: Agent discovery"
tmpdir=$(mktemp -d)
cd "$tmpdir" && git -c init.defaultBranch=main init -q && git commit --allow-empty -m "init" -q
git checkout -b feature -q
echo "x" >file.go && git add file.go && git commit -m "add" -q
result=$(AGENTS_DIR="$SCRIPT_DIR/../agents" bash "$SCRIPT" 2>/dev/null)
agent_count=$(echo "$result" | jq '.agents | length')
if [[ "$agent_count" -gt 0 ]]; then
	echo "  PASS: discovered $agent_count agents"
	PASS=$((PASS + 1))
else
	echo "  FAIL: no agents discovered"
	FAIL=$((FAIL + 1))
fi
rm -rf "$tmpdir"

# Test 6: Impossible session directory (mkdir failure)
echo "Test 6: Impossible session directory"
tmpdir=$(mktemp -d)
cd "$tmpdir" && git -c init.defaultBranch=main init -q && git commit --allow-empty -m "init" -q
git checkout -b feature -q
echo "x" >file.go && git add file.go && git commit -m "add" -q
result=$(XDG_CACHE_HOME="/dev/null/impossible" AGENTS_DIR="$SCRIPT_DIR/../agents" bash "$SCRIPT" 2>/dev/null)
assert_json_status "$result" "skip" "status is skip when mkdir fails"
if echo "$result" | jq -r '.message' | grep -qi "directory"; then
	echo "  PASS: message mentions directory"
	PASS=$((PASS + 1))
else
	echo "  FAIL: message doesn't mention directory"
	FAIL=$((FAIL + 1))
fi
rm -rf "$tmpdir"

# Test 7: Verify stderr is clean on successful runs
echo "Test 7: Verify stderr is clean"
tmpdir=$(mktemp -d)
cd "$tmpdir" && git -c init.defaultBranch=main init -q && git commit --allow-empty -m "init" -q
git checkout -b feature -q
echo "package main" >main.go && git add main.go && git commit -m "add main" -q
stderr_file=$(mktemp)
AGENTS_DIR="$SCRIPT_DIR/../agents" bash "$SCRIPT" 2>"$stderr_file" >/dev/null
if [[ ! -s "$stderr_file" ]]; then
	echo "  PASS: no stderr output"
	PASS=$((PASS + 1))
else
	stderr_content=$(cat "$stderr_file")
	echo "  FAIL: stderr output detected: ${stderr_content}"
	FAIL=$((FAIL + 1))
fi
rm -f "$stderr_file"
rm -rf "$tmpdir"

# Test 8: Spec mode auto-detection
echo "Test 8: Spec mode auto-detection"
tmpdir=$(mktemp -d)
cd "$tmpdir" && git -c init.defaultBranch=main init -q && git commit --allow-empty -m "init" -q
git checkout -b feature -q
mkdir -p specs && echo "# Feature spec" >specs/feature.md && git add specs/feature.md && git commit -m "add spec" -q
result=$(AGENTS_DIR="$SCRIPT_DIR/../agents" bash "$SCRIPT" 2>/dev/null)
assert_json_field "$result" "mode" "spec" "auto-detected spec mode"
rm -rf "$tmpdir"

# Test 9: --effort flag with valid values
echo "Test 9: --effort flag (valid values)"
tmpdir=$(mktemp -d)
cd "$tmpdir" && git -c init.defaultBranch=main init -q && git commit --allow-empty -m "init" -q
git checkout -b feature -q
echo "x" >file.go && git add file.go && git commit -m "add" -q
result=$(AGENTS_DIR="$SCRIPT_DIR/../agents" bash "$SCRIPT" --effort quick 2>/dev/null)
assert_json_field "$result" "effort" "quick" "effort=quick in JSON"
result=$(AGENTS_DIR="$SCRIPT_DIR/../agents" bash "$SCRIPT" --effort standard 2>/dev/null)
assert_json_field "$result" "effort" "standard" "effort=standard in JSON"
result=$(AGENTS_DIR="$SCRIPT_DIR/../agents" bash "$SCRIPT" --effort deep 2>/dev/null)
assert_json_field "$result" "effort" "deep" "effort=deep in JSON"
rm -rf "$tmpdir"

# Test 10: --effort flag with invalid value
echo "Test 10: --effort flag (invalid value)"
tmpdir=$(mktemp -d)
cd "$tmpdir" && git -c init.defaultBranch=main init -q && git commit --allow-empty -m "init" -q
git checkout -b feature -q
echo "x" >file.go && git add file.go && git commit -m "add" -q
result=$(AGENTS_DIR="$SCRIPT_DIR/../agents" bash "$SCRIPT" --effort banana 2>/dev/null)
assert_json_status "$result" "skip" "invalid effort value returns skip"
rm -rf "$tmpdir"

# Test 11: --effort defaults to standard when omitted
echo "Test 11: --effort default"
tmpdir=$(mktemp -d)
cd "$tmpdir" && git -c init.defaultBranch=main init -q && git commit --allow-empty -m "init" -q
git checkout -b feature -q
echo "x" >file.go && git add file.go && git commit -m "add" -q
result=$(AGENTS_DIR="$SCRIPT_DIR/../agents" bash "$SCRIPT" 2>/dev/null)
assert_json_field "$result" "effort" "standard" "effort defaults to standard"
rm -rf "$tmpdir"

# Test 12: --effort value appears in session.txt
echo "Test 12: --effort in session.txt"
tmpdir=$(mktemp -d)
cd "$tmpdir" && git -c init.defaultBranch=main init -q && git commit --allow-empty -m "init" -q
git checkout -b feature -q
echo "x" >file.go && git add file.go && git commit -m "add" -q
result=$(AGENTS_DIR="$SCRIPT_DIR/../agents" bash "$SCRIPT" --effort deep 2>/dev/null)
session_dir=$(echo "$result" | jq -r '.session_dir')
if grep -q "Effort:.*deep" "$session_dir/session.txt"; then
	echo "  PASS: effort=deep in session.txt"
	PASS=$((PASS + 1))
else
	echo "  FAIL: effort=deep not found in session.txt"
	FAIL=$((FAIL + 1))
fi
rm -rf "$tmpdir"

# Test 13: --effort value appears in tracking.md
echo "Test 13: --effort in tracking.md"
tmpdir=$(mktemp -d)
cd "$tmpdir" && git -c init.defaultBranch=main init -q && git commit --allow-empty -m "init" -q
git checkout -b feature -q
echo "x" >file.go && git add file.go && git commit -m "add" -q
result=$(AGENTS_DIR="$SCRIPT_DIR/../agents" bash "$SCRIPT" --effort quick 2>/dev/null)
session_dir=$(echo "$result" | jq -r '.session_dir')
if grep -q "Effort: quick" "$session_dir/tracking.md"; then
	echo "  PASS: effort=quick in tracking.md"
	PASS=$((PASS + 1))
else
	echo "  FAIL: effort=quick not found in tracking.md"
	FAIL=$((FAIL + 1))
fi
rm -rf "$tmpdir"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
