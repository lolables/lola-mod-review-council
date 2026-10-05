#!/usr/bin/env bash
# cg-adoption-probe.sh — extend ctx-adoption-probe.sh's off/on measurement
# with the two arms that probe were missing: `codegraph` (CodeGraph alone)
# and `both` (CodeGraph + context-mode together).
#
# ctx-adoption-probe.sh answered "does context-mode get used when properly
# configured". It could not answer whether context-mode's low routing rate
# reflects context-mode being unnecessary rather than under-used: CodeGraph
# reduces how much an agent needs to read (pre-indexed targeted answers
# instead of grep/read loops); context-mode reduces what reading costs (raw
# bytes go to a sandbox instead of the context window). If CodeGraph already
# prevents the reads, context-mode has nothing left to compress, and its low
# routing rate on the `both` arm would be *correct* behaviour, not
# under-use. This script is that second half of the measurement — same
# target, same range, same prompt, same provisioning as ctx-adoption-probe.sh
# (see its header for the full rationale on those choices), so its two arms
# and this script's two arms form one comparable four-arm matrix.
#
# Naming: this script's arms are called `codegraph` (mirrors
# ctx-adoption-probe.sh's `on`, but for the other tool) and `both`. There is
# no `neither` arm here — that is ctx-adoption-probe.sh's `off` arm, already
# run; this script does not repeat it.
#
# CodeGraph active means three separate pieces, not just an MCP connection:
#   1. the MCP server (mcp__codegraph__codegraph_explore) — cg-mode-config.sh
#   2. the UserPromptSubmit hook (`codegraph prompt-hook`) — cg-mode-config.sh
#   3. the standing CLAUDE.md instruction telling the agent to reach for it
#      before grep/find/reading files — an isolated CLAUDE_CONFIG_DIR has no
#      such instruction (it lives in the operator's user-level
#      ~/.claude/CLAUDE.md, outside CLAUDE_CONFIG_DIR's isolation boundary),
#      so it is supplied per-invocation via --append-system-prompt-file,
#      extracted verbatim from the live file's CODEGRAPH_START/END markers
#      (not paraphrased or hand-copied — a drifted copy would test different
#      instructions than the ones an operator actually runs under).
# All three are required, or this script is not testing CodeGraph — see the
# mcp_servers self-check below, which aborts rather than reports a number if
# the wrong servers (or the wrong combination) connected.
#
# The `codegraph` arm needs a CodeGraph index in the clone before it runs —
# the clone has no .codegraph/ of its own. `codegraph init` builds one; its
# wall-clock time and the resulting index size are captured to
# codegraph-init.json in out_dir, since an operator adopting CodeGraph pays
# that cost too and it belongs in the report.
#
# Usage: cg-adoption-probe.sh [out_dir]
#   out_dir defaults to a timestamped directory under .lola-eval/transcripts/
#   (gitignored — see ctx-adoption-probe.sh's usage comment for why).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
MODULE_DIR="$PROJECT_ROOT/module"

TARGET_REPO_URL="https://github.com/voxpupuli/openvox-ca.git"
BASE_SHA="d74253a04e4a"
HEAD_SHA="5a92d50de565"
MODEL="${CG_ADOPTION_MODEL:-claude-sonnet-4-6}"
MAX_BUDGET_USD="${CG_ADOPTION_MAX_BUDGET_USD:-25}"

out_dir="${1:-$PROJECT_ROOT/.lola-eval/transcripts/cg-adoption-probe-$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p "$out_dir"

# shellcheck source=.lola-eval/analysis/scripts/lib/live-claude.sh
source "$SCRIPT_DIR/lib/live-claude.sh"

if [[ ! -d "$MODULE_DIR/agents" ]] || [[ ! -d "$MODULE_DIR/skills/review-council" ]]; then
	echo "ERROR: $MODULE_DIR does not look like a review-council module (missing agents/ or skills/review-council/)" >&2
	exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# --- clone the target and check out the PR head, identical to
# ctx-adoption-probe.sh's clone step (see its header for the rationale on
# every choice here: env -u for the org's classic-PAT block, the
# GIT_CONFIG_* hygiene, why HEAD_SHA resolves without a second fetch). Not
# reused via a shared script because ctx-adoption-probe.sh does not expose
# this step as a callable unit — duplicated verbatim rather than factored
# out for a two-caller seam that does not otherwise exist yet.
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
# Identical to ctx-adoption-probe.sh's provisioning step — see its
# PROVISIONING NOTE for why project-level (not CLAUDE_CONFIG_DIR-level) is
# what makes review-council discoverable under an isolated config dir.
mkdir -p "$repo_dir/.claude/agents" "$repo_dir/.claude/skills"
cp "$MODULE_DIR"/agents/*.md "$repo_dir/.claude/agents/"
cp -a "$MODULE_DIR"/skills/. "$repo_dir/.claude/skills/"
if [[ -d "$MODULE_DIR/references" ]]; then
	mkdir -p "$repo_dir/.claude/references"
	cp -a "$MODULE_DIR"/references/. "$repo_dir/.claude/references/"
fi

# --- build the CodeGraph index the codegraph/both arms need ----------------
# Timed and sized here rather than left implicit: an operator adopting
# CodeGraph pays this cost once per repo, and "how long does the index take,
# how big is it" is exactly the kind of number that turns into a silent
# assumption if it is not measured.
codegraph_init_start="$(date +%s.%N)"
codegraph init "$repo_dir" >"$work/codegraph-init.log" 2>&1
codegraph_init_end="$(date +%s.%N)"
codegraph_init_seconds="$(jq -n --argjson s "$codegraph_init_start" --argjson e "$codegraph_init_end" '$e - $s')"

if [[ ! -d "$repo_dir/.codegraph" ]]; then
	echo "ERROR: codegraph init did not produce $repo_dir/.codegraph — see $work/codegraph-init.log" >&2
	cat "$work/codegraph-init.log" >&2
	exit 1
fi
codegraph_index_bytes="$(du -sb "$repo_dir/.codegraph" | cut -f1)"
# `codegraph status` is diagnostic only (node/edge counts for the report) —
# unlike the `claude` invocations below, its failure does not invalidate a
# measurement already in hand (the index itself is confirmed present above),
# so it does not abort the whole run. But its stderr is captured and surfaced
# rather than discarded, so a real failure is visible instead of silently
# read as "codegraph has no status to report".
codegraph_status_log="$work/codegraph-status.stderr.log"
if ! codegraph_status_json="$(codegraph status "$repo_dir" --json 2>"$codegraph_status_log")"; then
	echo "WARNING: codegraph status --json failed (index still built and usable) — see $codegraph_status_log" >&2
	cat "$codegraph_status_log" >&2
	codegraph_status_json='{}'
fi
jq -n --argjson seconds "$codegraph_init_seconds" --argjson index_bytes "$codegraph_index_bytes" \
	--argjson status "$codegraph_status_json" \
	'{init_seconds: $seconds, index_bytes: $index_bytes, status: $status}' |
	tee "$out_dir/codegraph-init.json" >&2

# --- context-mode and codegraph configs for the treatment arms -------------
bash "$SCRIPT_DIR/ctx-mode-config.sh" "$work/ctx"
bash "$SCRIPT_DIR/cg-mode-config.sh" "$work/cg"

# `both` arm settings.json: neither --settings flag is variadic (unlike
# --mcp-config, which the both arm below hands both mcp.json files to
# directly and lets the CLI merge), so the two hooks blocks are merged here
# by hand. Concatenating arrays per event key (rather than jq's `*`, which
# would let the second operand's array silently replace the first's) is the
# only correct merge: UserPromptSubmit is the one event both sides define,
# and both entries must survive, or the `both` arm silently drops one tool's
# hook.
jq -n --slurpfile ctx "$work/ctx/settings.json" --slurpfile cg "$work/cg/settings.json" '
	($ctx[0].hooks) as $ctx_hooks
	| ($cg[0].hooks) as $cg_hooks
	| (($ctx_hooks | keys) + ($cg_hooks | keys) | unique) as $all_keys
	| {hooks: (reduce $all_keys[] as $k ({}; .[$k] = (($cg_hooks[$k] // []) + ($ctx_hooks[$k] // []))))}
' >"$work/both-settings.json"

# --- the standing CodeGraph instruction, extracted verbatim ----------------
# An isolated CLAUDE_CONFIG_DIR has no user-level CLAUDE.md, so the
# "reach for CodeGraph before grep/find/reading files" instruction that
# ordinarily lives there is missing entirely unless supplied per-invocation.
# Extracted from the live file between its own CODEGRAPH_START/END markers
# rather than hand-copied, so this measures the instruction an operator
# actually runs under, not a paraphrase that could drift from it.
codegraph_claude_md="${CG_HOST_CLAUDE_MD:-$HOME/.claude/CLAUDE.md}"
sed -n '/<!-- CODEGRAPH_START -->/,/<!-- CODEGRAPH_END -->/p' "$codegraph_claude_md" |
	sed '1d;$d' >"$work/codegraph-instruction.md"
if [[ ! -s "$work/codegraph-instruction.md" ]]; then
	echo "ERROR: no CODEGRAPH_START/END section found in $codegraph_claude_md — cannot supply the standing instruction" >&2
	exit 1
fi

PROMPT="Use /review-council to review this repository. Scope: the commit range ${BASE_SHA}..${HEAD_SHA} — treat this exactly as you would the user input \"${BASE_SHA}..${HEAD_SHA}\". Run the complete review pipeline end-to-end without pausing for confirmation. When finished, report the final council verdict (APPROVE or REQUEST CHANGES) and the full list of findings."

WITH_SCRATCH="$PROJECT_ROOT/.taskfiles/scripts/with-scratch.sh"

# Mirrors ctx-adoption-probe.sh's run_arm: fresh isolated CLAUDE_CONFIG_DIR,
# transcript persisted under $out_dir (never $work, which the EXIT trap
# deletes), with-scratch.sh isolation for the review-council session cache,
# and check_claude_result aborting the whole script loudly on any failure —
# see ctx-adoption-probe.sh's comment above its own run_arm for why a
# truncated run must never fall through to the analysis below.
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

echo "--- running codegraph arm (isolated CLAUDE_CONFIG_DIR + codegraph settings/mcp, --strict-mcp-config) ---" >&2
codegraph_transcript="$(run_arm codegraph "$work/cfg-codegraph" \
	--settings "$work/cg/settings.json" --mcp-config "$work/cg/mcp.json" \
	--strict-mcp-config \
	--append-system-prompt-file "$work/codegraph-instruction.md")"

echo "--- running both arm (isolated CLAUDE_CONFIG_DIR + codegraph+context-mode settings/mcp, --strict-mcp-config) ---" >&2
both_transcript="$(run_arm both "$work/cfg-both" \
	--settings "$work/both-settings.json" --mcp-config "$work/cg/mcp.json" "$work/ctx/mcp.json" \
	--strict-mcp-config \
	--append-system-prompt-file "$work/codegraph-instruction.md")"

# --- per-arm analysis --------------------------------------------------------
#
# mcp_servers is pulled from the system/init event, same as
# ctx-adoption-probe.sh's mcp_servers_of.
mcp_servers_of() { # transcript_file
	jq -cs '
		(map(select(.type == "system" and .subtype == "init")) | first) as $init
		| if $init == null then null else ($init.mcp_servers // []) end
	' "$1"
}

# Reviewer-dispatch evidence, identical in shape to ctx-adoption-probe.sh's
# review_evidence_of — see its comment for why this is read by a human
# alongside the numbers rather than folded into a gate.
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
	# codegraph_explore's share is derived from the same tool_histogram
	# ctx-routing-rate.sh already computed for context-mode's ctx_* share —
	# not a second traversal of the transcript, just a second read of a
	# number that script already produced.
	jq -nc --arg arm "$arm" --arg transcript "$transcript_file" \
		--argjson usage "$usage" --argjson volume "$volume" --argjson routing "$routing" \
		--argjson mcp_servers "$mcp_servers" --argjson evidence "$evidence" \
		'{arm: $arm, transcript_file: $transcript, usage: $usage, volume: $volume,
		  routing: ($routing + {
				codegraph_explore_calls: ($routing.tool_histogram["mcp__codegraph__codegraph_explore"] // 0),
				codegraph_explore_share: (($routing.tool_histogram["mcp__codegraph__codegraph_explore"] // 0) / $routing.total_tool_calls)
		  }),
		  mcp_servers: $mcp_servers, review_evidence: $evidence}'
}

codegraph_report="$(build_report codegraph "$codegraph_transcript")"
both_report="$(build_report both "$both_transcript")"

# --- mcp_servers self-check --------------------------------------------------
# Every failure mode here can produce a plausible-looking transcript with the
# wrong tools connected — a typo'd server name, a missing --strict-mcp-config,
# a stale config dir. This never trusts a routing rate on its own: the
# codegraph arm must show codegraph connected and NOT context-mode; the both
# arm must show both. Any other combination aborts the whole script rather
# than emitting numbers for a run that was not testing what its name claims —
# same discipline as ctx-adoption-probe.sh's reuse of ctx-tax-reduce.sh's
# self-check, adapted here since that script's gate is hardcoded to the
# off/on shape and only checks for context-mode.
check_servers() { # arm mcp_servers_json expect_codegraph expect_context_mode
	local arm="$1" servers="$2" expect_cg="$3" expect_ctx="$4"
	local has_cg has_ctx
	# The null check runs before either jq call below: `jq '.[] | ...'` raises
	# "Cannot iterate over null" on a null input, and under this script's
	# `set -e`, that failure would abort with jq's own diagnostic instead of
	# this function's clearer message — a plain assignment (not `local
	# x=$(...)`, which bash would mask) does propagate the inner command's
	# exit status, so the ordering here is load-bearing, not cosmetic.
	if [[ "$servers" == "null" ]]; then
		echo "ERROR: $arm arm has no mcp_servers recorded (missing system/init event) — cannot verify what connected" >&2
		exit 1
	fi
	has_cg="$(jq -c '[.[] | select(.name == "codegraph")] | length > 0' <<<"$servers")"
	has_ctx="$(jq -c '[.[] | select(.name == "plugin_context-mode_context-mode")] | length > 0' <<<"$servers")"
	if [[ "$has_cg" != "$expect_cg" ]]; then
		echo "ERROR: $arm arm codegraph connection state is $has_cg, expected $expect_cg (mcp_servers: $servers)" >&2
		exit 1
	fi
	if [[ "$has_ctx" != "$expect_ctx" ]]; then
		echo "ERROR: $arm arm context-mode connection state is $has_ctx, expected $expect_ctx (mcp_servers: $servers)" >&2
		exit 1
	fi
}

codegraph_mcp_servers="$(jq -c '.mcp_servers' <<<"$codegraph_report")"
both_mcp_servers="$(jq -c '.mcp_servers' <<<"$both_report")"
check_servers codegraph "$codegraph_mcp_servers" true false
check_servers both "$both_mcp_servers" true true

# --- final combined report ---------------------------------------------------
final="$(jq -nc --argjson codegraph "$codegraph_report" --argjson both "$both_report" \
	--slurpfile init "$out_dir/codegraph-init.json" \
	'{codegraph: $codegraph, both: $both, codegraph_init: $init[0]}')"

printf '%s\n' "$final" | tee "$out_dir/report.json"
