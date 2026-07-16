---
version: 2.0.0
description: "Shared procedures for all Review Council reviewer agents."
---

# Reviewer Protocol

Shared procedures for all reviewer agents. Read before beginning review.

## Evidence Discipline

Every finding MUST be grounded in file content you directly read.

- **Read file first.** Never rely on expectations from name, project type, or common patterns.
- **Verify existence.** Before claiming package, function, type, or interface exists, read file and confirm.
- **Verify absence.** Before claiming something missing, read file, search repo, include search result in Evidence field. "I did not find it" not evidence — show search.
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

### Self-Attestation Header

Output MUST begin with `Files read:` block listing every file opened during review:

```
Files read:
- path/to/first-file.go
- path/to/second-file.go
```

Cross-checked by orchestrator. Omitting marks response as low-confidence.

### Finding Format

```
### [SEVERITY] Finding Title

**File**: `path/to/file:line`
**Evidence**: <direct quote from the file you read>
**Constraint**: Which convention is violated
**Description**: What the issue is and why it matters
**Recommendation**: How to fix it
```

**Evidence** field mandatory — direct quote from file, or (for absence findings) what you searched for and where.
