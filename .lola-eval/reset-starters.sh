#!/usr/bin/env bash
# reset-starters.sh — strip module artifacts from every eval starter.
#
# The harness installs review-council into each cell itself, with a real
# `lola install` from `module_source` in config.yaml, and refuses to run
# while any starter still ships .lola/modules. This removes everything the
# old provision.sh wrote, so a checkout that ran it, or a compare-commits leg
# at a commit that predates module_source, leaves a bare starter behind.
#
# Usage: reset-starters.sh [tests_dir]
#   tests_dir defaults to tests/ beside this script.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="${1:-$SCRIPT_DIR/tests}"

if [[ ! -d "$TESTS_DIR" ]]; then
  echo "reset-starters.sh: tests dir not found: $TESTS_DIR" >&2
  exit 1
fi

reset=0
for case_dir in "$TESTS_DIR"/*/; do
  starter="${case_dir}starter"
  [[ -d "$starter" ]] || continue
  rm -rf "$starter/.lola" "$starter/.claude" "$starter/.opencode" \
    "$starter/.gitconfig" "${case_dir}starter-clean"
  reset=$((reset + 1))
done

if [[ $reset -eq 0 ]]; then
  echo "reset-starters.sh: no starter dirs found under $TESTS_DIR" >&2
  exit 1
fi

echo "reset-starters.sh: $reset starter(s) reset"
