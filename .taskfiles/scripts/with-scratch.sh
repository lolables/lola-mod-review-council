#!/usr/bin/env bash
# Run <command> with its scratch state redirected into a directory that is
# deleted when it returns.
#
# Two leaks, with different shapes.
#
# The cache leak is unconditional: 19 of the 25 suites run rc-prepare.sh without
# setting XDG_CACHE_HOME, so every run writes review sessions into the operator's
# real cache. One `task test` deposits 44 session directories (369 files) there,
# indistinguishable to anyone reading that cache from genuine review sessions;
# 20,021 of them (300MB) had accumulated before this was wired up.
#
# The temp leak is conditional. The suites do clean up after themselves — 228
# `rm -rf` calls across 26 files — so a run that finishes leaves /tmp as it found
# it. But none of that cleanup is on a `trap`, so a run that is interrupted
# abandons whatever it had open: killing a single suite mid-run leaks 2
# directories, and 1,100 had collected that way.
#
# The fix is one seam rather than an audit of 239 `mktemp` call sites. mktemp
# honours TMPDIR and rc-prepare.sh honours XDG_CACHE_HOME, so pointing both
# inside a per-run scratch directory redirects every call site at once —
# including any added later. Deleting that directory unconditionally covers the
# interrupted-run case the suites' own cleanup cannot.
#
# <command> runs as a child process, so its own EXIT traps are its own. This
# matters: run-degraded-tests.sh already installs `trap 'rm -rf "$workdir"'
# EXIT`, and bash replaces rather than chains EXIT traps, so setting one here in
# the same shell would silently disarm it.
set -uo pipefail

if [[ $# -eq 0 ]]; then
	echo "usage: with-scratch.sh <command> [args...]" >&2
	exit 2
fi

# Created before TMPDIR is reassigned, so the root itself lands in the caller's
# temp directory rather than inside itself.
scratch=$(mktemp -d) || {
	echo "with-scratch.sh: cannot create scratch directory" >&2
	exit 1
}
trap 'rm -rf "$scratch"' EXIT

# Separate subdirectories rather than one shared path: a suite that globs its
# cache would otherwise walk every temp file the run produced, and a reader
# looking at leftover state during a hung run can tell the two apart.
export TMPDIR="$scratch/tmp"
export XDG_CACHE_HOME="$scratch/cache"
mkdir -p "$TMPDIR" "$XDG_CACHE_HOME"

# TMPDIR alone carries that redirection on GNU/coreutils hosts but not on macOS.
# Apple's mktemp(1) resolves the -t directory from
# confstr(_CS_DARWIN_USER_TEMP_DIR) and reads $TMPDIR only when that call fails
# (shell_cmds/mktemp/mktemp.c, unchanged from shell_cmds-187 through -329) — and
# a bare `mktemp` or `mktemp -d`, which is every call site here, implies -t. So
# on macOS the export above redirects none of them and they keep writing to
# /var/folders, outside the tree this script deletes.
#
# No environment variable reaches that decision, so the seam moves up a level: a
# mktemp ahead of the real one on PATH, supplying the template BSD would
# otherwise choose for itself. Every invocation is routed through TMPDIR — the
# one exception is a template operand, because mktemp creates one path per
# template, so appending ours to a call that already carries one would create a
# second, stray path and print two lines. rc-prepare.sh makes exactly that kind
# of call to keep its diff cache inside the session directory.
#
# A consequence worth knowing before writing one: the forms that name a
# directory in a flag — `-p DIR`, `-t PREFIX`, `--tmpdir=DIR` — are rewritten
# too, and what that costs varies. GNU rejects `-t` and `--tmpdir` outright and
# honours `-p`, placing the result outside the scratch tree; BSD fails on all
# three, because the directory it takes from the flag is joined to the absolute
# template appended here. Neither form appears at any call site: all 253 are
# bare, 239 of them `mktemp -d`.
#
# The real path is baked into the generated script rather than handed over in
# the environment. A nested run resolves `mktemp` to the outer shim, and a
# shared variable would by then hold the inner run's value — so the outer shim
# would exec itself, forever. Baking it in makes each shim delegate to the one
# that spawned it.
mktemp_real=$(command -v mktemp) || {
	echo "with-scratch.sh: mktemp not found on PATH" >&2
	exit 1
}
mkdir -p "$scratch/bin"
{
	printf '#!/usr/bin/env bash\n'
	printf 'real=%q\n' "$mktemp_real"
	cat <<'SHIM'
# A template operand is the caller naming its own path; hand those over as they
# are. Everything else is placed in TMPDIR, which is what BSD mktemp will not do
# on its own.
for arg; do
	case $arg in
	-*) ;;
	*) exec "$real" "$@" ;;
	esac
done
exec "$real" "$@" "${TMPDIR:-/tmp}/tmp.XXXXXXXXXX"
SHIM
} >"$scratch/bin/mktemp"
chmod +x "$scratch/bin/mktemp"
export PATH="$scratch/bin:$PATH"

# No `set -e` in this script: the command's exit status is the wrapper's result
# and has to survive being observed. Aborting here would report the wrapper's
# own failure instead of the test run's.
"$@"
exit $?
