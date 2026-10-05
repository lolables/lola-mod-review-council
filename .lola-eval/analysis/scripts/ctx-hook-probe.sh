#!/usr/bin/env bash
# Probe whether context-mode's PreToolUse hook breaks Review Council's
# execution contract, before spending real money on the live eval matrix.
#
# rc-prepare.sh runs as a real `bash` subprocess and writes session
# artifacts to disk (session.txt, tracking.md, changeset.txt, diff.patch,
# session-manifest.json, verdicts/_meta/). Context-mode's PreToolUse hook
# matcher covers Bash and Agent (see ctx-mode-config.sh). If it redirects
# the Bash call that runs rc-prepare.sh into a sandbox tool, and that
# sandbox discards its filesystem on exit, those artifacts never land and
# RC's whole shell-script pipeline is dead under context-mode regardless of
# what the token arithmetic says.
#
# This is a LIVE, PAID probe: it drives one full `claude -p` agentic turn
# under an isolated CLAUDE_CONFIG_DIR with context-mode's settings/mcp
# config (see ctx-mode-config.sh), instructing the model to run
# rc-prepare.sh as a shell command against a throwaway two-commit repo.
#
# Passing is defined ENTIRELY by what exists on disk afterward. The
# transcript's own claims ("I ran the prepare script and it worked") are
# not evidence: a redirected call that no-ops in a discarded sandbox would
# say exactly that. Only rc-prepare.sh's own artifacts under its session
# cache directory count — see the filesystem check below.
#
# stderr from the `claude` invocation is never discarded: an auth failure
# or a killed run must abort loudly, not be reported as "artifacts
# missing" — that would be a false disqualifying result for the whole
# RC-under-context-mode integration.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
MODULE_DIR="$REPO_ROOT/module"
RC_PREPARE="$MODULE_DIR/skills/review-council/scripts/rc-prepare.sh"
AGENTS_DIR="$MODULE_DIR/agents"
MODEL="${CTX_HOOK_PROBE_MODEL:-claude-sonnet-4-6}"

# Auth seeding (seed_auth) and the claude exit-status/stderr failure guard
# (check_claude_result) are shared with ctx-measure-tax.sh — both scripts
# make live `claude` invocations under an isolated CLAUDE_CONFIG_DIR and hit
# the same "Not logged in" wall and the same need to abort loudly on
# failure. See lib/live-claude.sh for the rationale.
# shellcheck source=.lola-eval/analysis/scripts/lib/live-claude.sh
source "$SCRIPT_DIR/lib/live-claude.sh"

if [[ ! -f "$RC_PREPARE" ]]; then
	echo "ERROR: rc-prepare.sh not found at $RC_PREPARE" >&2
	exit 1
fi
if [[ ! -d "$AGENTS_DIR" ]]; then
	echo "ERROR: AGENTS_DIR not found at $AGENTS_DIR" >&2
	exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# --- Build a throwaway repo with a real diff --------------------------------
#
# GIT_CONFIG_GLOBAL/SYSTEM=/dev/null plus explicit GIT_AUTHOR_*/GIT_COMMITTER_*
# stop the caller's own git config (identity, signing, hooks, pagers) from
# reaching this fixture — module/tests/helpers.sh's convention for every
# test that touches git, applied here for the same reason.
#
# GIT_CONFIG_GLOBAL/SYSTEM only suppress config FILES, and only on git >=2.32
# — they do nothing about commit.gpgsign already enabled some other way (e.g.
# a system-wide default baked into the git build). helpers.sh's
# git_init_sandbox documents that gap and closes it with two per-repo
# `git config` calls after `git init`; this fixture needs the same fallback
# for the parity its comment already claims to be real.
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME="ctx-hook-probe"
export GIT_AUTHOR_EMAIL="ctx-hook-probe@test.invalid"
export GIT_COMMITTER_NAME="ctx-hook-probe"
export GIT_COMMITTER_EMAIL="ctx-hook-probe@test.invalid"

repo_dir="$work/target-repo"
mkdir -p "$repo_dir"
git -C "$repo_dir" init -q -b main
git -C "$repo_dir" config commit.gpgsign false
git -C "$repo_dir" config tag.gpgsign false
cat >"$repo_dir/greeter.py" <<'PY'
def greet(name):
    return "Hello, " + name
PY
git -C "$repo_dir" add greeter.py
git -C "$repo_dir" commit -q -m "Add greeter"

# Second commit carries a real finding (string-built SQL) so this is a
# genuine diff a reviewer would have something to say about, not just two
# commits for their own sake.
cat >"$repo_dir/greeter.py" <<'PY'
def greet(name):
    return "Hello, " + name


def lookup_user(cursor, username):
    # BUG: string-built SQL, not parameterised -- a real finding for RC.
    query = "SELECT * FROM users WHERE username = '" + username + "'"
    cursor.execute(query)
    return cursor.fetchone()
PY
git -C "$repo_dir" commit -aq -m "Add lookup_user with string-built SQL"

# --- context-mode config for the treatment arm ------------------------------
bash "$SCRIPT_DIR/ctx-mode-config.sh" "$work/ctx"

config_dir="$work/config"
seed_auth "$config_dir"

# --- rc-prepare.sh's target session dir, computed in advance ----------------
#
# rc-prepare.sh (Section 5, prepare-repo.sh) keys its cache dir on a hash of
# $PWD: `pwd | sha256sum | head -c 12`. Computed identically here, in a
# subshell cd'd to the same repo_dir, so this script checks the exact
# directory the agent's Bash call would have written to — independent of
# anything the transcript claims happened.
project_id="$(cd "$repo_dir" && pwd | sha256sum | head -c 12)" # DevSkim: ignore DS126858
cache_root="${XDG_CACHE_HOME:-$HOME/.cache}/review-council/${project_id}"
# Never reused: guarantees this run's session (if any) is the only entry
# under cache_root, so the artifact check below cannot pick up a stale
# session from an earlier probe run that hashed to the same project_id.
rm -rf "$cache_root"

# --- drive the agent ---------------------------------------------------------
#
# One command, one Bash tool_use: `cd` and the invocation are chained so the
# model cannot separate them into two calls and lose the working directory
# rc-prepare.sh's own $PWD-based session keying depends on.
prompt="Run this exact shell command and report its output verbatim. Do not summarize, paraphrase, or skip it — run it with your shell/Bash tool:

cd \"${repo_dir}\" && AGENTS_DIR=\"${AGENTS_DIR}\" bash \"${RC_PREPARE}\" --scope range --scope-value HEAD~1..HEAD --mode code --effort quick"

transcript_file="$work/transcript.jsonl"
stderr_file="$work/stderr.log"
status=0
CLAUDE_CONFIG_DIR="$config_dir" claude -p "$prompt" \
	--model "$MODEL" \
	--output-format stream-json --verbose \
	--permission-mode bypassPermissions \
	--settings "$work/ctx/settings.json" --mcp-config "$work/ctx/mcp.json" \
	--strict-mcp-config \
	--add-dir "$repo_dir" \
	>"$transcript_file" 2>"$stderr_file" || status=$?

check_claude_result "$status" "$stderr_file" "aborting rather than reporting a false artifact result"

# --- tool-call histogram + denial evidence, from the transcript -------------
#
# $names maps each tool_use id to its tool name so a tool_result (which
# carries only the id) can be attributed.
#
# BLIND SPOT: stream-json does not surface a non-blocking PreToolUse
# response at all — no hook_started/hook_response system event, no text in
# the tool_result. Confirmed empirically: a live Bash "cat" call nudged by
# context-mode's additionalContext guidance produces a transcript
# indistinguishable from one the hook never touched. So transcript-based
# interference detection is structurally incomplete for that path — it can
# only ever see the DENY path (the "context-mode: ..." reason text that
# lands in an is_error tool_result, e.g. WebFetch's redirect message).
# `deny_text_evidence` below is named and scoped accordingly: it proves a
# deny happened, and its absence proves nothing about whether a
# same-turn additionalContext nudge fired. The marker-file check further
# down is what actually observes the nudge path, via the hook's own
# on-disk throttle state rather than the transcript.
report="$(jq -s '
	def result_text:
		if (.content | type) == "string" then .content
		else (.content // [] | map(select(.type == "text") | .text) | join(""))
		end;

	(reduce (.[] | select(.type == "assistant")
	         | .message.content // [] | .[]
	         | select(.type == "tool_use"))
	   as $u ({}; .[$u.id] = $u.name)) as $names

	| [ .[] | select(.type == "assistant") | .message.content // [] | .[]
	    | select(.type == "tool_use") | .name ] as $tool_use_names

	| ($tool_use_names | reduce .[] as $n ({}; .[$n] = ((.[$n] // 0) + 1))) as $histogram

	| [ .[] | select(.type == "user") | .message.content // [] | .[]
	    | select(.type == "tool_result")
	    | { name: ($names[.tool_use_id] // "UNKNOWN"),
	        is_error: (.is_error // false),
	        text: result_text } ] as $results

	| [ $results[] | select(.name == "Bash" and .is_error == true) ] as $bash_denied
	| [ $results[] | select(.name == "Agent" and .is_error == true) ] as $agent_denied
	| [ $results[] | select((.text // "") | test("context-mode:"; "i")) ] as $ctx_marked
	| (map(select(.session_id != null)) | first | .session_id) as $session_id
	| {
			tool_histogram: $histogram,
			bash_call_count: ($tool_use_names | map(select(. == "Bash")) | length),
			agent_call_count: ($tool_use_names | map(select(. == "Agent")) | length),
			bash_denied_count: ($bash_denied | length),
			agent_denied_count: ($agent_denied | length),
			# Transcript-visible only — see the BLIND SPOT note above. This
			# catches a deny reason (or a "modify" substitution, if one ever
			# quotes the same "context-mode:"-prefixed text back into a
			# tool_result) landing in a tool_result. It never catches a
			# same-turn additionalContext nudge (Bash/Read/Grep) or an Agent
			# prompt injection (Agent modify rewrites tool_use.input, not any
			# tool_result) — both are invisible here by construction.
			deny_text_evidence: ($ctx_marked | map({tool: .name, is_error, snippet: (.text[0:220])})),
			session_id: $session_id
		}
' "$transcript_file")"

# --- nudge detection via the hook's own on-disk throttle marker -------------
#
# The transcript cannot see a non-blocking additionalContext nudge (see the
# BLIND SPOT note above), so this checks the mechanism that actually
# reveals one: context-mode's PreToolUse hook throttles Bash/Read/Grep
# guidance to once per session by touching
# ${TMPDIR:-/tmp}/context-mode-guidance-s-<session id>/<lowercase tool
# name> the first time it nudges that tool in that session. Verified
# empirically against the installed hook binary: a Bash "cat" call creates
# .../bash and a repeated "cat" in the same session touches nothing further
# (already nudged); a safe-listed command ("git status", "pwd") creates
# neither the guidance directory nor the marker at all — the hook's
# `isStructurallyBounded` allowlist passes it through with no side effect.
# A marker present is therefore proof the hook engaged on Bash in THIS run;
# its absence means either the hook never fired or the command it saw was
# safe-listed — the transcript alone cannot tell those apart, but this can.
session_id="$(printf '%s' "$report" | jq -r '.session_id // empty')"
bash_nudge_marker="${TMPDIR:-/tmp}/context-mode-guidance-s-${session_id}/bash"
bash_nudge_fired=false
if [[ -n "$session_id" ]] && [[ -f "$bash_nudge_marker" ]]; then
	bash_nudge_fired=true
fi
report="$(printf '%s' "$report" | jq --arg marker "$bash_nudge_marker" --argjson fired "$bash_nudge_fired" \
	'. + {bash_nudge_marker_path: $marker, bash_nudge_fired: $fired}')"

# --- the ONLY check that decides pass/fail: artifacts on disk ---------------
session_dirs=()
if [[ -d "$cache_root" ]]; then
	mapfile -t session_dirs < <(find "$cache_root" -mindepth 1 -maxdepth 1 -type d 2>/dev/null || true)
fi

if [[ ${#session_dirs[@]} -eq 0 ]]; then
	echo "$report" | jq --arg cache_root "$cache_root" \
		'. + {session_dir: null, artifacts_found: false, missing_artifacts: ["(no session directory at all)"]}'
	echo "ERROR: no review-council session directory under $cache_root — rc-prepare.sh never reached session creation (Section 5). This is the disqualifying failure mode: the agent's Bash call was either never made or was redirected into a sandbox that discarded its output." >&2
	exit 1
fi

# Run-id directory names are `date +%Y%m%d-%H%M%S`, which sorts correctly as
# text; take the newest in the (expected-to-be-singleton) set under cache_root.
session_dir="$(printf '%s\n' "${session_dirs[@]}" | sort | tail -n1)"

required_files=(session.txt tracking.md changeset.txt diff.patch session-manifest.json)
missing=()
for f in "${required_files[@]}"; do
	[[ -f "$session_dir/$f" ]] || missing+=("$f")
done
[[ -d "$session_dir/verdicts/_meta" ]] || missing+=("verdicts/_meta/")

artifacts_found=true
[[ ${#missing[@]} -eq 0 ]] || artifacts_found=false

missing_json="$(printf '%s\n' "${missing[@]}" | jq -R . | jq -s 'map(select(length > 0))')"
final="$(echo "$report" | jq --arg session_dir "$session_dir" --argjson missing "$missing_json" --argjson ok "$artifacts_found" \
	'. + {session_dir: $session_dir, missing_artifacts: $missing, artifacts_found: $ok}')"
printf '%s\n' "$final"

if [[ "$artifacts_found" != true ]]; then
	echo "ERROR: rc-prepare.sh's session artifacts are missing under $session_dir: ${missing[*]}. This disqualifies Review Council from running under context-mode on this path." >&2
	exit 1
fi

echo "PASS: rc-prepare.sh's session artifacts landed on disk under $session_dir — context-mode's PreToolUse hook did not break RC's execution contract on this path." >&2
