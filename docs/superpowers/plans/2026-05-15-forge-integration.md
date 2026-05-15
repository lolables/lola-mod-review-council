# Forge Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend the Review Council module with forge-aware input parsing, CI causality detection, and acceptance criteria coverage tracking.

**Architecture:** All changes modify existing Markdown instruction files under `module/`. No new files are created. The changes flow through the existing five-phase pipeline: prepare.md gains argument parsing, forge detection, and issue/review fetching; quality-gates.md gains run-to-completion behavior and causality detection; delegate.md gains context injection; report.md gains CI causality sections and an AC coverage appendix; review-council.md gains updated coordinator flow.

**Tech Stack:** Markdown instruction files (LLM context injection). No executable code.

**Spec:** `docs/superpowers/specs/2026-05-15-forge-integration-design.md`

**Validation pattern:** After each task's commit, dispatch a reviewer subagent that reads the modified file and the spec, then checks: (1) all spec requirements for that file are present, (2) no contradictions with other phase files, (3) no hardcoded paths or references to removed behavior. The subagent reports PASS or lists specific gaps. Fix before proceeding to the next task.

---

## File Map

| File | Action | Responsibility |
|------|--------|---------------|
| `module/commands/review-council/prepare.md` | Modify | Add Step 0 (argument parsing, forge detection, tooling chain, PR metadata fetch, PR state handling), Step 6 (linked issues), Step 7 (prior reviews). Update session metadata format. |
| `module/commands/review-council/quality-gates.md` | Modify | Replace stop-on-failure with run-to-completion. Add causality detection. Add forge CI integration from pr-metadata.txt. Add ci-causality.txt output. |
| `module/commands/review-council/delegate.md` | Modify | Add conditional context injection sections for linked issues, prior reviews, and CI causality data. |
| `module/commands/review-council/report.md` | Modify | Add CI Failures sections (PR-caused and Pre-existing). Add Acceptance Criteria Coverage appendix. |
| `module/commands/review-council.md` | Modify | Update coordinator step 2 to not stop on CI failure. |
| `module/AGENTS.md` | Modify | Version bump to 1.1.0. Add Usage section with new invocation forms. |
| `module/skills/review-council/SKILL.md` | Modify | Update Quick Start with new invocation forms. |

Seven files modified. Zero files created.

---

### Task 1: Extend `prepare.md` — Argument Parsing and Forge Detection

**Files:**
- Modify: `module/commands/review-council/prepare.md`

This is the largest change. Insert Step 0 before the existing Step 1, covering argument parsing, forge detection, tooling fallback chain, timeouts, PR metadata fetch with section-delimited format, and PR state handling.

- [ ] **Step 1: Read the current `prepare.md`**

Read `module/commands/review-council/prepare.md` in full. Understand the existing structure: Step 1 (Determine Review Mode), Step 2 (Discover Available Reviewers), Step 3 (Session Setup), Step 4 (Capture Changeset), Step 5 (Prior Run Awareness).

- [ ] **Step 2: Insert Step 0 — Parse Input Arguments**

Insert a new `## 0. Parse Input Arguments` section **before** the existing `## 1. Determine Review Mode`. This section must contain all the following subsections in order. The exact content for each subsection is specified in the spec under "Feature 1: Forge Input Parsing" > "Changes to prepare.md". Here is what to write:

**Section: `## 0. Parse Input Arguments`**

Open with a description: "Parse `$ARGUMENTS` to determine the input type, detect the forge, verify tooling, and fetch PR metadata if applicable."

**Subsection: `### Argument Parsing`**

Positional left-to-right parsing. Content must match spec section "Argument Parsing (positional, left to right)" exactly:

1. First token check: if exactly `code` or `specs` (full word match, not substring), extract as mode override, remove from tokens.
2. Remaining tokens classified into the four-row table (Empty, PR number matching `^[0-9]+$`, Ref range containing `..`, URL containing `://`).
3. Include the combined example: `/review-council code 42`.

**Subsection: `### Forge Detection`**

Two paths:
- Local inputs: `git remote get-url origin 2>/dev/null`, check for `github.com` or `gitlab.com`, else `local`.
- URL inputs: parse hostname directly.

Include the pseudocode block from the spec.

**Subsection: `### Tooling Fallback Chain`**

Two tiers only (CLI tool, then CLI API subcommand). No curl/WebFetch.

Failure behavior:
- Local repo inputs: degrade to local diff-only, log warning, skip forge features.
- URL inputs: stop with error listing what was tried and how to fix.

Include the note: "No raw HTTP fallback..."

**Subsection: `### Timeouts`**

- Forge CLI operations: 30-second timeout via `timeout 30 gh ...`
- Local CI commands (referenced by quality-gates): 5-minute timeout per check.
- Timeout treated same as failure.

**Subsection: `### PR Metadata Fetch`**

Only for PR number and URL inputs. Include both GitHub and GitLab commands:

GitHub:
```bash
gh pr view $number --json number,title,body,baseRefName,headRefName,url,state,statusCheckRollup
```

GitLab:
```bash
glab mr view $number --output json
```

For URL inputs, add `--repo $owner/$repo` to the GitHub command.

Write to `${session_dir}/pr-metadata.txt` using the section-delimited format. Include the full example from the spec showing key-value header, `--- BODY ---` / `--- END BODY ---`, and `--- STATUS CHECKS ---` / `--- END STATUS CHECKS ---` sections.

Include all three parsing rules from the spec.

**Subsection: `### PR State Handling`**

After fetching metadata, check the `state` field. Include the four-row table (open, draft, merged, closed) with the exact announcement text for each.

- [ ] **Step 3: Update Step 1 — Mode Detection with PR diff**

In the existing `## 1. Determine Review Mode` section, add a paragraph at the start of the "Auto-Detection" subsection:

> When PR metadata was fetched in Step 0, mode detection
> uses the PR's diff (from `gh pr diff` or equivalent)
> instead of `git diff --name-only`. Extract file paths
> from the diff headers (`diff --git a/... b/...`) for
> classification. The classification logic (spec files vs.
> code files) is unchanged.

- [ ] **Step 4: Update Step 3 — Session Metadata format**

In the existing `## 3. Session Setup` section, find the `session.txt` template. Add these fields after the existing `Agents:` line:

```
Input:     {auto|pr_number|ref_range|url}
Forge:     {github|gitlab|local}
PR:        #{number} "{title}" ({url}) -- or "none"
Tooling:   {gh|glab|api|none}
Issues:    {count} linked -- or "none"
Reviews:   {count} prior -- or "none"
```

In the tracking.md initialization (same section), add to the Preparation phase fields:

```
- Input type: {auto|pr_number|ref_range|url}
- Forge: {github|gitlab|local}
- Tooling: {tool that succeeded}
- PR: #{number} or "none"
- Linked issues: {count}
- Prior reviews: {count}
```

- [ ] **Step 5: Update Step 4 — Diff Resolution for non-local inputs**

In `## 4. Capture Changeset`, update the Code Review Mode subsection. Add a new paragraph before the existing `a.` step:

> **When PR metadata exists** (Step 0 fetched a PR), the
> diff source depends on the input type:
>
> | Input type | Diff source |
> |-----------|-------------|
> | PR number | `gh pr diff $number` / API fallback |
> | Ref range | `git diff $ref_range` |
> | URL | `gh pr diff $number --repo $owner/$repo` / API fallback |
>
> For URL inputs with no local repo, skip all local
> operations (changeset capture from git, local CI).
> Write the forge-fetched diff to `${session_dir}/diff.patch`
> and extract file paths from diff headers for
> `${session_dir}/changeset.txt`.
>
> **When no PR metadata exists** (auto-detect or ref range
> in a local repo), use the existing behavior below.

- [ ] **Step 6: Verify the complete prepare.md reads coherently**

Read the full modified file from top to bottom. Verify:
- Step numbers are sequential (0, 1, 2, 3, 4, 5)
- No duplicate section headings
- Cross-references between steps are correct
- The new Step 0 content matches the spec

- [ ] **Step 7: Commit**

```bash
git add module/commands/review-council/prepare.md
git commit -m "prepare: add argument parsing, forge detection, PR metadata fetch

Step 0 handles four input forms (empty, PR number, ref range,
URL) with positional parsing. Forge detection from git remote
or URL hostname. Two-tier tooling fallback (CLI, then API
subcommand). PR metadata in section-delimited format with
status checks for quality-gates reuse. 30s forge timeouts."
```

- [ ] **Step 8: Validate with reviewer subagent**

Dispatch a subagent with the modified `prepare.md` and the spec. The subagent checks:
- Step 0 contains all 6 subsections: Argument Parsing, Forge Detection, Tooling Fallback Chain, Timeouts, PR Metadata Fetch, PR State Handling
- Argument parsing uses positional first-token mode extraction (not substring matching)
- Tooling chain has exactly 2 tiers (CLI, API subcommand) — no curl/WebFetch
- PR metadata uses section-delimited format with `--- BODY ---` and `--- STATUS CHECKS ---` delimiters
- Session metadata includes all 6 new fields (Input, Forge, PR, Tooling, Issues, Reviews)
- Step 4 has diff resolution table for non-local inputs
- Step 1 references PR diff for mode detection
- No references to `curl`, `WebFetch`, `git stash`, or `git checkout {base}`

Fix any gaps before proceeding.

---

### Task 2: Extend `prepare.md` — Linked Issues and Prior Reviews

**Files:**
- Modify: `module/commands/review-council/prepare.md`

Add Steps 6 and 7 after the existing Step 5 (Prior Run Awareness).

- [ ] **Step 1: Read the current prepare.md**

Read `module/commands/review-council/prepare.md` to see the state after Task 1.

- [ ] **Step 2: Add Step 6 — Fetch Linked Issues**

After the existing `## 5. Prior Run Awareness` section, add a new `## 6. Fetch Linked Issues` section. Skip this step if no PR metadata exists or no issue references are found.

Content must include:

1. Parse `pr-metadata.txt` body (between `--- BODY ---` and `--- END BODY ---`) for issue references. List all six patterns (case-insensitive): `Fixes #N`, `Closes #N`, `Resolves #N`, `Fixed #N`, `Close #N`, `Resolve #N`, plus full GitHub and GitLab issue URLs.

2. Limit to 5 issues by order of appearance. If more than 5, append note: `(N additional issues referenced but not fetched: #X, #Y, #Z)`.

3. Fetch each via tooling fallback chain. Include both GitHub (`gh issue view $N --json title,body,state`) and GitLab (`glab issue view $N --output json`) commands. For URL inputs, add `--repo $owner/$repo`.

4. Truncate each issue body to 2000 characters.

5. Extract acceptance criteria: lines matching `- [ ]` or `- [x]` checkbox patterns, or content under headings containing "acceptance criteria" (case-insensitive).

6. Write to `${session_dir}/linked-issues.txt`. Include the full example format from the spec showing Issue headers, Body sections, Acceptance Criteria sections, and `---` separators.

- [ ] **Step 3: Add Step 7 — Fetch Prior Reviews**

After Step 6, add `## 7. Fetch Prior Reviews`. Skip if no PR metadata exists.

Content must include:

1. Fetch review comments. GitHub: `gh api repos/{owner}/{repo}/pulls/{number}/reviews` and `gh api repos/{owner}/{repo}/pulls/{number}/comments`. GitLab: `glab api projects/:id/merge_requests/{number}/notes`.

2. Truncation strategy: 500 chars per review body, 300 chars per inline comment body, 5000 chars total cap, reverse chronological (most recent first), omission note for older reviews.

3. Write to `${session_dir}/prior-reviews.txt`. Include the full example format from the spec showing Reviews section with `@username (STATE, date)` headers and Inline Comments table.

- [ ] **Step 4: Verify prepare.md reads coherently**

Read the full file. Verify step numbering is 0-7, all sections are present, and cross-references are correct.

- [ ] **Step 5: Commit**

```bash
git add module/commands/review-council/prepare.md
git commit -m "prepare: add linked issue fetching and prior review collection

Step 6 parses PR body for issue references (6 patterns),
fetches up to 5 issues with acceptance criteria extraction.
Step 7 fetches prior forge reviews with per-item and total
truncation limits. Both skip gracefully when no PR metadata."
```

- [ ] **Step 6: Validate with reviewer subagent**

Dispatch a subagent with the modified `prepare.md` and the spec. The subagent checks:
- Step 6 lists all 6 issue reference patterns (Fixes, Closes, Resolves, Fixed, Close, Resolve) plus URL patterns
- 5-issue limit with overflow note format specified
- Issue body truncation at 2000 chars
- Acceptance criteria extraction covers both checkbox patterns and heading-based extraction
- `linked-issues.txt` output format matches spec example
- Step 7 specifies all truncation limits (500/review, 300/comment, 5000 total)
- Reverse chronological ordering with omission note
- `prior-reviews.txt` output format matches spec example
- Both steps have skip conditions (no PR metadata)
- Step numbering is 0-7, sequential, no gaps

Fix any gaps before proceeding.

---

### Task 3: Rewrite `quality-gates.md` — Run-to-Completion and Causality

**Files:**
- Modify: `module/commands/review-council/quality-gates.md`

Replace the stop-on-failure behavior with run-to-completion, add causality detection, add forge CI integration, and add ci-causality.txt output.

- [ ] **Step 1: Read the current `quality-gates.md`**

Read `module/commands/review-council/quality-gates.md` in full. Understand the current structure: Phase A (CI checks, hard gate with stop on failure), Phase B (Quality tool, conditional).

- [ ] **Step 2: Rewrite Phase A**

Replace the current Phase A section. The new Phase A must contain:

**Section heading:** Keep `## Phase A — CI Checks (mandatory)` but remove `hard gate` from the heading — it is no longer a gate.

**Step a:** Read CI configuration files (unchanged from current).

**Step b:** Execute each CI command locally. **Run all commands to completion.** Do not stop on first failure. Record each command's result (pass/fail) and output. Use 5-minute timeout per command:

```bash
timeout 300 {command}
```

If a command times out, record as failed with `output: (timed out after 300s)`.

**Step c:** Remove the current "If any command fails: STOP immediately" instruction. Replace with:

> Record all results. CI failures are reported as CRITICAL
> findings with the full error output in the final report.
> **Do not stop.** Proceed to causality detection (Phase A.5),
> then Phase B.

**Step d:** Keep the "If all commands pass" instruction but change its wording to "report success and proceed to Phase A.5" (not Phase B directly).

- [ ] **Step 3: Insert Phase A.5 — Causality Detection**

Add a new `## Phase A.5 — CI Causality Detection` section between Phase A and Phase B.

Content:

1. Opening: "For each failing CI check, determine whether the failure is caused by the PR or pre-existing on the base branch."

2. **Method 1 — Forge CI data (preferred):** When `${session_dir}/pr-metadata.txt` contains a `--- STATUS CHECKS ---` section, read forge CI results from there. Do not re-query the forge API. Map conclusions: SUCCESS->pass, FAILURE->fail, NEUTRAL->pass, SKIPPED->skipped, PENDING/null->pending.

   For each local failure, find the matching forge check by name. If the forge check also failed, `causality: pre-existing`. If passed, `causality: pr-caused`. If not found, `causality: unknown`.

   For forge-only checks (no local equivalent), include them in the results with `source: forge-api` and determine causality by fetching the base branch's check status:
   ```bash
   timeout 30 gh api repos/{owner}/{repo}/commits/{base_ref}/check-runs \
     --jq ".check_runs[] | select(.name == \"{check_name}\") | .conclusion"
   ```

3. **Method 2 — Conservative default:** If no forge data is available, classify all failures as `causality: unknown` and treat as PR-caused. Include the rationale note about rejecting local worktree manipulation.

4. **Merge rules:** When the same check appears in both local and forge results:
   - Local ran and passed: use local (authoritative)
   - Local ran and failed: use local with causality
   - Local did not run: use forge result with causality

5. **Output:** Write `${session_dir}/ci-causality.txt` with the exact format from the spec: CI Results table (Check, Status, Source, Causality) followed by Failure Details subsections.

6. **Tracking updates:** List the new tracking.md fields (CI checks run/passed/failed with causality breakdown, CI source).

- [ ] **Step 4: Verify quality-gates.md reads coherently**

Read the full file. Verify Phase A flows into A.5 flows into B. No stop-on-failure behavior remains. The phase always proceeds to completion.

- [ ] **Step 5: Commit**

```bash
git add module/commands/review-council/quality-gates.md
git commit -m "quality-gates: run all checks to completion, add causality detection

Phase A no longer stops on first failure. All CI commands run
to completion with 5-minute timeouts. Phase A.5 determines
causality (pr-caused vs pre-existing) using forge status check
data from pr-metadata.txt. Results written to ci-causality.txt
for the report phase."
```

- [ ] **Step 6: Validate with reviewer subagent**

Dispatch a subagent with the modified `quality-gates.md` and the spec. The subagent checks:
- Phase A heading no longer says "hard gate"
- No "STOP immediately" or "stop" instructions remain in Phase A
- 5-minute timeout (`timeout 300`) specified for CI commands
- Phase A.5 exists between A and B
- Causality detection uses forge data from `pr-metadata.txt` `--- STATUS CHECKS ---` section — does NOT re-query the forge API
- Conclusion mapping (SUCCESS->pass, etc.) is complete
- Conservative default for missing forge data is `unknown` treated as PR-caused
- No references to `git stash`, `git checkout`, or local worktree manipulation
- ci-causality.txt format matches spec (table + failure details)
- Merge rules for local+forge overlap are specified
- Tracking updates include all 4 new fields

Fix any gaps before proceeding.

---

### Task 4: Extend `delegate.md` — Context Injection

**Files:**
- Modify: `module/commands/review-council/delegate.md`

Add conditional context sections to the delegation prompt for linked issues, prior reviews, and CI causality data.

- [ ] **Step 1: Read the current `delegate.md`**

Read `module/commands/review-council/delegate.md` in full. Find the Code Review Delegation > Prompt Template section, specifically the part after the existing "When quality analysis data is available" and "When prior run context is available" paragraphs.

- [ ] **Step 2: Add three conditional context sections**

After the existing "When prior run context is available" paragraph in the Code Review Delegation section, add three new paragraphs:

**Linked Issues:**

> **When linked issues are available** (`${session_dir}/linked-issues.txt` exists): append a "Linked Issues" section to each delegation prompt containing the full content of `linked-issues.txt`, followed by:
>
> > When reviewing, consider whether the changes address the
> > acceptance criteria listed above. Note any criteria that
> > appear unaddressed by the changes.

**Prior Reviews:**

> **When prior forge reviews are available** (`${session_dir}/prior-reviews.txt` exists): append a "Prior Reviews" section containing the full content of `prior-reviews.txt`, followed by:
>
> > These reviews were previously submitted on this PR. Do not
> > re-flag issues that have already been raised unless the
> > current changes make them worse or the prior feedback was
> > not addressed.

**CI Results:**

> **When CI causality data is available** (`${session_dir}/ci-causality.txt` exists): append a "CI Results" section containing the full content of `ci-causality.txt`, followed by:
>
> > CI failures tagged as "pre-existing" also fail on the base
> > branch and are not caused by the changes under review.

- [ ] **Step 3: Add the same three sections to Spec Review Delegation**

In the Spec Review Delegation section, after the existing "Include prior run context if available" sentence, add the same three conditional sections (linked issues, prior reviews, CI results). The CI results section is less likely to be present in spec review (quality gates are skipped), but if it exists from a prior code review run, it should still be included.

- [ ] **Step 4: Commit**

```bash
git add module/commands/review-council/delegate.md
git commit -m "delegate: inject linked issues, prior reviews, and CI causality

Delegation prompts now conditionally include linked issue
context with acceptance criteria, prior forge review comments,
and CI causality data when the corresponding session artifacts
exist."
```

- [ ] **Step 5: Validate with reviewer subagent**

Dispatch a subagent with the modified `delegate.md` and the spec. The subagent checks:
- Three conditional sections added to Code Review Delegation
- Each section checks for the correct session artifact file
- Linked Issues section includes the "consider whether changes address acceptance criteria" instruction
- Prior Reviews section includes the "do not re-flag" instruction
- CI Results section includes the "pre-existing" explanation
- Same three sections added to Spec Review Delegation
- File paths reference `${session_dir}/linked-issues.txt`, `prior-reviews.txt`, `ci-causality.txt`

Fix any gaps before proceeding.

---

### Task 5: Extend `report.md` — CI Causality and AC Coverage

**Files:**
- Modify: `module/commands/review-council/report.md`

Add CI failure detail sections and the Acceptance Criteria Coverage appendix.

- [ ] **Step 1: Read the current `report.md`**

Read `module/commands/review-council/report.md` in full. Understand the structure: Code Review Mode report, Spec Review Mode report, Prior Learnings Feedback, Verdict Summary.

- [ ] **Step 2: Add CI Failure sections to Code Review Mode report**

In the `## Final Report — Code Review Mode` section, after the existing bullet list, add:

> **When CI causality data is available** (`${session_dir}/ci-causality.txt` exists), add two CI failure sections to the report:
>
> **CI Failures (PR-caused):** For each failure with `causality: pr-caused` or `causality: unknown`, include the check name, exit code, likely cause (inferred from the output), and truncated output.
>
> **CI Failures (Pre-existing):** For each failure with `causality: pre-existing`, include the check name and output, prefixed with: "Note: This failure also occurs on the base branch ({base}). It is not caused by the changes under review."
>
> Include the CI results summary table (Check, Status, Source, Causality) from `ci-causality.txt`.

Include the example format from the spec showing both sections.

- [ ] **Step 3: Add CI Failure sections to Spec Review Mode report**

In the `## Final Report — Spec Review Mode` section, add the same CI failure sections. Note: "These sections are unlikely to be present in Spec Review Mode (quality gates are skipped), but if they exist from a combined review or prior run, include them."

- [ ] **Step 4: Add Acceptance Criteria Coverage appendix**

After the existing `## Verdict Summary` section (at the very end of the file), add a new section:

```markdown
---

## Acceptance Criteria Coverage (Appendix)

**When to include:** Only when `${session_dir}/linked-issues.txt`
exists AND at least one linked issue has acceptance criteria.
If no linked issues have acceptance criteria, omit this
section entirely (no empty heading).

For each linked issue that has acceptance criteria, produce
a coverage assessment:

1. For each criterion, scan the diff
   (`${session_dir}/diff.patch`) and verified findings for
   evidence of implementation:

   - **COVERED**: diff contains code that clearly implements
     the criterion (matching function names, route paths,
     test names, or variable names corresponding to the
     criterion)
   - **PARTIALLY COVERED**: some aspects are addressed but
     gaps remain (annotate what is missing)
   - **NOT COVERED**: no evidence of implementation in the
     diff

2. Present as a checklist grouped by issue:

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

3. Issues with no acceptance criteria are listed with
   "(No acceptance criteria found in issue)" — do not
   omit them, as the listing confirms they were checked.
```

- [ ] **Step 5: Verify report.md reads coherently**

Read the full file. Verify the new sections are in the correct positions: CI failures within each report mode section, AC coverage as a standalone appendix after the verdict.

- [ ] **Step 6: Commit**

```bash
git add module/commands/review-council/report.md
git commit -m "report: add CI causality sections and acceptance criteria coverage

CI failures are now split into PR-caused and Pre-existing
sections with causality tags. Acceptance Criteria Coverage
appendix maps each criterion to COVERED/PARTIALLY/NOT COVERED
based on diff evidence. Both sections are conditional on
session artifacts."
```

- [ ] **Step 7: Validate with reviewer subagent**

Dispatch a subagent with the modified `report.md` and the spec. The subagent checks:
- CI Failures (PR-caused) section present in Code Review Mode report
- CI Failures (Pre-existing) section present with "also occurs on base branch" note
- CI sections conditional on `ci-causality.txt` existence
- AC Coverage appendix is after Verdict Summary (at end of file)
- AC section conditional on `linked-issues.txt` with acceptance criteria
- Three coverage classifications (COVERED, PARTIALLY COVERED, NOT COVERED) specified
- Checklist format matches spec example with `[x]`, `[~]`, `[ ]` markers
- Issues with no AC show "(No acceptance criteria found in issue)"
- Section omitted entirely when no AC exist (no empty heading)

Fix any gaps before proceeding.

---

### Task 6: Update `review-council.md` — Coordinator Flow

**Files:**
- Modify: `module/commands/review-council.md`

Update the coordinator's Code Review flow step 2 to not stop on CI failure.

- [ ] **Step 1: Read the current `review-council.md`**

Read `module/commands/review-council.md`. Find the Code Review Mode execution flow, specifically step 2.

- [ ] **Step 2: Update step 2 in the Code Review Mode flow**

Find this text in the Code Review Mode section:

```
2. Read and follow `quality-gates.md`
   → Update tracking: Quality Gates
   → If CI fails: stop with CRITICAL findings
```

Replace with:

```
2. Read and follow `quality-gates.md`
   → Update tracking: Quality Gates
   → CI failures are recorded with causality tags
     (pr-caused, pre-existing, unknown). Review
     continues regardless — failures are reported
     in the final report, not used as a gate.
```

- [ ] **Step 3: Verify no other stop-on-CI-failure references exist**

Search the file for other references to stopping on CI failure. The file should not have any other "stop" or "halt" instructions conditioned on CI results.

- [ ] **Step 4: Commit**

```bash
git add module/commands/review-council.md
git commit -m "coordinator: remove CI failure as a review gate

Quality gates now run to completion and classify failures by
causality. The review proceeds regardless of CI results —
failures are reported in the final report with causality tags."
```

- [ ] **Step 5: Validate with reviewer subagent**

Dispatch a subagent with the modified `review-council.md` and the spec. The subagent checks:
- Step 2 in Code Review Mode flow no longer says "stop with CRITICAL findings"
- Step 2 mentions causality tags and "review continues regardless"
- No other stop-on-CI-failure instructions exist in the file
- Spec Review flow is unchanged (still skips quality gates)

Fix any gaps before proceeding.

---

### Task 7: Update `AGENTS.md` and `SKILL.md` — Version and Usage

**Files:**
- Modify: `module/AGENTS.md`
- Modify: `module/skills/review-council/SKILL.md`

Version bump and updated usage documentation.

- [ ] **Step 1: Read both files**

Read `module/AGENTS.md` and `module/skills/review-council/SKILL.md`.

- [ ] **Step 2: Update AGENTS.md**

1. Change version from `1.0.0` to `1.1.0`.

2. After the "What It Does" section, add a `## Usage` section (or update if one exists):

```markdown
## Usage

```
/review-council              # auto-detect from current branch
/review-council code         # force code review mode
/review-council specs        # force spec review mode
/review-council 42           # review PR #42
/review-council main..feat   # review a ref range
/review-council https://github.com/org/repo/pull/42  # review by URL
```

**Input forms:**

- **Empty**: auto-detect mode from current branch, diff
  against base branch
- **PR number**: fetch PR metadata, diff, linked issues,
  and prior reviews from the forge
- **Ref range**: diff between two refs in the local repo
- **URL**: review a PR from any GitHub/GitLab repo
  (requires `gh` or `glab` CLI with authentication)

All forms support an optional mode prefix (`code` or
`specs`) as the first argument.
```

- [ ] **Step 3: Update SKILL.md**

In `module/skills/review-council/SKILL.md`, update the Quick Start section to show the new invocation forms. Replace the existing quick start block:

```
/review-council        # auto-detect mode from workspace
/review-council code   # force code review
/review-council specs  # force spec review
```

With:

```
/review-council              # auto-detect from current branch
/review-council code         # force code review mode
/review-council specs        # force spec review mode
/review-council 42           # review PR #42
/review-council main..feat   # review a ref range
/review-council https://github.com/org/repo/pull/42  # review by URL
```

- [ ] **Step 4: Commit**

```bash
git add module/AGENTS.md module/skills/review-council/SKILL.md
git commit -m "docs: bump to v1.1.0, add forge input forms to usage

AGENTS.md version 1.0.0 -> 1.1.0. Both AGENTS.md and the
review-council SKILL.md now document PR number, ref range,
and URL input forms alongside the existing mode keywords."
```

---

### Task 8: Final Verification

Verify all changes are consistent and complete against the spec.

- [ ] **Step 1: Verify file structure is unchanged**

```bash
find module/ -type f | sort
```

Expected: same 29 files as before. No new files, no deleted files.

- [ ] **Step 2: Verify no hardcoded paths leaked in**

```bash
grep -r '\.opencode/' module/ || echo "OK: No .opencode references"
grep -r '\.specify/' module/ || echo "OK: No .specify references"
```

- [ ] **Step 3: Verify spec coverage**

Read the spec and check each requirement against the modified files:

| Spec Section | Implemented In |
|-------------|---------------|
| Argument parsing (positional) | prepare.md Step 0 |
| Forge detection | prepare.md Step 0 |
| Tooling fallback (2-tier, no curl) | prepare.md Step 0 |
| Timeouts (30s forge, 5min CI) | prepare.md Step 0, quality-gates.md Phase A |
| PR metadata fetch + section-delimited format | prepare.md Step 0 |
| PR state handling | prepare.md Step 0 |
| Diff resolution for non-local inputs | prepare.md Step 4 |
| Mode detection with PR diff | prepare.md Step 1 |
| Session metadata updates | prepare.md Step 3 |
| Linked issues (5 limit, overflow note, AC extraction) | prepare.md Step 6 |
| Prior reviews (truncation strategy) | prepare.md Step 7 |
| CI run-to-completion | quality-gates.md Phase A |
| CI causality detection (forge data only) | quality-gates.md Phase A.5 |
| Forge CI integration (from pr-metadata.txt) | quality-gates.md Phase A.5 |
| ci-causality.txt output format | quality-gates.md Phase A.5 |
| Linked issues in delegation prompt | delegate.md |
| Prior reviews in delegation prompt | delegate.md |
| CI causality in delegation prompt | delegate.md |
| CI Failures (PR-caused) in report | report.md |
| CI Failures (Pre-existing) in report | report.md |
| AC Coverage appendix | report.md |
| Coordinator flow update | review-council.md |
| Version bump 1.0.0 -> 1.1.0 | AGENTS.md |
| Usage section with new forms | AGENTS.md, SKILL.md |

- [ ] **Step 4: Read each modified file in full**

Read all seven modified files to verify internal consistency:
- prepare.md: steps 0-7 are sequential, no broken cross-references
- quality-gates.md: Phase A -> A.5 -> B flow is coherent
- delegate.md: conditional sections use correct file paths
- report.md: CI sections and AC appendix in correct positions
- review-council.md: step 2 updated, no conflicting stop instructions
- AGENTS.md: version is 1.1.0, Usage section present
- SKILL.md: Quick Start updated

- [ ] **Step 5: Commit verification results (if any fixes were needed)**

If any fixes were made during verification, commit them:

```bash
git add module/
git commit -m "fix: address consistency issues found during verification"
```

If no fixes needed, skip this step.
