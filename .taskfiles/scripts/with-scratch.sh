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

# No `set -e` in this script: the command's exit status is the wrapper's result
# and has to survive being observed. Aborting here would report the wrapper's
# own failure instead of the test run's.
"$@"
exit $?
