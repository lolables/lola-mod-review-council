# Phase: Preparation

Determine the review mode, discover agents, set up the
session, and capture the changeset.

## Inputs

- `$ARGUMENTS` from the user command invocation
- Project workspace (git repository)

## Outputs

Write to `${session_dir}`:
- `session.txt` — human-readable session metadata
- `changeset.txt` — one file per line
- `diff.patch` — full patch (Code Review Mode only)

Update `${session_dir}/tracking.md` Phase: Preparation
with: mode, branch, base, agents discovered, agents
absent, changeset size, prior run ID (if any).

---

## 1. Determine Review Mode

### Explicit Override

If `$ARGUMENTS` contains the word **"specs"**, use
**Spec Review Mode** regardless of auto-detection.

If `$ARGUMENTS` contains the word **"code"**, use
**Code Review Mode** regardless of auto-detection.

### Auto-Detection (when no explicit override)

When no mode keyword is provided, detect the mode by
examining the current branch and workspace:

1. **Get the current branch name**:
   ```bash
   git rev-parse --abbrev-ref HEAD
   ```

2. **Guard: verify this is a git repository**:
   ```bash
   git rev-parse HEAD
   ```
   If this command fails (non-zero exit code), **stop
   immediately** and report:
   > "This does not appear to be a git repository.
   > Please specify the review mode explicitly:
   > `/review-council code` or `/review-council specs`."

3. **Get the diff against the base branch**:

   First try `main`:
   ```bash
   git diff --name-only main...HEAD
   ```
   If `main` does not exist (command exits non-zero),
   try `master`:
   ```bash
   git diff --name-only master...HEAD
   ```
   If neither branch exists, **stop immediately** and
   report:
   > "Cannot determine base branch (`main` and `master`
   > both not found). Please specify the review mode
   > explicitly: `/review-council code` or
   > `/review-council specs`."

   Use whichever base branch succeeded for the rest of
   the auto-detection steps.

4. **Classify the changed files**:
   - **Spec files**: paths under `specs/`, `docs/specs/`,
     `docs/design/`, `docs/superpowers/`, `design/`, or
     files named `spec.md`, `plan.md`, `tasks.md`,
     `design.md`, `research.md`
   - **Code files**: everything else (source code, config,
     build files, agent files, etc.)

5. **Select mode based on classification**:

   | Condition | Mode | Rationale |
   |-----------|------|-----------|
   | Code files changed | **Code Review** | Post-implementation — review the code |
   | Only spec files changed | **Spec Review** | Pre-implementation — review the specs |
   | No files changed vs base | **Spec Review** | On base or fresh branch — review specs |

6. **Announce the detected mode**: Always tell the user
   which mode was selected and why.

---

## 2. Discover Available Reviewers

1. **List mode-specific agent files** in the agents
   directory. Use a file listing or glob pattern
   matching `divisor-*-{mode}.md` where `{mode}` is
   `code` or `spec` based on the determined review
   mode.

2. **Extract agent names**: for each discovered file,
   strip the `-{mode}.md` suffix to get the base
   persona name (e.g., `divisor-adversary-code.md`
   → `divisor-adversary`).

3. **Guard clause**: if zero reviewer agents are
   found, report to the user and stop.

4. **Note absent personas**: compare discovered
   agents against the Known Persona Roles table in
   `delegate.md`. Any known role not discovered is
   noted as absent (informational only — does not
   block the review).

---

## 3. Session Setup

### Cache Directory

```bash
project_id=$(pwd | sha256sum | head -c 12)
run_id=$(date +%Y%m%d-%H%M%S)
session_dir="${XDG_CACHE_HOME:-$HOME/.cache}/review-council/${project_id}/${run_id}"
mkdir -p "${session_dir}/verdicts"
```

**Announce the session directory to the user
immediately after creation:**

> "Review session: `{session_dir}`"

### Session Metadata

Write a human-readable `session.txt` to the session
directory:

```
Review Council Session
======================
Project:   {absolute path to working directory}
Branch:    {current branch name}
Base:      {base branch (main or master)}
Mode:      {Code Review or Spec Review}
Started:   {ISO 8601 timestamp}
Agents:    {comma-separated list of discovered agents}
```

### Initialize Tracking File

Write `${session_dir}/tracking.md` with the initial
state. See the coordinator (`review-council.md`) for
the tracking file format.

---

## 4. Capture Changeset

### Code Review Mode

a. Run `git diff --name-only {base}...HEAD` to get the
   authoritative file list. If auto-detection already
   produced this list, reuse it. Also include any
   uncommitted changes to tracked files
   (`git diff --name-only`).

b. Run `git diff {base}...HEAD` (without `--name-only`)
   to capture the full patch. Also append any
   uncommitted changes (`git diff`).

c. Write the file list to
   `${session_dir}/changeset.txt` (one per line).
   Write the full patch to
   `${session_dir}/diff.patch`.

If the changeset is empty (no changed files), report
to the user and stop — there is nothing to review.

### Spec Review Mode

Scan these common locations for spec artifacts:

- `specs/` — feature specifications
- `docs/specs/` — spec documents under docs
- `docs/design/` — design documents under docs
- `docs/superpowers/` — design specs and plans from superpowers workflows
- `design/` — design artifacts

**Do NOT read** files that appear to contain
credentials, private keys, or environment-specific
configuration.

Write the artifact list to
`${session_dir}/changeset.txt` (one per line).

---

## 5. Prior Run Awareness

Check for previous runs on the same project and branch:

```bash
ls -t "${XDG_CACHE_HOME:-$HOME/.cache}/review-council/${project_id}/"
```

If a previous run exists for the **same branch**
(check `session.txt` in each run directory):

1. Read the previous run's `verification.txt` to
   identify findings that were already addressed.
2. Save the prior run context for use in delegation
   (the delegate phase includes it in agent prompts).
3. If the previous run has unresolved findings,
   note them as carry-forward items.

If no prior run exists, skip this step.
