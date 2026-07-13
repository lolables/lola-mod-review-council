# Phase: Delegation — LLM Judgment Reference

This file guides the orchestrator's prompt construction and dispatch mechanism for reviewer agents.

## Known Persona Roles (Reference Table)

This table provides context when constructing delegation prompts. The **invocation list comes solely from discovery** — not from this table.

Agent files use the naming convention `divisor-{name}-code.md` and `divisor-{name}-spec.md`.

| Base Name           | Persona       | Code Review Focus                               | Spec Review Focus                       |
|---------------------|---------------|-------------------------------------------------|-----------------------------------------|
| `divisor-adversary` | The Adversary | Secrets, CVEs, error handling, injection safety | Completeness, ambiguity, security gaps  |
| `divisor-guard`     | The Guard     | Intent drift, zero-waste, constitution          | Intent fidelity, scope discipline       |
| `divisor-testing`   | The Tester    | Test architecture [PACK], coverage, isolation   | Testability, fixtures, contract surface |
| `divisor-sre`       | The Operator  | Permissions, efficiency, pipeline [PACK]        | Deployment, operational requirements    |
| `divisor-curator`   | The Curator   | Documentation gaps, issue filing                | Documentation completeness in specs     |

For any discovered agent not in this table, use a generic review prompt appropriate to the current mode.

## Dispatch Mechanism

When dispatching reviewer agents, use the discovered agent filename **minus the `.md` extension** as the subagent identifier (e.g., dispatch to `divisor-adversary-code`, not to a generic agent type). This ensures the host loads the agent's persona definition — including calibration rules, severity thresholds, and grounding requirements — as system context for the subagent.

**Do NOT dispatch reviewers as generic or general-purpose agents with an inline prompt.** The persona files contain critical calibration that cannot be reliably reproduced inline.

If the orchestrating tool does not support named subagent dispatch, read the agent's `.md` file from `${AGENTS_DIR}` (e.g., `${AGENTS_DIR}/divisor-adversary-code.md`) and include its full content at the top of the delegation prompt.

## Prompt Discipline

**Do NOT inject investigative questions, leading hints, or speculative prompts** into delegation prompts. The prompt template provides the changeset, diff, focus area, severity calibration, and grounding requirements. That is sufficient.

Adding questions like "What happens when X is nil?" or "Is Y missing?" biases the reviewer toward manufacturing findings for each question. Let the reviewer apply its persona expertise to the code without pre-determining what to find.

## Model Selection Guidance

When the orchestrating tool supports model selection for subagents, use these tiers:

| Tier         | Reasoning Demand                        | Personas                  |
|--------------|-----------------------------------------|---------------------------|
| **Capable**  | Deep judgment, security/intent analysis | Adversary, Guard          |
| **Standard** | Checklist-driven with moderate judgment | Tester, Operator, Curator |

If the tool does not support model selection, all agents run on the default model. For empirical performance data by model class, see `${REFERENCES_DIR}/model-guidance.md`.

---

## Code Review Delegation

### Prompt Template

**Every delegation prompt MUST include** the changeset AND the diff (when available).

**Data sources:** Read the file list from `${session_dir}/changeset.txt` and the diff from `${session_dir}/diff.patch`. Read the scope from `${session_dir}/tracking.md` (the `Scope:` and `Scope value:` fields).

**Scope framing:** Use the scope from tracking.md to frame the review accurately:
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

For each discovered agent, add the focus area from the Persona Roles table (Code Review Focus column).

**Framework-aware detection hints**: read the detected language and framework from `${session_dir}/tracking.md` (recorded in section 4b of the Preparation phase). If a matching row exists in the table below, append the listed hints to the relevant persona's delegation prompt. These are detection focus areas, not leading questions — they tell the agent *what patterns to check for*, not *what to find*.

If the language is `unknown` or no matching row exists, skip this section and rely on the generic Persona Roles focus areas.

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

Hints are additive — they supplement, not replace, the generic focus area. Do NOT frame them as questions (e.g., "What happens if..."). Frame them as check instructions (e.g., "Check for X pattern").

**Convention pack loading**: include this instruction in every delegation prompt:

> Convention packs are at `${REFERENCES_DIR}`. Load packs per the rules in `${REFERENCES_DIR}/reviewer-protocol.md`: always load `${REFERENCES_DIR}/severity.md`, then the language pack (`lang-{language}.md`) or `base.md` if none exists, then the framework pack (`fw-{framework}.md`) if one exists.

**When quality analysis data is available**: append a "Quality Context" section containing the Quality Report summary.

**When prior run context is available**: append a "Prior Run Context" section listing resolved findings from the prior run. Instruct agents not to re-flag these unless the fix introduced a new problem.

**When linked issues are available** (`${session_dir}/linked-issues.txt` exists): append a "Linked Issues" section to each delegation prompt containing the full content of `linked-issues.txt`, followed by:

> When reviewing, consider whether the changes address the acceptance criteria listed above. Note any criteria that appear unaddressed by the changes.

**When prior forge reviews are available** (`${session_dir}/prior-reviews.txt` exists): append a "Prior Reviews" section containing the full content of `prior-reviews.txt`, followed by:

> These reviews were previously submitted on this PR. Do not re-flag issues that have already been raised unless the current changes make them worse or the prior feedback was not addressed.

**When forge CI status is available** (`${session_dir}/ci-status.txt` exists): append a "CI Status" section containing the full content of `ci-status.txt`, followed by:

> These are the CI check results reported by the forge. Failing checks may or may not be caused by the changes under review — use your judgment when assessing relevance to your findings.

For each agent, instruct it to return its verdict (**APPROVE** or **REQUEST CHANGES**) along with all findings. Remind agents that every finding must include an **Evidence** field quoting the actual code or content observed.

**Grounding requirement**: append to every code review delegation prompt:

> When citing line numbers, confirm them by reading the actual file — do not compute line numbers from the diff. When claiming something is absent or not referenced, search for it with `grep -rn` and include the search result in your Evidence field. Only reference identifiers (variable names, file names, targets) you have directly read in source files.

**Severity calibration**: append to every code review delegation prompt:

> Before submitting your verdict, re-read the severity pack definitions. Verify each finding's severity meets the stated boundary for that level. CRITICAL requires immediate concrete harm, not theoretical risk. HIGH requires likely near-term problems, not possible future issues under unlikely conditions.
>
> If the code is clean, idiomatic, well-tested, and well-documented, APPROVE with zero findings is the correct outcome. Do not manufacture findings to justify your review effort. Standard language behavior (nil pointer panics in Go, AttributeError in Python, TypeError in JavaScript) is not a defect.

### Batching

Check the project's "Review Council Configuration" section for a "Batch size" entry. Default: **20** files.

If the changeset exceeds the batch size:

a. Group files by parent directory so related files stay together.
b. Fill batches up to the configured size. If a single directory exceeds the batch size, split it alphabetically.
c. Dispatch each batch as a separate delegation round — all agents review batch 1 in parallel, then batch 2, etc.
d. Merge findings from all batches before proceeding.
e. Write `${session_dir}/batches.txt` listing which files went into which batch.

If the orchestrating tool has native batching or context management, it may use its own mechanism instead.

---

## Spec Review Delegation

### Prompt Template

**Every delegation prompt MUST list the spec artifacts** from `${session_dir}/changeset.txt`:

> ## Review Artifacts
>
> The following spec artifacts are in scope:
>
> ```
> {artifact list, one per line}
> ```
>
> **Read every artifact before producing any findings.** Do not report on files you have not read. See reviewer-protocol.md for evidence discipline rules.

For each discovered agent, add the focus area from the Persona Roles table (Spec Review Focus column).

**Convention pack loading**: include this instruction in every delegation prompt:

> Convention packs are at `${REFERENCES_DIR}`. Load packs per the rules in `${REFERENCES_DIR}/reviewer-protocol.md`: always load `${REFERENCES_DIR}/severity.md`, then the language pack (`lang-{language}.md`) or `base.md` if none exists, then the framework pack (`fw-{framework}.md`) if one exists.

Instruct agents to review the listed spec artifacts (not code), plus the project context and governance documents. Include prior run context if available.

**Grounding requirement**: append to every spec review delegation prompt:

> Only reference identifiers, file names, section headings, and spec fields you have directly read in the artifacts. When claiming a cross-reference is missing or a section is absent, search for it and include the search result in your Evidence field.

**Severity calibration**: append to every spec review delegation prompt:

> Before submitting your verdict, re-read the severity pack definitions. Verify each finding's severity meets the stated boundary for that level.

**When linked issues are available** (`${session_dir}/linked-issues.txt` exists): append a "Linked Issues" section to each delegation prompt containing the full content of `linked-issues.txt`, followed by:

> When reviewing, consider whether the changes address the acceptance criteria listed above. Note any criteria that appear unaddressed by the changes.

**When prior forge reviews are available** (`${session_dir}/prior-reviews.txt` exists): append a "Prior Reviews" section containing the full content of `prior-reviews.txt`, followed by:

> These reviews were previously submitted on this PR. Do not re-flag issues that have already been raised unless the current changes make them worse or the prior feedback was not addressed.

**When forge CI status is available** (`${session_dir}/ci-status.txt` exists): append a "CI Status" section containing the full content of `ci-status.txt`, followed by:

> These are the CI check results reported by the forge. Failing checks may or may not be caused by the changes under review — use your judgment when assessing relevance to your findings.

---

## Verdict Collection

**CRITICAL: Write each agent's RAW output verbatim** to
`${session_dir}/verdicts/{agent-name}.md`. Do NOT summarize,
paraphrase, reformat, or editorialize the agent's response.
The downstream verification script (`rc-verify-evidence.sh`)
parses finding structure from these files — specifically the
`### [SEVERITY] Title`, `**File**:`, and `**Evidence**:` fields.
If you rewrite or summarize the output, the parser cannot extract
findings, and the entire verification pipeline silently degrades
to a rubber stamp with zero findings.

Copy the agent's return value as-is. If it includes a
`Files read:` attestation header, finding blocks, and a verdict
line, all of those must appear in the verdict file unchanged.

**Handling agent failures**:
- If an agent fails to return a valid verdict (neither APPROVE nor REQUEST CHANGES, or crashes/times out), treat as a **warning** and continue collecting from remaining agents.
- If an agent returns REQUEST CHANGES with zero findings, flag as a malformed response.
- If **all** agents fail, **stop immediately** and report:
  > "All reviewer agents failed to return a verdict. This may indicate a configuration issue."
