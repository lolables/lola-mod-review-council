# lola-eval Improvement Notes

Observations from integrating lola-eval with Review Council (2026-05-20).
These are suggestions for the lola-eval framework itself, not this project.

## 1. No built-in commit-comparison workflow

**What:** The baseline/diff tools compare runs within the same config, but
there is no first-class support for "eval at commit A, eval at commit B,
compare." We had to build a Taskfile task that stashes, checks out the
merge-base, runs eval, promotes baseline, checks out HEAD, runs eval again,
and diffs.

**Suggestion:** A `lola-eval compare-ref <ref-a> <ref-b>` command that
automates this. It would need a `pre_run` hook to let the project provision
starters at each ref.

## 2. Starter provisioning is static

**What:** The `starter/` directory is copied as-is by the orchestrator's
`reset.sh`. There is no hook for transforming starters before the agent
runs. We need an external `provision.sh` to copy our module into each
starter before `lola-eval test` runs.

**Suggestion:** Add a `pre_run` field to `task.yaml` (shell command) or a
`provision` phase in the orchestrator. This would run after `reset.sh`
copies the starter but before the agent is spawned.

## 3. No profile for local module install

**What:** Profiles can replace config dirs and copy files, but there is no
directive for "install this local directory as a lola module." This is the
natural provisioning model for testing lola packs/modules in-repo.

**Suggestion:** Add `setup.<target>.install_module: <path>` to the profile
schema. The profile setup phase would call `lola install --local <path>`.

## 4. Judge model aliases risk drift

**What:** The judge config accepts `model: sonnet` (an alias), but aliases
can resolve to different underlying model versions over time. For eval
reproducibility, this means scores can shift between runs without any
change to the eval or the code under test.

**Suggestion:** In regression mode, warn when the judge model is an alias
rather than a pinned model ID. Record the resolved model ID
in runs.db so drift analysis can correlate score changes with model
version changes.

## 5. Fingerprint does not include module version

**What:** The fingerprint is based on `target_cli + pack_id + task_id +
task_version + rubric_version + exec_mode + invocation_style + profile_id`.
When the module under test changes between runs (the whole point of our
eval), the fingerprint stays the same. Drift tracking cannot distinguish
"module changed" from "model behavior changed."

**Suggestion:** Add an optional `module_version` or `subject_version`
field to `task.yaml` that is included in the fingerprint. The provisioning
step could set this automatically from the module's version metadata.

## 6. Bundled promptfoo not on PATH

**What:** The `lola-eval` entry script adds `/opt/lola-eval/lib/node/bin`
to `$PATH`, but the bundled promptfoo binary lives at
`/opt/lola-eval/share/promptfoo/node_modules/.bin/promptfoo` — which is
not on PATH. The runner's `_resolve_promptfoo_cmd()` falls back to
`npx --no-install promptfoo`, which fails with "npx canceled due to
missing packages" since promptfoo isn't installed in the local
`node_modules`.

Doctor passes because it reads `package.json` directly; the runner fails
because it needs the binary on PATH.

**Workaround:** `sudo ln -s /opt/lola-eval/share/promptfoo/node_modules/.bin/promptfoo /opt/lola-eval/lib/node/bin/promptfoo`

**Suggestion:** Either symlink promptfoo into the bundled node bin during
`make install`, or have the runner check
`BUNDLE_ROOT/share/promptfoo/node_modules/.bin/` before falling back to
npx. Doctor should also verify that the binary is actually invocable, not
just that `package.json` exists.

## 7. Mode 1 (pack_id=project) does not install CLI integration

**What:** In Mode 1, `install_pack.sh` exits as a no-op for
`pack_id="project"`, assuming "the project is responsible for its own
provisioning." But the provisioning gap isn't just the module files —
it's the CLI integration. For `claude-code`, the agent needs
`.claude/skills/`, `.claude/commands/`, `.claude/agents/` created by
`lola install`. For `opencode`, it needs `.opencode/` equivalents.

Without these, the agent sees the module in `.lola/modules/` but cannot
invoke `/review-council` because the CLI doesn't discover the skill.
claude-code's clean room config (`CLAUDE_CONFIG_DIR` → temp dir) doesn't
affect project-level `.claude/`, but the files must exist in the first
place.

**Observed failure:** claude-code agent tried to invoke
`/review-council`, got "Unknown skill", then spent 452s (126 tool calls)
exploring files without producing a review.

**Workaround:** provision.sh runs `lola mod add` to register the module,
then `lola install review-council -a <target> --scope project` in each
starter directory.

**Suggestion:** The Mode 1 documentation should explicitly state that
`lola install` is a prerequisite and not handled by the orchestrator.
Alternatively, `install_pack.sh` could detect a `.lola/modules/`
directory in the workdir and auto-run `lola install` for `project`
pack_id instead of no-oping.

## 8. Judge truncates transcript to 50K chars — misses verdicts

**What:** `judge_client._build_prompt()` truncates the transcript at
50,000 characters (`transcript[:50_000]`). For multi-agent workflows
like Review Council, transcripts commonly exceed 400K–700K characters
because they include sub-agent conversations. The final verdict and
findings appear at the END of the transcript, well beyond the 50K
window.

**Observed failure:** Across 4 runs, the judge consistently reported
"the review was never completed" or "agent was still in the preparation
phase" — despite the agent completing full reviews (91–134 tool calls,
528–561s runtime, clear VERDICT + FINDINGS blocks in the transcript).
The judge literally cannot see the agent's output.

**Why this matters:** This is the single highest-impact issue in
lola-eval for multi-agent workflows. It makes the entire judging
pipeline produce garbage results — not just inaccurate scores, but
inverted conclusions. An agent that successfully completes its task
scores the same as one that fails entirely, because the judge can
only see the preamble.

**Why `followup_messages` doesn't help:** We tried adding
`followup_messages` to task.yaml to emit a structured summary. The
followup response is appended to the transcript *after* the main run,
making the transcript even longer (698KB). The judge's 50K window
still only sees the beginning. The summary ends up at byte 698K.

**Workaround we applied:** In our local `trajectory_judge.py`, we
pre-truncate the transcript using head(10K) + tail(40K) before passing
to the judge. This lets the judge see both setup context and the
conclusion. The judge now correctly evaluates the agent's output. But
this is a lossy workaround — 93% of the transcript is discarded, and
the judge has no visibility into what happened in the middle (which
agents were dispatched, what evidence they found, how findings were
verified).

**Recommended fix:** Size the truncation limit to the judge model's
context window instead of using a fixed 50K char limit. Modern models
handle large contexts natively:

- Claude Sonnet handles 200K tokens (~800K chars)
- Claude Opus handles 200K tokens
- GPT-4o handles 128K tokens

A 700K char transcript is ~175K tokens — it fits in Sonnet's context
window with room for the rubric, diff, and judge reasoning. The judge
already sees the full rubric and diff; the transcript is the only
input that gets truncated, and it's the most important one.

```python
# In judge_client.py — replace the hardcoded 50_000
MODEL_CONTEXT_LIMITS = {
    "sonnet": 800_000,    # 200K tokens ≈ 800K chars
    "opus": 800_000,
    "haiku": 800_000,
    "gpt-4o": 500_000,    # 128K tokens ≈ 500K chars
}

def _transcript_limit(judge_model: str) -> int:
    for key, limit in MODEL_CONTEXT_LIMITS.items():
        if key in judge_model.lower():
            # Reserve 20% for rubric + diff + judge reasoning
            return int(limit * 0.8)
    return 50_000  # conservative fallback for unknown models
```

**Why this is the best approach:**
- The judge sees the full trajectory, including intermediate agent
  interactions, evidence gathering, and reasoning chains. This is
  critical for rubrics that evaluate process quality, not just output.
- No information loss — the judge can assess trajectory quality,
  false positive reasoning, and evidence fidelity.
- Minimal code change (one function + one call site).
- Backward-compatible: unknown models fall back to the current 50K.
- Cost impact is small: judge calls are ~$0.10–0.30 even with full
  transcripts, vs $2.67+ per agent run. The judge is <10% of total
  eval cost.

**If cost is a concern**, a configurable `judge_transcript_limit` in
`task.yaml` would let eval authors choose the tradeoff per-task. But
the default should be the model's context window, not 50K.

**Fallback approaches (if increasing the limit is rejected):**
1. Head+tail truncation (what we use as a workaround): head(10K) +
   tail(40K). Loses the middle but preserves setup + conclusion.
2. Structured output extraction: parse the transcript for verdict,
   findings, and evidence before passing to the judge. Requires
   format knowledge and is fragile to agent output variations.
3. Two-pass judge: first pass summarizes the full transcript, second
   pass evaluates the summary + rubric. Higher cost and complexity,
   but preserves information without relying on the model's context
   window.

## 9. `lola install` is slow for multi-case provisioning

**What:** When provisioning N test cases for M targets, `lola install`
runs N×M times sequentially. Each invocation takes 15-30 seconds
(Python startup + file copy + symlink creation). For 6 cases × 2
targets = 12 invocations, provisioning takes 3-6 minutes.

**Root cause:** `lola install` is designed for interactive use, not
batch provisioning. It re-parses the module registry and re-reads
the module manifest on every call.

**Observed failure:** On I/O-constrained systems (NFS, network-mounted
storage, or slow disk), `lola install` Python processes enter D state
(uninterruptible sleep) and stall indefinitely. Two concurrent installs
hung for 10+ minutes without producing output, requiring manual kill.

**Workaround:** provision.sh now copies agents/, commands/, and skills/
directly from the module source into .claude/ and .opencode/ per starter,
bypassing `lola install` entirely. Provisioning dropped from 3-6 minutes
to under 1 second.

**Suggestion:** Either:
1. Add a batch mode to `lola install` (`lola install mod -a cli1 -a cli2 --targets dir1 dir2 ...`)
2. Or provide a lightweight `lola scaffold` that just copies files
   without the full module resolution machinery
3. Or make the provisioning script copy `.claude/` and `.opencode/`
   directly instead of going through `lola install` (since the
   output files are deterministic for a given module version)
4. Or fix the I/O behavior so `lola install` doesn't stall on slow
   storage

## 10. No transcript diffing

**What:** `lola-eval baseline diff` compares scores (composite, per-criterion)
but there is no way to see what changed in the agent's behavior — which
findings appeared or disappeared, which evidence was added or removed, how
the trajectory differed.

**Suggestion:** A `lola-eval transcript-diff <run-a> <run-b>` command that
extracts structured outputs (findings, verdict, evidence) from transcripts
and produces a semantic diff. This would be far more actionable than score
deltas alone when investigating regressions.

## 11. opencode provider model resolution passes alias, not resolved model

**What:** The opencode provider's `resolveModel()` correctly resolves
the alias `sonnet` to `google-vertex/claude-sonnet-4-6@default`, and
`opencode run -m google-vertex/claude-sonnet-4-6@default` works
interactively. However, when invoked through the provider's clean room
environment (with `OPENCODE_CONFIG_DIR` set to a temp dir), opencode
reports `"Model not found: sonnet/."` and exits with code 1.

**Observed failure:** Intermittent. In some runs, opencode/sonnet
scores 0.00 (target_error) with 0 tool calls and 48s duration, with
errors `"Model not found: sonnet/."` and `"Unexpected server error."`.
In other runs (same config, same case), opencode resolves the model
successfully and completes the review. The intermittency suggests a
race condition or state-dependent behavior in opencode's model
resolution path.

**Root cause hypothesis:** The opencode clean room config
(`opencode.jsonc`) may lack a required `models` or `provider`
configuration that the user's normal config provides. Without it,
opencode falls back to a different model resolution path that
misinterprets the resolved model string. The intermittency may be
related to opencode caching model lists across invocations.

**Suggestion:** The opencode provider should log the full command
line and environment it passes to `opencode run` when the agent
exits with an error, making diagnosis easier. The clean room config
should also include the minimal provider/model configuration needed
for the target model to be found.

## 12. Judge subprocess timeout too short for large transcripts

**What:** The judge subprocess (`judge_client.judge()`) has a
`DEFAULT_TIMEOUT_S = 120`. When the judge receives a 50K-character
truncated transcript (the current limit) plus a multi-criterion rubric,
the judge model needs to read the transcript, reason through each rubric
criterion, produce scores and explanations, and return structured JSON.
For complex multi-agent transcripts, 120 seconds is insufficient —
especially when the judge CLI is `claude-code`, which has its own startup
overhead (config loading, permission checks, model initialization).

**Observed failure:** In case-005-py-meta, the opencode/sonnet row
completed successfully (51 tool calls, 344KB transcript, $1.08) but the
judge timed out at 120s with `judge timeout after 120s`. The claude-code
row for the same case judged successfully in a similar timeframe, so the
timeout is marginal — sometimes it finishes, sometimes it doesn't.

**Why this matters:** A judge timeout produces `exit_status=judge_error`
and `composite=0.0`, which is indistinguishable from a genuinely failed
agent in aggregate statistics. The agent did its job; the eval
infrastructure failed to evaluate it. This inflates false-negative rates
in regression tracking.

**Suggestion:** Scale `DEFAULT_TIMEOUT_S` based on the transcript size
being sent to the judge. A 50K-char transcript with a 6-criterion rubric
should have at least 300s. If #8 is fixed (transcript limit scaled to
model context window), the timeout should scale proportionally:

```python
def _judge_timeout(transcript_len: int, base: int = 120) -> int:
    # ~2s per 1000 chars for the judge to process, minimum 120s
    return max(base, transcript_len // 500)
```

Alternatively, make the timeout configurable in `task.yaml` as
`judge_timeout_seconds` (separate from the existing `timeout_seconds`
which controls the agent, and `judge_timeout_seconds` in
`trajectory_judge.py` which controls the fan-out wall clock, not the
per-judge subprocess).

## 13. `reset.sh` does not propagate `.gitignore` into workdirs

**What:** `reset.sh` copies the starter into a fresh workdir, then runs
`git init` + `git add -A` + `git commit` to create a baseline commit for
post-run diffing. If the starter lacks a `.gitignore`, the subsequent
`git diff --no-color HEAD` (in `orchestrator.py:349`) captures every
file the agent creates — including build artifacts like `node_modules/`,
`dist/`, `__pycache__/`, `vendor/`, etc.

**Observed failure:** In case-006-ts-pack, the opencode agent ran
`npm install`, creating `node_modules/`. The workdir diff captured the
entire dependency tree: 28.5MB stored in `runs.db` as a single
`workdir_diff` TEXT value. This inflated the database from ~24KB of
actual eval data to 28MB. Over repeated runs the DB would grow by tens
of megabytes per TypeScript eval.

**Why this matters beyond storage:** The oversized diff is also sent to
the judge as part of the evaluation context. A 28MB diff dominates the
judge's context window and crowds out the transcript and rubric, even
with truncation. The diff should reflect intentional code changes, not
build artifacts.

**Workaround:** Add language-appropriate `.gitignore` files to each
starter directory. Since `reset.sh` copies the starter as-is before
`git add -A`, the `.gitignore` is in place and git respects it.

**Suggestion:** `reset.sh` should inject a minimal default `.gitignore`
into every workdir before `git add -A`, covering the most common build
artifact patterns across languages:

```bash
# In reset.sh, after cp -a but before git init:
cat >> "$workdir/.gitignore" <<'IGNORE'
node_modules/
__pycache__/
*.pyc
dist/
vendor/
*.egg-info/
.venv/
*.exe
*.test
*.out
.tsbuildinfo
IGNORE
```

This is a safety net — starters can still ship their own `.gitignore`
for project-specific patterns. The appended defaults just ensure that
universal build artifacts never leak into the diff even when the starter
author forgets.

## 14. No git provenance in runs.db or reports

**What:** The `runs` table schema has no columns for the commit SHA,
branch, repo URL, or module version of the code under test. The
report generator (`markdown_report.py`, `build_json()`) inherits
this gap — reports show *how* the agent performed but not *what
code* it was evaluating.

**Why this matters:** Without provenance, eval results are
unanchored. You cannot:
- Correlate a score regression to a specific commit
- Compare eval results across branches in a PR review
- Reproduce a run (you know the config but not the code state)
- Answer "when did this case start failing?" without cross-
  referencing git log timestamps manually

For regression tracking, provenance is the join key between "what
changed" and "how scores moved." Without it, drift analysis floats
in a vacuum.

**Workaround:** We built `.lola-eval/snapshot.sh` that captures
git metadata externally and writes it alongside the eval results
into an append-only JSONL ledger. This works but duplicates data
the framework should own.

**Suggestion:** Add optional provenance columns to `runs`:

```sql
ALTER TABLE runs ADD COLUMN git_sha      TEXT;
ALTER TABLE runs ADD COLUMN git_branch   TEXT;
ALTER TABLE runs ADD COLUMN git_remote   TEXT;
ALTER TABLE runs ADD COLUMN subject_version TEXT;
```

Populate them in `trajectory_judge.py._persist()` from environment
variables set by the runner:

```python
"git_sha": os.environ.get("LOLA_GIT_SHA"),
"git_branch": os.environ.get("LOLA_GIT_BRANCH"),
"git_remote": os.environ.get("LOLA_GIT_REMOTE"),
"subject_version": os.environ.get("LOLA_SUBJECT_VERSION"),
```

The runner already has access to the workdir — it can capture
`git rev-parse HEAD` alongside the existing `git diff HEAD` and
set these env vars before spawning the agent. The report generator
then includes a "Provenance" section when these fields are present.

This pairs naturally with #5 (fingerprint should include module
version): `subject_version` would serve both the provenance record
and the fingerprint input.

## 15. No historical export from CLI

**What:** `lola-eval report --format json` only exports the last
run (it reads `last-run.json` to find which rows to include). There
is no command to export all runs, a date range, or a specific
fingerprint's history from `runs.db`.

**Why this matters:** The DB is the only source of historical data,
but it is a binary SQLite file that should remain gitignored (it
contains large `workdir_diff` blobs and machine-local transcript
paths). Without an export command, accessing history requires
direct SQLite queries — which means knowing the schema, installing
a SQLite client, and writing ad-hoc SQL.

**Observed need:** To backfill a JSONL ledger with all 18 historical
runs, we had to write a 30-line `sqlite3 -json` + `jq` pipeline.
This is the kind of operation that should be a single CLI command.

**Suggestion:** Add `lola-eval export` with filtering options:

```
lola-eval export                          # all runs
lola-eval export --task case-001          # filter by task
lola-eval export --since 2026-05-20      # date range
lola-eval export --fingerprint abc123    # specific cell history
lola-eval export --format csv            # CSV for spreadsheets
```

The default JSON output should match `report --format json` but
include all matching rows, not just the last run. Exclude
`workdir_diff` and `transcript_path` by default (add
`--include-diff` / `--include-paths` flags for the rare case
where they are needed).
