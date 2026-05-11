---
description: "Shared procedures for all Divisor Council reviewer agents."
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
  missing from a file, read the file and confirm
  the absence.
- **Verify line references.** If you cite a specific
  line number, you must have read that line.

### Prohibited:

- Fabricating file paths, function signatures, line
  numbers, or code excerpts
- Generating findings based on what "typical" projects
  of this type contain
- Reporting on files you have not read in this review
- Citing specific line numbers you have not observed
- Claiming a file has specific content without reading it
- Claiming a file lacks content without reading it

### When you cannot verify:

If you cannot read a file (binary, too large, access
error), note it as an informational skip. Do not
guess at its contents or generate findings about it.

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

1. The project governance document — if a "Review
   Council Configuration" section exists with a
   "Constitution" entry, read that file for core
   principles. If not configured, skip constitution-
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

Load convention packs from the resolution chain in
this order. Higher-priority locations override
same-named files from lower-priority locations.

1. Always load `severity.md`.
2. Identify the project's primary language. If a
   language-specific pack exists (e.g., `go.md`,
   `typescript.md`), load ONLY that pack — it
   includes all base conventions.
3. If no language-specific pack exists, load
   `base.md` (the language-agnostic default).
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
