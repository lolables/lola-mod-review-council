# A/B evaluations

Evaluating whether some external tool or module change makes Review Council
better or cheaper is not the same job as adding an eval case. Two of these have
run so far — the code-graph pre-pass (rejected) and context-mode (cost benefit
shown, quality unresolved) — and both spent most of their effort discovering that a
number they already had was wrong. The rules below are what those runs cost to
learn.

Both sets of measurements are in `.lola-eval/analysis/` —
`context-mode-*.md` and `code-graph-prepass-*.md`.

## Pin the decision rule, and its threshold, before you measure

"Cost drops materially" is not a rule. Decide what counts as a win while you
still do not know the answer, and derive the bar from data rather than taste —
the baseline arm's own run-to-run spread is a defensible bar, because a saving
smaller than the noise it must be read against is not a saving.

The code-graph study reached its rejection only after three live runs, because
efficiency was never pinned to a number in advance. Everything after that was
argument rather than measurement.

## Prove the arms differ, in the harness's own output

An arm that was supposed to have the thing under test, and did not, produces a
clean result rather than an error. Make the harness assert the difference and
abort when it fails — not a human checking a transcript once and remembering.

`ctx-measure-tax.sh` captures each arm's `system`/`init` `mcp_servers` array and
refuses to emit a number if the control arm connected anything or the treatment
arm did not connect what it should.

## Prove every gate can fail

A check that cannot fail is decoration, and it reads exactly like a check that
passed. Force both directions before trusting one: point the treatment arm at an
empty config so it registers nothing, and hand the control arm a server so it
registers something. Both must abort.

Same for pass/fail flags. `bash_nudge_fired` only became evidence once a run with
a safe-listed command showed it reporting `false`.

## Verify the run did the work before trusting its metric

Every cheap failure — an unprovisioned module, a budget cap hit, an auth failure,
a truncated capture — produces a run with few tool calls and therefore a
plausible, low, wrong number. That number will usually agree with whatever you
already expected, which is when to distrust it hardest.

Gate the metric on evidence the work happened: reviewer dispatches, findings
produced, artifacts on disk. `ctx-adoption-probe.sh` reports
`persona_dispatch_count` and the verdict line alongside its routing rate for this
reason.

## Isolate the environment on both arms

A "no flags" arm is not a control if the host supplies the thing under test
anyway. This container sets `RIOTBOX_CONTEXT_MODE=1` and wires context-mode into
the default `CLAUDE_CONFIG_DIR` at boot, so a flagless `claude` run still has it
connected. Both arms need a fresh isolated config dir, seeded with
`.credentials.json` or the CLI reports "Not logged in".

Check what the host injects before assuming the absence of a flag means the
absence of a feature. The same applies to hook blocks: `~/.claude/settings.json`
carries entries belonging to several tools, and copying it wholesale contaminates
the arm with whichever ones you did not mean to test.

## Use the same basis on both sides of an arithmetic comparison

The context-mode pre-screen first charged the fixed tax once per context while
crediting the saving with a per-turn re-read. That asymmetry rigged the
comparison before any number went in. Redone on one basis across three re-read
models, the result held in every model: at the median, the best case never
triggered reject, and the realised saving triggered it in every usable log.

When a model choice can flip the result, publish a sensitivity table across the
plausible choices rather than a point estimate. If every row agrees, the finding
is robust. If they disagree, that is the finding.

## Separate the best-case bound from the measured behaviour

A ceiling and an observation answer different questions. Report both and let the
reader see the gap; do not quietly substitute one when the other is inconvenient.

Context-mode's ceiling always cleared the bar. Its measured adoption in an
unconfigured environment never did. Both were true, and the useful discovery was
that adoption is a configuration property — 3.34% of tool calls routed through it
across incidental production logs, 36.25% in an arm configured on purpose.

## Check the corpus before treating it as a baseline

All 35 production logs used for the context-mode baseline turned out to have been
captured with context-mode already active, because the container wires it in.
They still measured something real — compressible volume it was present for and
did not compress — but that is a different claim from the one they were about to
be used for. Say which claim your corpus supports.

## Replication does not fix a structural confound

If the treatment variable perturbs an input the measurement defers to, more runs
average over the problem instead of removing it.

The context-mode run hit this. Review Council's batching was then prose in
`phases/delegate.md`, and it told any host with "native batching or context
management" to use its own mechanism, so the context tool under test was
licensed to batch differently from the control. That made the quality comparison
unmeasurable rather than noisy. Issue #26 closed it: `rc-plan-batches.sh` now
computes the split on context bytes and `delegate.md` binds every host to that
plan, which is what makes a quality re-run of context-mode worth paying for.

Before buying more runs, ask whether the thing you are averaging is noise.

## Suspect the rubric before the subject

The code-graph study's one apparent capability gap — `orphan_function_identified`
scoring 0.50, 0.50, 0.00 — was a rubric defect. The reviewers had searched for the
symbol, found its absence, and declined to call an exported constructor with no
internal caller a defect. Their judgement was right and the rubric's was wrong;
the component was inverted to `exported_api_calibration` and the same three runs
rescored 0.98 median without re-running anything.
