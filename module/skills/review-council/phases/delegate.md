# Phase: Delegation — LLM Judgment Reference

Guides orchestrator prompt construction and dispatch for reviewer agents.

## Known Persona Roles (Reference Table)

Context for delegation prompts. **Invocation list comes solely from discovery** — not this table.

Agent files follow naming convention `divisor-{name}-code.md` and `divisor-{name}-spec.md`.

| Base Name           | Persona       | Code Review Focus                               | Spec Review Focus                       |
|---------------------|---------------|-------------------------------------------------|-----------------------------------------|
| `divisor-adversary` | The Adversary | Secrets, CVEs, error handling, injection safety | Completeness, ambiguity, security gaps  |
| `divisor-guard`     | The Guard     | Intent drift, zero-waste, constitution          | Intent fidelity, scope discipline       |
| `divisor-testing`   | The Tester    | Test architecture [PACK], coverage, isolation   | Testability, fixtures, contract surface |
| `divisor-sre`       | The Operator  | Permissions, efficiency, pipeline [PACK]        | Deployment, operational requirements    |
| `divisor-curator`   | The Curator   | Documentation gaps, issue filing                | Documentation completeness in specs     |

For discovered agents not in this table, use generic review prompt matching current mode.

## Dispatch Mechanism

Use discovered agent filename **minus `.md` extension** as subagent identifier (e.g., dispatch to `divisor-adversary-code`, not generic agent type). Ensures host loads persona definition — calibration rules, severity thresholds, grounding requirements — as system context.

**Do NOT dispatch reviewers as generic agents with inline prompt.** Persona files contain critical calibration not reliably reproduced inline.

If orchestrating tool lacks named subagent dispatch, read agent `.md` file from `${AGENTS_DIR}` (e.g., `${AGENTS_DIR}/divisor-adversary-code.md`) and include full content at top of delegation prompt.

## Prompt Discipline

**Do NOT inject investigative questions, leading hints, or speculative prompts** into delegation prompts. Template provides changeset, diff, focus area, severity calibration, grounding requirements. Sufficient.

Questions like "What happens when X is nil?" bias reviewer toward manufacturing findings. Let reviewer apply persona expertise without pre-determining what to find.

## Model Selection Guidance

When orchestrating tool supports model selection for subagents, use these tiers:

| Tier         | Reasoning Demand                        | Personas                  | Temperature |
|--------------|-----------------------------------------|---------------------------|-------------|
| **Capable**  | Deep judgment, security/intent analysis | Adversary, Guard          | 0.1         |
| **Standard** | Checklist-driven with moderate judgment | Tester, Operator, Curator | 0.1 – 0.2  |

Temperature controls output determinism (lower = more focused). Set if
hosting tool supports it; omit if not — agents produce usable output at
any temperature. Curator uses 0.2 (slightly higher creativity for
content opportunity identification); all others use 0.1.

If tool lacks model selection, all agents run on default model. Empirical performance data by model class in `${REFERENCES_DIR}/model-guidance.md`.

---

## Code Review Delegation

### Prompt Template

**Every delegation prompt MUST include** changeset AND diff (when available).

**Data sources:** Read file list from `${session_dir}/changeset.txt`, diff from `${session_dir}/diff.patch`. Read scope from `${session_dir}/tracking.md` (`Scope:` and `Scope value:` fields). Read `Effort:` field from tracking.md to determine delegation mode.

**Scope framing:** Use scope from tracking.md to frame review accurately:
- If scope is `changed`: "The following files changed on branch `{branch}` vs `{base}`:"
- If scope is `range`: "The following files changed in `{scope_value}`:"
- If scope is `all`: "The following project files are in scope for review:"
- If scope is `pr`: "The following files changed in PR #{scope_value}:"
- For any scope, if a path filter was applied: append "filtered to `{scope_dir}`"

> ## Changeset
>
> {scope framing sentence from above}
>
> ```
> {file list from ${session_dir}/changeset.txt, one per line}
> ```
>
> ## Diff
>
> ```diff
> {diff from ${session_dir}/diff.patch — if the file is empty, state "No diff available. Read the files directly for review."}
> ```
>
> The diff shows exactly what changed. Read every file in the changeset for full context, but focus your analysis on the lines that changed. If no diff is available (e.g., `--scope all`), read every file in the changeset directly.
>
> **Read every file in this changeset before producing any findings.** Do not report on files you have not read. See reviewer-protocol.md for evidence discipline rules.

For each discovered agent, add focus area from Persona Roles table (Code Review Focus column).

**Framework-aware detection hints**: read detected language and framework from `${session_dir}/tracking.md` (recorded in section 4b of Preparation phase). If matching row exists below, append listed hints to relevant persona's delegation prompt. Detection focus areas, not leading questions — tell agent *what patterns to check for*, not *what to find*.

If language is `unknown` or no matching row exists, skip this section. Rely on generic Persona Roles focus areas.

| Language/Framework   | Persona   | Detection Hints                                                                                                                                                                            |
|----------------------|-----------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| **Go**               | Adversary | Check for `sql.Query`/`sql.Exec` with string interpolation (SQL injection); `exec.Command` with user-controlled arguments (command injection); hardcoded credentials in source             |
| **Go**               | Guard     | Check for interface pollution (interfaces with >5 methods or single-implementation interfaces); package-level mutable globals; circular package dependencies                               |
| **Go**               | Tester    | Check for missing error-path tests; table-driven tests that only check the happy path; test helpers that swallow errors                                                                    |
| **TypeScript/React** | Guard     | Check for prop drilling (props passed through 3+ component levels unchanged); god components (>200 lines or >5 state hooks with mixed concerns); circular module imports                   |
| **TypeScript/React** | Adversary | Check for `dangerouslySetInnerHTML` with unsanitized input; missing error boundary components (crash propagation risk); inline event handlers with user data; missing CSRF tokens on forms |
| **TypeScript/React** | Tester    | Check for tests that mock everything (no integration coverage); missing accessibility attribute tests                                                                                      |
| **TypeScript**       | Guard     | Check for `any` type usage; missing strict mode; barrel export cycles                                                                                                                      |
| **Python**           | Adversary | Check for `eval()`/`exec()` with user input; `pickle.loads()` on untrusted data; `subprocess.call(shell=True)` with string formatting; hardcoded secrets                                   |
| **Python**           | Guard     | Check for circular imports; mutable default arguments; missing `__init__.py` exports; god modules (>500 lines)                                                                             |
| **Python**           | Tester    | Check for `assert True` tautologies; broad `except: pass` in test setup; missing edge-case tests for off-by-one errors                                                                     |
| **Rust**             | Adversary | Check for `unsafe` blocks without safety comments; unchecked `.unwrap()` on user input; raw pointer arithmetic                                                                             |
| **Rust**             | Guard     | Check for unnecessary `clone()` calls; overly broad trait bounds; modules with >500 lines                                                                                                  |
| **Java**             | Adversary | Check for SQL injection via string concatenation in JDBC; deserialization of untrusted data; hardcoded credentials                                                                         |
| **Java**             | Guard     | Check for god classes (>500 lines); deep inheritance hierarchies (>3 levels); package-level circular dependencies                                                                          |

Hints are additive — supplement, not replace, generic focus area. Do NOT frame as questions (e.g., "What happens if..."). Frame as check instructions (e.g., "Check for X pattern").

**Convention pack loading**: include in every delegation prompt:

> Convention packs are at `${REFERENCES_DIR}`. Load packs per the rules in `${REFERENCES_DIR}/reviewer-protocol.md`: always load `${REFERENCES_DIR}/severity.md`, then the language pack (`lang-{language}.md`) or `base.md` if none exists, then the framework pack (`fw-{framework}.md`) if one exists.

**When quality analysis data available**: append "Quality Context" section with Quality Report summary.

**When prior run context available**: append "Prior Run Context" section listing resolved findings from prior run. Instruct agents not to re-flag unless fix introduced new problem.

**When linked issues available** (`${session_dir}/linked-issues.txt` exists): append "Linked Issues" section to each delegation prompt with full content of `linked-issues.txt`, followed by:

> When reviewing, consider whether the changes address the acceptance criteria listed above. Note any criteria that appear unaddressed by the changes.

**When prior forge reviews available** (`${session_dir}/prior-reviews.txt` exists): append "Prior Reviews" section with full content of `prior-reviews.txt`, followed by:

> These reviews were previously submitted on this PR. Do not re-flag issues that have already been raised unless the current changes make them worse or the prior feedback was not addressed.

**When forge CI status available** (`${session_dir}/ci-status.txt` exists): append "CI Status" section with full content of `ci-status.txt`, followed by:

> These are the CI check results reported by the forge. Failing checks may or may not be caused by the changes under review — use your judgment when assessing relevance to your findings.

For each agent, instruct to return verdict (**APPROVE** or **REQUEST CHANGES**) with all findings. Every finding must include **Evidence** field quoting actual code or content observed.

**Grounding requirement**: append to every code review delegation prompt:

> When citing line numbers, confirm them by reading the actual file — do not compute line numbers from the diff. When claiming something is absent or not referenced, search for it with `grep -rn` and include the search result in your Evidence field. Only reference identifiers (variable names, file names, targets) you have directly read in source files.

**Severity calibration**: append to every code review delegation prompt:

> Before submitting your verdict, re-read the severity pack definitions. Verify each finding's severity meets the stated boundary for that level. CRITICAL requires immediate concrete harm, not theoretical risk. HIGH requires likely near-term problems, not possible future issues under unlikely conditions.
>
> If the code is clean, idiomatic, well-tested, and well-documented, APPROVE with zero findings is the correct outcome. Do not manufacture findings to justify your review effort. Standard language behavior (nil pointer panics in Go, AttributeError in Python, TypeError in JavaScript) is not a defect.

### Batching

Check project's "Review Council Configuration" for "Batch size" entry. Default: **20** files.

If changeset exceeds batch size:

a. Group files by parent directory so related files stay together.
b. Fill batches up to configured size. Single directory exceeds batch size, split alphabetically.
c. Dispatch each batch as separate delegation round — all agents review batch 1 in parallel, then batch 2, etc.
d. Merge findings from all batches before proceeding.
e. Write `${session_dir}/batches.txt` listing which files went into which batch.

If orchestrating tool has native batching or context management, may use its own mechanism instead.

### Deep Mode — Per-Subsystem Delegation

**When effort is `deep` and `${session_dir}/subsystems.json` exists:**

Instead of delegating over whole changeset, run one delegation
round per subsystem:

1. Read `${session_dir}/subsystems.json`.
2. For each subsystem:
   a. Filter `changeset.txt` to only the subsystem's files.
   b. Filter `diff.patch` to only the hunks for the subsystem's files.
   c. Replace the scope framing sentence with:
      > "The following files belong to the **{subsystem name}** subsystem ({subsystem description}):"
   d. Dispatch all 5 personas for this subsystem in parallel.
   e. Write verdicts to `${session_dir}/verdicts/{subsystem-name}/{agent-name}.md`.
      Create the subsystem subdirectory first: `mkdir -p ${session_dir}/verdicts/{subsystem-name}`.
3. After all subsystems complete, proceed to verification.

**Batching within subsystems:** If subsystem's file count exceeds
batch size, apply same batching rules within that subsystem.

**Cross-cutting files** (files in multiple subsystems) included in
each subsystem's delegation round. Each agent reviews file in
context of that subsystem's concern.

---

## Spec Review Delegation

### Prompt Template

**Every delegation prompt MUST list spec artifacts** from `${session_dir}/changeset.txt`:

> ## Review Artifacts
>
> The following spec artifacts are in scope:
>
> ```
> {artifact list, one per line}
> ```
>
> **Read every artifact before producing any findings.** Do not report on files you have not read. See reviewer-protocol.md for evidence discipline rules.

For each discovered agent, add focus area from Persona Roles table (Spec Review Focus column).

**Convention pack loading**: include in every delegation prompt:

> Convention packs are at `${REFERENCES_DIR}`. Load packs per the rules in `${REFERENCES_DIR}/reviewer-protocol.md`: always load `${REFERENCES_DIR}/severity.md`, then the language pack (`lang-{language}.md`) or `base.md` if none exists, then the framework pack (`fw-{framework}.md`) if one exists.

Instruct agents to review listed spec artifacts (not code), plus project context and governance documents. Include prior run context if available.

**Grounding requirement**: append to every spec review delegation prompt:

> Only reference identifiers, file names, section headings, and spec fields you have directly read in the artifacts. When claiming a cross-reference is missing or a section is absent, search for it and include the search result in your Evidence field.

**Severity calibration**: append to every spec review delegation prompt:

> Before submitting your verdict, re-read the severity pack definitions. Verify each finding's severity meets the stated boundary for that level.

**When linked issues available** (`${session_dir}/linked-issues.txt` exists): append "Linked Issues" section to each delegation prompt with full content of `linked-issues.txt`, followed by:

> When reviewing, consider whether the changes address the acceptance criteria listed above. Note any criteria that appear unaddressed by the changes.

**When prior forge reviews available** (`${session_dir}/prior-reviews.txt` exists): append "Prior Reviews" section with full content of `prior-reviews.txt`, followed by:

> These reviews were previously submitted on this PR. Do not re-flag issues that have already been raised unless the current changes make them worse or the prior feedback was not addressed.

**When forge CI status available** (`${session_dir}/ci-status.txt` exists): append "CI Status" section with full content of `ci-status.txt`, followed by:

> These are the CI check results reported by the forge. Failing checks may or may not be caused by the changes under review — use your judgment when assessing relevance to your findings.

---

## Verdict Collection

**CRITICAL: Write each agent's RAW output verbatim** to
`${session_dir}/verdicts/{agent-name}.md`. Do NOT summarize,
paraphrase, reformat, or editorialize agent's response.
Downstream verification script (`rc-verify-evidence.sh`)
parses finding structure from these files — specifically
`### [SEVERITY] Title`, `**File**:`, and `**Evidence**:` fields.
Rewriting or summarizing output means parser cannot extract
findings, verification pipeline silently degrades to rubber
stamp with zero findings.

Copy agent's return value as-is. If it includes
`Files read:` attestation header, finding blocks, and verdict
line, all must appear in verdict file unchanged.

**Deep mode paths:** When effort is `deep`, write verdicts to
`${session_dir}/verdicts/{subsystem-name}/{agent-name}.md` instead
of `${session_dir}/verdicts/{agent-name}.md`. Subsystem name
matches `name` field from `subsystems.json`.

**Handling agent failures**:
- Agent fails to return valid verdict (neither APPROVE nor REQUEST CHANGES, or crashes/times out): treat as **warning**, continue collecting from remaining agents.
- Agent returns REQUEST CHANGES with zero findings: flag as malformed response.
- **All** agents fail: **stop immediately** and report:
  > "All reviewer agents failed to return a verdict. This may indicate a configuration issue."
