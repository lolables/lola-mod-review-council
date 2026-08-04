# Golden session fixture

A complete Review Council session, shaped like real reviewer output rather
than like the schema. It exists because the unit fixtures modelled idealised
input — no `evidence` value anywhere in the suite contained a newline — and
that single omission hid three defects at once (a jq scoping bug that deleted
findings, `grep -F` multi-line semantics, and a SIGPIPE abort).

`test-rc-pipeline.sh` and `e2e/pipeline.venom.yml` both run the real scripts
over this fixture in sequence: extract → verify → consolidate → render.

## Layout

| Path | Role |
|------|------|
| `repo/` | The review root. Every `evidence` quote below is copied verbatim from it, so the fixture cannot drift into citing text that does not exist. |
| `outside/creds.env` | A readable file **outside** the review root, one level up — the target of the path-traversal finding. Placed as a sibling of `repo/` so the traversal is a fixed `../`, independent of how deep the temp directory is. |
| `session/` | Session directory: `tracking.md` plus the four reviewers' raw output. |
| `clusters.json` | The cross-agent consolidation manifest. In a real run the orchestrator writes this into `session/verdicts/` between verification and consolidation; the pipeline test copies it in at that point so the ordering is exercised, not assumed. |

## What each finding is here to exercise

Nothing in this fixture is filler. Each finding pins a specific behaviour, and
several encode defects that shipped.

| Agent | Finding | Expected outcome | Why it is here |
|-------|---------|------------------|----------------|
| adversary | `tools.go:23`, 3-line unmarshal guard | **verified** | The guard block repeats at lines 7, 15 and 23. Citing the third means the ±5 window (18–28) excludes the first occurrence, so a matcher that reports only the first match rejects an accurate citation. |
| adversary | `tools.go:9`, fabricated `db.Exec(...)` block ending `\t}` | **correctable**, `EVIDENCE_NOT_FOUND` | The last line exists at 9, 17 and 25. Under `grep -F` — which splits a pattern on newlines — this fabrication verified clean. |
| adversary | `../outside/creds.env:1` | **stripped**, `PATH_OUTSIDE_ROOT` | `file` is reviewer-authored. Escaping the review root would let a reviewer present any readable file as changeset evidence. |
| guard | `tools.go:23`, partial-line quote | **verified** | Agents quote fragments, not only whole lines. Deliberately *different* evidence from the adversary finding at the same line, so it survives exact-dedup and reaches semantic consolidation. |
| guard | `cmd/root.go:4` | **verified**, survives consolidation | Bystander. Asserting on the cluster survivor alone cannot detect collateral deletion — that is exactly how the consolidation bug stayed hidden. |
| testing | `internal/mcp/missing.go:5` | **stripped**, `FILE_NOT_FOUND` | Fabricated file path. |
| testing | `docs/README.md:3` | **verified**, survives consolidation | Bystander, and evidence beginning with `-`, which `grep` would read as an option without `--`. |
| sre | `token.go:6`, partial-line quote | **verified**, survives consolidation | Bystander, and the only finding carrying the optional `constraint` field the schema permits. |

## Expected end state

```
verify:      8 total → 5 verified, 1 correctable, 2 stripped
consolidate: 5 verified → 4  (one 2-member cluster merged)
council:     REQUEST CHANGES  (two reviewers requested changes)
```

The consolidation step is the conservation check that matters:
`5 − (2 − 1) = 4`. Three of the four survivors are bystanders in unrelated
files, so a reducer that over-deletes fails here even though the cluster
itself merged correctly.

## Maintaining it

The `.go` and `.md` files under `repo/` are **fixture text, never compiled** —
this project has no Go toolchain, and an editor's Go language server will
report undefined symbols in them. That is expected.

If you change a file under `repo/`, re-check every `line` and `evidence` value
in `session/verdicts/*.raw.md` against it. `test-rc-pipeline.sh` asserts exact
counts and will fail loudly if the fixture and its expectations drift apart.
