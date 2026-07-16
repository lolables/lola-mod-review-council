# Phase: Decompose — Deep Mode Changeset Analysis

Runs only in **deep** effort mode, between Prepare and Quality Gates.
Analyzes changeset, produces subsystem map for per-subsystem delegation.

Orchestrator-local analysis step — does NOT dispatch subagent.
Orchestrator performs this directly.

---

## Inputs

Read from session directory:
- `${session_dir}/changeset.txt` — changed file list
- `${session_dir}/diff.patch` — diff (may be empty for `--scope all`)

## Analysis

Analyze changeset, group files into logical subsystems:

1. **Read file list** from `changeset.txt`.
2. **Read diff** to understand changes and file relationships.
3. **Identify logical groupings** based on:
   - Import/dependency relationships visible in diff
   - Shared domain concepts (files operating on same data types
     or serving same feature)
   - Package/module boundaries in project structure
4. **Group by cohesion, not directory.** Same-directory files serving
   different concerns go in different subsystems. Different-directory
   files sharing concern go in same subsystem.

## Decomposition Rules

- **Target range: 2-6 subsystems.** Fewer than 2 means changeset
  already cohesive — abandon decomposition, signal fallback to
  standard-mode delegation.
- **Minimum 2 files per subsystem.** Merge single-file subsystems into
  nearest related subsystem.
- **Cross-cutting files** may appear in multiple subsystems. Mark with
  all memberships.
- **More than 6 subsystems** suggests very large changeset. Proceed but
  note in tracking that decomposition produced high subsystem count.

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
- `description`: one sentence, states subsystem responsibility
- `files`: array of file paths exactly as in `changeset.txt`

## Fallback

If decomposition produces only 1 subsystem:
- Do NOT write `subsystems.json`
- Log: "Changeset is cohesive — falling back to standard delegation"
- Delegation proceeds as whole-changeset (standard behavior)

## Update Tracking

Append to `${session_dir}/tracking.md`:

```
## Phase: Decomposition

- Subsystems: {count}
- Names: {comma-separated list}
- Cross-cutting files: {count}
```
