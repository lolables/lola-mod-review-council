# Phase: Decompose — Deep Mode Changeset Analysis

This phase runs only in **deep** effort mode, between Prepare and
Quality Gates. It analyzes the changeset and produces a subsystem map
for per-subsystem delegation.

This is an orchestrator-local analysis step — it does NOT dispatch a
subagent. The orchestrator performs this analysis directly.

---

## Inputs

Read from the session directory:
- `${session_dir}/changeset.txt` — list of changed files
- `${session_dir}/diff.patch` — the diff (may be empty for `--scope all`)

## Analysis

Analyze the changeset and group files into logical subsystems:

1. **Read the file list** from `changeset.txt`.
2. **Read the diff** to understand what changed and how files relate.
3. **Identify logical groupings** based on:
   - Import/dependency relationships visible in the diff
   - Shared domain concepts (files that operate on the same data types
     or serve the same feature)
   - Package/module boundaries in the project structure
4. **Group by cohesion, not directory.** Files in the same directory that
   serve different concerns go in different subsystems. Files in
   different directories that share a concern go in the same subsystem.

## Decomposition Rules

- **Target range: 2-6 subsystems.** Fewer than 2 means the changeset is
  already cohesive — abandon decomposition and signal fallback to
  standard-mode delegation.
- **Minimum 2 files per subsystem.** Merge single-file subsystems into
  the nearest related subsystem.
- **Cross-cutting files** may appear in multiple subsystems. Mark these
  with all their memberships.
- **More than 6 subsystems** suggests the changeset is very large.
  Proceed but note in tracking that decomposition produced a high
  subsystem count.

## Output

Write `${session_dir}/subsystems.json`:

```json
[
  {
    "name": "kebab-case-name",
    "description": "One sentence describing the subsystem's purpose",
    "files": [
      "path/to/file1.ts",
      "path/to/file2.ts"
    ]
  }
]
```

**Schema rules:**
- `name`: kebab-case, descriptive, 2-4 words
- `description`: one sentence, states the subsystem's responsibility
- `files`: array of file paths exactly as they appear in `changeset.txt`

## Fallback

If decomposition produces only 1 subsystem:
- Do NOT write `subsystems.json`
- Log: "Changeset is cohesive — falling back to standard delegation"
- Delegation will proceed as whole-changeset (standard behavior)

## Update Tracking

Append to `${session_dir}/tracking.md`:

```
## Phase: Decomposition

- Subsystems: {count}
- Names: {comma-separated list}
- Cross-cutting files: {count}
```
