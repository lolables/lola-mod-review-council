---
version: 2.1.0
description: "Shared procedures for all Review Council reviewer agents."
---

# Reviewer Protocol

Shared procedures for all reviewer agents. Read before beginning review.

## Evidence Discipline

Every finding MUST be grounded in file content you directly read.

- **Read file first.** Never rely on expectations from name, project type, or common patterns.
- **Verify existence.** Before claiming package, function, type, or interface exists, read file and confirm.
- **Verify absence.** Before claiming something missing, read the file and search the repo — "I did not find it" is not evidence. Record what you searched for and where in `description`, NOT in `evidence`: evidence is matched against the cited file as a contiguous byte sequence, so a search transcript can never verify and the finding is stripped. Anchor the finding to a verbatim quote of the thing whose counterpart is missing — the function that has no test, the table row where the missing column would sit, the config block that omits the key. When the absence is repo-level and has no local counterpart (no LICENSE anywhere, no CI configuration at all), anchor to the nearest file that *should* have referenced it — the README section listing project metadata, the Taskfile that would invoke the missing target — and quote that. There is always such a file, and anchoring to it keeps the finding inside what the pipeline can verify: `file` must exist or the finding is stripped as `FILE_NOT_FOUND`, and `evidence` must occur in it, so a finding with no anchor file cannot be reported at all.
- **Verify line references.** Confirm line numbers by reading file with line numbers. Never compute from diff offsets.
- **Ground every identifier.** Only reference identifiers directly observed in file you read during this review.

Cannot read file (binary, too large, access error) — note as informational skip. Never guess contents.

## Standards Anchors

Apply as baseline review criteria. Not enumeration of rules — recall anchors for domain-specific knowledge you already have:

- **SEI CERT Coding Standards** (Carnegie Mellon) — Apply relevant language standard: input validation, integer overflow, memory management, concurrency, error handling, API misuse. Apply general CERT practice standards always.
- **ACM Code of Ethics and Professional Conduct** — professional obligations informing review judgment: honesty in technical claims, respect for stakeholders' time and trust, responsibility to flag harm, commitment to quality over expediency.

## Engineering Discipline

Patterns models routinely overlook during review. Flag when found in diff:

- **No stubs or placeholders.** `TODO`, `FIXME`, `pass`, `unimplemented!()`, empty catch/except blocks, hardcoded return values standing in for real logic, `// similar handling` comments — all findings. Function exists in diff, must honor full contract.
- **No silenced errors.** Bare `except: pass`, `_ = err`, `|| true` hiding failures, swallowed return codes, empty `catch {}` blocks. Every error path must be handled or explicitly propagated.
- **Validate untrusted data at deserialization points.** Even outside system boundary — `JSON.parse`, `pickle.loads`, `yaml.Unmarshal`, `encoding/gob`, `serde::Deserialize` — untrusted source means validate after deserialization.
- **No dead code in diff.** Unused imports, unreachable branches, commented-out code blocks, functions added but never called within changeset. Not wired up, should not be in diff.

## Severity Self-Check

Before assigning severity, re-read severity pack definition for that level:

- **CRITICAL**: Immediate, concrete harm (data loss, security breach, build failure)? Theoretical or unlikely — use HIGH or lower.
- **HIGH**: Likely causes problems before merge? Risk requires compromised upstream, specific attacker capability, or absent misconfiguration — use MEDIUM.
- **MEDIUM/LOW**: Match severity pack's examples for your persona and issue type?

When in doubt, use lower severity. Severity inflation erodes trust.

## Proportionality

Not every review must produce findings. Clean, idiomatic, well-tested code following project conventions — **APPROVE with zero findings**.

Never manufacture findings to justify review effort. Never elevate style preferences into blocking issues. Before reporting, ask: "Would senior engineer on this team consider this real problem needing fix before merge?" If no, downgrade to LOW or omit.

## Pack Loading Rules

Module references at `${REFERENCES_DIR}`. Pack filenames encode type and trigger:

- `lang-{language}.md` — standalone language packs (replace `base.md`)
- `fw-{framework}.md` — additive framework packs (load alongside language pack)
- No prefix — infrastructure files (`severity.md`, `reviewer-protocol.md`, `model-guidance.md`, `base.md`)

Load packs from resolution chain in order (higher-priority locations override same-named files):

1. Always load `${REFERENCES_DIR}/severity.md`.
2. Identify primary language from `tracking.md`. If `${REFERENCES_DIR}/lang-{language}.md` exists, load it — includes all base conventions.
3. No language pack exists — load `${REFERENCES_DIR}/base.md`.
4. Framework detected — load `${REFERENCES_DIR}/fw-{framework}.md` if exists. Framework packs additive — supplement language pack, not replace.
5. Load additional packs from:
   a. User packs at `$XDG_CONFIG_HOME/review-council/packs/` (if present)
   b. Project packs at `.review-council/packs/` (if present)

### Companion References

Convention pack `{name}.md` may have companion `{name}-reference.md` with extended rules, examples, rationale. Companion files NOT auto-loaded. Agents load only when delegation prompts or project packs explicitly request deeper coverage for specific domain.

## Verdict

- **APPROVE** if no HIGH or CRITICAL findings remain.
- **REQUEST CHANGES** if at least one HIGH or CRITICAL finding exists.

End with clear verdict and one-paragraph summary. Each persona applies domain-specific blocking criteria from its agent file.

## Output Format

Your entire response MUST be a single fenced ```json code block and nothing
else — no prose before or after it. The orchestrator extracts this block and
validates it against `${REFERENCES_DIR}/verdict-schema.json`. A response the
validator rejects is re-dispatched once; do not add commentary outside the block.

```json
{
  "agent": "divisor-adversary-code",
  "files_read": ["path/to/first.go", "path/to/second.go"],
  "verdict": "REQUEST CHANGES",
  "findings": [
    {
      "severity": "MEDIUM",
      "file": "path/to/file.go",
      "line": 42,
      "evidence": "<direct quote from the file you read>",
      "constraint": "Which convention is violated",
      "description": "What the issue is and why it matters",
      "recommendation": "How to fix it"
    }
  ]
}
```

- `files_read` MUST list every file you opened (replaces the prose attestation).
- `verdict` MUST be `APPROVE` or `REQUEST CHANGES` — see "## Verdict" above.
  `APPROVE WITH ADVISORIES` is a council-level aggregate the orchestrator
  derives from multiple reviewer verdicts (see `report.md`); no individual
  reviewer emits it.
- `findings` MAY be empty for a clean APPROVE. Do not manufacture findings.
- Each finding's `file` is a repo-relative path; `line` is the confirmed line
  (integer) or `null` when no single line applies. Put ranges and
  cross-references in `description`, never in `file`.
- `evidence` MUST be a byte-for-byte contiguous quote copied out of the file
  named in `file`. The verifier searches the file for it as a single block, so
  anything not literally present there fails: no `...` elisions joining two
  passages, no `path/to/file.md:12-18 —` location prefix, no reflowed
  whitespace, no paraphrase. Quote a shorter span rather than a stitched one.
  Use normal JSON string escaping for control characters (a literal tab is
  `\t`); do not double-escape them as `\\t`. For an absence finding, quote the
  present code whose counterpart is missing and put the search you ran in
  `description` — for a repo-level absence with no local counterpart, quote
  the nearest file that should have referenced it (see "Verify absence" above).

A clean review returns an empty `findings` array — do not manufacture findings:

```json
{
  "agent": "divisor-guard-code",
  "files_read": ["stringset.go", "stringset_test.go"],
  "verdict": "APPROVE",
  "findings": []
}
```
