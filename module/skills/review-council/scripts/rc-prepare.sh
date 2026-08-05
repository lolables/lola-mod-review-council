#!/usr/bin/env bash
set -uo pipefail

# shellcheck source=module/skills/review-council/scripts/rc-lib.sh
source "$(dirname "$0")/rc-lib.sh"
rc_trap_errors     # report script:line on any unhandled failure (never silent)
rc_require_timeout # this script makes forge calls; fail before any side effect

# Deliberate: -e is omitted. This script handles errors per-section so that
# failures in optional enrichment (forge API, CI checks) do not abort session
# creation. Only hard failures (no git, no jq, no agents) call exit directly.
#
# Do NOT add -e without auditing every pipeline whose right-hand side exits
# early. `producer | head -n5` kills the producer with SIGPIPE once it writes
# more than the pipe buffer holds; under `-o pipefail` the pipeline then exits
# 141 and `-e` turns that into a dead script. Two such pipelines exist below
# (the issue-ref dedup and the issue-body truncation) and are safe only because
# -e is absent here. rc-verify-evidence.sh had this exact shape and did abort
# mid-phase, losing the whole verification run.

# ============================================================================
# Preparation stages, sourced in execution order
# ============================================================================
#
# Sourced rather than executed: each stage is straight-line code over the
# globals its predecessors set, which is what it was when this file held all
# 1,400 lines. Source order IS execution order — reordering these lines
# reorders the pipeline, and Section 16 in prepare-emit.sh depends on Section
# 15 having already written tracking.md.
#
# No arguments are passed to `source`, so $@ inside prepare-args.sh is still
# this script's own and its `shift` loop consumes the real positional
# parameters.

RC_LIB_DIR="$(dirname "$0")/lib"

# shellcheck source=module/skills/review-council/scripts/lib/prepare-args.sh
source "$RC_LIB_DIR/prepare-args.sh"
# shellcheck source=module/skills/review-council/scripts/lib/prepare-repo.sh
source "$RC_LIB_DIR/prepare-repo.sh"

# The forge adapter is chosen on the forge prepare-repo.sh has just detected,
# and sourced before the stages that call it. Every difference between forges —
# CLI name, flags, API shapes, JSON field names — lives behind the contract in
# lib/forge/github.sh; the stages below hold no forge-specific code, which is
# what lets a new forge be a new file rather than a branch in five places.
# `forge=local`, and any forge without an adapter, simply has none sourced: the
# stages test for the contract before calling it and skip forge enrichment.
if [[ -f "$RC_LIB_DIR/forge/${forge}.sh" ]]; then
	# shellcheck source=module/skills/review-council/scripts/lib/forge/github.sh
	source "$RC_LIB_DIR/forge/${forge}.sh"
fi

# shellcheck source=module/skills/review-council/scripts/lib/prepare-target.sh
source "$RC_LIB_DIR/prepare-target.sh"
# shellcheck source=module/skills/review-council/scripts/lib/prepare-changes.sh
source "$RC_LIB_DIR/prepare-changes.sh"
# shellcheck source=module/skills/review-council/scripts/lib/prepare-context.sh
source "$RC_LIB_DIR/prepare-context.sh"
# shellcheck source=module/skills/review-council/scripts/lib/prepare-emit.sh
source "$RC_LIB_DIR/prepare-emit.sh"
