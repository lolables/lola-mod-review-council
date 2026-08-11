#!/usr/bin/env bash
# Guards the scratch-state isolation wrapper in .taskfiles/scripts/with-scratch.sh.
#
# 19 of the 25 suites run rc-prepare.sh without setting XDG_CACHE_HOME, so every
# `task test` writes 44 review sessions into the *operator's* real cache —
# residue indistinguishable, to anyone reading that cache, from genuine review
# sessions. 20,021 of them (300MB) had accumulated before this was wired up.
# Temp directories leak on a narrower path: the suites do remove their own, but
# none of that cleanup sits on a `trap`, so an interrupted run abandons what it
# had open.
#
# Rewriting 239 `mktemp` call sites would be the wrong fix. mktemp honours TMPDIR
# and rc-prepare.sh honours XDG_CACHE_HOME, so pointing both at a per-run scratch
# directory redirects every one of them at once, and deleting that directory
# unconditionally collects what an interrupted run left behind. This wrapper is
# that seam; these tests pin the contract the Taskfile relies on.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$SCRIPT_DIR/../../.taskfiles/scripts/with-scratch.sh"
# shellcheck source=module/tests/helpers.sh
source "$SCRIPT_DIR/helpers.sh"

[[ -f "$SCRIPT" ]] || {
	echo "ERROR: wrapper not found: $SCRIPT" >&2
	exit 1
}

# This suite owns its temp files, unlike the suites whose residue it exists to
# stop. The recorder file has to live outside the scratch tree, or the wrapper
# would delete the evidence before it could be read.
recorder=$(mktemp)
# The BSD-mktemp stub and the directory it stands in for share the recorder's
# fate — see the Darwin test below, which is the only place they are used.
stub_dir=$(mktemp -d)
darwin_temp=$(mktemp -d)
trap 'rm -f "$recorder"; rm -rf "$stub_dir" "$darwin_temp"' EXIT

# Run the wrapper with a payload that records the scratch environment it was
# given, then reports what the wrapper set up and tore down.
#
# Line 1 is $TMPDIR, line 2 is $XDG_CACHE_HOME, line 3 is a directory the
# payload created with a bare `mktemp -d` — the whole point of the seam, since
# that is the call the 239 sites make. Sets RC/TMP_SEEN/CACHE_SEEN/MKTEMP_SEEN.
#
# The payload's own output is left on the terminal rather than captured: it
# writes its findings to $REC and prints nothing, so anything that does appear is
# a real error worth seeing rather than something to swallow.
# Usage: run_payload <payload-script>
run_payload() {
	local payload="$1"
	: >"$recorder"
	set +e
	REC="$recorder" bash "$SCRIPT" bash -c "$payload"
	RC=$?
	set -e
	TMP_SEEN=$(sed -n '1p' "$recorder")
	CACHE_SEEN=$(sed -n '2p' "$recorder")
	MKTEMP_SEEN=$(sed -n '3p' "$recorder")
}

# Payload used by every environment assertion: record the three paths.
# shellcheck disable=SC2016 # deliberately unexpanded: this string is the script
# the wrapper's child evaluates, so the variables must be read in that shell —
# expanding them here would record this suite's environment, not the wrapper's.
RECORD_ENV='printf "%s\n%s\n" "$TMPDIR" "$XDG_CACHE_HOME" >"$REC"; mktemp -d >>"$REC"'

echo "Test: the wrapper hands its command an isolated TMPDIR and XDG_CACHE_HOME"
run_payload "$RECORD_ENV"
assert_equals "$RC" "0" "a succeeding command exits 0"
[[ -n "$TMP_SEEN" ]] && r=yes || r=no
assert_equals "$r" "yes" "TMPDIR is set inside the command"
[[ -n "$CACHE_SEEN" ]] && r=yes || r=no
assert_equals "$r" "yes" "XDG_CACHE_HOME is set inside the command"

# Both must sit under one scratch root, so a single rm collects the lot.
scratch_root=$(dirname "$TMP_SEEN")
assert_equals "$(dirname "$CACHE_SEEN")" "$scratch_root" \
	"TMPDIR and XDG_CACHE_HOME share one scratch root"

echo ""
echo "Test: the isolated cache is not the operator's real cache"
# The defect this wrapper exists to fix. Comparing against $HOME/.cache rather
# than "somewhere under \$HOME" keeps the assertion honest on a host whose
# TMPDIR already lives in the home directory.
[[ "$CACHE_SEEN" == "${HOME}/.cache" ]] && r=same || r=different
assert_equals "$r" "different" "XDG_CACHE_HOME is not \$HOME/.cache"

echo ""
echo "Test: a bare mktemp -d inside the command lands in the scratch tree"
# 239 call sites depend on exactly this and none of them will be changed.
case "$MKTEMP_SEEN" in
"$TMP_SEEN"/*) r=inside ;;
*) r=outside ;;
esac
assert_equals "$r" "inside" "mktemp -d resolves under the scratch TMPDIR"

echo ""
echo "Test: the scratch tree is gone once the command returns"
[[ -e "$scratch_root" ]] && r=present || r=removed
assert_equals "$r" "removed" "scratch root is removed after a successful run"

echo ""
echo "Test: a failing command still gets its scratch tree cleaned up"
# Cleanup on the happy path only would leave residue on exactly the runs an
# operator is most likely to repeat.
run_payload "$RECORD_ENV; exit 7"
assert_equals "$RC" "7" "the command's exit status is propagated, not swallowed"
failed_root=$(dirname "$TMP_SEEN")
[[ -e "$failed_root" ]] && r=present || r=removed
assert_equals "$r" "removed" "scratch root is removed after a failing run"

echo ""
echo "Test: each run gets its own scratch root"
# Two runs sharing a root would let one run's residue be read as the next run's
# state, which is the confusion this whole seam removes.
run_payload "$RECORD_ENV"
second_root=$(dirname "$TMP_SEEN")
[[ "$second_root" == "$scratch_root" ]] && r=reused || r=fresh
assert_equals "$r" "fresh" "a second run does not reuse the first run's root"

echo ""
echo "Test: the scratch TMPDIR holds even where mktemp ignores TMPDIR"
# macOS is such a host, which is why this suite went red there and nowhere else.
# Apple's mktemp(1) resolves the -t directory — implied by a bare `mktemp` or
# `mktemp -d`, which is every call site in this repo — from
# confstr(_CS_DARWIN_USER_TEMP_DIR), and reads $TMPDIR only if that call fails
# (shell_cmds/mktemp/mktemp.c, unchanged from shell_cmds-187 through -329). So
# exporting TMPDIR redirects nothing there and the suites keep writing to
# /var/folders, outside the tree the wrapper deletes.
#
# The stub reproduces that decision on any host. Without it this property is
# only ever asserted on the platform that already satisfies it, which is how the
# gap reached CI in the first place.
STUB_REAL_MKTEMP="$(command -v mktemp)"
export STUB_REAL_MKTEMP
export STUB_DARWIN_TEMP="$darwin_temp"
cat >"$stub_dir/mktemp" <<'STUB'
#!/usr/bin/env bash
# Stands in for a BSD mktemp: an explicit template is honoured, and everything
# else lands in the per-user temp directory regardless of TMPDIR.
for arg; do
	case $arg in
	-*) ;;
	*) exec "$STUB_REAL_MKTEMP" "$@" ;;
	esac
done
exec "$STUB_REAL_MKTEMP" "$@" "$STUB_DARWIN_TEMP/tmp.XXXXXXXXXX"
STUB
chmod +x "$stub_dir/mktemp"

saved_path="$PATH"
PATH="$stub_dir:$PATH"
run_payload "$RECORD_ENV"
PATH="$saved_path"
case "$MKTEMP_SEEN" in
"$TMP_SEEN"/*) r=inside ;;
*) r=outside ;;
esac
assert_equals "$r" "inside" "mktemp -d lands in the scratch tree on a BSD mktemp"

echo ""
echo "Test: invoked with no command it fails loudly"
# A wrapper that silently succeeded on an empty argv would make a Taskfile
# typo look like a green test run.
set +e
usage=$(bash "$SCRIPT" 2>&1)
usage_rc=$?
set -e
assert_equals "$usage_rc" "2" "usage errors exit 2"
case "$usage" in
*with-scratch.sh*) r=named ;;
*) r=unnamed ;;
esac
assert_equals "$r" "named" "the usage message names the script"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
