#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$SCRIPT_DIR/../skills/review-council/scripts/rc-prepare.sh"

# shellcheck source=module/tests/helpers.sh
source "$SCRIPT_DIR/helpers.sh"

assert_json_status() {
	local json="$1" expected="$2" test_name="$3"
	assert_json_field "$json" "status" "$expected" "$test_name"
}

# Assert that <path> is listed (or not listed) in a changeset file.
#
# A missing changeset is reported, not silently tolerated: grep exits 2 on a
# file that does not exist, which reads as "absent" and would pass every
# absence assertion against a session that was never created at all.
# Usage: assert_changeset <changeset> <path> <present|absent> <test_name>
assert_changeset() {
	local changeset="$1" path="$2" expected="$3" test_name="$4" actual="absent"
	if [[ ! -f "$changeset" ]]; then
		echo "  FAIL: $test_name — changeset file missing: $changeset"
		FAIL=$((FAIL + 1))
		return
	fi
	if grep -qxF "$path" "$changeset"; then
		actual="present"
	fi
	assert_equals "$actual" "$expected" "$test_name"
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
cd "$tmpdir"
git_init_sandbox
git checkout -q -b main
git commit --allow-empty -qm init
result=$(AGENTS_DIR="$SCRIPT_DIR/../agents" bash "$SCRIPT" 2>/dev/null)
assert_json_status "$result" "empty" "status is empty"
rm -rf "$tmpdir"

# Test 3: Git repo with changes
echo "Test 3: Normal git repo with changes"
tmpdir=$(mktemp -d)
cd "$tmpdir"
git_init_sandbox
git checkout -q -b main
git commit --allow-empty -qm init
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
cd "$tmpdir"
git_init_sandbox
git checkout -q -b main
git commit --allow-empty -qm init
mkdir -p specs && echo "# Spec" >specs/feature.md
result=$(AGENTS_DIR="$SCRIPT_DIR/../agents" bash "$SCRIPT" --mode specs 2>/dev/null)
assert_json_status "$result" "ok" "status is ok"
assert_json_field "$result" "mode" "spec" "mode is spec"
rm -rf "$tmpdir"

# Test 5: Agent discovery
echo "Test 5: Agent discovery"
tmpdir=$(mktemp -d)
cd "$tmpdir"
git_init_sandbox
git checkout -q -b main
git commit --allow-empty -qm init
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
cd "$tmpdir"
git_init_sandbox
git checkout -q -b main
git commit --allow-empty -qm init
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
cd "$tmpdir"
git_init_sandbox
git checkout -q -b main
git commit --allow-empty -qm init
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
cd "$tmpdir"
git_init_sandbox
git checkout -q -b main
git commit --allow-empty -qm init
git checkout -b feature -q
mkdir -p specs && echo "# Feature spec" >specs/feature.md && git add specs/feature.md && git commit -m "add spec" -q
result=$(AGENTS_DIR="$SCRIPT_DIR/../agents" bash "$SCRIPT" 2>/dev/null)
assert_json_field "$result" "mode" "spec" "auto-detected spec mode"
rm -rf "$tmpdir"

# Test 9: --effort flag with valid values
echo "Test 9: --effort flag (valid values)"
tmpdir=$(mktemp -d)
cd "$tmpdir"
git_init_sandbox
git checkout -q -b main
git commit --allow-empty -qm init
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
cd "$tmpdir"
git_init_sandbox
git checkout -q -b main
git commit --allow-empty -qm init
git checkout -b feature -q
echo "x" >file.go && git add file.go && git commit -m "add" -q
result=$(AGENTS_DIR="$SCRIPT_DIR/../agents" bash "$SCRIPT" --effort banana 2>/dev/null)
assert_json_status "$result" "skip" "invalid effort value returns skip"
rm -rf "$tmpdir"

# Test 11: --effort defaults to standard when omitted
echo "Test 11: --effort default"
tmpdir=$(mktemp -d)
cd "$tmpdir"
git_init_sandbox
git checkout -q -b main
git commit --allow-empty -qm init
git checkout -b feature -q
echo "x" >file.go && git add file.go && git commit -m "add" -q
result=$(AGENTS_DIR="$SCRIPT_DIR/../agents" bash "$SCRIPT" 2>/dev/null)
assert_json_field "$result" "effort" "standard" "effort defaults to standard"
rm -rf "$tmpdir"

# Test 12: --effort value appears in session.txt
echo "Test 12: --effort in session.txt"
tmpdir=$(mktemp -d)
cd "$tmpdir"
git_init_sandbox
git checkout -q -b main
git commit --allow-empty -qm init
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
cd "$tmpdir"
git_init_sandbox
git checkout -q -b main
git commit --allow-empty -qm init
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

# Test 14: --scope all selects by rejecting binaries, not by allow-listing text
echo "Test 14: --scope all file selection"
tmpdir=$(mktemp -d)
cd "$tmpdir"
git_init_sandbox
git checkout -q -b main
mkdir -p src node_modules/pkg
printf '{"title":"schema"}\n' >schema.json
printf '# Readme\n' >src/readme.md
printf 'module.exports = {}\n' >node_modules/pkg/index.js
printf '{"lockfileVersion":3}\n' >package-lock.json
# Binary shapes a repo can plausibly carry outside the SMART_EXCLUDES
# directories, one per classifier arm. All are built from magic bytes so the
# suite does not depend on a toolchain: an ELF header (application/x-executable),
# a WebAssembly module, a DOS executable, a SQLite database, and a tar archive.
# `file` does not follow symlinks, so link-to-blob arrives as inode/symlink.
printf '\177ELF\002\001\001\000\000\000\000\000\000\000\000\000\002\000\076\000' >src/blob.bin
printf '\000asm\001\000\000\000' >src/mod.wasm
{
	printf 'MZ'
	head -c 62 /dev/zero
} >src/app.exe
{
	printf 'SQLite format 3\000\020\000\001\001\000\100\040\040'
	head -c 4076 /dev/zero
} >src/store.db
tar cf src/fixture.tar src/readme.md 2>/dev/null
ln -s blob.bin src/link-to-blob
git add schema.json src package-lock.json
git commit -qm init
# PIE is the default link mode for current toolchains, and no header forged by
# hand reproduces it — `file` reads x-pie-executable off the interpreter and
# dynamic entries a real link produces. Gated: cc is not guaranteed in CI.
pie_built=no
if command -v cc >/dev/null 2>&1; then
	printf 'int main(void) { return 0; }\n' >pie.c
	if cc -pie -fPIE -o src/pie.out pie.c 2>/dev/null; then
		pie_built=yes
		git add src/pie.out
		git commit -qm pie
	fi
	rm -f pie.c
fi
result=$(AGENTS_DIR="$SCRIPT_DIR/../agents" bash "$SCRIPT" --mode code --scope all 2>/dev/null)
assert_json_status "$result" "ok" "status is ok"
session_dir=$(echo "$result" | jq -r '.session_dir')
assert_changeset "$session_dir/changeset.txt" "schema.json" "present" "JSON is reviewable"
assert_changeset "$session_dir/changeset.txt" "src/readme.md" "present" "markdown is reviewable"
assert_changeset "$session_dir/changeset.txt" "src/blob.bin" "absent" "ELF binary is excluded"
assert_changeset "$session_dir/changeset.txt" "src/mod.wasm" "absent" "wasm module is excluded"
assert_changeset "$session_dir/changeset.txt" "src/app.exe" "absent" "DOS executable is excluded"
assert_changeset "$session_dir/changeset.txt" "src/store.db" "absent" "SQLite database is excluded"
assert_changeset "$session_dir/changeset.txt" "src/fixture.tar" "absent" "tar archive is excluded"
assert_changeset "$session_dir/changeset.txt" "src/link-to-blob" "absent" "symlink is excluded"
if [[ "$pie_built" == "yes" ]]; then
	assert_changeset "$session_dir/changeset.txt" "src/pie.out" "absent" \
		"PIE executable is excluded"
else
	echo "  SKIP: PIE executable not covered (no cc on this host)"
fi
assert_changeset "$session_dir/changeset.txt" "node_modules/pkg/index.js" "absent" \
	"excluded directory is excluded"
assert_changeset "$session_dir/changeset.txt" "package-lock.json" "absent" \
	"excluded filename is excluded"
rm -rf "$tmpdir"

# Test 15: --scope all on a host with no file(1)
# `file` is optional, so a host without it must still review the changeset.
# Rejecting every candidate would report a clean review of a changeset that was
# never inspected — the one direction a review tool must not be wrong in.
echo "Test 15: --scope all without file(1)"
tmpdir=$(mktemp -d)
maskdir=$(mktemp -d)
cd "$tmpdir"
git_init_sandbox
git checkout -q -b main
printf '{"title":"schema"}\n' >schema.json
printf '# Readme\n' >readme.md
git add schema.json readme.md
git commit -qm init
masked=$(path_without_command file "$maskdir")
result=$(PATH="$masked" AGENTS_DIR="$SCRIPT_DIR/../agents" bash "$SCRIPT" --mode code --scope all 2>/dev/null)
assert_json_status "$result" "ok" "status is ok without file(1)"
session_dir=$(echo "$result" | jq -r '.session_dir // empty')
if [[ -n "$session_dir" ]]; then
	assert_changeset "$session_dir/changeset.txt" "schema.json" "present" \
		"candidate admitted when the type cannot be checked"
fi
rm -rf "$tmpdir" "$maskdir"

# Build an agents directory holding only the named personas, for the chosen
# suffix, so a partial install can be simulated without touching the shipped
# module/agents. Usage: partial_agents_dir <workdir> <suffix> <persona>...
partial_agents_dir() {
	local dir="$1" suffix="$2" p
	shift 2
	mkdir -p "$dir"
	for p in "$@"; do
		printf -- '---\ndescription: fixture persona\n---\n\nFixture.\n' \
			>"$dir/divisor-${p}-${suffix}.md"
	done
}

# Assert that tracking.md carries <line> verbatim. Matched whole-line rather
# than parsed back out: rc-render-report.sh reads these with rc_parse_kv, so a
# test that parsed too would agree with a formatting bug instead of catching it.
# Usage: assert_tracking_line <tracking.md> <line> <test_name>
assert_tracking_line() {
	local file="$1" line="$2" name="$3"
	if [[ ! -f "$file" ]]; then
		echo "  FAIL: $name — tracking file missing: $file"
		FAIL=$((FAIL + 1))
		return
	fi
	if grep -qxF -- "$line" "$file"; then
		echo "  PASS: $name"
		PASS=$((PASS + 1))
	else
		echo "  FAIL: $name — expected line not found: $line"
		local got
		got=$(grep -m1 -F -- "${line%%:*}:" "$file") || got="<no such key>"
		echo "        got: $got"
		FAIL=$((FAIL + 1))
	fi
}

echo "Test 21: a full roster reports no absent personas"
# "Agents absent" used to be the literal string "none" written by this script
# and updated by nothing, so a host missing half its council still published a
# report claiming complete coverage. The roster makes absence measurable; this
# case pins the negative so the field cannot become a constant again in the
# other direction.
tmpdir=$(mktemp -d)
agentdir=$(mktemp -d)
partial_agents_dir "$agentdir" code adversary curator guard sre testing
cd "$tmpdir"
setup_repo "$tmpdir" >/dev/null
result=$(AGENTS_DIR="$agentdir" bash "$SCRIPT" --mode code 2>/dev/null)
assert_json_status "$result" "ok" "status is ok on a full roster"
session_dir=$(echo "$result" | jq -r '.session_dir')
assert_tracking_line "$session_dir/tracking.md" "- Agents absent: none" \
	"full roster reports absent: none"
assert_tracking_line "$session_dir/tracking.md" "- Agents discovered: 5" \
	"all five personas discovered"
rm -rf "$tmpdir" "$agentdir"

echo "Test 22: a partial install names the personas that are missing"
tmpdir=$(mktemp -d)
agentdir=$(mktemp -d)
partial_agents_dir "$agentdir" code adversary guard testing
cd "$tmpdir"
setup_repo "$tmpdir" >/dev/null
result=$(AGENTS_DIR="$agentdir" bash "$SCRIPT" --mode code 2>/dev/null)
assert_json_status "$result" "ok" "status is ok on a partial roster"
session_dir=$(echo "$result" | jq -r '.session_dir')
assert_tracking_line "$session_dir/tracking.md" \
	"- Agents absent: divisor-curator-code, divisor-sre-code" \
	"partial roster names both missing personas in roster order"
rm -rf "$tmpdir" "$agentdir"

echo "Test 23: absence is reported against the spec suffix in spec mode"
# The roster is suffix-agnostic; absence is not. A host carrying every -code
# persona and no -spec ones must not read as a complete spec council.
tmpdir=$(mktemp -d)
agentdir=$(mktemp -d)
partial_agents_dir "$agentdir" spec adversary curator guard sre
cd "$tmpdir"
git_init_sandbox
git checkout -q -b main
git commit --allow-empty -qm init
git checkout -q -b feature
mkdir -p specs && echo "# Feature spec" >specs/feature.md
git add specs/feature.md && git commit -qm "add spec"
result=$(AGENTS_DIR="$agentdir" bash "$SCRIPT" --mode specs 2>/dev/null)
assert_json_status "$result" "ok" "status is ok in spec mode"
session_dir=$(echo "$result" | jq -r '.session_dir')
assert_tracking_line "$session_dir/tracking.md" "- Agents absent: divisor-testing-spec" \
	"spec mode names the -spec persona"
rm -rf "$tmpdir" "$agentdir"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
