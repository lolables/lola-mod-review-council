# Case-004-go-clean: Root Cause Analysis and Lessons Learned

> Date: 2026-06-26
> Reference: e7ccb8423f1f415bf9119f9b441aa82d3926c104

## What is case-004?

A false-positive-control test. The subject code is a 93-line Go
string set library with 120 lines of idiomatic tests. The code is
clean, well-documented, and has no bugs. The correct review
outcome is **APPROVE** with zero or minimal findings.

**Rubric**: `correct_verdict` (weight 0.6) + `false_positive_rate`
(weight 0.4). Pass threshold: 0.70. A REQUEST CHANGES verdict
immediately costs 60% of the score. Three or more false positives
costs the remaining 40%.

**Source files under review**:

- [`stringset.go`](../tests/case-004-go-clean/starter/stringset.go) (93 lines)
- [`stringset_test.go`](../tests/case-004-go-clean/starter/stringset_test.go) (120 lines)
- [`go.mod`](../tests/case-004-go-clean/starter/go.mod) (3 lines)
- [`README.md`](../tests/case-004-go-clean/starter/README.md) (26 lines)

**Test definition**:

- [`task.yaml`](../tests/case-004-go-clean/task.yaml)
- [`prompt.md`](../tests/case-004-go-clean/prompt.md)
- [`rubric.md`](../tests/case-004-go-clean/rubric.md)

## The Result That Prompted This Investigation

**Run 8** (2026-06-27, with proper baseline isolation):

| Configuration | correct_verdict | false_positive_rate | Composite | Pass? |
|---|:---:|:---:|:---:|:---:|
| CC/Sonnet, bare model | 1.00 | 1.00 | **1.00** | YES |
| CC/Sonnet, review-council | 0.00 | 1.00 | **0.40** | NO |
| CC/Haiku, bare model | 0.00 | 0.70 | **0.28** | NO |
| CC/Haiku, review-council | 0.00 | 0.30 | **0.12** | NO |
| OC/Sonnet, bare model | 0.00 | 0.30 | **0.12** | NO |
| OC/Sonnet, review-council | 1.00 | 1.00 | **1.00** | YES |

CC = Claude Code, OC = OpenCode. Same model (Sonnet 4), same code,
same rubric. Two observations demand explanation:

1. **CC/Sonnet bare model scores 1.00 but CC/Sonnet with
   review-council scores 0.40.** The multi-agent pipeline made
   things worse, not better.

2. **OC/Sonnet bare model scores 0.12 but OC/Sonnet with
   review-council scores 1.00.** The multi-agent pipeline fixed
   what the bare model got wrong.

The same orchestration system, the same module instructions, the
same model. The only variable is the CLI host.

## Historical Progression

Case-004 scores across all eval runs during this development cycle:

| Run | CC/Sonnet | CC/Haiku | OC/Sonnet | CC/Opus | OC/Opus |
|-----|:---------:|:--------:|:---------:|:-------:|:-------:|
| 1 | 1.00 | 0.00 | 1.00 | — | — |
| 2 | 0.28 | 0.12 | 1.00 | — | — |
| 3 | 1.00 | 0.12 | 1.00 | 1.00 | 1.00 |
| 4 | 1.00 | 0.12 | 1.00 | 1.00 | 1.00 |
| 5 | 0.88 | 0.00 | 1.00 | 1.00 | 1.00 |
| 6 | 1.00 | 0.40 | 1.00 | 1.00 | 1.00 |
| 8 (proj) | 0.40 | 0.12 | 1.00 | — | — |
| 8 (none) | 1.00 | 0.28 | 0.12 | — | — |

Observations:

- **OC/Sonnet with review-council: 7/7 perfect scores (1.00).**
  Never failed once across all runs.
- **CC/Sonnet with review-council: 5/7 runs passed, 2 failed
  (0.28, 0.40).** High variance. The 0.88 in Run 5 also shows
  weakness (passed but barely).
- **CC/Haiku with review-council: 0/7 runs passed.** Scored 0.00,
  0.12, 0.12, 0.12, 0.00, 0.40, 0.12. Never once produced a
  correct APPROVE.
- **Opus (both CLIs): 4/4 perfect scores (1.00).** Not enough
  data to be conclusive but consistently perfect where tested.
- **Bare model (Run 8 only):** CC/Sonnet nails it (1.00),
  OC/Sonnet fails (0.12), CC/Haiku fails (0.28). The bare model
  without review-council is unreliable across CLIs.

## The Three Root Causes

These were identified through forensic transcript analysis of
passing and failing runs on the same case, same model.

### Root Cause 1: Subagent Dispatch Mechanism

**Claude Code** dispatched all 6 reviewer agents as
`general-purpose` subagents. The
[`divisor-*-code.md`](../../module/agents/) persona files
were never loaded as system context. The coordinator built the
entire review prompt inline.

**OpenCode** dispatched each agent by name
(`divisor-adversary-code`, `divisor-architect-code`, etc.), loading
the full persona `.md` file as the subagent's system instructions.
Each agent received its calibration rules, severity thresholds, and
grounding requirements as first-class context.

This matters because the persona files contain severity calibration
that prevents over-flagging. Without them, agents flag everything
they can find, regardless of whether it represents a real problem.

**Evidence**: In the CC/Sonnet failing run, the `task_started`
events for all 6 agents show `subagent_type: general-purpose`. In
the OC/Sonnet passing run, the `task` tool calls show
`subagent_type: divisor-adversary-code` (etc.).

### Root Cause 2: Leading Questions in Delegation Prompts

The Claude Code coordinator generated investigative questions and
injected them into each subagent's prompt. These questions
functionally told the reviewers what to find.

**Adversary prompt (CC, failing)**:
> "1. Nil receiver panics: All methods use `s.m` directly. What
>    happens when s is nil? Or when s.m is nil (zero-value Set)?"

This directs the agent to manufacture a nil-safety finding. The
OpenCode Adversary prompt instead said:
> "Standard Go nil-pointer behavior (map access on nil receiver)
>  is NOT a defect per CS-005. Do not manufacture findings."

**Curator prompt (CC, failing)**:
> "7. Missing: CHANGELOG, CONTRIBUTING, LICENSE?"

This directs the agent to report missing files as findings. The
OpenCode prompt had no such leading questions.

Every CC subagent prompt contained 5-8 numbered leading questions.
Every OC subagent prompt contained neutral task framing with
explicit anti-inflation calibration.

The [`delegate.md`](../../module/commands/review-council/delegate.md)
procedure file does not instruct the coordinator to inject
investigative questions. These were generated by the coordinator
model itself. The CC coordinator deviated from its instructions;
the OC coordinator followed them.

### Root Cause 3: Skipped Verification Phase

The [`verify.md`](../../module/commands/review-council/verify.md)
procedure file (508 lines) specifies a 6-step verification
process: attestation check, evidence verification against source
files, correction round, severity calibration, strip unverified
findings, and deduplication.

**Claude Code (failing)**: Zero tool calls between the last agent
verdict and the final report. The coordinator went from raw agent
results directly to a 240-line thinking block and emitted the
report. No evidence verification, no deduplication, no severity
recalibration. All 18 findings from 6 agents were accepted at face
value, including 4 fabricated HIGHs.

**OpenCode (passing)**: Proper Phase 4 execution. Listed all 6
agent verdicts (all APPROVE). Identified 3 overlapping findings
across agents and consolidated them. Verified each finding's
evidence against actual file content. Recalibrated one severity
(downgraded MEDIUM to LOW based on proportionality). Caught one
fabricated finding (Architect claimed README Usage section was a
placeholder) and dropped it. Wrote `verification.txt` with full
results.

The `verify.md` instructions are comprehensive and correct. The
CC coordinator chose not to follow them.

## Why the Bare Model Results Differ

The bare-model results are also informative:

- **CC/Sonnet bare = 1.00**: Without review-council, Sonnet on
  Claude Code produced a clean APPROVE with no false positives.
  Claude Code injected the prompt directly and the model reviewed
  competently on its own.
- **OC/Sonnet bare = 0.12**: Without review-council, Sonnet on
  OpenCode produced REQUEST CHANGES with 2-3 false positives
  (zero-value safety as HIGH, nil-argument panics as HIGH, test
  coverage as HIGH blockers).

This shows the **bare model is not consistently good or bad** — it
depends on the prompt framing from the CLI. The value of
review-council is that it adds structure (multi-persona review,
evidence verification, severity calibration) that corrects for
model tendencies. But only if the coordinator follows the
procedure.

## What the Failing CC/Sonnet Run Actually Produced

The judge's explanation for the CC/Sonnet/project failure:

> "The review council produced a REQUEST CHANGES verdict rather
> than the expected APPROVE. The dissenting vote came solely from
> the Tester persona, which flagged two MEDIUM findings:
> (1) missing empty-set edge cases in Union/Intersect/Difference
> tests, and (2) test function names not following the
> TestXxx_Description convention. While these are genuine
> observations about test quality style and coverage completeness,
> neither constitutes a fabricated bug..."

The false_positive_rate was actually 1.00 (no false positives). The
problem was entirely that the verdict was REQUEST CHANGES instead
of APPROVE. Two real-but-minor MEDIUM findings from the Tester
persona tipped the verdict. The verification phase, had it
executed, should have caught that MEDIUM-only findings from a
single persona do not warrant REQUEST CHANGES per the severity
calibration rules.

## What the Passing OC/Sonnet Run Actually Produced

The judge's explanation:

> "The council correctly returned APPROVE. All six agents voted
> APPROVE, and the final report carries that verdict. The findings
> produced are either legitimate test quality observations (MEDIUM:
> TestNew only asserts Len rather than element membership, a real
> TC-007 gap), minor efficiency notes (LOW: Union's unnecessary
> sort allocation via Elements()), or acceptable style and
> operational improvement suggestions... The one genuinely
> fabricated finding (The Architect's claim that the README Usage
> section is a placeholder) was caught during the verification
> phase and explicitly dropped from the final report as fabricated;
> it does not appear as a reported finding."

The verification phase caught a fabricated finding and removed it.
All surviving findings were correctly calibrated. All 6 agents
voted APPROVE.

## Fixes Applied During This Investigation

### Module-level fixes (applied to [`module/`](../../module/))

1. **Dispatch mechanism**
   ([`delegate.md`](../../module/commands/review-council/delegate.md)):
   Added explicit instruction to use discovered agent filename
   minus `.md` as subagent identifier. Do NOT dispatch as
   generic/general-purpose. Fallback: include full `.md` content
   in prompt if host doesn't support named dispatch.

2. **Prompt discipline**
   ([`delegate.md`](../../module/commands/review-council/delegate.md)):
   Added instruction: "Do NOT inject investigative questions,
   leading hints, or speculative prompts." The delegation template
   (changeset, diff, focus area, severity calibration, grounding)
   is sufficient.

3. **Mandatory verification**
   ([`review-council.md`](../../module/commands/review-council.md),
   [`verify.md`](../../module/commands/review-council/verify.md)):
   Verification phase marked as MANDATORY with inline label on both
   code and spec review flows. Preamble added to verify.md: "A
   verification phase that produces no tool calls is not a
   verification phase; it is a rubber stamp."

4. **Hard gate in report.md**
   ([`report.md`](../../module/commands/review-council/report.md)):
   Pre-condition block checks that verification.txt exists, has
   SUMMARY section, has no placeholder values, and that tool calls
   were actually made. If any check fails, coordinator must return
   to verify phase.

5. **Phase completion checklists**: All 5 phase files now end with
   mandatory checklists that must be satisfied before proceeding.
   - [`prepare.md`](../../module/commands/review-council/prepare.md)
   - [`delegate.md`](../../module/commands/review-council/delegate.md)
   - [`verify.md`](../../module/commands/review-council/verify.md)
   - [`report.md`](../../module/commands/review-council/report.md)
   - [`quality-gates.md`](../../module/commands/review-council/quality-gates.md)

6. **Path grounding**
   ([`review-council.md`](../../module/commands/review-council.md)):
   Added MODULE_DIR, AGENTS_DIR, PACKS_DIR anchors so coordinators
   can find [agent personas](../../module/agents/),
   [convention packs](../../module/packs/), and phase files without
   guessing.

7. **Framework-aware detection hints**
   ([`delegate.md`](../../module/commands/review-council/delegate.md)):
   Language- and framework-specific hints added to delegation
   template to reduce persona seam gaps (e.g., React/JSX: Architect
   checks prop drilling; Go: Adversary checks exec.Command).

### Eval harness fixes

1. **Recursive command copy**
   ([`provision.sh`](../provision.sh)): Changed flat glob to
   `cp -a` so phase procedure files (5 files in
   `commands/review-council/`) are actually deployed.

2. **Baseline isolation** (patched in lola-eval package's bundled
   `install_pack.sh` and `reset.js`): For `pack_id=none`, strip
   all module artifacts (agents, commands, skills, packs,
   AGENTS.md/CLAUDE.md instruction blocks) so the bare model truly
   runs without review-council. This is a gap in lola-eval's
   Mode 1 (in-repo) baseline support — `calculate_baseline` was
   designed for Mode 2 (external packs) where installation is
   dynamic.

3. **Cross-contamination**
   ([`provision.sh`](../provision.sh)): Added `starter-clean/`
   directories alongside provisioned `starter/` for verification.

## Impact of Fixes

| Metric | Run 1 (before fixes) | Run 6 (after fixes) |
|--------|:--------------------:|:-------------------:|
| Overall pass rate | 66.7% (12/18) | 93.3% (28/30) |
| CC/Sonnet case-004 | 1.00 | 1.00 |
| CC/Haiku case-004 | 0.00 | 0.40 |
| OC/Sonnet case-004 | 1.00 | 1.00 |

The fixes brought the overall pass rate from 66.7% to 93.3%. The
remaining failures are CC/Haiku (model too weak for false-positive
control) and stochastic variance on CC/Sonnet case-004.

CC/Sonnet case-004 is volatile across runs: 1.00, 0.28, 1.00,
1.00, 0.88, 1.00, 0.40. The instructions are correct, but the CC
coordinator does not always follow them. This is a stochastic
compliance problem, not an instruction gap.

## Lessons Learned

### 1. Multi-agent orchestration amplifies model weaknesses

When a model is prone to over-flagging, adding more agents gives it
more opportunities to generate false positives. The verification
phase is the safety net, but only if it actually runs. Without
verification, multi-agent review is strictly worse than single-
model review on clean code.

### 2. The CLI host's dispatch mechanism matters more than the instructions

[`delegate.md`](../../module/commands/review-council/delegate.md)
says "use the agent filename as the subagent identifier." OpenCode
does this natively because its `task` tool accepts agent names.
Claude Code's `Agent` tool only supports `general-purpose`, `plan`,
and `explore` as subagent types — the
[`divisor-*-code.md`](../../module/agents/) files are not
registered as agent types. The fallback (inline prompt) works but
loses persona calibration.

The module cannot fix this. It is a host capability gap.

### 3. LLM coordinators deviate from instructions under time pressure

The Claude Code coordinator consistently skipped the verification
phase and injected leading questions, despite explicit instructions
not to. This happened across multiple runs. The instructions were
clear, but the model chose to shortcut. Adding checklists and hard
gates reduced this but did not eliminate it.

### 4. Baseline isolation requires active stripping, not passive omission

The original `calculate_baseline` design assumed pack installation
was dynamic (Mode 2). In Mode 1 (in-repo provisioning), the module
is already baked into starters. Achieving a true bare-model
baseline required actively stripping module artifacts, not just
skipping the install step.

### 5. False-positive control is harder than detection

Across all runs and all models, case-004 (false-positive control)
is the most frequently failed case. Detection cases (001, 003) are
easy — models find bugs reliably. Restraint — correctly identifying
that there is nothing wrong — is the harder task and the better
measure of review quality.

### 6. The same model behaves differently across CLIs

Sonnet on CC/bare scores 1.00; Sonnet on OC/bare scores 0.12.
Same model, same code, different system prompts and tool
configurations from the CLI host. This means eval results are not
portable across CLIs. A module that works on one host may fail on
another, and fixing the module alone is not sufficient.

## Appendix: Rubric

From [`rubric.md`](../tests/case-004-go-clean/rubric.md):

```yaml
pass_threshold: 0.7
weights:
  correct_verdict: 0.6    # APPROVE expected
  false_positive_rate: 0.4 # Zero false positives expected
```

## Appendix: Source Code Under Review

93-line [`stringset.go`](../tests/case-004-go-clean/starter/stringset.go):
unordered set of strings backed by a map. Constructor (`New`),
mutators (`Add`, `Remove`), queries (`Contains`, `Len`,
`Elements`), set operations (`Union`, `Intersect`, `Difference`),
and `String()`. Safe for concurrent reads, not writes.

120-line [`stringset_test.go`](../tests/case-004-go-clean/starter/stringset_test.go):
table-driven `TestNew`, `TestAddAndContains`, `TestRemove`,
`TestElements`, `TestUnion`, `TestIntersect`, `TestDifference`,
`TestString`. All pass. Standard `testing` package, no external
dependencies.

The code is intentionally clean. There are no bugs, no security
issues, no architectural problems.

## Appendix: Key Module Files

| File | Role |
|------|------|
| [`review-council.md`](../../module/commands/review-council.md) | Top-level command, path anchoring, phase orchestration |
| [`prepare.md`](../../module/commands/review-council/prepare.md) | Mode detection, agent discovery, changeset capture |
| [`delegate.md`](../../module/commands/review-council/delegate.md) | Dispatch mechanism, prompt templates, severity calibration |
| [`verify.md`](../../module/commands/review-council/verify.md) | Evidence verification, deduplication, validation gate |
| [`report.md`](../../module/commands/review-council/report.md) | Final report generation, pre-condition gate |
| [`quality-gates.md`](../../module/commands/review-council/quality-gates.md) | CI status, quality tool integration |
| [`reviewer-protocol.md`](../../module/packs/reviewer-protocol.md) | Shared reviewer procedures, pack loading rules |
| [`go.md`](../../module/packs/go.md) | Go convention pack |
| [`severity.md`](../../module/packs/severity.md) | Shared severity level definitions |
| [`SKILL.md`](../../module/skills/review-council/SKILL.md) | Skill summary, model guidance pointer |
| [`config.yaml`](../config.yaml) | Eval matrix configuration |
| [`provision.sh`](../provision.sh) | Starter provisioning script |
