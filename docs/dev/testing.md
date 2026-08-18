# Testing

Four layers, each catching a class the others structurally cannot. Run
everything with `task check`.

| Command | What it runs |
|---------|--------------|
| `task test` | Unit suites — one script each |
| `task test:e2e` | Venom pipeline suite — the scripts in sequence, black box |
| `task test:degraded` | Unit suites once per optional tool missing from `PATH` |
| `task test:mutate` | Reintroduces each fixed defect, asserts a suite catches it |
| `task check` | Lint plus all of the above |

## What CI runs

Two workflows split the work, and neither runs `task check` under that name:

| Workflow | Runs | On |
|----------|------|-----|
| `.github/workflows/test.yml` | `task test:all` — all four test layers | `ubuntu-latest` and `macos-latest` |
| `.github/workflows/megalinter.yml` | Linting | `ubuntu-latest` |

Every test layer runs on both operating systems. None is gated by OS. That is
deliberate: the mutation harness is the layer that caught GNU-only `sed`
constructs, so restricting it to Linux would retire the check that justifies
having a macOS leg at all. If a layer ever genuinely cannot run on macOS, gate
it with an explicit `if:` condition and record the reason here — do not quietly
narrow what the workflow invokes.

`test.yml` installs Venom itself, pinned to a tag and to the SHA-256 of each
published asset. Venom publishes no checksum file, so the digests are recorded
in the workflow; bump the tag and all three together. Both legs also get `bash`
(macOS ships bash 3.2, and the suites need 4+), `jq`, and GNU `coreutils` for
`timeout`, which macOS lacks.

`jsonschema` is deliberately *not* installed. Its absence is the default
condition for most users, and `task test:degraded` exercises that fallback
explicitly.

## Why four layers

The suite was once a single layer — one unit suite per script — and a live run
found six defects in an afternoon. Each layer below exists because of a defect
that got past everything else.

**Unit** (`module/tests/test-*.sh`). Most files pin one script with `SCRIPT=`
and exercise it in isolation. Every file matching `test-*.sh` runs
automatically; the list used to be hand-maintained in `Taskfile.yml`, where a
suite nobody remembered to register silently never ran. Shared code lives in
`helpers.sh` — deliberately *not* named `test-helpers.sh`, so the discovery
glob means exactly "a suite".

A suite with no `SCRIPT=` covers something that spans scripts: a documented rule
(`test-rc-doc-guards.sh`), a shared library (`test-rc-lib.sh`), a contract
between scripts (`test-rc-pipeline.sh`), a schema (`test-verdict-schema.sh`), or
the helpers themselves (`test-harness.sh`). The helpers are the case worth
naming — they have no suite of their own to go red, and a helper that quietly
stops doing its job does not fail. It weakens whatever depends on it, which is
how a PATH-masking helper went on reporting that three scripts were tested
without their dependency while the binary was still on the PATH it handed them.

`test-rc-idempotency.sh` covers a property across *every* phase script: re-run
it against a live session and its state must not change. SKILL.md Step 6 offers
to fix findings and return to Step 3, and verify.md re-dispatches an agent and
runs the extractor again, so re-running is part of the contract rather than an
edge case. **Adding a phase script means adding it here** — the per-script
suites cover the specific defects they were written for, and a script absent
from this sweep is a script whose re-run behaviour nobody checks.
`rc-prepare.sh` is the one deliberate omission: a session *is* a run, so
re-running must produce a new one, and its growth is bounded by the session LRU
instead.

**End-to-end** (`module/tests/e2e/pipeline.venom.yml`). Unit tests cannot see
seams. Verification Step 3c tells the orchestrator to write `clusters.json`
into `verdicts/`, and `rc-verify-evidence.sh` globbed `verdicts/` — neither
script wrong alone, the contract between them broken, and no unit test could
have caught it. This layer runs the real scripts in the real order.

**Degraded** (`.taskfiles/scripts/run-degraded-tests.sh`). A fallback branch
only executes on a host that lacks the tool, so on any given machine it is
always taken or never taken, and never deliberately exercised. That is how the jq fallback
validator shipped accepting `"HIG"` as a severity. Each optional tool
(`jsonschema`, `gh`, `glab`) is hidden from `PATH` in turn and the whole suite
must produce identical results.

**Mutation** (`.taskfiles/scripts/mutate-check.sh`). A green suite proves
nothing on its own. Two regression tests written for these defects passed on
their first run, before any fix existed, because the fixture geometry happened
to satisfy them. Each entry reintroduces one defect into a throwaway copy and
asserts the named suite goes red. A mutation that applies cleanly and is *not*
caught is a hole, and fails the run.

## Writing a test that actually tests something

**Watch it fail first.** If a new test passes against unfixed code, it is
measuring the wrong thing. Reshape the fixture until it fails, then fix.

**Assert on what must survive, not on what changed.** Every consolidation
fixture used to consist entirely of cluster members, so `assert length == 1`
held whether the reducer merged correctly or deleted the array — which is how a
bug that destroyed unrelated HIGH findings passed for months. Use
`assert_conserved` and put bystanders in the fixture; it refuses to run without
them.

**Assert the fixture reached the code you claim to test.** A renderer refusing
its precondition still writes a file, and a test comparing two refusals passes
without the section under test ever executing. `test-rc-idempotency.sh` Test 5
did exactly that for as long as its fixture lacked the verification log
`rc-render-report.sh` refuses to render without. Grep the output for something
only the real path produces — a finding's own location — before asserting
anything about how it behaves.

**Assert re-runs with `assert_idempotent`,** which runs a command twice and
diffs a named state path. Two things about it are load-bearing. The snapshot is
taken *after* run 1, not before: the first run is the one legitimately allowed
to do work, and idempotence is the claim about every run after it. And the state
path is an argument rather than "the session", so a subtree required to grow can
be excluded from the claim — `rc-extract-verdict.sh` is asserted on `verdicts/`
precisely because `gate-firings.jsonl` beside it must keep appending. All three
of its exits report through `FAIL` and return 0; a helper that returned non-zero
would take a `set -e` suite down at the exact moment it had a regression to
report, before the suite could print its `Results:` line.

**Match precisely.** `! grep -q '700'` over a log that also contains timestamps
and generated ids fails at random — a run at 07:00 was enough. Anchor to
`issues/comments/700`.

**Do not encode the host.** A traversal fixture built as `"../.." + $TMPDIR`
only works when temp directories sit two levels below `/`. Build paths relative
to the fixture, never to an absolute system path.

**Add a mutation** when you fix a defect, so the guard is itself guarded.

## Fixtures

`module/tests/fixtures/session-golden/` is a complete session shaped like real
reviewer output — multi-line evidence, a block repeated three times, a
partial-line quote, a fabrication, a path traversal, a cluster, and bystanders.
It exists because no fixture in the suite had ever contained a newline in an
`evidence` value, and that one omission hid three defects at once. See its
[README](../../module/tests/fixtures/session-golden/README.md) for what each
finding pins.

Fixture repos are built through `git_init_sandbox`, which stubs identity and
disables commit and tag signing. Without that, a contributor with
`commit.gpgsign = true` gets every fixture commit rejected, surfacing as an
unrelated assertion failing much later against a repo with no commits in it.

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
  `mktemp -d` directories — 228 `rm -rf` calls — but none of that cleanup is on a
  `trap`, so a run that is killed abandons whatever it had open.

Redirecting the two variables fixes all 239 `mktemp` call sites at once,
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
`task test`, or set both variables yourself:

```bash
scratch=$(mktemp -d)
TMPDIR="$scratch" XDG_CACHE_HOME="$scratch" bash module/tests/test-rc-prepare.sh
rm -rf "$scratch"
```

On macOS that isolates the cache but not `mktemp`, for the reason above; only
`task test` gets you both.

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
