# Context-mode pre-screen — arithmetic gate, no eval spend

**Date:** 2026-08-24
**Branch:** `test/context-mode-eval`
**Decision rule (set before any data existed):** adopt only if median `cost_usd`
drops by more than the baseline arm's own run-to-run spread AND median
`composite` stays within the configured 0.15 tolerance.
**Reject condition (also set in advance):** reject if `tax paid` ≥
`best-case saving`, where best-case assumes context-mode compresses ALL
compressible tool output to nothing — deliberately absurd in context-mode's
favour, so a loss against it needs no eval spend to act on.
**Run:** `ctx-volume-split.sh`, `ctx-measure-tax.sh`, `ctx-hook-probe.sh`,
plus one direct hook invocation, all against 35 archived Review Council
transcripts in `/workspace/.review-council-logs/`.

## Update — 2026-08-24: the realised-saving branch below is superseded

**What changed:** the adoption probe (`ctx-adoption-probe.sh`, see
`context-mode-decision.md` in this directory) ran Review Council twice over
the same PR, back to back, with context-mode off and on. The `on` arm's
routing rate was **36.25%** (58 of 160 tool calls) — eleven times the 3.34%
pooled corpus rate this pre-screen used for "realised saving" below.

That gap is not a measurement error in either number. The 3.34% figure comes
from 35 archived logs captured on a host where context-mode auto-wires itself
(`RIOTBOX_CONTEXT_MODE=1`) but nothing in those sessions asked reviewers to
route through it. The adoption probe is the first run where context-mode was
deliberately the thing under test. 3.34% measures incidental use; 36.25%
measures use under a run built to exercise it. Both are real; they answer
different questions, and only the second one bears on "what happens if this
gets adopted."

Substituting 36.25% for 3.34% in Step 3's own per-log-median tax and
best-case-saving figures (medians scale linearly under a positive constant
multiplier, so no re-run of the per-log arithmetic is needed):

| Model | Median tax | Median best-case saving | Realised @ 36.25% | Clears tax? |
|---|---|---|---|---|
| 1. No re-read | 22,603 | 313,708 | 113,719 | Yes, 5.0x |
| 2. Average re-read | 1,136,365 | 5,823,565 | 2,111,042 | Yes, 1.9x |
| 3. Full re-read (symmetric ceiling) | 1,136,365 | 11,647,130 | 4,222,085 | Yes, 3.7x |

At 36.25%, realised saving clears tax in every model — the opposite of the
"realised always rejects" result reported in Step 3 and the Verdict below.
**This is what unstuck the DECISION REQUIRED verdict**: see
`context-mode-decision.md` for the adoption probe's full numbers and the
argument built on them.

This does not make the original Step 2/Step 3 arithmetic wrong. The pre-screen
was correct about what the 35-log corpus showed, and the corpus's own caveat
(Step 2: "all 35 logs already had context-mode wired in and still routed to
it 3.34% of the time") is exactly what flagged that number as a floor, not a
ceiling, on achievable routing. What was wrong was treating an
incidental-use rate as the number that should govern an adoption decision.
The fix is a second, deliberately configured measurement, not a re-reading of
the first one — original figures below are left as-run, not restated.

## Result: best-case and realised disagree, and the disagreement is not an artifact of the re-read model — DECISION REQUIRED (as of this document's original writing; see update above)

An earlier draft of this document computed tax on a "paid once per context"
basis and saving on a "re-read every turn" basis, then compared the two. That
mismatch is a bug, not a modelling choice: the injected prefix costs anything
*because* it re-reads on every subsequent turn as a cache hit — the same
mechanism a Read/Bash/Grep result would ride if it were left uncompressed. If
re-reads count toward saving, they have to count toward tax on the same
terms, or the comparison is rigged before the first number is plugged in.

Redone on a consistent basis (three re-read models, Step 3 below), the
picture is not "verdict flips depending on modelling taste" — it is stable
in both directions at once:

- **Best-case never triggers reject**, under any of the three models tested,
  at the point-median level, and in the large majority of individual logs.
- **Realised — the saving scaled by the measured 3.34% routing rate — always
  triggers reject**, under every model tested, at the point-median level and
  in every one of the 34 usable logs.

That is the disagreement the original pre-screen brief anticipated
("If those two answers differ, say so prominently. Do NOT pick one and
present it as the verdict") — now confirmed robust rather than resting on
one arbitrary multiplier choice.

## Step 1 — V and M across the corpus

```
for f in /workspace/.review-council-logs/*.log; do
    printf '%s ' "$(basename "$f")"
    .lola-eval/analysis/scripts/ctx-volume-split.sh <"$f"
done
```

34 of 35 logs pass the filter's guards. One, `junhoyeo-tokscale-pr-1098.log`,
fails with `no result event found in transcript (run may have been aborted)`
— its stream-json has no terminal `result` event, meaning the run was cut
off before completion. `ctx-volume-split.sh` refuses to guess a turn count
for a transcript that never finished, per its own guard, so this log is
excluded from every volume/tax figure below. It is not silently dropped: it
is counted here, and it is not excluded from Step 2's routing-rate count,
because that count only needs `tool_use` blocks, which the aborted
transcript still has.

| Field | min | p25 | median | p75 | max |
|---|---|---|---|---|---|
| `compressible_bytes` | 51,282 | 311,647 | **1,254,830.5** | 2,948,819 | 6,179,538 |
| `incompressible_bytes` | 9,656 | 14,792 | **29,589.5** | 127,486 | 1,548,227 |
| `agent_dispatches` | 6 | 7 | **8** | 15 | 48 |
| `turns` | 7 | 31 | **45** | 75 | 169 |

n = 34. The spread is wide, not narrow — `compressible_bytes` spans two
orders of magnitude (51K to 6.2M) and `agent_dispatches` spans 6 to 48. A
median stated alone would understate how differently these 34 PRs behaved;
the per-log arithmetic further down is where that spread shows up as a real
disagreement between runs, not just noise around a center.

## Step 2 — context-mode routing rate

All 35 logs were captured on a host where `RIOTBOX_CONTEXT_MODE=1`
auto-wires context-mode's MCP server at container boot. Context-mode was
installed, connected, and available in every run measured here. `V`
(compressible bytes) is therefore **not** "compressible volume in a
context-mode-free run" — it is compressible volume that context-mode was
present for and chose not to compress, because Review Council's reviewers
never called it. Counting `mcp__plugin_context-mode_context-mode__*` calls
against total tool calls, per log:

| Metric | Value |
|---|---|
| Corpus-wide pooled rate (Σctx / Σtotal) | 339 / 10,158 = **3.34%** |
| Per-log rate, median | **0.0%** (20 of 35 logs made zero context-mode calls) |
| Per-log rate, max | 57.0% (`voxpupuli-openvox-ca-pr-223.log`, 85/149) |
| Spot check (`voxpupuli-openvox-ca-pr-167.log`) | 2/845 — matches the pre-supplied spot check exactly |

The median and the pooled rate disagree by design of the data: a handful of
logs (15 of 35) drive nearly all context-mode usage, while most logs (20 of
35) never touch it. Read plainly: even with context-mode wired in and ready,
Review Council's reviewers reached for it on a small minority of calls, and
in most runs never reached for it at all. "Realised saving" below uses the
pooled corpus-wide rate (3.34%), per the instruction to report one
corpus-wide number — the per-log median of 0% is reported here as the
caveat it is, not folded into the arithmetic.

## Step 3 — the arithmetic

**Fixed prefix tax `T`**, from `ctx-measure-tax.sh` (3 samples, live
`claude -p` calls, isolated `CLAUDE_CONFIG_DIR` per arm):

```
$ bash .lola-eval/analysis/scripts/ctx-measure-tax.sh
{
  "samples": [
    { "fixed_tax_tokens": 1481, ... },
    { "fixed_tax_tokens": 1501, ... },
    { "fixed_tax_tokens": 1481, ... }
  ],
  "median_fixed_tax_tokens": 1481
}
```

Median 1481, one sample landed at 1501 (+20) — consistent with the ± 20
wobble already on record. Both arms confirmed connected/disconnected as
claimed (`mcp_servers_off: []`, `mcp_servers_on:
plugin_context-mode_context-mode`), so the gate this script runs before
reporting a number was satisfied, not skipped.

**Agent injection size**, measured directly rather than trusted, by piping a
synthetic `Agent` tool-use payload into the installed hook:

```
$ echo '{"hook_event_name":"PreToolUse","tool_name":"Agent",
  "tool_input":{"subagent_type":"general-purpose","prompt":"Investigate the
  auth module and report findings."},
  "session_id":"ctx-prescreen-probe-session","cwd":"/tmp"}' \
  | context-mode hook claude-code pretooluse
```

The hook returns `{"action":"modify","updatedInput":{...prompt +
<context_window_protection>...}}` unconditionally — the same block visible
at the top of this very session's context. Measured injected block: **4,637
bytes** (the pre-supplied figure was 4,638 — a 1-byte difference, immaterial)
≈ **1,159 tokens** at 4 bytes/token, close to the pre-supplied "~1,150."
Reading `routing.mjs:894-916` confirms this fires on every `Agent`
dispatch with no once-per-session throttle — there is no `guidanceOnce(...)`
call on this branch, unlike the Read/Grep/Bash branches at lines 826-872,
which do throttle via `guidanceOnce`. `routing.mjs:260-324`
(`SAFE_COMMAND_PATTERNS`) confirms the safe-list claim: `pwd`, `git status`,
`ls` (non-recursive) all match; `ls -la` is not itself pattern-matched by
name but `ls(?!\s+-[a-zA-Z]*R)...` accepts any non-`-R` flag bundle, so
`ls -la` passes.

**Why tax and saving must share a re-read model.** Both `T` and a
Read/Bash/Grep/Glob result enter the context at some turn and, from that
turn on, sit in every subsequent turn's input as accumulated conversation
history — a cache hit if nothing upstream evicts it, but still transmitted,
still billed, still "read" in the sense this arithmetic cares about. There is
no basis for crediting saving with re-reads while charging tax only once.
Three models below apply the *same* re-read principle to both sides — they
differ only in how much re-reading they assume, not in whether tax gets the
same treatment as saving.

| Model | Saving re-read count | Tax re-read count | Rationale |
|---|---|---|---|
| **1. No re-read** | ×1 (counted once) | ×1 (counted once) | Ignore conversation accumulation entirely on both sides — the floor case. |
| **2. Average re-read** | ×`turns/2` | ×`turns` | A tool result lands at a random turn and is re-read for the turns *remaining* after it enters — averages to half the run. The prefix is injected at turn 1, so nearly all turns remain: it is re-read the full count. This is the principled middle model — the prefix's own physical behaviour, not an arbitrary split. |
| **3. Full re-read (absurd-favour ceiling)** | ×`turns` | ×`turns` | Both artifacts treated as if present since turn 1 — the original best-case ceiling, now applied to tax as well so the ceiling is symmetric rather than one-sided. |

Tax's own formula is unchanged in shape — `T × (agent_dispatches + 1)` for
the prefix (one per context) plus `1,159 × agent_dispatches` for the Agent
injection — only the re-read multiplier changes between rows. Saving is
`compressible_bytes ÷ 4`, multiplied the same way. Realised saving is best
case × the measured pooled routing rate (3.34%, Step 2).

### Sensitivity table (per-log: each log's own tax/saving computed, then medianed — not medians multiplied together)

| Model | Median tax | Median best-case saving | Reject on best-case? | Median realised saving | Reject on realised? |
|---|---|---|---|---|---|
| 1. No re-read | 22,603 | 313,708 | No (point-median); **2/34** logs | 10,469 | **Yes** (point-median); **34/34** logs |
| 2. Average re-read | 1,136,365 | 5,823,565 | No (point-median); **4/34** logs | 194,348 | **Yes** (point-median); **34/34** logs |
| 3. Full re-read (symmetric ceiling) | 1,136,365 | 11,647,130 | No (point-median); **2/34** logs | 388,696 | **Yes** (point-median); **34/34** logs |

Read across, not just down: in every row, best-case clears tax by a wide
margin (13.9x at the tightest, Model 1) and tax exceeds realised by a wide
margin too (2.2x in Model 1, up to 5.8x in Model 2). Every one of the 34
usable logs rejects on realised, in every model — not a marginal split, not
sensitive to which row you pick. The 2-4 logs that reject on best-case are
the low-`compressible_bytes`, low-`turns`, non-trivial-`agent_dispatches`
outliers already flagged in Step 1's spread.

Worked example, Model 1, `voxpupuli-openvox-ca-pr-142.log` (`agent_dispatches:
7, turns: 31, compressible_bytes: 960,862`):

```
tax_once     = 1481×8 + 1159×7        = 11,848 + 8,114  = 19,963 tokens
saving_once  = 960,862 / 4                              = 240,216 tokens  (best-case)
realised     = 240,216 × 0.03337                        = 8,017 tokens
19,963 ≥ 240,216?  No  -> best-case does not reject
19,963 ≥ 8,017?    Yes -> realised rejects
```

## Hook-conflict result

`ctx-hook-probe.sh`, re-run for this task rather than trusted from Task 5's
record:

```
$ bash .lola-eval/analysis/scripts/ctx-hook-probe.sh
{
  "tool_histogram": {"Bash": 1},
  "bash_denied_count": 0, "agent_denied_count": 0,
  "deny_text_evidence": [],
  "bash_nudge_fired": true,
  "artifacts_found": true, "missing_artifacts": []
}
PASS: rc-prepare.sh's session artifacts landed on disk ... — context-mode's
PreToolUse hook did not break RC's execution contract on this path.
```

The hook engaged (`bash_nudge_fired: true` — the on-disk throttle marker was
written) and Review Council's own artifact contract (`session.txt`,
`tracking.md`, `changeset.txt`, `diff.patch`, `session-manifest.json`,
`verdicts/_meta/`) still landed on disk. Only `WebFetch` is unconditionally
denied by the routing table, and Review Council reaches forges via
`gh`/`glab` run inside `Bash`, not `WebFetch` — so this denial path does not
touch RC's actual network use.

## Caveats

1. **Corpus contamination (Step 2).** Every log was captured with
   context-mode already wired in. The routing rate measured here is
   adoption-when-available, not a treatment-vs-control comparison — it says
   nothing about whether a run built to route deliberately would reach a
   higher or lower rate.
2. **The re-read multiplier is modelled, not measured, on both sides.**
   Neither `turns` nor a per-byte/per-context timestamp tells us exactly when
   in a session each compressible byte or each agent context appeared, so
   all three rows of the sensitivity table are approximations of a real
   re-read pattern this data cannot pin down exactly. What the three rows do
   establish is that the direction of the disagreement (best-case clears tax,
   realised does not) does not depend on which approximation is chosen.
3. **Tax is modelled in token-equivalents, not dollars.** Cache-read pricing
   (a fraction of fresh-input price) is not applied to either side of this
   arithmetic; both tax and saving are counted in raw token-equivalents so
   they stay comparable to each other, not to a real invoice.
4. **This is not the adoption decision.** The pre-screen only rules out one
   failure mode — tax dominating even the most generous saving assumption.
   It does not touch median `cost_usd` spread or median `composite`
   tolerance, which is what Phase 2's live A/B is for.

## Verdict

**Superseded 2026-08-24** — see "Update — 2026-08-24" near the top of this
document and `context-mode-decision.md` for the resolution. Left below
exactly as originally written.

**DECISION REQUIRED**

The pre-registered reject rule is stated in terms of best-case: "reject if
tax paid ≥ best-case saving." Judged strictly against that rule, the
pre-screen says proceed — best-case saving clears tax by more than an order
of magnitude in all three re-read models, at the point-median level and in
30-32 of 34 individual logs.

But the brief also asked for the realised figure because it "may be the most
important number in the report," and realised paints the opposite picture:
tax paid exceeds realised saving in every one of the 34 usable logs, in every
one of the three re-read models tested. That is not a narrow miss sensitive
to which multiplier is chosen — it holds from the most conservative model
(no re-read credit for either side) to the most generous (both sides re-read
every turn from turn 1).

This is exactly the situation the original brief called out in advance and
told the analyst not to resolve unilaterally: best-case and realised
disagree, the disagreement is stable rather than a modelling artifact, and
the choice of which one governs the go/no-go call is a decision about how
much weight to put on measured-but-contaminated adoption behaviour (Step 2's
caveat: all 35 logs already had context-mode wired in and still routed to it
3.34% of the time, pooled, 0% at the per-log median) versus a hypothetical
ceiling no real compression scheme reaches. That call belongs to the user.

What this pre-screen does establish, and can be handed off with confidence:
the hook does not break Review Council's execution contract (confirmed
live), and the tax and injection figures are independently verified, not
assumed. The arithmetic gate itself resolves to a genuine fork, not a
rounding error — decide which side of that fork governs before committing to
the $60 matrix.
