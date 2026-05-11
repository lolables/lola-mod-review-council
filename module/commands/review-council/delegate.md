# Phase: Delegation

Construct prompts, apply batching, dispatch reviewer
agents, and collect verdicts.

## Inputs

- `${session_dir}/changeset.txt` — file list
- `${session_dir}/diff.patch` — full patch (Code Review)
- Discovered agents list (from preparation phase)
- Quality Report (if available, from quality gates)
- Prior Run Context (if available, from preparation)

## Outputs

Write to `${session_dir}`:
- `verdicts/{agent-name}.md` — one per agent
- `batches.txt` — batch assignments (if batching used)

Update `${session_dir}/tracking.md` Phase: Delegation
with: batch count, agents dispatched, verdicts
received, agent failures.

---

## Known Persona Roles (Reference Table)

This table provides context when constructing
delegation prompts. The **invocation list comes solely
from discovery** — not from this table.

Agent files use the naming convention
`divisor-{name}-code.md` and `divisor-{name}-spec.md`.

| Base Name | Persona | Code Review Focus | Spec Review Focus |
|-----------|---------|-------------------|-------------------|
| `divisor-adversary` | The Adversary | Secrets, CVEs, error handling, injection safety | Completeness, ambiguity, security gaps |
| `divisor-architect` | The Architect | Architecture, conventions [PACK], DRY | Template consistency, spec-plan alignment |
| `divisor-guard` | The Guard | Intent drift, zero-waste, constitution | Intent fidelity, scope discipline |
| `divisor-testing` | The Tester | Test architecture [PACK], coverage, isolation | Testability, fixtures, contract surface |
| `divisor-sre` | The Operator | Permissions, efficiency, pipeline [PACK] | Deployment, operational requirements |
| `divisor-curator` | The Curator | Documentation gaps, issue filing | Documentation completeness in specs |

For any discovered agent not in this table, use a
generic review prompt appropriate to the current mode.

## Model Selection Guidance

When the orchestrating tool supports model selection
for subagents, use these tiers:

| Tier | Reasoning Demand | Personas |
|------|------------------|----------|
| **Capable** | Deep judgment, security/intent analysis | Adversary, Architect, Guard |
| **Standard** | Checklist-driven with moderate judgment | Tester, Operator, Curator |

If the tool does not support model selection, all
agents run on the default model.

---

## Code Review Delegation

### Prompt Template

**Every delegation prompt MUST include** the changeset
AND the diff:

> ## Changeset
>
> The following files changed on branch `{branch}`
> vs `{base}`:
>
> ```
> {file list, one per line}
> ```
>
> ## Diff
>
> ```diff
> {full patch}
> ```
>
> The diff shows exactly what changed. Read every file
> in the changeset for full context, but focus your
> analysis on the lines that changed.
>
> **Read every file in this changeset before producing
> any findings.** Do not report on files you have not
> read. See reviewer-protocol.md for evidence
> discipline rules.

For each discovered agent, add the focus area from
the Persona Roles table (Code Review Focus column).

**When quality analysis data is available**: append a
"Quality Context" section containing the Quality
Report summary.

**When prior run context is available**: append a
"Prior Run Context" section listing resolved findings
from the prior run. Instruct agents not to re-flag
these unless the fix introduced a new problem.

For each agent, instruct it to return its verdict
(**APPROVE** or **REQUEST CHANGES**) along with all
findings. Remind agents that every finding must
include an **Evidence** field quoting the actual code
or content observed.

### Batching

Check the project's "Review Council Configuration"
section for a "Batch size" entry. Default: **20**
files.

If the changeset exceeds the batch size:

a. Group files by parent directory so related files
   stay together.
b. Fill batches up to the configured size. If a single
   directory exceeds the batch size, split it
   alphabetically.
c. Dispatch each batch as a separate delegation round —
   all agents review batch 1 in parallel, then batch 2,
   etc.
d. Merge findings from all batches before proceeding.
e. Write `${session_dir}/batches.txt` listing which
   files went into which batch.

If the orchestrating tool has native batching or
context management, it may use its own mechanism
instead.

---

## Spec Review Delegation

### Prompt Template

**Every delegation prompt MUST list the spec
artifacts** from `${session_dir}/changeset.txt`:

> ## Review Artifacts
>
> The following spec artifacts are in scope:
>
> ```
> {artifact list, one per line}
> ```
>
> **Read every artifact before producing any findings.**
> Do not report on files you have not read. See
> reviewer-protocol.md for evidence discipline rules.

For each discovered agent, add the focus area from the
Persona Roles table (Spec Review Focus column).

Instruct agents to review the listed spec artifacts
(not code), plus the project context and governance
documents. Include prior run context if available.

---

## Verdict Collection

As each agent returns, write its full output to
`${session_dir}/verdicts/{agent-name}.md`.

**Handling agent failures**:
- If an agent fails to return a valid verdict (neither
  APPROVE nor REQUEST CHANGES, or crashes/times out),
  treat as a **warning** and continue collecting from
  remaining agents.
- If an agent returns REQUEST CHANGES with zero
  findings, flag as a malformed response.
- If **all** agents fail, **stop immediately** and
  report:
  > "All reviewer agents failed to return a verdict.
  > This may indicate a configuration issue."
