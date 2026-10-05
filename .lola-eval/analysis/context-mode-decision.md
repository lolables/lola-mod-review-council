# Should Review Council run under context-mode? — decision record

**Date:** 2026-08-24
**Question:** Does running Review Council under
[context-mode](https://github.com/mksglu/context-mode) — an MCP server plus
hook bundle that keeps raw tool output out of the model's context — reduce
cost per review without reducing review quality?
**Answer:** Nuanced. Cost benefit demonstrated on the one comparison run so
far. Quality is unresolved, not "found acceptable" — the two arms shared zero
findings and the `off` arm caught something the `on` arm missed. Adoption is
blocked on a module bug ([lolables/lola-mod-review-council#26](
https://github.com/lolables/lola-mod-review-council/issues/26)) that
confounds the quality comparison, not on the cost result.
**Decision rule (set before any data existed):** adopt only if cost falls by
more than the baseline's own run-to-run spread AND review quality does not
regress. Quality is a hard gate — a cost win does not override it.
**Measurements:** `context-mode-prescreen.md` (same directory, Phase 1, arithmetic
gate) and this document's own adoption probe (Phase 2, live A/B), script
`ctx-adoption-probe.sh`, transcripts under
`.lola-eval/transcripts/ctx-adoption-probe-20260824T180446Z/`.

## Update — 2026-10-05: the #26 blocker has landed

[#26](https://github.com/lolables/lola-mod-review-council/issues/26) merged
in PR #33. Batching is now computed by `rc-plan-batches.sh` on context bytes,
and `phases/delegate.md` binds every host to that plan, including one that
offers its own batching or context management. The `delegate.md:291` escape
hatch quoted below is gone, and the description of batching as prose guidance
is true only of the module as it stood on 2026-08-24. The condition in "What
would reopen this" is met. The probe has not been re-run, so quality is still
unresolved; the cost result and the decision below stand as measured.

## What was measured

**Phase 1 — pre-screen (~$1.70, no live review run).** Measured the fixed
cost of running with context-mode present: 1,481 tokens of routing-block and
tool-schema tax per context, plus an unthrottled 4,637-byte (~1,159-token)
injection on every `Agent` dispatch. Confirmed the hook does not break Review
Council's on-disk artifact contract. Computed a sensitivity table across
three re-read models and found best-case saving always clears that tax, but
saving scaled by the then-available routing-rate evidence — 3.34% pooled
across 35 archived logs — never did, in any of the 34 usable logs. Full
detail and the arithmetic are in `context-mode-prescreen.md`, whose
realised-saving conclusion this document supersedes (see the update section
at the top of that file).

**Phase 2 — adoption probe (~$24.50, one live A/B).**
`ctx-adoption-probe.sh` ran `/review-council` twice over
[voxpupuli/openvox-ca#189](https://github.com/voxpupuli/openvox-ca/pull/189)
(`d74253a04e4a..5a92d50de565`, 31 files, +4915/−262) — identical PR, identical
prompt, differing only in whether context-mode was connected:

| | off | on |
|---|---|---|
| cost_usd | 14.864 | 9.645 |
| routing rate | 0 / 379 | 58 / 160 = 36.25% |
| compressible bytes | 3,455,720 | 251,826 |
| turns | 40 | 37 |
| persona dispatches | 15 | 11 |
| batches | 3 | 2 |
| diff bytes covered | 280,444 | 280,444 |
| mcp_servers | `[]` | `plugin_context-mode_context-mode` connected |
| verdict | APPROVE | APPROVE |
| findings | 4 (1 MEDIUM, 3 LOW) | 3 (0 MEDIUM, 3 LOW) |

Both arms are confirmed live sessions, not simulated: `off` shows zero
context-mode calls and an empty `mcp_servers` array; `on` shows the server
connected and 58 of its calls actually taken. Both dispatched the same five
personas — `divisor-adversary-code`, `divisor-curator-code`,
`divisor-guard-code`, `divisor-sre-code`, `divisor-testing-code` — and covered
the same 280,444 bytes of diff. Neither arm approached the $25 session cap.

The `on` arm hit two errors, both recovered without operator intervention:

- A named-agent dispatch for `divisor-guard-code` returned `Agent type
  'divisor-guard-code' not found. Available agents: claude, Explore,
  general-purpose, Plan, statusline-setup` and fell back to
  `general-purpose`, which completed the review with one `Read` call.
- One `ctx_execute_file` call was blocked by context-mode's own
  path-confinement: `"...resolves outside the project root
  (/tmp/tmp.4IJ2zbMZvF/openvox-ca). context-mode confines ctx_execute_file to
  the workspace so it cannot be used to bypass the host's sandbox/permission
  controls (issue #852)."` The reviewer fell back to `Read` immediately.

## The argument that decided it

**Cost fell 35%** (14.864 → 9.645), and the mechanism behind it is legible,
not a fluke of one run: routing rate in a deliberately configured arm was
36.25% — eleven times the 3.34% production baseline the pre-screen used.
Substituted into the pre-screen's own sensitivity table (see the update at
the top of `context-mode-prescreen.md`), 36.25% clears tax in all three
re-read models, by 1.9x to 5.0x. The pre-screen's `DECISION REQUIRED` verdict
turned on exactly this number, and this run replaces the incidental 3.34%
with a deliberate 36.25%.

**n = 1 on the cost figure.** One PR, one pair of runs. The 35% figure is a
real measurement, not an estimate, but it is a single data point, not a
distribution — the pre-screen's own corpus (Step 1) showed `compressible_bytes`
spanning two orders of magnitude across 34 logs, so a different PR shape could
land anywhere on that spread. Treat 35% as "cost can fall by this much," not
"cost falls by this much."

**Quality did not clear the same bar, and the reason it didn't is diagnosable
rather than mysterious.** The two arms found zero findings in common. The
`off` arm caught one the `on` arm missed: an untested `loadCRLCache` failure
path at `internal/ca/generate.go:319-322`, MEDIUM severity, confirmed by the
reviewer's own grep turning up no covering test. Read at face value, that
looks like context-mode degrading review quality. It is more precisely a
confound:

- The batch split differed — 3 batches `off`, 2 `on` — while covering
  identical diff bytes. Batching in Review Council is prose guidance in
  `phases/delegate.md`, not a script: `grep -rln
  "batches.txt\|batch_size\|batch size"
  module/skills/review-council/scripts/` returns nothing. The split is model
  judgement, not a deterministic function of the diff.
- `phases/delegate.md:291` says: *"If orchestrating tool has native batching
  or context management, may use its own mechanism instead."* context-mode
  **is** context management by the module's own definition, so its prose
  licenses the `on` arm to batch differently than the `off` arm — the
  treatment variable perturbs the input the batching rule defers to. A/B
  comparison assumes the only thing that differs between arms is the
  treatment; here the treatment also changes how work gets split before
  personas ever see it.
- Fewer batches in `on` also means fewer persona dispatches (11 vs 15) and a
  validation-gate skip that is itself protocol-correct: all of `on`'s
  findings were LOW, and the gate is specified to skip on all-LOW batches.

None of this proves context-mode is quality-neutral. It shows the current
experiment can't tell you either way — more replications would average over
the confound, not remove it, because the confound is structural (the module's
own escape hatch), not sampling noise.

**Given the decision rule, this is not a close call.** Quality is a hard
gate. One MEDIUM finding present in `off` and absent in `on`, with the
difference traceable to an unmeasured batching mechanism rather than to
context-mode's compression itself, is not "quality did not regress" — it is
"quality cannot currently be evaluated." Adoption is blocked until the
confound is removed, not until more evidence accumulates on top of it.

## Design decisions worth keeping if this is revisited

These were settled during the probe and would otherwise be re-derived from
scratch on a second attempt.

- **context-mode can never live inside the module.** It is an MCP server plus
  a host-side hook bundle — both host-specific by construction. `CLAUDE.md`'s
  tool-agnosticism rules forbid tool-specific dispatch syntax and require
  graceful degradation when a host lacks a capability; an MCP dependency
  fails both. Adoption, if it happens, is an operator-environment choice
  (how a reviewer's own Claude Code instance is configured), never a change
  to `module/`.
- **Both arms must isolate `CLAUDE_CONFIG_DIR`.** This container auto-wires
  context-mode via `RIOTBOX_CONTEXT_MODE=1` at boot (the same fact that
  contaminated the pre-screen's 35-log corpus — see `context-mode-prescreen.md`
  Step 2). Without an isolated config dir per arm, the `off` arm silently
  inherits context-mode anyway and the comparison measures nothing.
- **`--strict-mcp-config` is mandatory.** Without it, the server
  double-registers — once from the ambient container config, once from the
  arm's own config — and tool-call counts and routing rates come out wrong
  in ways that don't fail loudly.
- **The MCP server must be named exactly
  `plugin_context-mode_context-mode`.** The hooks' redirect text points
  reviewers at that literal tool name; a differently-named registration
  leaves the hooks telling the model to call a tool that doesn't exist.

## What would reopen this

Not the cost figure — that argument is made and, on this run, favourable.
The blocker is [#26](
https://github.com/lolables/lola-mod-review-council/issues/26): batching
triggers on file count while the resource it protects is context bytes, and
the fix the issue proposes (a deterministic byte budget, replacing the
current prose-plus-escape-hatch design) removes the exact mechanism that let
this probe's two arms split work differently. Once #26 lands deterministic,
byte-based batching, `ctx-adoption-probe.sh` re-runs unchanged — no new
tooling needed, just a re-run against a batching implementation that can no
longer diverge between arms.

## Licensing note

context-mode ships under the [Elastic License 2.0](
https://github.com/mksglu/context-mode/blob/main/LICENSE) — source-available,
not OSI-approved. Because adoption here means operator-side tooling (a
reviewer's own Claude Code configuration, per the design decision above) and
never a dependency the module itself ships or imports, ELv2 does not touch
`module/`'s licensing or dependency graph. It is still a real constraint on
recommending context-mode as standard workflow: an operator adopting it takes
on ELv2's terms for their own tooling, and that's a choice to flag, not one
this record can make on their behalf.
