#!/usr/bin/env bash
# Guards the venv bootstrap used by .taskfiles/scripts/ensure-lola-eval.sh.
#
# Every `task lola-eval:*` target runs this script before it runs anything
# else, so it is on the path of a contributor's very first eval command. That
# is the whole reason it exists — the harness used to be a manual `uv pip
# install` that the Taskfile could only detect and complain about — and it is
# also why its failure modes have to be loud. A bootstrap that silently does
# nothing leaves the caller running whatever `.venv` already held, and an eval
# scored against the wrong harness version is indistinguishable from an eval
# scored against the right one until someone tries to reproduce it.
#
# The tests stub `uv` rather than reaching the network. A real install pulls
# lola-eval and six dependencies from PyPI and GitHub, which is neither fast
# nor available on every host, and none of the decisions under test here are
# about what uv does with the spec — they are about which of create/install/
# skip/fail this script picks, and what it records afterwards.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$SCRIPT_DIR/../../.taskfiles/scripts/ensure-lola-eval.sh"
# shellcheck source=module/tests/helpers.sh
source "$SCRIPT_DIR/helpers.sh"

[[ -f "$SCRIPT" ]] || {
	echo "ERROR: script not found: $SCRIPT" >&2
	exit 1
}

SPEC='lola-eval @ git+https://example.invalid/lola-eval.git@main'
OTHER_SPEC='lola-eval @ git+https://example.invalid/lola-eval.git@other'

# A `uv` that records its arguments and, on `pip install`, fabricates the
# binary a real install would have produced. MODE picks the failure being
# simulated:
#   ok        install succeeds and leaves bin/lola-eval behind
#   nobinary  install reports success but produces nothing (a wheel that
#             stopped shipping the console script would look exactly like this)
#   fail      install exits non-zero
make_uv_stub() { # dir mode
	local dir="$1" mode="$2"
	cat >"$dir/uv" <<-STUB
		#!/usr/bin/env bash
		printf '%s\n' "\$*" >>"$dir/uv.log"
		if [[ "\$1" == "venv" ]]; then
		  # Last argument is the venv path; mirror uv's own layout.
		  for target in "\$@"; do :; done
		  mkdir -p "\$target/bin"
		  exit 0
		fi
		if [[ "\$1" == "pip" ]]; then
		  case "$mode" in
		    ok)
		      # --python points at <venv>/bin/python; put the console script
		      # beside it exactly as a real install would.
		      for i in "\$@"; do
		        [[ -n "\${want:-}" ]] && { python_path="\$i"; unset want; }
		        [[ "\$i" == "--python" ]] && want=1
		      done
		      printf '#!/bin/sh\ntrue\n' >"\${python_path%/*}/lola-eval"
		      chmod +x "\${python_path%/*}/lola-eval"
		      ;;
		    nobinary) : ;;
		    fail) echo "uv: simulated resolution failure" >&2; exit 1 ;;
		  esac
		  exit 0
		fi
		exit 0
	STUB
	chmod +x "$dir/uv"
}

# A managed venv that already holds an installed harness at <spec>.
make_installed_venv() { # venv spec
	local venv="$1" spec="$2"
	mkdir -p "$venv/bin"
	printf '#!/bin/sh\ntrue\n' >"$venv/bin/lola-eval"
	chmod +x "$venv/bin/lola-eval"
	printf '%s\n' "$spec" >"$venv/.lola-eval-spec"
}

# Test 1: a host install outside the managed venv is left alone
echo "Test 1: host install short-circuits the bootstrap"
work=$(mktemp -d)
bin=$(mktemp -d)
make_uv_stub "$bin" ok
mkdir -p "$work/usr"
printf '#!/bin/sh\ntrue\n' >"$work/usr/lola-eval"
chmod +x "$work/usr/lola-eval"
set +e
PATH="$bin:$PATH" bash "$SCRIPT" "$work/usr/lola-eval" "$work/.venv" "$SPEC" >/dev/null 2>&1
status=$?
set -e
assert_equals "$status" "0" "an RPM/PATH install is accepted"
if [[ ! -e "$bin/uv.log" ]]; then
	echo "  PASS: no venv work attempted for a host install"
	PASS=$((PASS + 1))
else
	# Assigned before use rather than inlined into the echo: a command
	# substitution nested in another command has its exit status discarded
	# (SC2312), so a failed read would print an empty log and look like a
	# tidier version of the same failure.
	uv_log=$(cat "$bin/uv.log")
	echo "  FAIL: uv ran anyway: $uv_log"
	FAIL=$((FAIL + 1))
fi
if [[ ! -d "$work/.venv" ]]; then
	echo "  PASS: no .venv created alongside a host install"
	PASS=$((PASS + 1))
else
	echo "  FAIL: .venv created despite a host install"
	FAIL=$((FAIL + 1))
fi
rm -rf "$work" "$bin"

# Test 2: a host install that is not executable is an error, not a fallback.
# Falling back to building a venv would silently ignore the operator's own
# install and review with a different harness than the one they chose.
echo "Test 2: unusable host install fails loudly"
work=$(mktemp -d)
bin=$(mktemp -d)
make_uv_stub "$bin" ok
set +e
err=$(PATH="$bin:$PATH" bash "$SCRIPT" "$work/usr/lola-eval" "$work/.venv" "$SPEC" 2>&1 >/dev/null)
status=$?
set -e
assert_equals "$status" "1" "a missing host install returns non-zero"
if grep -q "$work/usr/lola-eval" <<<"$err"; then
	echo "  PASS: the error names the path it could not use"
	PASS=$((PASS + 1))
else
	echo "  FAIL: the error does not name the path; got '$err'"
	FAIL=$((FAIL + 1))
fi
rm -rf "$work" "$bin"

# Test 3: an up-to-date managed venv is left untouched. This is the hot path —
# it runs before every single eval task — so it must not shell out to uv at
# all, let alone reach the network.
echo "Test 3: matching spec skips the install"
work=$(mktemp -d)
bin=$(mktemp -d)
make_uv_stub "$bin" ok
make_installed_venv "$work/.venv" "$SPEC"
set +e
PATH="$bin:$PATH" bash "$SCRIPT" "$work/.venv/bin/lola-eval" "$work/.venv" "$SPEC" >/dev/null 2>&1
status=$?
set -e
assert_equals "$status" "0" "an up-to-date venv succeeds"
if [[ ! -e "$bin/uv.log" ]]; then
	echo "  PASS: uv is not invoked when the spec already matches"
	PASS=$((PASS + 1))
else
	uv_log=$(cat "$bin/uv.log")
	echo "  FAIL: uv ran for an up-to-date venv: $uv_log"
	FAIL=$((FAIL + 1))
fi
rm -rf "$work" "$bin"

# Test 4: bumping the spec in the Taskfile re-installs. Without this the pin is
# decorative: every existing checkout keeps running the harness it bootstrapped
# with, and only a fresh clone would pick the new one up.
echo "Test 4: changed spec triggers a reinstall"
work=$(mktemp -d)
bin=$(mktemp -d)
make_uv_stub "$bin" ok
make_installed_venv "$work/.venv" "$OTHER_SPEC"
set +e
PATH="$bin:$PATH" bash "$SCRIPT" "$work/.venv/bin/lola-eval" "$work/.venv" "$SPEC" >/dev/null 2>&1
status=$?
set -e
assert_equals "$status" "0" "a respec succeeds"
if grep -q -- "--clear" "$bin/uv.log"; then
	echo "  PASS: the stale venv is cleared rather than layered over"
	PASS=$((PASS + 1))
else
	uv_log=$(cat "$bin/uv.log")
	echo "  FAIL: no --clear in uv log: $uv_log"
	FAIL=$((FAIL + 1))
fi
if grep -qF -- "$SPEC" "$bin/uv.log"; then
	echo "  PASS: uv is asked for the new spec"
	PASS=$((PASS + 1))
else
	uv_log=$(cat "$bin/uv.log")
	echo "  FAIL: new spec absent from uv log: $uv_log"
	FAIL=$((FAIL + 1))
fi
stamped=$(cat "$work/.venv/.lola-eval-spec")
assert_equals "$stamped" "$SPEC" "the stamp records the new spec"
rm -rf "$work" "$bin"

# Test 5: a stamp is not a substitute for the binary. A half-deleted venv, or
# one whose Python was removed by an OS upgrade, still has its stamp.
echo "Test 5: missing binary triggers a reinstall despite a matching stamp"
work=$(mktemp -d)
bin=$(mktemp -d)
make_uv_stub "$bin" ok
mkdir -p "$work/.venv"
printf '%s\n' "$SPEC" >"$work/.venv/.lola-eval-spec"
set +e
PATH="$bin:$PATH" bash "$SCRIPT" "$work/.venv/bin/lola-eval" "$work/.venv" "$SPEC" >/dev/null 2>&1
status=$?
set -e
assert_equals "$status" "0" "the rebuild succeeds"
if [[ -x "$work/.venv/bin/lola-eval" ]]; then
	echo "  PASS: the binary is restored"
	PASS=$((PASS + 1))
else
	echo "  FAIL: no binary after the rebuild"
	FAIL=$((FAIL + 1))
fi
rm -rf "$work" "$bin"

# Test 6: --force reinstalls a venv that is already current. This is what
# `task lola-eval:update` rides on: with a floating ref the spec string never
# changes, so nothing else in this script would ever pull a newer commit.
echo "Test 6: --force reinstalls an up-to-date venv"
work=$(mktemp -d)
bin=$(mktemp -d)
make_uv_stub "$bin" ok
make_installed_venv "$work/.venv" "$SPEC"
set +e
PATH="$bin:$PATH" bash "$SCRIPT" --force "$work/.venv/bin/lola-eval" "$work/.venv" "$SPEC" >/dev/null 2>&1
status=$?
set -e
assert_equals "$status" "0" "the forced reinstall succeeds"
if [[ -e "$bin/uv.log" ]]; then
	echo "  PASS: uv runs even though the spec matches"
	PASS=$((PASS + 1))
else
	echo "  FAIL: --force did not reach uv"
	FAIL=$((FAIL + 1))
fi
rm -rf "$work" "$bin"

# Test 7: no uv, no bootstrap — and say which tool is missing. The Taskfile
# carries a precondition with the same remedy, but the script is callable on
# its own and must not fail as a bare "uv: command not found" from inside a
# subshell three frames down.
echo "Test 7: missing uv reports an actionable error"
work=$(mktemp -d)
masked=$(path_without_command uv "$work")
set +e
err=$(PATH="$masked" bash "$SCRIPT" "$work/.venv/bin/lola-eval" "$work/.venv" "$SPEC" 2>&1 >/dev/null)
status=$?
set -e
assert_equals "$status" "1" "a missing uv returns non-zero"
if grep -q 'uv' <<<"$err"; then
	echo "  PASS: the error names uv"
	PASS=$((PASS + 1))
else
	echo "  FAIL: the error does not name uv; got '$err'"
	FAIL=$((FAIL + 1))
fi
rm -rf "$work"

# Test 8: an install that reports success but leaves no binary is a failure.
# Reported as success it would hand the caller a path that does not exist, and
# the eval task would die on `no such file` with nothing pointing back here.
echo "Test 8: an install producing no binary is an error"
work=$(mktemp -d)
bin=$(mktemp -d)
make_uv_stub "$bin" nobinary
set +e
err=$(PATH="$bin:$PATH" bash "$SCRIPT" "$work/.venv/bin/lola-eval" "$work/.venv" "$SPEC" 2>&1 >/dev/null)
status=$?
set -e
assert_equals "$status" "1" "a binary-less install returns non-zero"
if grep -q "$work/.venv/bin/lola-eval" <<<"$err"; then
	echo "  PASS: the error names the binary that never appeared"
	PASS=$((PASS + 1))
else
	echo "  FAIL: the error does not name the binary; got '$err'"
	FAIL=$((FAIL + 1))
fi
if [[ ! -e "$work/.venv/.lola-eval-spec" ]]; then
	echo "  PASS: no stamp written for a failed install"
	PASS=$((PASS + 1))
else
	echo "  FAIL: stamped a venv that has no binary"
	FAIL=$((FAIL + 1))
fi
rm -rf "$work" "$bin"

# Test 9: a failed install must leave no stamp, so the next invocation retries
# instead of treating the wreckage as current.
echo "Test 9: a failed install is not stamped"
work=$(mktemp -d)
bin=$(mktemp -d)
make_uv_stub "$bin" fail
set +e
PATH="$bin:$PATH" bash "$SCRIPT" "$work/.venv/bin/lola-eval" "$work/.venv" "$SPEC" >/dev/null 2>&1
status=$?
set -e
assert_equals "$status" "1" "a uv failure propagates"
if [[ ! -e "$work/.venv/.lola-eval-spec" ]]; then
	echo "  PASS: no stamp written for a failed install"
	PASS=$((PASS + 1))
else
	echo "  FAIL: stamped a failed install"
	FAIL=$((FAIL + 1))
fi
rm -rf "$work" "$bin"

# Test 10: the argument contract is enforced. Called with the wrong count the
# script would otherwise build a venv at an empty path.
echo "Test 10: wrong argument count is rejected"
work=$(mktemp -d)
bin=$(mktemp -d)
make_uv_stub "$bin" ok
set +e
err=$(PATH="$bin:$PATH" bash "$SCRIPT" "$work/.venv/bin/lola-eval" 2>&1 >/dev/null)
status=$?
set -e
assert_equals "$status" "2" "too few arguments returns 2"
if grep -qi 'usage' <<<"$err"; then
	echo "  PASS: the error shows usage"
	PASS=$((PASS + 1))
else
	echo "  FAIL: no usage in the error; got '$err'"
	FAIL=$((FAIL + 1))
fi
rm -rf "$work" "$bin"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
