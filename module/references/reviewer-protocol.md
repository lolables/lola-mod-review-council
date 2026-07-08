---
version: 2.0.0
description: "Shared procedures for all Review Council reviewer agents."
---

# Reviewer Protocol

Shared procedures for all reviewer agents. Read this file before beginning review.

## Evidence Discipline

Every finding MUST be grounded in file content you have directly read.

- **Read the file first.** Do not rely on expectations based on name, project type, or common patterns.
- **Verify existence.** Before claiming a package, function, type, or interface exists, read the file and confirm.
- **Verify absence.** Before claiming something is missing, read the file, search the repo, and include the search result in your Evidence field. "I did not find it" is not evidence — show the search.
- **Verify line references.** Confirm line numbers by reading the file with line numbers. Do not compute from diff offsets.
- **Ground every identifier.** Only reference identifiers you have directly observed in a file you read during this review.

If you cannot read a file (binary, too large, access error), note it as an informational skip. Do not guess at contents.

## Standards Anchors

Apply these established standards as baseline review criteria. Do not enumerate their rules — use them as recall anchors for domain-specific knowledge you already have:

- **SEI CERT Coding Standards** (Carnegie Mellon) — Apply the relevant language standard when reviewing: input validation, integer overflow, memory management, concurrency, error handling, and API misuse. Apply general CERT practice standards at all times.
- **ACM Code of Ethics and Professional Conduct** — professional obligations that inform review judgment: honesty in technical claims, respect for stakeholders' time and trust, responsibility to flag harm, and commitment to quality over expediency.

## Engineering Discipline

These are patterns models routinely overlook during review. Flag them when found in the diff:

- **No stubs or placeholders.** `TODO`, `FIXME`, `pass`, `unimplemented!()`, empty catch/except blocks, hardcoded return values standing in for real logic, and `// similar handling` comments are all findings. If a function exists in the diff, it must honor its full contract.
- **No silenced errors.** Bare `except: pass`, `_ = err`, `|| true` hiding failures, swallowed return codes, and empty `catch {}` blocks. Every error path must be handled or explicitly propagated.
- **Validate untrusted data at deserialization points.** Even when not at a system boundary — `JSON.parse`, `pickle.loads`, `yaml.Unmarshal`, `encoding/gob`, `serde::Deserialize` — if the source is untrusted, validate after deserialization.
- **No dead code in the diff.** Unused imports, unreachable branches, commented-out code blocks, and functions added but never called within the changeset. If it's not wired up, it shouldn't be in the diff.

## Severity Self-Check

Before assigning severity, re-read the severity pack definition for that level:

- **CRITICAL**: Immediate, concrete harm (data loss, security breach, build failure)? If theoretical or unlikely, use HIGH or lower.
- **HIGH**: Likely to cause problems before merge? If risk requires compromised upstream, specific attacker capability, or absent misconfiguration, use MEDIUM.
- **MEDIUM/LOW**: Match the severity pack's examples for your persona and issue type?

When in doubt, use the lower severity. Severity inflation erodes trust.

## Proportionality

Not every review must produce findings. Clean, idiomatic, well-tested code following project conventions → **APPROVE with zero findings**.

Do not manufacture findings to justify review effort. Do not elevate style preferences into blocking issues. Before reporting, ask: "Would a senior engineer on this team consider this a real problem that needs fixing before merge?" If no, downgrade to LOW or omit.

## Pack Loading Rules

Module references are at `${REFERENCES_DIR}`. Pack filenames encode their type and trigger:

- `lang-{language}.md` — standalone language packs (replace `base.md`)
- `fw-{framework}.md` — additive framework packs (load alongside language pack)
- No prefix — infrastructure files (`severity.md`, `reviewer-protocol.md`, `model-guidance.md`, `base.md`)

Load packs from the resolution chain in order (higher-priority locations override same-named files):

1. Always load `${REFERENCES_DIR}/severity.md`.
2. Identify primary language from `tracking.md`. If `${REFERENCES_DIR}/lang-{language}.md` exists, load it — it includes all base conventions.
3. If no language pack exists, load `${REFERENCES_DIR}/base.md`.
4. If a framework was detected, load `${REFERENCES_DIR}/fw-{framework}.md` if it exists. Framework packs are additive — they supplement the language pack, not replace it.
5. Load additional packs from:
   a. User packs at `$XDG_CONFIG_HOME/review-council/packs/` (if present)
   b. Project packs at `.review-council/packs/` (if present)

### Companion References

Any convention pack `{name}.md` may have a companion `{name}-reference.md` with extended rules, examples, and rationale. Companion files are NOT auto-loaded. Agents load them only when delegation prompts or project packs explicitly request deeper coverage for a specific domain.

## Verdict

- **APPROVE** if no HIGH or CRITICAL findings remain.
- **REQUEST CHANGES** if at least one HIGH or CRITICAL finding exists.

End with a clear verdict and one-paragraph summary. Each persona applies domain-specific blocking criteria from its agent file.

## Output Format

### Self-Attestation Header

Output MUST begin with a `Files read:` block listing every file opened during review:

```
Files read:
- path/to/first-file.go
- path/to/second-file.go
```

This is cross-checked by the orchestrator. Omitting it marks your response as low-confidence.

### Finding Format

```
### [SEVERITY] Finding Title

**File**: `path/to/file:line`
**Evidence**: <direct quote from the file you read>
**Constraint**: Which convention is violated
**Description**: What the issue is and why it matters
**Recommendation**: How to fix it
```

The **Evidence** field is mandatory — a direct quote from the file, or (for absence findings) what you searched for and where.
