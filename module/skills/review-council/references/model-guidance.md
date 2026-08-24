---
description: "Empirical model comparison data from the Review Council eval suite."
last_updated: 2026-06-30
---

# Model Guidance for Review Council

Empirical data from eval suite (6 cases: Go security, TypeScript/React architecture, Python multi-concern, false-positive resistance, per-persona coverage, convention pack detection).

## Summary

Sonnet-class best quality-to-cost ratio. Matches or exceeds opus-class on detection, costs 2-4x less. Haiku-class passes most cases but struggles with false-positive suppression and convention pack attribution.

## Scores by Model Class

Composites (0.0-1.0) across weighted rubric dimensions. Pass thresholds: 0.60-0.70.

| Case                              | Opus     | Sonnet   | Haiku    |
|-----------------------------------|----------|----------|----------|
| Go security (4 flaws)             | 1.00     | 1.00     | 0.85     |
| TS/React architecture (5 flaws)   | 0.73     | 0.87     | 0.73     |
| Python multi-concern (7 flaws)    | 0.88     | 1.00     | 1.00     |
| Go clean code (0 flaws)           | 1.00     | 1.00     | 0.40     |
| Python per-persona (6 flaws)      | 0.95     | 0.84     | 0.90     |
| TS convention pack (5 violations) | 0.77     | 0.82     | 0.45     |
| **Average**                       | **0.89** | **0.92** | **0.72** |

Scores averaged across multiple CLI hosts.

> Haiku scores 0.40 on clean codebases (Go clean code), indicating 60% false positive rate — primary reason not recommended for reviewer subagents.

## Cost Per Review

<!-- READ BY CODE — this table is data, not just prose.
     scripts/rc-cost-estimate.sh (cost_rows) parses the rows below and the
     `Council size:` line beneath them to price a deep run before it dispatches.

     The contract, all three parts required:
       * each row stays `| <Class> | $<low>-$<high> |`
       * column 1 is the name `REVIEW_COUNCIL_MODEL_CLASS` matches, lowercased
       * `Council size: <n>` stays a bare `Key: value` line (read by rc_parse_kv)

     Re-measuring the models is expected and welcome: edit the numbers here and
     module/tests/test-rc-cost-estimate.sh goes red naming the new band, which
     is your cue to update the fallback constants in the script to match. That
     red is the feature — it stops the shipped table and the quoted figure
     drifting apart.

     Changing the SHAPE is the dangerous edit. The suite catches it, but at
     runtime a table the estimator cannot parse degrades quietly to a built-in
     Sonnet band, and operators are quoted Sonnet prices for an Opus council. -->

| Model Class | Cost Range  |
|-------------|-------------|
| Opus        | $1.30-$8.80 |
| Sonnet      | $1.00-$2.80 |
| Haiku       | $0.07-$0.72 |

<!-- READ BY CODE — not a stray line. rc_parse_kv reads it as `Key: value`;
     rewriting it as prose ("The council is five personas") breaks the parse. -->

Council size: 5

Each range above is one whole review — a single council pass of five reviewer
dispatches, the roster the eval suite ran. Divide by the council size for a
per-dispatch figure, and multiply back up by the roster a given session
actually discovered. `rc-cost-estimate.sh` does exactly that, so re-measuring
the models updates this document and the figure operators are quoted in one
edit.

Cost varies with codebase size and finding count. Pricing as of 2026-06-30.

## Cost of Contextual Persona Selection

`rc-select-council.sh` (SKILL.md Step 2.2) drops reviewers whose lens the
changeset does not touch. Against the per-dispatch figures above, on a Sonnet
council:

| Changeset shape | Dispatches | Saved per iteration |
|-----------------|-----------:|--------------------:|
| Prose docs only | 3 of 5 | 40% |
| Tests only | 4 of 5 | 20% |
| Lockfiles only | 2 of 5 | 60% |
| Anything else | 5 of 5 | none |

The saving compounds where the cost does. Deep mode dispatches a council per
subsystem and repeats up to the iteration cap, so a docs subsystem inside a
five-subsystem, three-iteration run costs 6 dispatches instead of 15. Selection
is evaluated per subsystem for exactly that reason.

Most real changesets are `mixed` and save nothing, which is the intended shape
of the feature: it is a discount on the reviews that were never worth full
price, not a general reduction in council size. The five-persona roster stands
on its measured yield; nothing here narrows a changeset that has code in it.

**The posture is fail-open, and deliberately asymmetric.** A redundant dispatch
costs the per-dispatch figure above. A false skip costs a finding, and nothing
downstream can tell that the finding is missing. So selection narrows only on a
signal it can state — every file in the changeset falling in one class — and
dispatches the full council on everything else: an inconclusive shape, prose
that sits under a prompt surface (where markdown is executable), spec mode,
explicit `--review-instructions`, a pinned persona, a partial install whose
council would empty, or a session it cannot read. Preparation seeds the council
with the whole roster, so a host that never runs the step is unaffected.

Every skip is published with its reason, in `tracking.md`, the report's
Discovery Summary and the PR comment's reviewer table. A narrowed review never
presents as full coverage.

## Cost of Subsystem Triage

Triage (SKILL.md Step 2.3, deep mode, **off by default**) spends one
cheapest-tier dispatch to remove reviewer dispatches from the deep-mode grid.
Against the tables above, on a Sonnet council with a Haiku triage:

| | Cost |
|---|---:|
| One triage pass | $0.014 - $0.144 |
| One reviewer dispatch removed | $0.20 - $0.56 |

It has to run on every deep review to save on some, so it clears its own cost
once it removes roughly **one** dispatch — about 7% to 26% of a single cell,
on a grid of 10 to 30. Anything past that is margin. The saving compounds with
the iteration cap, because a removed cell stays removed on every subsequent
iteration.

**Why this is permissible where a whole-changeset judgement is not.** The rule
this file declines to ship — "no API change, so drop the Curator" — asks a
cheap model whether a lens is needed at all, which is the strong reviewer's
own job and loses a whole lens when it is wrong. Triage asks only which
subsystem a lens should spend its dispatch on, and three invariants in
`rc-apply-triage.sh` hold it there: `row-coverage` (a lens excluded everywhere
is restored), `column-floor` (no subsystem below two reviewers), and
`open-finding` (a reviewer with an unresolved finding keeps that subsystem).
The worst available outcome is one lens missing one subsystem it still reviews
elsewhere — bounded, disclosed, and recoverable by re-running with `--no-triage`.

The default stays `off` until measured. `.lola-eval/tests/case-026-triage-recall/`
plants one defect per lens per subsystem and fails if triage loses any of them;
that case has not been run, and this document will say so until it has.

## Recommendations

**Coordinator**: Use user-configured model. Orchestration, not deep analysis.

**Reviewer subagents**: Sonnet-class sweet spot. Per-subagent tiers (if host supports model selection):

- **Capable tier** (Adversary, Guard): Sonnet or above. Requires judgment on intent, security, governance.
- **Standard tier** (Tester, Operator, Curator): Sonnet. Checklist-driven but needs accurate code reading and false-positive control.

Haiku not recommended for reviewers. Budget option for Standard tier only — expect lower false-positive control and convention detection. Never use haiku for Capable tier.

## Limitations

- Eval suite uses small, focused codebases (50-300 lines). Real-world patterns may differ.
- Only Claude model variants tested.
- Scores reflect full pipeline including verification, not raw model capability.
