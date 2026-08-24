# Should Review Council incorporate a code graph? — decision record

**Date:** 2026-08-23 (validated against a real PR 2026-08-24)
**Question:** Would wiring a code-intelligence tool (CodeGraph or Graphify) into
Review Council as a procedural pre-pass make reviews more correct or more
efficient, and should such an integration be pluggable?
**Answer:** No. Investigated, designed, measured, rejected.
**Measurements:** `code-graph-prepass-baseline.md` (same directory).

The full design spec was written to
`docs/superpowers/specs/2026-08-23-code-graph-prepass-design.md`, which is
gitignored. This record carries the parts worth keeping.

## The candidates

| | CodeGraph (`colbymchenry/codegraph`) | Graphify (`Graphify-Labs/graphify`) |
|---|---|---|
| Shape | CLI + MCP server over a prebuilt SQLite symbol graph | Claude Code skill that builds a knowledge graph |
| Domain | Code — symbols, call edges, imports, dynamic dispatch | Multimodal — code, PDFs, markdown, screenshots |
| Output unit | Callers, callees, impact radius, line-numbered source | Communities, wiki pages, GraphML/Neo4j/SVG |
| License | MIT | Apache-2.0 |
| Maturity (2026-08-23) | 67.7k ★, 42 contributors, v1.5.0 | 109.7k ★, 100+ contributors, v0.9.48 |

**Graphify was rejected on inspection.** Its output unit is a topic map over a
document corpus. The council reviews a diff against conventions and requires
byte-exact evidence anchoring, so a community map produces nothing that survives
`rc-verify-evidence.sh`. It would also add a Python runtime and a second graph
model to a module that is bash, jq and agent markdown, and it remains pre-1.0.

One provenance note: Graphify's README CI badge points at `safishamsi/graphify`
while the repository lives under `Graphify-Labs`. Churn of that kind in a
dependency is what `divisor-adversary-code` flags under NIST SSDF PW.4.

**CodeGraph was carried forward to a full design and an eval gate.**

## Why the efficiency argument does not transfer

CodeGraph's own README states the constraint:

> CodeGraph only helps when queried *directly* [...] otherwise a sub-agent reads
> files regardless and CodeGraph becomes overhead.

Review Council is a sub-agent fan-out. The published savings are measured on a
single-agent exploration loop. Three further reasons the token case is weak here:

1. **The council does not explore to find files.** `rc-prepare.sh` hands
   reviewers `changeset.txt` and `diff.patch`; the discovery phase a graph
   optimises away is already done by a shell script.
2. **A fresh clone has nothing to amortise.** `rc-clone-target.sh` materialises a
   new checkout per PR review, so incremental `sync` and the file watcher — where
   the amortisation lives — buy nothing.
3. **The cheap steps stay cheap.** Council selection and subsystem triage run
   over file *lists*.

That left correctness as the whole case, which is what the eval measured.

## What the eval found

Three purpose-built cases, three runs each, baseline arm only (no graph).
Medians **1.00 / 0.98 / 1.00** against thresholds 0.60 / 0.60 / 0.70.

- `caller_identification` — 1.00 in every run. The council already reaches
  outside the diff, by reading the files.
- `missing_test_identified` — 1.00 in every run.
- The one apparent gap turned out to be a defect in the rubric, not the council.
  See `code-graph-prepass-baseline.md`.

**No cross-file finding class was left for a graph to win.**

## The argument that decided it

Probed directly, CodeGraph does return the facts, and fast — a 13-file index in
172ms, `codegraph callers formatAmount` returning 4 of 4 caller files where the
council named 3.

But on `case-031`, `codegraph callers NewQuotaWithBurst` returns `[]`, and that
is **a true fact that must not become a finding**: it is an exported constructor
in a library package, and exported API routinely has no internal caller. The
council searched, found the same absence, and correctly declined to report it.

A graph supplies structure with no judgement about whether it matters. The
pipeline's one measured weakness — `caller_false_alarm` 0.50 in a single run of
`case-032` — is already over-reaching from structural facts. Feeding reviewers
caller lists optimises for the failure mode, not against it.

## Costs that were never earned

- A `SKILL.md` HARD-GATE carve-out to execute a third-party indexer over
  attacker-authored checkouts, plus a write *into* the checkout: `codegraph
  index` has no out-of-tree index location.
- A dependency with telemetry on by default, pointed at arbitrary third-party
  pull requests.
- `rc-graph.sh`, an artifact schema, an extension point and `delegate.md`
  changes to maintain.

## Design decisions worth keeping, if this is ever revisited

The spec resolved several questions before the eval killed it. Re-deriving them
would be wasted work.

- **CLI, never the MCP server.** MCP wiring is host-specific and the server's
  guidance reaches only the main agent. Agent files here carry only
  `description` frontmatter by design (see `CLAUDE.md` tool-agnosticism rules),
  so reviewer tool access cannot be guaranteed on any host.
- **Script-owned, not reviewer-queried.** One script before delegation writes a
  bounded artifact; no reviewer calls a graph tool. This single choice resolves
  determinism (`EXECUTION-CONTRACT`), tool agnosticism, the HARD-GATE, and
  CodeGraph's own sub-agent caveat at once.
- **Never index the operator's own tree.** When `review_root` is `.`, reuse an
  existing `.codegraph/` or skip. Creating one is an unrequested write to a
  repository the module was asked only to read.
- **A graph fact may motivate a finding, never be its `evidence`.** Evidence
  stays a byte-exact quote verified by `rc-verify-evidence.sh`; a finding
  supported only by a graph fact may not exceed MEDIUM.
- **Pluggability costs nothing at the config and artifact layer, and a lot at
  the adapter layer.** A `Graph tool:` extension point alongside `Knowledge
  tool:` and `Quality tool:` in `SKILL.md`, plus a fixed artifact schema, is the
  whole of it. An adapter framework for one implementation is speculative
  generality — revisit at the second tool.

## Validation on a real PR (2026-08-24)

The eval fixtures were 12-13 files, and "index cost on a large repository is
unmeasured" was a stated caveat. Re-tested against
[voxpupuli/openvox-ca#189](https://github.com/voxpupuli/openvox-ca/pull/189) —
31 changed files, +4915/-262, 19 of them Go — in a repo of 199 Go files and
71,572 Go LOC.

### Index cost is a non-issue

```
codegraph init .   ->  246 files, 3,851 nodes, 13,817 edges in 372ms
                       1.9s wall clock, 22.8 MB DB
```

Against a review that takes 12-23 minutes, indexing is free. **This caveat
resolves in CodeGraph's favour** and should not be cited against it again.

### The JSON substrate the design was specced on is 92% noise on real Go

`codegraph callers` matches by **name only** — there is no receiver or
definition-site disambiguation flag. Go interface implementations share method
names across receiver types, so on a real codebase the caller list conflates
them all.

Of the 47 functions the PR touches, 14 have callers outside the changeset,
implicating 28 distinct files. Splitting those by whether the name is unique in
the repo:

| | symbols | out-of-changeset files claimed |
|---|---|---|
| Ambiguous name (>1 declaration) | 12 | 27 |
| Unique name (exactly 1) | 2 | 2 |

**26 of the 28 files — 92% — trace to name collisions.** `Put` has 14
declarations in this repo, `AcquireLock` 13, `Exists` 7.

The worst case is not marginal. The `Put` this PR changes is:

```go
// internal/ca/generate_test.go:220
func (b *crlWriteFailBackend) Put(ctx context.Context, key string, data []byte, kind storage.BlobKind) error
```

— a **test double**. `codegraph callers Put` returns 22 callers across
`internal/storage/migrate.go`, `storage.go` and `overlay.go`. None of them call
it. Injected into a reviewer prompt, that is 22 invitations to file a finding
against files the change cannot reach: exactly the over-flag
`case-032`'s `caller_false_alarm` component exists to catch, at 92% noise.

### The tool's accurate path cannot be a deterministic artifact

`codegraph explore` — the vendor's recommended single tool — is substantially
better. It disambiguates by definition site, listing `Put` at
`backend.go:132`, `filesystem.go:172` and `overlay.go:104` as separate entries
with separate caller counts, and flags `⚠️ no covering tests found` per symbol.

It is still unusable here:

- **No `--json`.** Options are `--path` and `--max-files` only. It emits prose
  plus verbatim source, so it cannot back a schema'd artifact or a
  deterministic, script-owned phase.
- **~5,200-6,300 tokens per call** (20.8-25.2 KB). Paid once per persona, that
  is the fan-out multiplier the "lazy, not injected" rule was written to avoid.
- **It did not pin the symbol asked for.** Queried directly about
  `crlWriteFailBackend.Put` in `generate_test.go`, it returned 53 symbols across
  3 files — `Generate`, `Backend`, and three unrelated `Put`s — but not that one.

So the two paths fail for different reasons: the machine-readable primitive is
92% wrong on real Go, and the accurate one is neither machine-readable nor
affordable at fan-out. The design could have been built on either, and both
would have made the council worse.

## What would reopen this

Not correctness, and no longer index cost — the real-PR test settled that at 1.9s.
The remaining open question is **latency and token spend**: the
baseline spends $3.64-5.25 and 12-23 minutes per review, much of it on file
reads a graph could short-cut. The pre-registered decision rule rejected a
cost-only win, and that rule was honoured here. If per-review latency later
becomes the problem, reopen this as a *performance* question with its own
metric — not as a correctness one, which is settled.
