#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=module/skills/review-council/scripts/rc-lib.sh
source "$(dirname "$0")/rc-lib.sh"
rc_trap_errors

# rc-prepare-dispatch.sh <session_dir> [--inline-persona] [--keep-receipts]
# Runs the three scripts that turn a prepared session into dispatchable prompts,
# in the order SKILL.md Step 2.6 depends on: rc-plan-batches.sh (batch-plan.json),
# rc-build-context.sh (prompts/preamble.md, bundles, context.json) and
# rc-assemble-prompts.sh (prompts/dispatch/, dispatch.json). They used to be
# three orchestrator turns, and every turn re-reads the skill docs (issue #107).
#
# Stops at the first script whose status is not `ok` and prints that script's
# JSON and exits with its code, unchanged, so the failure handling each script
# documents still applies. Otherwise prints one combined result:
#
#   batching  applied, reason, batch_count, context_bytes from the plan
#   context   rc-build-context.sh's summary (preamble, packs, per-round counts)
#   prompts   rc-assemble-prompts.sh's summary (prompt count, index)
#
# --inline-persona and --keep-receipts go to rc-assemble-prompts.sh, whose
# --keep-receipts recovery re-runs the earlier two as well: a bundle receipt is
# a hash of the bundle body, so rounds whose bundle is unchanged keep matching.
# Arguments are checked here first so a bad flag fails before any step has
# rewritten the session.

session_dir=""
assemble_flags=()
for arg in "$@"; do
	case "$arg" in
	--inline-persona | --keep-receipts) assemble_flags+=("$arg") ;;
	-*)
		json_output "error" "Unknown option: $arg. The options are --inline-persona and --keep-receipts."
		exit 1
		;;
	*)
		if [[ -n "$session_dir" ]]; then
			json_output "error" "Unexpected argument: $arg. Usage: rc-prepare-dispatch.sh <session_dir> [--inline-persona] [--keep-receipts]"
			exit 1
		fi
		session_dir="$arg"
		;;
	esac
done

script_dir="$(dirname "$0")"

# Runs one script; on a non-ok status prints its JSON and exits with its code.
# Sets step_out to its JSON otherwise. A script that printed no readable status
# (crashed, or killed) is reported as an error naming it, never passed on blank.
step_out=""
run_step() { # script args...
	local script="$1" step_rc=0 step_status
	shift
	step_out=$(bash "$script_dir/$script" "$@") || step_rc=$?
	step_status=$(jq -r '.status // empty' <<<"$step_out" 2>/dev/null) || step_status=""
	if [[ -z "$step_status" ]]; then
		json_output "error" "$script printed no readable result (exit $step_rc); see its stderr above."
		exit "$((step_rc == 0 ? 1 : step_rc))"
	fi
	if [[ "$step_status" != "ok" ]]; then
		printf '%s\n' "$step_out"
		exit "$step_rc"
	fi
}

run_step rc-plan-batches.sh "$session_dir"
plan_out="$step_out"
run_step rc-build-context.sh "$session_dir"
context_out="$step_out"
run_step rc-assemble-prompts.sh "$session_dir" "${assemble_flags[@]+"${assemble_flags[@]}"}"
prompts_out="$step_out"

message=$(jq -r '.message' <<<"$plan_out")
summary=$(jq -n --argjson plan "$plan_out" --argjson context "$context_out" --argjson prompts "$prompts_out" \
	'{batching: {applied: $plan.applied, reason: $plan.reason,
	             batch_count: ($plan.batches | length), context_bytes: $plan.context_bytes},
	  context: ($context | del(.status, .message)),
	  prompts: ($prompts | del(.status, .message))}')
json_output "ok" "Dispatch prepared. $message" "$summary"
