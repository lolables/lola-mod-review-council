# Render Bleed & the JSON-Native Harness Rework

> Date: 2026-07-21
> Trigger: `/review-council` runs against `voxpupuli/openvox-ca` PRs, 2026-07-18..21
> Reporter: user (submitter account `trevor-vaughan-ai`)
> Companion bug list: [`../../RC_BUGS.md`](../../RC_BUGS.md)

## Summary

Running the council across a batch of real PRs surfaced two classes of
defect in the *output*, not the review judgment:

1. **The per-agent table can misrepresent the findings** — an agent's real
   `REQUEST CHANGES` can render as `APPROVE | 0`.
2. **Output-format bleed** — reviewer scaffolding, escape sequences, and
   internal pipeline notes leak into the posted PR comment.

Root cause for both is a single architectural decision: the pipeline is
**free-text → bash-regex parse → JSON → awk re-parse → markdown**. Reviewer
agents emit semi-structured markdown; two separate layers of shell regex
reverse-engineer findings back out of that prose. Every place the prose can
drift out of the assumed grammar is a place a finding is dropped or mangled.

Decision (owner-approved): **retire the free-text contract**. Reviewers emit a
single fenced ```json verdict block; a JSON schema is the contract; scripts own
all structure deterministically; a prose subagent contributes only narrative
text spliced into fixed slots. See "Approved design direction" below.

## Evidence: what actually shipped to PRs

Seven council comments were audited (PRs 124, 119, 118, 115, 114, 89×2 on
`voxpupuli/openvox-ca`). Findings:

- **Class (a) table-vs-findings mismatch: not observed in the wild.** The only
  comment carrying a per-reviewer verdict table (PR 89, `5026142358`)
  reconciled exactly (2 HIGH / 18 MED / 20 LOW; Tester = Changes drives the
  verdict). The class-(a) bug is real *in code* (see RC_BUGS #2) but manifests
  in quick mode; it did not surface in these standard-mode comments.
- **Class (b) format bleed: widespread.** Dominant patterns below.

### Wild defect → code root cause

The posted PR comment is rendered by `rc-render-comment.sh`
(`rc_render_comment_body`), which reads the base64 `detail` blob stored by the
regex parser in `rc-verify-evidence.sh` and **re-parses it** with a second pile
of awk (`reflow_fields`, `bulletize_cd`, `rec_bulletize`, the Recommendation
splitter around line 258). The bleed lives in this second layer.

| Wild defect (PRs) | Root cause |
|---|---|
| `\t` / `\\` literals inside evidence quotes (PR 114, 89-current) | `jq … \| @tsv` (rc-render-comment.sh:280) escapes embedded tabs/backslashes for TSV framing; `IFS=$'\t' read` splits on real tabs but never un-escapes the literals inside a field |
| `APPROVE` + agent summary prose leaking into per-finding recommendation slots (PR 115) | free-text `detail` boundary capture in rc-verify-evidence.sh swept the trailing verdict + summary into the finding body; the awk re-split cannot cleanly separate it |
| `<!-- severity calibrated HIGH → MEDIUM … -->` and dedup notes in the published body (PR 114) | verification-phase calibration/dedup notes injected as inline HTML comments into prose, then rendered verbatim |
| Model tier split into standalone bullets — `> - claude-opus-4-8` / `> - Capable tier` (PR 115) | `models.txt` is free-format one-value-per-line; orchestrator wrote the tier on its own line (contrast PR 118, correct) |
| Severity bucket says MEDIUM but the finding text says "which is why it is LOW" (PR 114) | severity is stored twice (bucket + agent prose); a downgrade updated the bucket only |
| Mangled evidence/analysis pair, stray empty `- ` bullets (PR 115, 89) | one-line evidence slot fed reviewer prose instead of a code excerpt; awk field detection misfired |

**Key takeaway:** the entire right-hand column is transport and
re-segmentation damage. None of it is a model-judgment error. A structured
contract with field-addressed rendering removes the failure surface rather than
hardening the parser against it.

### Where the class-(a) table bug lives (RC_BUGS #2)

`rc-render-report.sh` derives the two table columns from two sources that can
disagree:

- **Verdict** — `grep -qE '^\*\*Verdict\*\*:.*REQUEST CHANGES|^(REQUEST CHANGES)$'`
  (line 163). A `Verdict: REQUEST CHANGES` line without bold markdown matches
  neither branch → silently defaults to `APPROVE`.
- **Finding count** — only `evidence-check.json .verified[]` filtered by agent
  (line 170). Any finding classed `correctable` (line off by >5, or evidence
  not an exact substring) is excluded → `0`.

In quick mode there is no correction round, so `correctable` findings are never
promoted and never shown. An agent's real `REQUEST CHANGES` with two findings
can render `APPROVE | 0` with no indication anything was dropped — the unsafe
default for a review gate.

## Approved design direction (JSON-native harness)

Three forks were decided with the owner:

1. **Scope:** full JSON-native rework (retire the regex field-parser; jq is the
   only extraction; one canonical findings model is the single source of truth
   for verdict *and* count).
2. **Render ownership:** script owns all structure; a prose subagent receives
   only the structured JSON and returns only prose blobs (TL;DR, narrative),
   which the script splices into fixed slots. Matches the repo's stated
   "Deterministic rendering" principle (CLAUDE.md).
3. **Emit mechanism:** each reviewer's output is a single fenced ```json verdict
   block, extracted by the orchestrator and validated against a JSON schema.
   Host-neutral — no reliance on any host's native structured-output API.

### Target data flow

```
reviewer agent  ──►  ```json {attestation, verdict, findings[…]}```
                          │  (fenced-block extraction + schema validation)
                          ▼
                  verdicts/<agent>.json          ← canonical, per agent
                          │  (jq: file-exists + evidence-substring + line±5)
                          ▼
                  findings.json                  ← single source of truth
                     (verdict, severity, file, line, evidence,
                      constraint, description, recommendation,
                      provenance: {calibrated_from, dedup_of, validator})
                          │
          ┌───────────────┴───────────────┐
          ▼ (jq -r field access)          ▼ (JSON only)
   rc-render-comment.sh            prose subagent → TL;DR + narrative
   (all structure: table,                  │
    counts, findings, verdict)             ▼
          └──────────► fixed slots spliced in ◄──────┘
```

### What this removes

- The `### [SEVERITY]` / `**File**:` / `**Evidence**:` regex field-parser in
  `rc-verify-evidence.sh`.
- The `@tsv` transport and the awk re-segmentation in `rc-render-comment.sh`
  (`reflow_fields`, `bulletize_cd`, `rec_bulletize`, Recommendation splitter).
- Free-format `models.txt`; replaced by a structured, single-render record.
- Inline HTML-comment calibration notes; calibration becomes a `severity` field
  update plus a `provenance` note, never prose injection.

### Orthogonal bugs to fold in (grounded, cheap)

Not caused by the parse pipeline, but confirmed in the same run:

- **RC_BUGS #1** — `REFERENCES_DIR` resolved from `MODULE_DIR` breaks on a split
  install (agents under `~/.claude/agents`, references under
  `~/.claude/skills/review-council/`). Resolve references relative to
  `SKILL_DIR`, or resolve each root independently.
- **RC_BUGS #3** — `rc-prepare.sh` in a non-git directory reports "Please specify
  the review mode explicitly" when the mode *was* specified; the real blocker is
  the missing repo. Separate the two checks.

## Open items for the spec

- JSON schema definition (required vs optional fields; verdict enum;
  severity enum) and the validation gate that replaces the current
  `format_error` short-circuit.
- Migration of the reviewer agent files and `reviewer-protocol.md` "Output
  Format" section to the JSON contract.
- Deep-mode aggregation across `verdicts/<subsystem>/<agent>.json`.
- Test coverage: schema-invalid input, escape-heavy evidence (the `\t` case),
  calibration/dedup provenance, and a table-reconciliation regression guard.
