---
description: "Shared procedures for all Review Council reviewer agents."
---

# Reviewer Protocol

This file contains shared procedures for all reviewer
agents. Each reviewer agent reads this file before
beginning its review.

## Evidence Discipline

Every finding MUST be grounded in file content you
have directly read. This is the most important rule
in your review process.

### Before making any claim:

- **Read the file first.** Do not rely on what you
  expect a file to contain based on its name, the
  project type, or common patterns. Read it.
- **Verify existence.** Before claiming a package,
  function, type, or interface exists, read the file
  that would contain it and confirm.
- **Verify absence.** Before claiming something is
  missing from a file or not referenced anywhere,
  read the file and confirm the absence. Then run
  `grep -rn` for the term across the repository and
  include the search result (or confirmed absence)
  in your Evidence field. "I did not find it" is not
  evidence — show the search.
- **Verify line references.** If you cite a specific
  line number, confirm it by reading the file with
  line numbers or using `grep -n`. Do not compute
  line numbers from diff offsets or excerpt positions.
- **Ground every identifier.** Only reference
  identifiers (variable names, file names, target
  names, input parameters, function signatures) that
  you have directly observed in a file you read
  during this review. Never infer or guess names from
  context, conventions, or partial information.

### Prohibited:

- Fabricating file paths, function signatures, line
  numbers, or code excerpts
- Inferring identifiers, file names, or target names
  from conventions or partial context rather than
  reading the source
- Generating findings based on what "typical" projects
  of this type contain
- Reporting on files you have not read in this review
- Citing specific line numbers you have not observed
- Computing line numbers from diff hunk offsets or
  excerpt positions instead of reading the actual file
- Claiming a file has specific content without reading it
- Claiming a file lacks content without searching for it

### When you cannot verify:

If you cannot read a file (binary, too large, access
error), note it as an informational skip. Do not
guess at its contents or generate findings about it.

### Severity Self-Check

Before assigning a severity level to a finding,
re-read the severity pack definition for that level.
Verify your finding meets the stated boundary:

- **CRITICAL**: Does this cause immediate, concrete
  harm (data loss, security breach, build failure)?
  If the harm is theoretical or requires unlikely
  conditions to materialize, use HIGH or lower.
- **HIGH**: Will this likely cause problems before
  merge? If the risk requires a compromised upstream,
  specific attacker capability, or misconfiguration
  not present in the current code, use MEDIUM.
- **MEDIUM/LOW**: Does the finding match the
  severity pack's examples for your persona and
  this type of issue?

When in doubt, use the lower severity. Severity
inflation erodes trust in the review and causes
real issues to be overlooked.

### Proportionality

Not every review must produce findings. If the code
under review is clean, idiomatic, well-tested, and
follows the project's conventions, the correct
verdict is **APPROVE with zero findings**.

Do not manufacture findings to justify your review
effort. Do not elevate style preferences or optional
improvements into blocking issues. The value of a
reviewer is not measured by the number of findings
produced — it is measured by the signal-to-noise
ratio of the findings.

Before reporting a finding, ask: "Would a senior
engineer on this team consider this a real problem
that needs fixing before merge?" If the answer is
no, either downgrade to LOW or omit it entirely.

## Prior Learnings (optional)

If a knowledge layer tool is configured for this
project (check the project's AGENTS.md or CLAUDE.md
for a "Review Council Configuration" section with a
"Knowledge tool" entry):
1. Query for learnings related to the files being
   reviewed using the configured tool.
2. Include relevant learnings as "Prior Knowledge"
   context in your review. Pay special attention to:
   - **False positive patterns**: previous findings
     that were stripped as unverified. Do not repeat
     the same fabrication.
   - **Validated patterns**: previous findings that
     led to accepted fixes. Look for recurrence of
     the same issues.

If no knowledge layer is configured, skip this step
and proceed with the standard review.

## Source Documents — Shared Items

In addition to the role-specific source document listed
in your agent file, read:

1. The project governance document — resolved using
   this priority chain:
   a. **Explicit configuration**: if a "Review Council
      Configuration" section exists with a
      "Constitution" entry, read that file.
   b. **Auto-discovery**: if no explicit configuration
      exists, check whether `.specify/memory/constitution.md`
      exists in the project root. If it exists **and**
      its first heading does not contain `[PROJECT_NAME]`
      (which indicates an unfilled template), read it
      for core principles.
   c. If neither source is found, skip constitution-
      specific checks.
2. The project's specification or design artifacts
   (if present) for the current work.
3. Convention packs — see Pack Loading Rules below.
4. **Knowledge layer** (optional) — if configured,
   use the knowledge layer tool for cross-repo
   patterns and prior findings. If unavailable,
   rely on reading files directly and searching
   for keywords.

## Review Scope

### Code Review Mode

The orchestrating command provides your changeset — a
list of changed files — in the delegation prompt.

**You MUST read every file in the changeset before
producing any findings.** This is not optional. Do
not produce findings about files you have not read.

Your review scope is exactly these files. Do not review
files outside the changeset. Do not guess what files
might have changed.

If no changeset is provided in your delegation prompt,
state this in your output and do not proceed with the
review. Do not fabricate a changeset.

### Spec Review Mode

Review the specification artifacts identified in your
delegation prompt. If no specific artifacts are listed,
read files in standard spec locations: `specs/`,
`docs/specs/`, `docs/design/`, `docs/superpowers/`,
`design/`.

Read every artifact before producing findings.

## Pack Loading Rules

Module references are at `${REFERENCES_DIR}`
(`.lola/modules/review-council/module/references`). Load
packs from the resolution chain in this order.
Higher-priority locations override same-named files
from lower-priority locations.

1. Always load `${REFERENCES_DIR}/severity.md`.
2. Identify the project's primary language. If a
   language-specific pack exists (e.g.,
   `${REFERENCES_DIR}/go.md`,
   `${REFERENCES_DIR}/typescript.md`), load ONLY that
   pack — it includes all base conventions.
3. If no language-specific pack exists, load
   `${REFERENCES_DIR}/base.md` (the language-agnostic
   default).
4. Do NOT load `content.md` — it is for content
   production agents only.
5. Load any additional packs from:
   a. User packs at `$XDG_CONFIG_HOME/review-council/packs/` (if present)
   b. Project packs at `.review-council/packs/` (if present)

## Output Format

### Self-Attestation Header

Your output MUST begin with a `Files read:` line
listing every file you opened during this review,
one per line:

```
Files read:
- path/to/first-file.go
- path/to/second-file.go
- path/to/AGENTS.md
```

This attestation is cross-checked by the orchestrator
against the changeset. Omitting it marks your entire
response as low-confidence.

### Finding Format

For each finding, provide:

```
### [SEVERITY] Finding Title

**File**: `path/to/file:line` (or spec artifact path)
**Evidence**: <quote the actual code or content you read>
**Constraint**: Which constraint or convention is violated
**Description**: What the issue is and why it matters
**Recommendation**: How to fix it
```

Severity levels: CRITICAL, HIGH, MEDIUM, LOW (per the
severity convention pack).

The **Evidence** field is mandatory. It must contain a
direct quote from the file you read — the actual code,
configuration, or text that triggered the finding. If
the finding is about something absent (e.g., a missing
test file, a function that should exist), state what
you looked for and where you looked.
