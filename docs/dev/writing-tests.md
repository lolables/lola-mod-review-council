# Writing tests

For a contributor adding or changing a suite under `module/tests/`. Work
through the rules below and you will end up with a test that goes red for the
defect it names — rather than one that passes for a reason you did not intend —
plus a mutation entry that keeps it honest. Each rule is one way a test in this
repository has already passed while measuring nothing. For why the suite is
split into four layers at all, see [testing.md](testing.md).

Every helper named below — `assert_conserved`, `assert_jq`, `assert_idempotent`,
`discard_fixture` — lives in `module/tests/helpers.sh`.

**Watch it fail first.** If a new test passes against unfixed code, it is
measuring the wrong thing. Reshape the fixture until it fails, then fix.

**Size the fixture to the failure, not to readability.** A test that reproduces
a defect only sometimes is worse than no test, because a flaky red gets re-run
until it is green.

`test-degraded-selection.sh` guards a defect that only
appears once a reader's output outgrows the 64KiB pipe buffer: reading a file as
`sed … | grep -q` under `set -o pipefail` reports a match as a miss, because
grep exits on the match, sed is left writing into a closed pipe and dies of
SIGPIPE, and `pipefail` returns 141 for the pipeline.

Its fixture is 2000 lines
for that reason and misses 20 times out of 20 against the defective form; at 400
lines it passed against the same defect and tested nothing. Where a fixture's
*size* is what makes it bite, say so in the fixture, or someone will tidy it
back under the threshold.

Prefer `cmd <<<"$var"` or `cmd < <(…)` to `producer | grep -q`. Anything that
exits early on the left of a pipe under `pipefail` turns a success into a 141.

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
diffs a named state path. Two things about it are load-bearing.

The snapshot is
taken *after* run 1, not before: the first run is the one legitimately allowed
to do work, and idempotence is the claim about every run after it. And the state
path is an argument rather than "the session", so a subtree required to grow can
be excluded from the claim — `rc-extract-verdict.sh` is asserted on `verdicts/`
precisely because `gate-firings.jsonl` beside it must keep appending.

All three
of its failure exits — a run that exited non-zero, a state path missing after a
run, and a second run that changed the state — report through `FAIL` and return
0; a helper that returned non-zero would take a `set -e` suite down at the exact
moment it had a regression to report, before the suite could print its
`Results:` line.

**Match precisely.** `! grep -q '700'` over a log that also contains timestamps
and generated ids fails at random — a run at 07:00 was enough. Anchor to
`issues/comments/700`.

**Do not encode the host.** A traversal fixture built as `"../.." + $TMPDIR`
only works when temp directories sit two levels below `/`. Build paths relative
to the fixture, never to an absolute system path.

**Add a mutation** when you fix a defect, so the guard is itself guarded.
Entries are `check_mutation <label> <script> <sed-expr> <suite>` calls at the
bottom of `.taskfiles/scripts/mutate-check.sh`, where `<script>` is relative to
`module/skills/review-council/scripts/` and `<suite>` to `module/tests/`. A real
one, from that file:

```bash
check_mutation "RC-1  consolidation ident scoping" \
	jq/consolidate-clusters.jq \
	's/any(. == \$fid)/any(. == ident)/' \
	test-rc-jq-programs.sh
```

Anchor the expression tightly and keep it POSIX BRE — one that no longer matches
is reported as `BROKEN` rather than silently counted as caught.
