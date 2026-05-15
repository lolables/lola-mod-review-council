# Forge Integration, CI Causality, and Acceptance Criteria Coverage

Extends the Review Council with three features: forge-aware input
parsing (PR numbers, URLs, linked issues, prior reviews), CI failure
causality detection, and acceptance criteria coverage tracking in the
final report.

## Scope

Three features integrated into the existing five-phase architecture
by extending `prepare.md`, `quality-gates.md`, `report.md`, and
`delegate.md`. No new phases or skills.

### In Scope

- Parse PR numbers, ref ranges, and GitHub/GitLab URLs as input
- Tooling fallback chain: CLI tools, API subcommands
- Fetch PR metadata, linked issues, prior reviews from forges
- CI causality detection (PR-caused vs. pre-existing)
- Acceptance criteria extraction and coverage tracking
- Graceful degradation when tooling is unavailable

### Out of Scope

- Posting reviews back to forges (existing `remote_write` gating
  is not part of this module)
- Supporting forges other than GitHub and GitLab
- Changing the existing review loop (delegation, verification,
  fix iterations)

## Architecture

All changes extend existing phase files. No new files are created
except session artifacts.

### Session Directory Additions

The following files are added to `${session_dir}/` when applicable:

| File | Written by | Consumed by | Present when |
|------|-----------|-------------|--------------|
| `pr-metadata.txt` | prepare | delegate, report | PR/MR was resolved |
| `linked-issues.txt` | prepare | delegate, report | PR description references issues |
| `prior-reviews.txt` | prepare | delegate, verify | Forge reviews exist on the PR |
| `ci-causality.txt` | quality-gates | report | Any CI check failed |

All are plain text. When absent, downstream phases skip the
corresponding logic.

## Feature 1: Forge Input Parsing

### Changes to `prepare.md`

Insert **Step 0 -- Parse Input Arguments** before the existing
Step 1 (Determine Review Mode).

#### Input Forms

#### Argument Parsing (positional, left to right)

Split `$ARGUMENTS` on whitespace into tokens. Parse left to
right:

1. If the **first token** is exactly `code` or `specs` (full
   word match, not substring), extract it as the mode override
   and remove it. Only the first token is checked for mode
   keywords -- this prevents false matches against URLs or
   branch names containing "code" or "specs" as substrings.

2. Join remaining tokens (if any) into a single string and
   classify:

| Form | Example | Detection rule |
|------|---------|---------------|
| Empty | `/review-council` | No remaining tokens |
| PR number | `/review-council 42` | Matches `^[0-9]+$` |
| Ref range | `/review-council main..feature` | Contains `..` |
| URL | `/review-council https://github.com/org/repo/pull/42` | Contains `://` |

Combined example: `/review-council code 42` extracts mode
`code`, then parses `42` as a PR number.

#### Forge Detection

For local inputs (empty, PR number, ref range):

```
remote_url = git remote get-url origin 2>/dev/null
if remote_url contains "github.com": forge = github
elif remote_url contains "gitlab.com": forge = gitlab
else: forge = local
```

For URL inputs, parse the hostname directly.

#### Tooling Fallback Chain

When forge operations are needed, try tools in this order:

1. **CLI tool** (`gh` / `glab`) -- preferred, handles auth
2. **CLI API subcommand** (`gh api` / `glab api`) -- if the
   view subcommand fails or is unavailable

If both fail, stop forge operations for this input:

- **Local repo inputs** (empty, PR number, ref range): degrade
  to local diff-only mode. Log a warning naming the tool that
  was tried and the error. Forge-dependent features (linked
  issues, prior reviews, forge CI) are skipped.
- **URL inputs**: stop with a clear error listing what was
  tried and how to fix it (install `gh`/`glab`, run
  `gh auth login`/`glab auth login`).

No raw HTTP fallback (curl, WebFetch). The forge CLIs handle
authentication, pagination, and API versioning. Reimplementing
that with raw HTTP adds complexity for a scenario where the
user likely doesn't have auth configured anyway.

Log which tool succeeded (or that all failed) in the session
metadata.

#### Timeouts

All forge CLI operations should use a 30-second timeout.
In bash, use the `timeout` command:

```bash
timeout 30 gh pr view $number --json ...
```

If the command times out, treat it the same as a failure
and proceed to the next step in the fallback chain. Log
the timeout in the session metadata.

For local CI commands (quality-gates), use a 5-minute
timeout per individual check. CI commands that exceed this
are killed and recorded as failed with `output: (timed out
after 300s)`.

#### PR Metadata Fetch

For PR number and URL inputs, fetch:

- PR number, title, body, state
- Base ref, head ref
- URL

GitHub (include `statusCheckRollup` so quality-gates can
reuse it without a second API call):
```bash
gh pr view $number --json number,title,body,baseRefName,headRefName,url,state,statusCheckRollup
```

GitLab:
```bash
glab mr view $number --output json
```

Write to `${session_dir}/pr-metadata.txt` using a
section-delimited format. Single-line fields use `key: value`.
The body (which can be multiline and contain arbitrary
content) is in its own delimited section:

```
number: 42
title: Add user authentication
base: main
head: feature/auth
url: https://github.com/org/repo/pull/42
state: open

--- BODY ---
Adds login/logout flow.
Fixes #38
Closes #41
--- END BODY ---

--- STATUS CHECKS ---
build: SUCCESS
test: FAILURE
lint: FAILURE
security-scan: FAILURE
deploy-preview: SUCCESS
--- END STATUS CHECKS ---
```

Parsing rules:
- Lines before `--- BODY ---` are key-value pairs (split
  on first `: `).
- Everything between `--- BODY ---` and `--- END BODY ---`
  is the raw PR description.
- Everything between `--- STATUS CHECKS ---` and
  `--- END STATUS CHECKS ---` is one check per line
  (`name: conclusion`). This section is present only when
  `statusCheckRollup` data was fetched. Quality-gates reads
  this instead of re-querying the forge API.

This format avoids YAML parsing dependencies and handles
arbitrary body content (including lines that contain `:`
or start with `-`). Each delimited section is independent.

#### PR State Handling

After fetching PR metadata, check the `state` field:

| State | Behavior |
|-------|----------|
| `open` / `OPEN` | Proceed normally |
| `draft` / `DRAFT` | Proceed normally, announce: "Note: this PR is in draft state." |
| `merged` / `MERGED` | Proceed normally, announce: "Note: this PR has been merged. Review is informational only." |
| `closed` / `CLOSED` | Proceed normally, announce: "Note: this PR is closed. Review is informational only." |

The review always proceeds regardless of state. The
announcement gives the user context about what they're
reviewing.

#### Diff Resolution

| Input type | Diff source |
|-----------|-------------|
| Empty | `git diff {base}...HEAD` (existing behavior) |
| PR number | `gh pr diff $number` / API fallback |
| Ref range | `git diff $ref_range` |
| URL | `gh pr diff $number --repo $owner/$repo` / API fallback |

For URL inputs with no local repo, the diff comes entirely
from the forge API. Skip all local operations (changeset
capture from git, local CI).

#### Impact on Mode Detection

When PR metadata is available, mode detection uses the PR's
diff (fetched above) instead of `git diff --name-only`. The
classification logic (spec files vs. code files) is unchanged.

### New Step 6 -- Fetch Linked Issues

After Step 5 (Prior Run Awareness).

Parse `pr-metadata.txt` body for issue references:

```
Patterns (case-insensitive):
  Fixes #N
  Closes #N
  Resolves #N
  Fixed #N
  Close #N
  Resolve #N
  https://github.com/{owner}/{repo}/issues/{N}
  https://gitlab.com/{owner}/{repo}/-/issues/{N}
```

Limit to 5 issues (by order of appearance in the PR body).
If more than 5 are referenced, fetch the first 5 and append
a note to `linked-issues.txt`:

```
(N additional issues referenced but not fetched: #X, #Y, #Z)
```

For each of the first 5, fetch via the tooling fallback
chain:

GitHub:
```bash
gh issue view $N --json title,body,state
```

GitLab:
```bash
glab issue view $N --output json
```

Truncate each issue body to 2000 characters (untrusted content
boundary).

Extract acceptance criteria:
- Lines matching `- [ ]` or `- [x]` checkbox patterns
- Content under headings containing "acceptance criteria"
  (case-insensitive)

Write to `${session_dir}/linked-issues.txt`:

```
## Issue #38: Add user authentication
State: open

### Body (truncated)
Adds login/logout flow with session management.

### Acceptance Criteria
- [ ] Users can log in with email/password
- [ ] Session timeout is configurable
- [ ] Password reset flow works end-to-end

---

## Issue #41: Fix logout redirect
State: open

### Body (truncated)
After logout, user should redirect to landing page.

### Acceptance Criteria
(none found)
```

Skip this step if no PR metadata exists or no issue
references are found.

### New Step 7 -- Fetch Prior Reviews

After Step 6. Skip if no PR metadata exists.

Fetch existing review comments from the forge:

GitHub:
```bash
gh api repos/{owner}/{repo}/pulls/{number}/reviews
gh api repos/{owner}/{repo}/pulls/{number}/comments
```

GitLab:
```bash
glab api projects/:id/merge_requests/{number}/notes
```

Truncation strategy (prior reviews can be verbose):

- Each individual review body: truncate to 500 characters
- Each inline comment body: truncate to 300 characters
- Total file size cap: 5000 characters
- If the cap is reached, include reviews in reverse
  chronological order (most recent first) until the cap
  is hit. Omit older reviews with a note:
  `(N earlier reviews omitted -- see forge for full history)`

Write to `${session_dir}/prior-reviews.txt`:

```
## Reviews

### @reviewer1 (APPROVED, 2026-05-14)
LGTM, minor nit on line 42.

### @reviewer2 (CHANGES_REQUESTED, 2026-05-14)
The auth middleware needs rate limiting.

## Inline Comments

| File | Line | Author | Body |
|------|------|--------|------|
| src/auth.py | 42 | @reviewer1 | "Consider using bcrypt" |
| src/auth.py | 67 | @reviewer2 | "Missing rate limit check" |
```

### Session Metadata Updates

`session.txt` gains:
```
Input:     {auto|pr_number|ref_range|url}
Forge:     {github|gitlab|local}
PR:        #{number} "{title}" ({url}) -- or "none"
Tooling:   {gh|glab|api|none}
Issues:    {count} linked -- or "none"
Reviews:   {count} prior -- or "none"
```

`tracking.md` Preparation phase gains:
```
- Input type: {auto|pr_number|ref_range|url}
- Forge: {github|gitlab|local}
- Tooling: {tool that succeeded}
- PR: #{number} or "none"
- Linked issues: {count}
- Prior reviews: {count}
```

## Feature 2: CI Causality Detection

### Changes to `quality-gates.md`

Replace the current Phase A behavior (stop on first failure)
with: run all CI checks to completion, then classify failures.

#### New Phase A Behavior

a. Read CI configuration files (unchanged).

b. Execute each CI command locally. **Run all commands to
   completion.** Do not stop on first failure. Record each
   command's result (pass/fail) and output.

c. For each failing check, determine causality.

d. Report all results (pass, fail with causality) as CRITICAL
   findings. Proceed to Phase B regardless.

#### Causality Detection

For each failing CI check, determine whether the failure is
caused by the PR or pre-existing on the base branch.

**Method 1 -- Forge CI data (preferred):**

When `${session_dir}/pr-metadata.txt` exists, fetch the base
branch's CI status:

GitHub:
```bash
gh api repos/{owner}/{repo}/commits/{base_ref}/check-runs \
  --jq ".check_runs[] | select(.name == \"{check_name}\") | .conclusion"
```

- Base check passed -> `causality: pr-caused`
- Base check failed -> `causality: pre-existing`
- Base check not found -> `causality: unknown`

**Method 2 -- Conservative default:**

If forge CI data is unavailable (no PR metadata, forge API
unreachable), classify as `causality: unknown` and treat as
PR-caused in the report (conservative default).

Local worktree manipulation (`git stash`/`git checkout`) was
considered and rejected: it modifies the working tree during a
review, risks merge conflicts with uncommitted work, and
creates a confusing state if interrupted. The forge API is
the only causality data source. When it is unavailable, the
conservative default is the right answer.

#### Forge CI Integration

When `${session_dir}/pr-metadata.txt` contains a
`--- STATUS CHECKS ---` section (written by prepare.md),
read forge CI results from there. **Do not re-query the
forge API** — the data was already fetched during PR
metadata collection.

Map each check:
```
SUCCESS -> pass
FAILURE -> fail
NEUTRAL -> pass
SKIPPED -> skipped
PENDING / null -> pending
```

Merge forge CI results with local CI results. When the same
check appears in both:
- If local ran and passed: use local result (authoritative)
- If local ran and failed: use local result with causality
- If local did not run (no local equivalent): use forge result
  with causality from forge data

#### Output

Write `${session_dir}/ci-causality.txt`:

```
## CI Results

| Check | Status | Source | Causality |
|-------|--------|--------|-----------|
| build | pass | local | n/a |
| test | fail | local | pr-caused |
| lint | fail | local | pre-existing |
| security-scan | fail | forge-api | pre-existing |
| deploy-preview | pass | forge-api | n/a |

## Failure Details

### test (PR-caused)
Exit code: 1
Output (truncated):
  FAIL TestAuth/login_timeout (0.3s)
  Expected 200, got 504

### lint (Pre-existing)
Exit code: 1
Output (truncated):
  src/legacy.py:12: E501 line too long (120 > 79)
```

All CI failures remain CRITICAL severity. The causality tag
is informational context, not a severity modifier. The review
proceeds regardless -- the phase does not exit early on
failure.

#### Tracking Updates

`tracking.md` Quality Gates phase gains:
```
- CI checks run: {count}
- CI checks passed: {count}
- CI checks failed: {count} ({N} pr-caused, {N} pre-existing, {N} unknown)
- CI source: {local|forge|both}
```

## Feature 3: Acceptance Criteria Coverage

### Changes to `report.md`

Add **Acceptance Criteria Coverage** as a separate appendix
section after the Verdict Summary. Present only when linked
issues with acceptance criteria exist.

#### Coverage Determination

For each acceptance criterion from `linked-issues.txt`:

1. Scan the diff for code that implements the criterion.
   Look for function names, variable names, route paths,
   test names, or comments that correspond to the criterion.

2. Scan verified findings for issues related to the
   criterion (a finding about auth middleware is relevant
   to an "authentication" criterion).

3. Classify:
   - **COVERED**: diff contains code that clearly implements
     the criterion
   - **PARTIALLY COVERED**: some aspects addressed, gaps
     remain
   - **NOT COVERED**: no evidence of implementation in the
     diff

#### Report Format

```markdown
## Acceptance Criteria Coverage

### From Issue #38: "Add user authentication"

- [x] COVERED: Users can log in with email/password
- [~] PARTIALLY COVERED: Session timeout is configurable
  (default set in config, no UI for changing it)
- [ ] NOT COVERED: Password reset flow

### From Issue #41: "Fix logout redirect"

(No acceptance criteria found in issue)
```

Omit the entire section if no linked issues have acceptance
criteria.

### Changes to `report.md` -- CI Section

Add CI failure detail sections when `ci-causality.txt` exists:

```markdown
## CI Failures (PR-caused)

### test
Exit code: 1
Likely cause: TestAuth/login_timeout assertion failure
Output:
  FAIL TestAuth/login_timeout (0.3s)
  Expected 200, got 504

## CI Failures (Pre-existing)

### lint
Note: This failure also occurs on the base branch (main).
It is not caused by the changes under review.
Output:
  src/legacy.py:12: E501 line too long (120 > 79)
```

## Scripts vs. Inline Instructions

The existing module is pure Markdown — no executable scripts.
The features in this spec introduce deterministic CLI
operations (forge detection, PR fetch, issue fetch, causality
checks) that are the same every time and don't benefit from
LLM interpretation. These are candidates for extraction into
shell scripts.

### Decision: Keep Inline (for now)

Rationale:

1. **Portability.** The module currently works as pure context
   injection across any LLM platform (Claude Code, Copilot,
   Gemini, etc.). Adding scripts would introduce a bash
   dependency and a runtime execution model that not all
   platforms support identically.

2. **Coherence.** The phase files are self-contained — an LLM
   reads them and knows what to do. Splitting logic between
   Markdown instructions and shell scripts creates two places
   to look and two things to keep in sync.

3. **Scope.** The mechanical operations are straightforward
   (3-5 CLI invocations per feature). They don't have the
   complexity that makes scripts clearly superior to inline
   instructions.

### When to Reconsider

Extract into `module/scripts/` if any of these become true:

- The CLI operations grow complex enough that LLMs
  inconsistently interpret the instructions (observed, not
  hypothetical)
- Multiple phase files need the same CLI sequence (DRY
  violation — a script becomes a shared function)
- The module adds a Taskfile or build system for other
  reasons, making scripts a natural fit

If scripts are introduced later, the phase files would
invoke them with `bash scripts/detect-forge.sh` and consume
their stdout. The Markdown instructions would describe what
the script does and when to call it, not how it works
internally.

## Supporting Changes

### Changes to `delegate.md`

When `linked-issues.txt` exists, append to each delegation
prompt:

```
## Linked Issues

{content of linked-issues.txt}

When reviewing, consider whether the changes address the
acceptance criteria listed above. Note any criteria that
appear unaddressed by the changes.
```

When `prior-reviews.txt` exists, append:

```
## Prior Reviews

{content of prior-reviews.txt}

These reviews were previously submitted on this PR. Do not
re-flag issues that have already been raised unless the
current changes make them worse or the prior feedback was
not addressed.
```

When `ci-causality.txt` exists, append:

```
## CI Results

{content of ci-causality.txt}

CI failures tagged as "pre-existing" also fail on the base
branch and are not caused by the changes under review.
```

### Changes to `review-council.md` (coordinator)

The coordinator's Code Review flow (step 2) currently reads:

> If CI fails: stop with CRITICAL findings

This contradicts the new quality-gates behavior, which runs
all checks to completion and proceeds regardless. Update the
coordinator flow:

**Before (step 2):**
```
2. Read and follow `quality-gates.md`
   → Update tracking: Quality Gates
   → If CI fails: stop with CRITICAL findings
```

**After (step 2):**
```
2. Read and follow `quality-gates.md`
   → Update tracking: Quality Gates
   → CI failures are recorded with causality tags.
     Review continues regardless — failures are reported
     in the final report, not used as a gate.
```

The Spec Review flow is unchanged (it already skips quality
gates).

### Changes to `AGENTS.md`

Version bump from 1.0.0 to 1.1.0.

Add to the Usage section:

```
## Usage

/review-council              # auto-detect from current branch
/review-council code         # force code review mode
/review-council specs        # force spec review mode
/review-council 42           # review PR #42
/review-council main..feat   # review a ref range
/review-council https://github.com/org/repo/pull/42  # review by URL
```

### Changes to `skills/review-council/SKILL.md`

Update the Quick Start section to show the new invocation
forms matching the AGENTS.md changes.

## Error Handling

| Scenario | Behavior |
|----------|----------|
| Forge CLI missing | Try API subcommand; if also missing, degrade to local (or error for URL inputs) |
| Forge auth expired | Clear error with fix instructions (`gh auth login` / `glab auth login`) |
| URL input, no working CLI | Stop with error listing what was tried and how to install/auth |
| Local input, no working CLI | Degrade to local diff-only, skip forge features, log warning |
| Issue fetch fails | Skip linked issues, note in session log |
| Prior review fetch fails | Skip prior reviews, note in session log |
| CI causality detection fails | Default to `unknown`, treat as PR-caused |
| No acceptance criteria found | Omit the AC section from the report |

## Testing

Verify these scenarios manually:

1. `/review-council` with no changes (existing behavior preserved)
2. `/review-council 42` on a GitHub repo with `gh` installed
3. `/review-council https://github.com/org/repo/pull/42` cross-repo
4. `/review-council main..feature` ref range
5. PR with linked issues containing acceptance criteria
6. PR with existing reviews from other contributors
7. CI failure that also fails on the base branch (pre-existing)
8. CI failure unique to the PR branch (PR-caused)
9. No forge tooling available (graceful degradation)
10. URL input with no forge tooling (clear error)
