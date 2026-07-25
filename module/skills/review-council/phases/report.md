# Phase: Report — LLM Judgment Reference

Guides orchestrator's narrative synthesis, learnings extraction, final verdict determination.

---

## Pre-condition Gate

**Before generating any report content**, verify Verification phase actually executed:

1. Read `${session_dir}/verdicts/verification.txt`.

2. **If file does not exist or is empty**: STOP. Do not generate report. Return to Verification phase and execute it. Display:
   > "verification.txt is missing — the Verification phase was not executed. Returning to Phase 4."

3. **If file exists but has no `=== SUMMARY ===` section**: STOP. Verification was incomplete. Return to Verification phase to finish it.

4. **If SUMMARY section contains only placeholder values** (e.g., `{N}` instead of actual numbers): STOP. Verification was templated, not executed. Return to Verification phase.

5. **If verification.txt shows zero tool calls were made** (no file reads, no greps, no evidence checks recorded in EVIDENCE VERIFICATION section): verification was performed mentally, not mechanically. Return to Verification phase and re-execute with actual tool calls.

Only proceed to generate report once verification.txt passes all five checks above.

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
1. Findings list from rendered template (sorted by severity)
2. Final verdict

Skip to Final Verdict Determination section.

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
     `${session_dir}/comment-summary.md`.
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

**Skip this section unless effort is `deep` and
`${session_dir}/subsystems.json` exists.**

Read `${session_dir}/subsystems.json` and verified findings.
Render subsystem tree before findings list:

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

**Skip if no merge-base advisories produced during
verification.**

List merge-base advisories after Subsystem Analysis, before
Verified Findings. Format:

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

**When to include:** Only when `${session_dir}/linked-issues.txt` exists AND at least one linked issue has acceptance criteria. If no linked issues have acceptance criteria, omit this section entirely (no empty heading).

For each linked issue with acceptance criteria, produce coverage assessment:

1. For each criterion, scan diff (`${session_dir}/diff.patch`) and verified findings for evidence of implementation:

   - **COVERED**: diff contains code that clearly implements criterion (matching function names, route paths, test names, or variable names corresponding to criterion)
   - **PARTIALLY COVERED**: some aspects addressed but gaps remain (annotate what is missing)
   - **NOT COVERED**: no evidence of implementation in diff

2. Present as checklist grouped by issue:

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

3. Issues with no acceptance criteria listed with "(No acceptance criteria found in issue)" — do not omit them, listing confirms they were checked.

If report includes linked issues with acceptance criteria, add coverage checklist after acceptance criteria section. If no criteria exist, note that none were found.

---

## Disposition Outcomes (Re-Review Only)

**When to include:** Only when the Disposition phase ran — check
`${session_dir}/verdicts/disposition.txt` exists and its `Result:` line
reads `ran`, not `skipped`. A first-time review never reaches Disposition
(no `pr-conversation.txt` to act on — see `disposition.md` Step 1), so this
whole section is absent from a first-time report.

All three subsections below read `findings.json`'s `provenance.disposition`
field, written by `disposition.md` Step 3. Query the array the action
actually lands in — `disposition.md` Step 4 moves both `resolved` and
`suppressed-low` findings out of `verified` into `stripped` (distinct
top-level `reason`s: `DISPOSITION_RESOLVED` vs.
`DISPOSITION_SUPPRESSED_LOW`); only `kept` findings stay in `verified`.
These are orchestrator-rendered from that structured field, the same way
Merge Advisories and Acceptance Criteria Coverage are — no
`rc-render-report.sh` change required.

Render all three after `## Findings by Severity` / `## Per-Agent Verdicts`,
before `## Council Synthesis` — the findings-context slot, same idea as
Merge Advisories ahead of the findings list.

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

End report with council verdict:

- **APPROVE** — all discovered reviewers returned APPROVE (after verification).
- **REQUEST CHANGES** — one or more reviewers returned REQUEST CHANGES with verified findings.
- **APPROVE WITH ADVISORIES** (Spec Review Mode only) — only LOW/MEDIUM findings remain; no HIGH/CRITICAL findings present. Remaining findings are advisory and do not block merge.

Discovery summary included regardless of verdict. Absent reviewers (known roles not found during discovery) do not affect verdict.

---

## Forge CI Status Section

**When forge CI status is available** (`${session_dir}/ci-status.txt` exists), add forge CI section to report:

```
## Forge CI Status

| Check | Status |
|-------|--------|
| build | pass   |
| test  | fail   |
| lint  | fail   |

Failing checks:
- test: FAILURE (see forge CI tab for details)
- lint: FAILURE (see forge CI tab for details)
```

Include full results table from `ci-status.txt`. Add this section after Session Information in report.

---

## Update Tracking

Update `${session_dir}/tracking.md` Phase: Report with: council verdict, learnings recorded.
