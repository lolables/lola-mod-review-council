# Testing

Four layers, each catching a class the others structurally cannot. Run
everything locally with `task check`.

| Command | What it runs |
|---------|--------------|
| `task test` (alias for `task test:unit`) | Unit suites — one script each |
| `task test:e2e` | Venom pipeline suite — the scripts in sequence, black box |
| `task test:degraded` | Re-runs the unit suites once per optional tool hidden from `PATH`, narrowed to the suites that can reach that tool |
| `task test:mutate` | Reintroduces each fixed defect, asserts a suite catches it |
| `task check` | Lint plus all of the above |

## What CI runs

Two workflows split the work. Neither invokes `task check`: CI reproduces it
layer by layer, as separate jobs, rather than calling that target.

| Workflow | Runs | On |
|----------|------|-----|
| `.github/workflows/test.yml` | One job per test layer | `ubuntu-latest` and `macos-latest` |
| `.github/workflows/megalinter.yml` | Linting | `ubuntu-latest` |

`test.yml` is a two-dimensional matrix — four layers by two operating systems,
eight jobs — plus a gating job that depends on all of them. The two are easy to
confuse: the matrix job has the id `test` and displays per leg as
`<layer> (<os>)`, while the gating job has the id `test-result` and displays as
`test`.

The layers used to run as one serial `task test:all` per OS, which made a leg's
wall clock their sum: macOS reached 24m48s against a 25m limit and the next
commit was killed at 25m22s.

They share no state, so as separate jobs a leg costs the slowest single
layer instead, and a layer that grows can no longer push an unrelated one over
the limit.

Gate on the `test-result` job — the check that appears as `test` — not on the
eight matrix jobs. It is one stable check name that does not change when a layer
or an OS is added, and it fails on a matrix that was cancelled or skipped as
well as one that failed.

Every test layer runs on both operating systems. None is gated by OS. That is
deliberate: the mutation harness is the layer that caught GNU-only `sed`
constructs, so restricting it to Linux would retire the check that justifies
having a macOS leg at all. If a layer ever genuinely cannot run on macOS, gate
it with an explicit `if:` condition and record the reason here — do not quietly
narrow what the workflow invokes.

`test.yml` installs Venom on the `e2e` jobs only — it is the one layer with a
hard precondition on it — pinned to a tag and to the SHA-256 of each published
asset. Venom publishes no checksum file, so the digests are recorded in the
workflow; bump the tag and all three digests together — one per published
asset, for `linux-amd64`, `darwin-arm64` and `darwin-amd64`.

Every macOS job runs `brew bundle` against the repo-root `Brewfile`, which
declares itself the single source of truth for that set, so a contributor's
`brew bundle` and this step cannot drift apart. It installs `bash` (macOS ships
bash 3.2, and the suites need 4+), `jq`, GNU `coreutils` for `timeout`, which
macOS lacks, and `uv`, which builds the `.venv` the `task lola-eval:*` harness
runs from. Every layer needs the first three, not just the e2e one; `uv` is the
one entry a plain `task test` never touches. Add a macOS prerequisite to the
`Brewfile`, not to the workflow.

`jsonschema` is deliberately *not* installed. Its absence is the default
condition for most users, and `task test:degraded` exercises that fallback
explicitly.

## Why four layers

The suite was once a single layer — one unit suite per script — and a live run
found six defects in an afternoon. Each layer below exists because of a defect
that got past everything else.

**Unit** (`module/tests/test-*.sh`). Of the 45 files, 23 pin one script with
`SCRIPT=` and exercise it in isolation. Every file matching `test-*.sh` runs
automatically; the list used to be hand-maintained in `Taskfile.yml`, where a
suite nobody remembered to register silently never ran. Shared code lives in
`helpers.sh` — deliberately *not* named `test-helpers.sh`, so the discovery
glob means exactly "a suite".

`run-unit-tests.sh` also takes suite paths as arguments and runs exactly those,
which is how the degraded layer runs its narrowed selection. Discovery is what
happens with no arguments, so `task test:unit` is unaffected. A named path it
cannot read fails the run rather than being skipped — a caller whose selection
has gone wrong would otherwise run a smaller set than it asked for and still be
told everything passed — and the `Suites run:` line counts what actually ran, not
what the directory holds.

A suite with no `SCRIPT=` covers something that spans scripts: a documented rule
(`test-rc-doc-guards.sh`), a shared library (`test-rc-lib.sh`), a contract
between scripts (`test-rc-pipeline.sh`), a schema (`test-verdict-schema.sh`), or
the helpers themselves (`test-harness.sh`). The helpers are the case worth
naming — they have no suite of their own to go red, and a helper that quietly
stops doing its job does not fail. It weakens whatever depends on it, which is
how a PATH-masking helper went on reporting that three scripts were tested
without their dependency while the binary was still on the PATH it handed them.

A *phase script* is one of the `rc-*.sh` scripts under
`module/skills/review-council/scripts/` that a phase document in
`module/skills/review-council/phases/` invokes against a session directory —
`rc-consolidate.sh`, `rc-verify-evidence.sh`, `rc-extract-verdict.sh`,
`rc-render-report.sh` and `rc-render-comment.sh` today.

`test-rc-idempotency.sh` covers a property across *every* phase script: re-run
it against a live session and its state must not change.
`module/skills/review-council/SKILL.md` Step 6 offers to fix findings and return
to Step 3, and `module/skills/review-council/phases/verify.md` re-dispatches an
agent and runs the extractor again, so re-running is part of the contract rather
than an edge case. **Adding a phase script means adding it here** — the
per-script suites cover the specific defects they were written for, and a
script absent from this sweep is a script whose re-run behaviour nobody checks.
`rc-prepare.sh` is the one deliberate omission: a session *is* a run, so
re-running must produce a new one, and its growth is bounded by the session LRU
instead — the prune in
`module/skills/review-council/scripts/lib/prepare-repo.sh` that keeps the newest
`REVIEW_COUNCIL_SESSION_CACHE_MAX` session directories per project (default 20,
by directory mtime) and removes the rest.

**End-to-end** (`module/tests/e2e/pipeline.venom.yml`). Unit tests cannot see
seams. `module/skills/review-council/phases/verify.md` Step 3c tells the
orchestrator to write `clusters.json` into `verdicts/`, and
`rc-verify-evidence.sh` globbed `verdicts/` — neither
script wrong alone, the contract between them broken, and no unit test could
have caught it. This layer runs the real scripts in the real order.

**Degraded** (`.taskfiles/scripts/run-degraded-tests.sh`). A fallback branch
only executes on a host that lacks the tool, so on any given machine it is
always taken or never taken, and never deliberately exercised. That is how the jq fallback
validator shipped accepting `"HIG"` as a severity. Each optional tool
(`jsonschema`, `gh`, `glab`) is hidden from `PATH` in turn and the suites that
can reach a call to it must produce identical results.

Which suites those are is derived from the tree by
`.taskfiles/scripts/degraded-suites.sh`, not hand-listed — the same reason the
unit layer discovers its suites. It seeds on the files that actually *use* the
tool (a `command -v` probe, the tool in command position, or an assignment for
later indirect invocation) and closes over `source`/`bash` references from
there, ignoring mentions in full-line comments. Running all 45 suites for each
of the three tools was three complete unit passes and the single largest block
of CI wall clock; the derived selection is 47 suite-runs — 9 for `jsonschema`,
20 for `gh`, 18 for `glab` — instead of 135, and cut the layer from about 474s
to 121s.

Two rules keep the narrowing from becoming a silent hole, which is the failure
this layer exists to prevent:

- **Ambiguity includes.** A trailing-comment mention counts as an invocation,
  because telling `foo # gh` from `foo "#gh"` is not something grep can decide,
  and a wrong guess in the other direction drops a suite without saying so.
- **An empty selection is an error.** A tool that matches nothing means either
  the name is wrong or the walk is broken. Both would otherwise report green
  having run no suite at all, so the run fails instead.

`module/tests/test-degraded-selection.sh` pins both, along with the cases that
have already gone wrong once — see the SIGPIPE note in
[writing-tests.md](writing-tests.md).

**Mutation** (`.taskfiles/scripts/mutate-check.sh`). A green suite proves
nothing on its own. Two regression tests written for these defects passed on
their first run, before any fix existed, because the fixture geometry happened
to satisfy them. Each entry reintroduces one defect into a throwaway copy and
asserts the named suite goes red. A mutation that applies cleanly and is *not*
caught is a hole, and fails the run.

## Writing a test that actually tests something

The rules for that — watch it fail first, size the fixture to the failure,
assert on what must survive, assert re-runs, match precisely, do not encode the
host, add a mutation — are a checklist you work through at the keyboard rather
than part of this document's argument, so they live in
[writing-tests.md](writing-tests.md). That document also gives the location of
the assertion helpers `assert_conserved`, `assert_jq`, `assert_idempotent` and
`discard_fixture` (`module/tests/helpers.sh`) and of the `check_mutation`
entries (`.taskfiles/scripts/mutate-check.sh`).

## Fixtures

`module/tests/fixtures/session-golden/` is a complete session shaped like real
reviewer output — multi-line evidence, a block repeated three times, a
partial-line quote, a fabrication, a path traversal, a cluster, and bystanders.
It exists because no fixture in the suite had ever contained a newline in an
`evidence` value, and that one omission hid three defects at once. See its
[README](../../module/tests/fixtures/session-golden/README.md) for what each
finding pins.

Fixture repos are built through `git_init_sandbox` in `module/tests/helpers.sh`,
which disables commit and tag signing per repo — the one setting with no
environment equivalent to fall back on. Without that, a contributor with
`commit.gpgsign = true` gets every fixture commit rejected, surfacing as an
unrelated assertion failing much later against a repo with no commits in it.

Identity and config isolation come from the environment instead, so they live in
one place rather than per repo. `helpers.sh` exports `GIT_CONFIG_NOSYSTEM`,
`GIT_CONFIG_GLOBAL`, `GIT_CONFIG_SYSTEM`, `GIT_AUTHOR_NAME`, `GIT_AUTHOR_EMAIL`,
`GIT_COMMITTER_NAME` and `GIT_COMMITTER_EMAIL` at source time, so a suite run
directly is hermetic on its own; `.taskfiles/test.yml` sets the same values on
the tasks, which covers the harness itself and anything it runs before a suite
is sourced.

## Where test state goes

Every task that runs a suite goes through `.taskfiles/scripts/with-scratch.sh`,
which creates a scratch directory, points `TMPDIR` and `XDG_CACHE_HOME` inside
it, and deletes it when the run returns — including when the run fails.

Both variables matter, for different reasons:

- **`XDG_CACHE_HOME`** is the one that bites. Most suites invoke
  `rc-prepare.sh`, which writes a session under
  `${XDG_CACHE_HOME:-$HOME/.cache}/review-council/`. Six suites set the variable
  themselves; the rest inherited the operator's own cache, so one `task test`
  left 44 review sessions there, shaped exactly like the real ones. Over time
  20,021 of them accumulated.
- **`TMPDIR`** covers the interrupted run. The suites do remove their own
  `mktemp -d` directories — 349 `rm -rf` calls — but none of that cleanup is on a
  `trap`, so a run that is killed abandons whatever it had open.

Redirecting the two variables fixes all 400 `mktemp` call sites at once,
including any added later, which is why this lives in one wrapper rather than in
the suites.

On macOS the `TMPDIR` export is not enough on its own. Apple's `mktemp(1)` takes
the directory for a bare `mktemp` or `mktemp -d` from
`confstr(_CS_DARWIN_USER_TEMP_DIR)` and reads `TMPDIR` only if that call fails,
so every call site kept writing to `/var/folders` — outside the tree the wrapper
deletes. No environment variable reaches that decision, so the wrapper also puts
a small `mktemp` on `PATH` ahead of the real one, which supplies the `TMPDIR`
template BSD would otherwise choose for itself and delegates everything else. A
call that already carries a template operand is passed through untouched, since
`mktemp` creates one path per template and appending a second would leave a
stray one behind. The forms that name a directory in a flag — `-p`, `-t`,
`--tmpdir` — are not supported under the wrapper: they either fail or land
outside the scratch tree, depending on the platform. No call site uses them.

**Running a suite directly bypasses it.** `bash module/tests/test-rc-prepare.sh`
gets no scratch directory and will write into your real cache. Either go through
`task test`, or set both variables yourself. Run the commands below from the
repository root — the `module/tests/...` paths in them are relative to it — and
be aware that on macOS this isolates the cache but not `mktemp`, for the reason
above:

```bash
scratch=$(mktemp -d)
TMPDIR="$scratch" XDG_CACHE_HOME="$scratch" bash module/tests/test-rc-prepare.sh
rm -rf "$scratch"
```

Only `task test` gets you both.

**Leave a fixture before removing it.** `cd "$tmpdir"` followed by `rm -rf
"$tmpdir"` unlinks the suite's own working directory, and the shell keeps that
unresolvable directory until its next `cd` — every process started in the window
inherits it. Call `discard_fixture "$tmpdir"` from `helpers.sh` instead; it
leaves the directory first and takes as many paths as you have to remove. Under
the wrapper the condition is loud, because `mktemp` is a shell shim there and
the next fixture setup therefore starts a shell that cannot resolve its own
working directory and says so. `run-unit-tests.sh` fails any suite whose output
carries that message. Run a suite directly, against the real `mktemp` binary,
and nothing announces it at all — which is how 26 of them accumulated in one
suite.

`test-rc-test-isolation.sh` pins the wrapper's contract: isolated paths, a
scratch root per run, cleanup on both the passing and failing path, and the
command's exit status propagated rather than swallowed. It runs one case against
a stub `mktemp` with BSD semantics, so the Linux leg of CI asserts the macOS
behaviour too rather than leaving it to the one platform that used to break.

## Requirements

`bash` 4+, `jq`, `git`, GNU `timeout` (or `gtimeout`). `shellcheck` and `shfmt`
for `task lint`; [venom](https://github.com/ovh/venom) for `task test:e2e`.

`task lint` runs `shellcheck -x --enable=all -S info`, so the optional checks
are on and notes fail the build. The two that bite most often are worth knowing
before you hit them:

- **SC2312** — a command substitution nested inside another command has its
  exit status thrown away, so `set -e` cannot see a failure. In a test this
  turns "jq errored" into "value was empty", which then reads as an ordinary
  assertion mismatch. Assign to a variable first, or use `assert_jq`, which
  exists for exactly this.
- **SC2310** — a function called in `if`, `!` or `||` runs with `set -e`
  suspended. Where that is the intent, say so in a `# shellcheck disable=SC2310`
  comment naming why the status is handled; do not disable it blindly.

Optional: `sourcemeta/jsonschema` — absent, the validator falls back to a jq
check that `task test:degraded` pins to the same behaviour.

All output goes to `.test-output/`, which is gitignored.
