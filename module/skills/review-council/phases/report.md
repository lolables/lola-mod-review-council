# Phase: Report — LLM Judgment Reference

Guides orchestrator's narrative synthesis, learnings extraction, final verdict determination.

---

## How Sections Reach the Report

Every structured section in the report is anchored by a marker
`rc-render-report.sh` emits. The orchestrator's whole job here is literal
string substitution, and it has exactly two moves:

- **The section applies** — replace the marker line with the section text.
- **The phase that produces it did not run** — delete the marker line **and
  its trailing blank line**. The renderer emits every marker as
  `blank / marker / blank`, so deleting the marker alone leaves the two blank
  lines touching. On the common path — a first-time review at standard effort
  with no CI — five of the eight markers are dropped. Four of those five sit
  together in the findings-context slot, so deleting only their marker lines
  leaves a five-line blank gap ahead of `## Council Synthesis`. Rendered HTML
  hides it; the `report.md` artifact a maintainer reads, and any MD012 linter,
  do not.

`<!-- TLDR -->` is the one marker the second move never applies to. Every
report has an outcome, so every report has a TL;DR — there is no run in which
the section does not apply, and no phase whose absence excuses it. Deleting it
leaves the verdict heading with a bare emoji line under it, which is the
condition the TL;DR exists to prevent.

Never append a section the renderer did not anchor, and never leave a marker
unreplaced; a raw HTML comment in a maintainer-facing report is the same
failure the quick-mode LEARNINGS rule guards against.

This is what SKILL.md's EXECUTION-CONTRACT means by "fill only the markers".
The marker set is larger than `<!-- NARRATIVE -->` and `<!-- LEARNINGS -->`:

| Marker                          | What replaces it                            | Procedure below              |
|---------------------------------|---------------------------------------------|------------------------------|
| `<!-- TLDR -->`                 | One-line TL;DR under the Council Verdict    | Narrative Synthesis          |
| `<!-- SUBSYSTEM-ANALYSIS -->`   | Subsystem Analysis section                  | Subsystem Analysis           |
| `<!-- MERGE-ADVISORIES -->`     | Merge Advisories section                    | Merge Advisories             |
| `<!-- ACCEPTANCE-CRITERIA -->`  | Acceptance Criteria Coverage section        | Acceptance Criteria Coverage |
| `<!-- DISPOSITION-OUTCOMES -->` | Disposition Outcomes, all three subsections | Disposition Outcomes         |
| `<!-- CI-COMMENTARY -->`        | CI Commentary section                       | CI Commentary                |
| `<!-- NARRATIVE -->`            | Council Synthesis body                      | Narrative Synthesis          |
| `<!-- LEARNINGS -->`            | Prior Learnings body                        | Learnings Extraction         |

The replacement text carries its own `##` heading. The renderer emits a bare
marker line and no heading precisely so that dropping the marker leaves no
dangling heading behind. `<!-- TLDR -->` is the exception on both counts: it
sits under `## Council Verdict`, which the renderer already emitted, and its
replacement is one plain sentence with no heading of its own.

A section you believe belongs in the report but has no marker is a renderer
bug — fix `rc-render-report.sh` and its tests, do not hand-append the section.

---

## Pre-condition Gate

**Before generating any report content**, verify Verification phase actually executed.

Checks 2, 3 and 4 are also enforced mechanically: `rc-render-report.sh` reads
the same file and refuses to render — emitting only a "Not rendered" notice with
no verdict — when it is missing, empty, has no `=== SUMMARY ===` section, or
still holds `{N}`-shaped template placeholders. Check them here anyway; reaching
the renderer and being turned away wastes a phase, and check 5 has no mechanical
equivalent.

1. Read `${session_dir}/verdicts/_meta/verification.txt`.

2. **If file does not exist or is empty**: STOP. Do not generate report. Return to Verification phase and execute it. Display:
   > "verification.txt is missing — the Verification phase was not executed. Returning to Phase 4."

3. **If file exists but has no `=== SUMMARY ===` section**: STOP. Verification was incomplete. Return to Verification phase to finish it.

4. **If SUMMARY section contains only placeholder values** (e.g., `{N}` instead of actual numbers): STOP. Verification was templated, not executed. Return to Verification phase.

5. **If verification.txt shows zero tool calls were made** (no file reads, no greps, no evidence checks recorded in EVIDENCE VERIFICATION section): verification was performed mentally, not mechanically. Return to Verification phase and re-execute with actual tool calls.

Only proceed to generate report once verification.txt passes all five checks above.

These five checks are unconditional. No phase outcome exempts a run from them.
That includes an evidence check that returned `nothing_to_do`: that path writes
an abbreviated `verification.txt` precisely so it can pass these checks — see
`phases/verify.md`, under its `nothing_to_do` heading. An exemption here would
rest on the orchestrator's own account of a status only it observed, which is
not evidence; the abbreviated record is.

---

## Provenance Disclosure

`rc-render-report.sh` opens every report with a banner stating it was
LLM-generated. **Mandatory, all effort modes** — never remove,
suppress, or soften. Review artifact a maintainer acts on must declare
it was produced by an LLM, not a human reviewer.

Before running `rc-render-report.sh`, record models used to
`${session_dir}/models.json` — a JSON array of `{"role":"...","id":"..."}`
objects — so the renderer names them in the provenance header. Record, to
extent host exposes model identity:

- Coordinator (this orchestrator) model.
- Each dispatched reviewer agent and its model.
- Validation-gate agent model, if validation gate ran.

Example `models.json`:

```json
[
  {"role": "coordinator", "id": "claude-opus-4-8"},
  {"role": "divisor-adversary-code", "id": "claude-sonnet-5"},
  {"role": "divisor-guard-code", "id": "claude-sonnet-5"},
  {"role": "validator", "id": "claude-opus-4-8"}
]
```

Host exposes no model IDs: record tier or human-readable names you
know (e.g., `{"role": "divisor-adversary-code", "id": "Capable tier"}`).
Nothing known: do not create the file — renderer states models not
recorded. Do NOT invent model IDs. Renderers dedupe entries
defensively, so repeated entries across dispatch rounds are safe.

---

## Narrative Synthesis

**Effort gate — quick mode:** If effort is `quick`, skip narrative
synthesis entirely. Compact report consists of:
1. Council verdict and its TL;DR, which the renderer puts first
2. Findings list from rendered template (sorted by severity)

Still splice `<!-- TLDR -->` — the marker is not droppable, and step 4 below
gives the fallback line to use whenever `comment-summary.md` is absent or
empty, which it always is here. Then skip to Final Verdict Determination
section.

Template rendering is performed by `rc-render-report.sh`, which owns all
structure (tables, counts, findings list, verdict) and leaves a
`<!-- NARRATIVE -->` marker line for this step to fill. The model's role here
is prose only — it never touches structure.

1. **Capture the rendered template.** Run `rc-render-report.sh` and save its
   stdout to `${session_dir}/report.md`.

2. **Dispatch a prose subagent** with **only** `${session_dir}/verdicts/findings.json`
   as input — no report template, no other session files. It returns two
   plain-text blobs and nothing else:

   - A one-line TL;DR (plain-language, under 25 words) — write to
     `${session_dir}/comment-summary.md`. This is the same one-liner that
     fills `<!-- TLDR -->` in the report (step 4 below) and that
     `rc-render-comment.sh` reads for the PR comment. Write it once, splice
     it twice; the two artifacts then cannot summarise the review differently.
   - A 2-4 paragraph narrative — write to `${session_dir}/narrative.md`.

   The narrative should cover:
   - What the review discovered (high-level patterns, themes)
   - What was verified vs. what was stripped
   - Key findings that remain (by severity and persona)
   - Deduplication and validation outcomes
   - Overall quality assessment

   The subagent MUST NOT emit tables, headings, finding lists, or any other
   markdown structure — structure is owned by the render scripts, and the
   subagent has no access to the report template. If it returns anything
   beyond the two blobs, discard the extra and keep only the prose.

3. **Splice deterministically.** `rc-render-report.sh` streams to stdout and
   performs no stateful file edits, so filling the marker is not the model
   free-forming the report — it is a plain string substitution the
   orchestrator performs after capturing the script's output. Replace the
   single `<!-- NARRATIVE -->` line in `${session_dir}/report.md` with the
   verbatim contents of `${session_dir}/narrative.md`.

4. **Splice the TL;DR.** Replace the single `<!-- TLDR -->` line in
   `${session_dir}/report.md` with the verbatim contents of
   `${session_dir}/comment-summary.md`. It sits directly under
   `## Council Verdict` at the top of the report, so the maintainer has the
   outcome and a plain-language summary of it before any table. Do not reword
   it for the report — the PR comment renders the same file.

   **Fallback — whenever `${session_dir}/comment-summary.md` is absent or
   empty**, replace the marker with the literal line
   `Automated review complete.`, the same fallback `rc-render-comment.sh`
   uses when the file is missing. This is not a `quick`-mode special case.
   The file is missing in `quick` mode because the subagent is never
   dispatched, and it can be missing in any mode because a dispatched
   subagent failed, was interrupted, or returned prose without writing it.
   The marker is never deleted instead: unlike every other marker it is not
   conditional on a phase having run, so an empty source is a fallback, not a
   reason to drop the section.

---

## Learnings Extraction

**Effort gate — quick mode:** If effort is `quick`, skip learnings
extraction entirely.

If knowledge layer tool is configured (see "Review Council Configuration" — "Knowledge tool"):

a. **False positive patterns** — record stripped findings (from Step 3) and validator retractions (from Step 4). Include agent name, fabricated claim, why stripped or retracted, and validator reasoning where applicable. For findings corrected in Step 1 but retracted in Step 4, also record as **correction failure** (agent doubled down).

b. **Positive patterns** — record validated findings that led to accepted fixes. Include file, issue, and fix applied.

c. **Evidence quality patterns** — record correction round outcomes (findings where agent's evidence was wrong but finding was real) and validator corrections (findings with inaccurate line numbers, wrong identifiers, or miscalibrated severity).

Store all learnings via configured knowledge tool so future Prior Learnings queries surface them.

If no knowledge layer is configured, write learnings to `${session_dir}/learnings.txt` as human-readable record. Available to future runs via Prior Run Awareness.

### Splicing the LEARNINGS Marker

Mirror the NARRATIVE splice (see "Narrative Synthesis" above): replace the
single `<!-- LEARNINGS -->` line in `${session_dir}/report.md` with the
same learnings summary just recorded — the verbatim contents of
`${session_dir}/learnings.txt`, or a short summary of what was stored when
a knowledge tool is configured instead. A plain string substitution
performed by the orchestrator, not the model free-forming the report.

**Effort gate — quick mode:** Learnings extraction is skipped, so there is
nothing to summarize. Replace the marker with the literal line
`None recorded.` instead. The rendered report must never contain a raw
`<!-- LEARNINGS -->` HTML comment.

---

## Subsystem Analysis (Deep Mode Only)

Fills `<!-- SUBSYSTEM-ANALYSIS -->`, which the renderer leaves immediately
before `## Findings by Severity`.

**Unless effort is `deep` and `${session_dir}/subsystems.json` exists**,
delete the marker line and its trailing blank line, then move on — deep mode
is the only mode that produces a subsystem map.

Otherwise read `${session_dir}/subsystems.json` and verified findings, and
replace the marker with the subsystem tree:

```
## Subsystem Analysis

{subsystem-name} ({severity counts})
  {file1}
  {file2}

{subsystem-name} ({severity counts})
  {file1}
  {file2}          <- also in: {other-subsystem}
```

**Rendering rules:**
- Subsystem name on header line with severity counts in parentheses
  (e.g., `auth-middleware (1 CRITICAL, 2 HIGH)`).
- Files indented with 2-space indent.
- Cross-cutting files (appearing in multiple subsystems) get
  `<- also in: {other-subsystem-names}` annotation.
- Subsystems with zero findings show `(clean)` instead of counts.
- Finding counts come from verified findings, not raw agent output.
- Sort subsystems by highest severity first: subsystems with CRITICAL
  findings first, then HIGH, etc.

---

## Merge Advisories (if applicable)

Fills `<!-- MERGE-ADVISORIES -->`.

**If verification produced no merge-base advisories**, delete the marker line
and its trailing blank line.

Otherwise replace it with the advisory list. Format:

```
## Merge Advisories

These are not defects in the branch. They are
operational risks from base-branch divergence that
the maintainer should address before merging.

**1. {Advisory title}**
- **File**: `{path}`
- **Risk**: {what will happen on merge}
- **Mitigation**: {recommended action, e.g., rebase}
```

Separated from findings so they don't inflate finding count
or affect council verdict, while still reaching maintainer.

---

## Acceptance Criteria Coverage

Fills `<!-- ACCEPTANCE-CRITERIA -->`.

**When to include:** Only when `${session_dir}/linked-issues.txt` exists AND at least one linked issue has acceptance criteria. Otherwise delete the marker line and its trailing blank line — an empty heading claims a coverage check that never happened.

For each linked issue with acceptance criteria, produce coverage assessment:

1. For each criterion, scan diff (`${session_dir}/diff.patch`) and verified findings for evidence of implementation:

   - **COVERED**: diff contains code that clearly implements criterion (matching function names, route paths, test names, or variable names corresponding to criterion)
   - **PARTIALLY COVERED**: some aspects addressed but gaps remain (annotate what is missing)
   - **NOT COVERED**: no evidence of implementation in diff

2. Replace the marker with this checklist, grouped by issue:

   ```
   ## Acceptance Criteria Coverage

   ### From Issue #38: "Add user authentication"

   - [x] COVERED: Users can log in with email/password
   - [~] PARTIALLY COVERED: Session timeout is configurable
     (default set in config, no UI for changing it)
   - [ ] NOT COVERED: Password reset flow

   ### From Issue #41: "Fix logout redirect"

   (No acceptance criteria found in issue)
   ```

3. Issues with no acceptance criteria listed with "(No acceptance criteria found in issue)" — do not omit them, listing confirms they were checked. That applies within the section; when *no* linked issue has criteria there is nothing to confirm, so the marker is deleted per "When to include" above.

---

## Disposition Outcomes (Re-Review Only)

Fills `<!-- DISPOSITION-OUTCOMES -->` — all three subsections below go into
that one marker, in the order given.

**When to include:** Only when the Disposition phase ran — check
`${session_dir}/verdicts/_meta/disposition.txt` exists and its `Result:` line
reads `ran`, not `skipped`. A first-time review never reaches Disposition
(no `pr-conversation.txt` to act on — see `disposition.md` Step 1), so on a
first-time report the marker line and its trailing blank line are deleted.
The same applies when Disposition ran but all three subsections come back
empty.

All three subsections below read `findings.json`'s `provenance.disposition`
field, written by `disposition.md` Step 3. Query the array the action
actually lands in — `disposition.md` Step 4 moves both `resolved` and
`suppressed-low` findings out of `verified` into `stripped` (distinct
top-level `reason`s: `DISPOSITION_RESOLVED` vs.
`DISPOSITION_SUPPRESSED_LOW`); only `kept` findings stay in `verified`.
These are orchestrator-rendered from that structured field, the same way
Merge Advisories and Acceptance Criteria Coverage are — substituted into the
marker the renderer already emits, which sits between `## Per-Agent Verdicts`
and `## Council Synthesis`. That is the findings-context slot: the maintainer
reads what the disposition round did to the finding set before reading the
synthesis prose that interprets it.

### Resolved Since Last Review

**Skip if empty (no empty heading).** Query:
`findings.json.stripped[] | select(.provenance.disposition.action == "resolved")`
— `disposition.md` Step 4 moves these out of `verified` with
`status: "stripped"`, `reason: "DISPOSITION_RESOLVED"`, so they no longer
appear in Findings by Severity above; this section is the only place they
still surface. Frame it as independently confirmed, not taken on faith —
the maintainer claimed the fix, and the council checked the source itself:

```
## Resolved Since Last Review

**1. {.title // .description[0:60]}** (`{file}:{line}`, {agent})
- **Maintainer said**: "{provenance.disposition.claim}"
- **Council confirmed**: {provenance.disposition.evidence}
```

### Claimed Fixed But Still Present

**Skip if empty (no empty heading).** Query:
`findings.json.verified[] | select(.provenance.disposition.action == "kept" and .provenance.disposition.claim_verified == false)`
— this is the safety-relevant output of Disposition: the maintainer said a
finding was fixed, and the council's own re-check of the source shows it
isn't. These entries are still in `verified` at their original severity —
per `disposition.md` Step 4, "a `kept` finding is, by definition, still
present and still verified" — so they still count toward the council
verdict exactly as shown in Findings by Severity above. This section adds
the disposition context on top of that entry; it never softens it:

```
## Claimed Fixed But Still Present

**1. {.title // .description[0:60]}** (`{file}:{line}`, {agent}) — still counts, still blocks
- **Maintainer said**: "{provenance.disposition.claim}"
- **Still present**: {provenance.disposition.note}
```

### Suppressed LOWs

**Skip if empty.** Query:
`findings.json.stripped[] | select(.provenance.disposition.action == "suppressed-low")`
— `disposition.md` Step 4 moves these out of `verified` the same way
`resolved` findings are, with `status: "stripped"` and
`reason: "DISPOSITION_SUPPRESSED_LOW"`, so a suppressed LOW no longer
appears in Findings by Severity above and no longer counts toward any
agent's finding total (that's what makes rule 3's "not re-raising" actually
happen instead of just being noted). This note is the only place they
surface — one compact line so the suppression is visible rather than
silent:

```
{N} LOW-severity finding(s) not re-raised this round per scoping hint: "{reason}"
```

---

## Final Verdict Determination

Determine the council verdict:

- **APPROVE** — all discovered reviewers returned APPROVE (after verification).
- **REQUEST CHANGES** — one or more reviewers returned REQUEST CHANGES with verified findings.
- **APPROVE WITH ADVISORIES** (Spec Review Mode only) — only LOW/MEDIUM findings remain; no HIGH/CRITICAL findings present. Remaining findings are advisory and do not block merge.

Discovery summary included regardless of verdict. Absent reviewers (known roles not found during discovery) do not affect verdict.

**Recording it.** Write the verdict as the first line of
`${session_dir}/verdict.txt` **before** running `rc-render-report.sh` (SKILL.md
Step 6 states this as the first action of the phase). The renderer emits the
`## Council Verdict` section from that file — at the head of the report, ahead
of every table and the findings list — and `rc-render-comment.sh` reads the
same file for the PR comment; deciding the verdict is this step's job,
rendering it is not. Do not append a verdict section to `report.md` by hand:
the EXECUTION-CONTRACT limits this step to filling the markers the renderer
emits, the verdict is not one of them (see "How Sections Reach the Report"),
and a hand-written section would duplicate the rendered one.

A report whose Council Verdict section reads "not recorded" means this step did
not write `verdict.txt` before rendering. Fix the ordering and re-render rather
than editing the rendered report.

---

## CI Commentary

Fills `<!-- CI-COMMENTARY -->`.

The `## Forge CI Status` table is script-owned: `rc-prepare.sh` writes it to
`ci-status.txt` and `rc-render-report.sh` emits it near the top of the report,
stripping the `# UNTRUSTED` envelope on the way through. This marker is for
the one thing no script can derive — whether the CI state changes how the
findings below should be read:

```
## CI Commentary

Two checks are failing on the head commit (`test`, `lint`). Both touch
`auth.go`, the same file as the CRITICAL finding above, so the failures and
the finding are likely the same defect.
```

Delete the marker line and its trailing blank line when `ci-status.txt` does
not exist, when every check passed, or when the failures have no bearing on
the findings. Restating the table adds nothing the maintainer cannot already
see a few lines up.

---

## Update Tracking

Update `${session_dir}/tracking.md` Phase: Report with: council verdict, learnings recorded.
