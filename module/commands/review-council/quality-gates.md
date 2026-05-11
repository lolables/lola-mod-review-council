# Phase: Quality Gates

Run local CI checks and optional quality analysis
before delegating to reviewer agents.

**This phase applies only to Code Review Mode.**
Spec Review Mode skips this phase entirely.

## Inputs

- Project CI configuration files
- "Review Council Configuration" section (for quality
  tool)

## Outputs

Update `${session_dir}/tracking.md` Phase: Quality
Gates with: CI result, CI failures (if any), quality
tool status, quality report summary.

---

## Phase A — CI Checks (mandatory, hard gate)

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
   test, and any coverage or security checks).

c. **If any command fails**: **STOP immediately.**
   Report each failure as a CRITICAL finding with the
   full error output. Do NOT proceed to Phase B or to
   delegation. The rationale: reviewing code that
   doesn't compile or pass tests is wasted work.

d. **If all commands pass**: report success and proceed
   to Phase B.

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
