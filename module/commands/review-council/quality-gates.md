# Phase: Quality Gates

Run local CI checks and optional quality analysis
before delegating to reviewer agents.

**This phase applies only to Code Review Mode.**
Spec Review Mode skips this phase entirely.

## Inputs

- Project CI configuration files
- "Review Council Configuration" section (for quality
  tool)
- `${session_dir}/pr-metadata.txt` (for forge CI data
  in Phase A.5)

## Outputs

Update `${session_dir}/tracking.md` Phase: Quality
Gates with: CI result, CI failures (if any), CI
checks run count, CI checks passed count, CI checks
failed count (with pr-caused, pre-existing, and
unknown breakdowns), CI source (local, forge, or
both), quality tool status, quality report summary.

Write `${session_dir}/ci-causality.txt` with the
merged CI results table and failure details (see
Phase A.5 output format).

---

## Phase A — CI Checks (mandatory)

a. Read CI configuration files to identify the exact
   commands CI runs. Check these locations:
   - `.github/workflows/` (GitHub Actions)
   - `.gitlab-ci.yml` (GitLab CI)
   - `Taskfile.yml` / `.taskfiles/` (Taskfile)
   - `Makefile` (Make)
   - `Justfile` (Just)
   Do not rely on a memorized list — the CI
   configuration files are the source of truth.

b. Execute each CI command locally in the order they
   appear in the configuration (typically: build, lint,
   test, and any coverage or security checks). **Run
   all commands to completion.** Do not stop on first
   failure. Record each command's result (pass/fail)
   and its full output. Use a 5-minute timeout per
   command: `timeout 300 {command}`. If a command
   times out, record it as failed with
   `output: (timed out after 300s)`.

c. **If any command fails**: record all results. CI
   failures are reported as CRITICAL findings with
   the full error output in the final report. **Do
   not stop.** Proceed to causality detection
   (Phase A.5), then Phase B.

d. **If all commands pass**: report success and
   proceed to Phase A.5.

---

## Phase A.5 — CI Causality Detection

For each failing CI check, determine whether the
failure is caused by the PR or pre-existing on the
base branch.

### Method 1 — Forge CI data (preferred)

When `${session_dir}/pr-metadata.txt` contains a
`--- STATUS CHECKS ---` section, read forge CI
results from there. Do not re-query the forge API.
Map conclusions:

```
SUCCESS  -> pass
FAILURE  -> fail
NEUTRAL  -> pass
SKIPPED  -> skipped
PENDING / null -> pending
```

For forge-only checks (no local equivalent), include
them in the results with `source: forge-api`.

For **every** failing check (local or forge-only),
determine causality by fetching the base branch's
check status:

```bash
timeout 30 gh api repos/{owner}/{repo}/commits/{base_ref}/check-runs \
  --jq ".check_runs[] | select(.name == \"{check_name}\") | .conclusion"
```

- Base check passed -> `causality: pr-caused`
- Base check failed -> `causality: pre-existing`
- Base check not found -> `causality: unknown`

### Method 2 — Conservative default

If no forge data is available (no `--- STATUS
CHECKS ---` section in pr-metadata.txt, or no
pr-metadata.txt at all), classify all failures as
`causality: unknown` and treat them as PR-caused
for review purposes.

Do not attempt to determine causality by
manipulating the local worktree (git stash, git
checkout of the base branch, or similar). The
worktree must remain on the PR branch throughout
the review.

### Merge rules

When the same check appears in both local and forge
results, apply these rules:

- **Local ran and passed**: use local result
  (authoritative).
- **Local ran and failed**: use local result with
  causality from forge comparison.
- **Local did not run**: use forge result with
  causality from base branch comparison.

### Output

Write `${session_dir}/ci-causality.txt` with this
format:

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

### Tracking updates

Update `${session_dir}/tracking.md` Quality Gates
phase with:

```
- CI checks run: {count}
- CI checks passed: {count}
- CI checks failed: {count} ({N} pr-caused, {N} pre-existing, {N} unknown)
- CI source: {local|forge|both}
```

---

## Phase B — Quality Tool (conditional)

Check the project's "Review Council Configuration"
section for a "Quality tool" entry.

a. **If a quality tool is configured**: invoke the
   configured agent to produce a quality report.
   Capture the agent's output as the **Quality Report**.

b. **If the quality tool invocation fails**: log the
   failure as a warning, proceed without quality data,
   and note the failure in the tracking file. Do not
   block the review on quality tool failures.

c. **If no quality tool is configured**: skip with an
   informational note:
   > "No quality tool configured — skipping quality
   > analysis."

   Proceed without quality data.
