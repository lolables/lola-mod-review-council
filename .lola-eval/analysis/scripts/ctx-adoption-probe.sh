#!/usr/bin/env bash
# ctx-adoption-probe.sh — measure context-mode's tool-call routing rate on a
# real, DELIBERATELY CONFIGURED Review Council run, and compare it to the
# 3.34% median-0% adoption measured across 35 ordinary-operator production
# logs (see ISSUES.md / the eval that motivated this probe).
#
# The production figure came from an operator environment where context-mode
# was installed but not specifically primed for the task at hand. The one
# thing that could overturn the pre-screen rejection built on that figure is
# a properly configured arm routing far more of its tool calls through
# context-mode. This script is that measurement: LIVE, PAID, and expensive
# (a Review Council standard-effort run over a 31-file, ~5000-line diff,
# times two arms) — not a cheap trivial-prompt probe like ctx-measure-tax.sh.
#
# Target: voxpupuli/openvox-ca PR #189, base d74253a04e4a, head 5a92d50de565.
# `gh` is blocked for this org (voxpupuli forbids classic-PAT access), so this
# clones unauthenticated and drives Review Council's --scope range directly,
# never touching the forge path.
#
# PROVISIONING NOTE: an isolated CLAUDE_CONFIG_DIR has no review-council
# skill — CLAUDE_CONFIG_DIR only isolates user-level plugins/auth, it is not
# where Claude Code looks for project skills. Project-level skills/agents are
# discovered from `<cwd>/.claude/{skills,agents}` regardless of
# CLAUDE_CONFIG_DIR, so this script copies module/agents and module/skills
# (recursively — module/skills/review-council/references lives under
# skills/, not a separate top-level dir) into the clone's own .claude/, the
# same three directories .lola-eval/provision.sh copies per starter, minus
# the .lola/ and .opencode/ pieces that only matter for the lola-eval
# harness and OpenCode, neither of which this script drives — this script
# runs the `claude` CLI directly, once per arm.
#
# Each arm gets a fresh, isolated CLAUDE_CONFIG_DIR: on a RiotBox host with
# RIOTBOX_CONTEXT_MODE=1, the DEFAULT CLAUDE_CONFIG_DIR has context-mode (and
# whatever else is installed — codegraph, Google Drive, ...) wired in at
# boot, so a flagless run against a non-isolated dir is not a clean "off",
# and a non-strict "on" run risks double-registering context-mode. See
# ctx-mode-config.sh's CONTROL-ARM WARNING for the full rationale; verified
# empirically before this script was written (isolated+flagless gives
# mcp_servers: [], isolated+ctx-mode-config.sh+--strict-mcp-config gives
# exactly plugin_context-mode_context-mode).
#
# Every failure mode here can produce a plausible-looking LOW routing rate —
# a missing skill, a budget cap, an auth failure — which would point at
# exactly the answer the pre-screen already leans toward. So this script
# never trusts a routing rate on its own: it also asserts the mcp_servers
# self-check per arm (borrowed from ctx-tax-reduce.sh, not reimplemented —
# it already carries fixture-tested proof that off connects nothing and on
# connects context-mode) and surfaces reviewer-dispatch evidence (Agent tool
# calls naming a divisor-*-code persona, and a verdict line in the final
# assistant turn) so a human can confirm the run reviewed anything before
# trusting its rate.
#
# Usage: ctx-adoption-probe.sh [out_dir]
#   out_dir defaults to a timestamped directory under
#   .lola-eval/transcripts/ (already gitignored — see .gitignore's
#   `.lola-eval/transcripts/` entry — so raw transcripts are never
#   accidentally committed).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
MODULE_DIR="$PROJECT_ROOT/module"

TARGET_REPO_URL="https://github.com/voxpupuli/openvox-ca.git"
BASE_SHA="d74253a04e4a"
HEAD_SHA="5a92d50de565"
MODEL="${CTX_ADOPTION_MODEL:-claude-sonnet-4-6}"
MAX_BUDGET_USD="${CTX_ADOPTION_MAX_BUDGET_USD:-25}"

out_dir="${1:-$PROJECT_ROOT/.lola-eval/transcripts/ctx-adoption-probe-$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p "$out_dir"

# shellcheck source=.lola-eval/analysis/scripts/lib/live-claude.sh
source "$SCRIPT_DIR/lib/live-claude.sh"

if [[ ! -d "$MODULE_DIR/agents" ]] || [[ ! -d "$MODULE_DIR/skills/review-council" ]]; then
	echo "ERROR: $MODULE_DIR does not look like a review-council module (missing agents/ or skills/review-council/)" >&2
	exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# --- clone the target and check out the PR head so the base..head range ----
# resolves against real history. The PR was still open on the eval date (the
# head commit lives only on origin/feature/offline-generate, not on the
# default branch), so a plain default-branch clone would not contain it —
# `git clone` still fetches every ref, it just checks out the default
# branch, so the head commit is present as an object and this checkout
# succeeds without a second fetch.
#
# GIT_CONFIG_NOSYSTEM/GLOBAL/SYSTEM stop the caller's own git config
# (identity, signing, hooks, pagers) from reaching this clone, matching
# ctx-hook-probe.sh's fixture-repo hygiene. `env -u GITHUB_TOKEN -u GH_TOKEN`
# strips any classic-PAT credential from the environment — voxpupuli
# forbids classic-PAT access entirely (`GraphQL: voxpupuli forbids access
# via a personal access token (classic)`), so a token leaking into this
# clone would turn a working unauthenticated fetch into a hard failure.
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null

repo_dir="$work/openvox-ca"
env -u GITHUB_TOKEN -u GH_TOKEN git clone --quiet "$TARGET_REPO_URL" "$repo_dir"
env -u GITHUB_TOKEN -u GH_TOKEN git -C "$repo_dir" checkout --quiet "$HEAD_SHA"

if ! git -C "$repo_dir" cat-file -e "${BASE_SHA}^{commit}" 2>/dev/null; then
	echo "ERROR: base commit $BASE_SHA not found in the clone — cannot resolve the review range" >&2
	exit 1
fi
range_file_count="$(git -C "$repo_dir" diff --name-only "${BASE_SHA}..${HEAD_SHA}" | wc -l)"
if [[ "$range_file_count" -eq 0 ]]; then
	echo "ERROR: commit range ${BASE_SHA}..${HEAD_SHA} touches zero files — nothing to review" >&2
	exit 1
fi
echo "cloned voxpupuli/openvox-ca, range ${BASE_SHA}..${HEAD_SHA} touches $range_file_count files" >&2

# --- provision the module into the clone's project-level .claude/ ----------
# See the PROVISIONING NOTE above for why project-level (not
# CLAUDE_CONFIG_DIR-level) is what makes this discoverable under an isolated
# config dir.
mkdir -p "$repo_dir/.claude/agents" "$repo_dir/.claude/skills"
cp "$MODULE_DIR"/agents/*.md "$repo_dir/.claude/agents/"
cp -a "$MODULE_DIR"/skills/. "$repo_dir/.claude/skills/"
if [[ -d "$MODULE_DIR/references" ]]; then
	mkdir -p "$repo_dir/.claude/references"
	cp -a "$MODULE_DIR"/references/. "$repo_dir/.claude/references/"
fi

# --- context-mode config for the treatment arm ------------------------------
bash "$SCRIPT_DIR/ctx-mode-config.sh" "$work/ctx"

PROMPT="Use /review-council to review this repository. Scope: the commit range ${BASE_SHA}..${HEAD_SHA} — treat this exactly as you would the user input \"${BASE_SHA}..${HEAD_SHA}\". Run the complete review pipeline end-to-end without pausing for confirmation. When finished, report the final council verdict (APPROVE or REQUEST CHANGES) and the full list of findings."

WITH_SCRATCH="$PROJECT_ROOT/.taskfiles/scripts/with-scratch.sh"

# Runs one `claude -p` arm from inside the provisioned clone, persists its
# transcript under $out_dir (never under $work — $work is deleted by the
# trap above, and the transcript is the expensive, irreplaceable artifact
# this whole script exists to produce), and guards the result.
#
# with-scratch.sh redirects TMPDIR/XDG_CACHE_HOME into a directory it deletes
# on its own exit, so this run's review-council session cache (normally
# ~/.cache/review-council/<project-id>/...) never lands in, or is read back
# from, the operator's real cache — the same isolation module/tests/*.sh get
# from run-unit-tests.sh, reused rather than reimplemented here.
#
# check_claude_result aborts the whole script on any failure (non-zero exit
# or non-empty stderr) rather than letting a truncated run fall through to
# the analysis below and report a number that looks plausible but measures
# nothing — a budget-cap abort surfaces here as a loud ERROR with the CLI's
# own diagnostic in stderr_file, not a silently-truncated transcript treated
# as a complete one.
run_arm() { # arm_name config_dir extra_claude_args...
	local arm="$1" config_dir="$2"
	shift 2
	seed_auth "$config_dir"

	local transcript_file="$out_dir/${arm}.transcript.jsonl"
	local stderr_file="$out_dir/${arm}.stderr.log"
	local status=0
	(
		cd "$repo_dir"
		CLAUDE_CONFIG_DIR="$config_dir" \
			bash "$WITH_SCRATCH" \
			claude -p "$PROMPT" \
			--model "$MODEL" \
			--output-format stream-json --verbose \
			--permission-mode bypassPermissions \
			--max-budget-usd "$MAX_BUDGET_USD" \
			"$@"
	) >"$transcript_file" 2>"$stderr_file" || status=$?

	check_claude_result "$status" "$stderr_file" "$arm arm"
	echo "$transcript_file"
}

echo "--- running off arm (isolated CLAUDE_CONFIG_DIR, no --settings/--mcp-config) ---" >&2
off_transcript="$(run_arm off "$work/cfg-off")"

echo "--- running on arm (isolated CLAUDE_CONFIG_DIR + context-mode settings/mcp, --strict-mcp-config) ---" >&2
on_transcript="$(run_arm on "$work/cfg-on" \
	--settings "$work/ctx/settings.json" --mcp-config "$work/ctx/mcp.json" \
	--strict-mcp-config)"

# --- per-arm analysis --------------------------------------------------------
#
# mcp_servers is pulled from the system/init event the same way
# ctx-measure-tax.sh's run_arm does it, so the pair can be handed to
# ctx-tax-reduce.sh below for the self-check gate without reimplementing its
# off-connects-nothing / on-connects-context-mode assertion.
mcp_servers_of() { # transcript_file
	jq -cs '
		(map(select(.type == "system" and .subtype == "init")) | first) as $init
		| if $init == null then null else ($init.mcp_servers // []) end
	' "$1"
}

# Reviewer-dispatch evidence: Agent tool calls whose input mentions a
# divisor-*-code persona, and the verdict line from the final assistant
# turn's result text. This is what proves the run reviewed anything at all
# before its routing rate is trusted — see the file header. Not extracted
# into a separate pure filter: unlike ctx-routing-rate.sh, this evidence
# never gates spend or a pre-screen decision, it is read by a human
# alongside the numbers.
review_evidence_of() { # transcript_file
	jq -cs '
		[ .[] | select(.type == "assistant") | .message.content // [] | .[]
		  | select(.type == "tool_use" and .name == "Agent")
		  | (.input // {} | tostring) ] as $agent_dispatch_inputs
		| [ $agent_dispatch_inputs[] | select(test("divisor-[a-z]+-code")) ] as $persona_dispatches
		| (map(select(.type == "result")) | last) as $result
		| {
				agent_tool_calls: ($agent_dispatch_inputs | length),
				persona_dispatch_count: ($persona_dispatches | length),
				personas_dispatched: (
					[$persona_dispatches[] | scan("divisor-[a-z]+-code")] | unique
				),
				verdict_line: (
					[($result.result // "") | scan("(?i)(APPROVE|REQUEST CHANGES)[^\n]*")] | first
				),
				final_result_present: ($result != null and ($result.result // "") != "")
			}
	' "$1"
}

build_report() { # arm transcript_file
	local arm="$1" transcript_file="$2"
	local usage volume routing mcp_servers evidence
	usage="$("$SCRIPT_DIR/ctx-usage-sum.sh" <"$transcript_file")"
	volume="$("$SCRIPT_DIR/ctx-volume-split.sh" <"$transcript_file")"
	routing="$("$SCRIPT_DIR/ctx-routing-rate.sh" <"$transcript_file")"
	mcp_servers="$(mcp_servers_of "$transcript_file")"
	evidence="$(review_evidence_of "$transcript_file")"
	jq -nc --arg arm "$arm" --arg transcript "$transcript_file" \
		--argjson usage "$usage" --argjson volume "$volume" --argjson routing "$routing" \
		--argjson mcp_servers "$mcp_servers" --argjson evidence "$evidence" \
		'{arm: $arm, transcript_file: $transcript, usage: $usage, volume: $volume,
		  routing: $routing, mcp_servers: $mcp_servers, review_evidence: $evidence}'
}

off_report="$(build_report off "$off_transcript")"
on_report="$(build_report on "$on_transcript")"

# --- mcp_servers self-check (reused, not reimplemented) ---------------------
pair_file="$out_dir/off-on-pair.jsonl"
off_usage_with_mcp="$(jq '.usage + {mcp_servers: .mcp_servers}' <<<"$off_report")"
on_usage_with_mcp="$(jq '.usage + {mcp_servers: .mcp_servers}' <<<"$on_report")"
jq -nc --argjson off "$off_usage_with_mcp" --argjson on "$on_usage_with_mcp" \
	'{off: $off, on: $on}' >"$pair_file"
self_check="$("$SCRIPT_DIR/ctx-tax-reduce.sh" <"$pair_file")"

# --- final combined report ---------------------------------------------------
final="$(jq -nc --argjson off "$off_report" --argjson on "$on_report" --argjson self_check "$self_check" \
	--arg production_baseline_routing_rate "0.0334" \
	'{
		off: $off,
		on: $on,
		self_check: $self_check,
		production_baseline_routing_rate: ($production_baseline_routing_rate | tonumber),
		routing_rate_delta: ($on.routing.routing_rate - $off.routing.routing_rate)
	}')"

printf '%s\n' "$final" | tee "$out_dir/report.json"
