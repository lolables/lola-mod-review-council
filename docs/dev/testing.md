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

**Unit** (`module/tests/test-*.sh`). One `SCRIPT=` per file, exercised in
isolation. Every file matching `test-*.sh` runs automatically; the list used to
be hand-maintained in `Taskfile.yml`, where a suite nobody remembered to
register silently never ran. Shared code lives in `helpers.sh` — deliberately
*not* named `test-helpers.sh`, so the discovery glob means exactly "a suite".
`test-harness.sh` is the one suite with no `SCRIPT=`: it covers the helpers
themselves, which have no suite of their own to go red. A helper that quietly
stops doing its job does not fail — it weakens whatever depends on it, which is
how a PATH-masking helper went on reporting that three scripts were tested
without their dependency while the binary was still on the PATH it handed them.

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
