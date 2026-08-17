# Persona Roster: Does the Council Need All Five Reviewers?

> Date: 2026-08-11
> Trigger: 20 live `/review-council` runs cached at `~/.cache/review-council/d435af3c9cd3/`, 2026-08-10..11
> Target: `voxpupuli/openvox-ca` (Go CA server), ~12 distinct PRs
> Corpus: 230 persona dispatches, 208 raw findings, every run `mode: code`, every role on `claude-sonnet-5`
> Question asked: can the reviewer roster be consolidated further?
> Decision (owner-approved): **no — keep all five code personas, and the Guard stays broad**
> Fixes shipped: `1f02287` (RC-036, RC-037, RC-038)

## Summary

The roster was tested for redundancy three independent ways. All three say the
same thing: **the council is not carrying duplicate reviewers.** Cross-persona
overlap is 3.4%, the personas occupy near-disjoint file territory, and every one
of the five owns at least one finding class no other produces.

What the corpus *does* show is two miscalibrated charters inside otherwise
load-bearing personas, and both were fixable without removing a reviewer:

1. The Guard was asserting bundlings were undisclosed against PR bodies that
   carried the disclosure — it had never been shown the PR description. This
   accounts for **four of the seven findings ever stripped**.
2. The Curator's blog/tutorial mandate fired exclusively in the one condition
   where it cannot be checked (no Docs repo configured), producing **27% of that
   persona's output**, all of it rejected downstream.

The tempting read of the data — "the Adversary fires 0.33 findings per dispatch,
cut it" — is the wrong inference, and Section 4 sets out why.

## 1. Per-persona economics

A *dispatch* is one agent invocation. Deep mode runs personas × subsystems, so
dispatches greatly exceed runs.

| persona | dispatches | silent (0 findings) | raw findings | per dispatch | verified | HIGH+ | stripped |
|---|---|---|---|---|---|---|---|
| `divisor-testing-code`   | 45 | 11 (24%) | 89 | **1.98** | 90 | 23 | 0 (0%) |
| `divisor-curator-code`   | 46 | 20 (43%) | 51 | 1.11 | 48 | 0 | 2 (4%) |
| `divisor-sre-code`       | 46 | 24 (52%) | 29 | 0.63 | 28 | 3 | 0 (0%) |
| `divisor-guard-code`     | 46 | 29 (63%) | 23 | 0.50 | 16 | 2 | **5 (24%)** |
| `divisor-adversary-code` | 46 | 32 (70%) | 15 | **0.33** | 14 | 1 | 0 (0%) |

Pipeline totals reconcile: 208 raw − 5 consolidated duplicates = 203 entering the
buckets, of which **196 verified, 7 stripped, 0 correctable**.

Per-run contribution across the 19 runs that produced a `findings.json`:

| persona | runs with ≥1 finding | runs with a HIGH |
|---|---|---|
| `divisor-testing-code`   | 16 (84%) | 11 (58%) |
| `divisor-sre-code`       | 15 (79%) | 2 (11%) |
| `divisor-curator-code`   | 14 (74%) | 2 (11%) |
| `divisor-adversary-code` | 9 (47%) | 1 (5%) |
| `divisor-guard-code`     | 9 (47%) | 3 (16%) |

`divisor-testing-code` alone produces **43% of all findings and 74% of all HIGH
severity**.

## 2. The redundancy test

### Measure A — the consolidation counter

`duplicates_consolidated` sums to **5 across 19 runs**. This is the pipeline's own
answer and it is close to zero, but it only catches near-identical findings, so it
cannot see two personas circling one concern from different angles. Hence B and C.

### Measure B — content collision

Every cross-persona finding pair within the same run *and* subsystem, matched on
identical evidence text or identical `file:line`: **7 pairs out of 208 findings
(3.4%)**. Only 4 are the same defect stated twice.

| location | persona A | persona B | same defect? |
|---|---|---|---|
| `magefile.go:63` | curator | guard | **yes — byte-identical evidence** |
| `packaging/systemd/openvox-ca.service:38` | curator | guard | **yes** |
| `internal/ca/signing.go:515` | guard | sre | **yes — same gap, different framing** |
| `docs/migrating-from-puppet-server.md:140` | adversary | sre | **yes — same `mktemp -d` gap** |
| `internal/ca/init.go:539` | adversary — unverified CRL cached | curator — warning undocumented | no |
| `.github/workflows/ci.yml:55` | adversary — checksum same-origin | sre — no tarball caching | no |
| `compose.yml:33` | adversary — floating image tag | sre — healthcheck breaks on alpine | no |

The Guard is party to **3 of the 4 true duplicates**. Every other pair is two
personas correctly finding two different defects that happen to share a line.

### Measure C — file territory

| persona | findings by file type | concentration |
|---|---|---|
| `divisor-testing-code`   | `.go` 62, `_test.go` 19 | 91% Go source and tests |
| `divisor-curator-code`   | `.md` 36, `.go` 11 | 71% markdown |
| `divisor-sre-code`       | `.go` 14, `.md` 6, `.yml` 5, `.libsonnet` 2 | code + CI + mixin |
| `divisor-guard-code`     | `.go` 10, `.md` 7, `_test.go` 2 | spread thin |
| `divisor-adversary-code` | `.go` 7, `.yml` 4, `.md` 3 | spread thin |

**Conclusion: no persona's output is substitutable by another.** The council is
carrying two *low-frequency* reviewers, which is a different problem with a
different fix.

## 3. Per-persona verdicts

### `divisor-testing-code` — keep. Best-calibrated agent in the council

All 89 findings are on-charter: an untested branch, a shallow assertion, a
concurrency test running without `-race`. Zero strips, highest yield, highest
severity mass. The learnings corroborate the mechanism — findings that tie a
coverage gap to a *newly reachable* path and cite a grep transcript survive
validation intact.

Its one recurring defect is severity inflation on untouched code. Runs
`20260811-143659` and `20260811-144931` both record the validator downgrading
HIGH→MEDIUM for coverage gaps in code the diff never touched, or in a file with
a repo-wide no-unit-test convention. Fixed in the persona rather than in the
severity pack — see RC-038 below.

### `divisor-adversary-code` — keep. A rare-event detector; 70% silence is correct

0.33 findings per dispatch reads like waste until you look at what it caught:

- an unverified foreign CRL accepted into the revocation cache
- unsanitised attacker-controlled certnames in bulk-sign logs, with an open CodeQL alert
- unrestricted `patch` on all Secrets/ConfigMaps in the Helm RBAC
- release artifacts verified against a checksum fetched from the same untrusted origin
- a copy-pasteable doc example dropping a plaintext CA key at a predictable `/tmp` path

**None of these appears anywhere in the other 193 findings.** A security auditor
that stays quiet on PRs with no security surface is behaving correctly:
`20260811-140650` records all five personas converging on APPROVE with zero
findings on a narrow suppression-comment PR, and its learnings note explicitly
that no persona manufactured a finding to justify the review effort.

Open: 1 HIGH in 15 findings. Either the severity ladder is too conservative for
this persona, or this target has little security surface. One repo cannot
distinguish the two.

### `divisor-curator-code` — keep the documentation charter, cap the content charter

The 51 findings split cleanly:

- **37 documentation accuracy and convention** — a stale README feature list, an
  undocumented 409 response, a doc example contradicting the shipped systemd
  unit, a cross-reference naming a pre-rename identifier. Real and grounded.
- **14 "no blog/tutorial issue filed"** (13 MEDIUM, 1 LOW) — **27% of the
  persona's entire output**, one recycled template.

Four independent lines of evidence condemn the content template:

1. **The PR author rejected it verbatim.**
   `20260811-155903/verdicts/_meta/disposition-output.json` records: *"Blog/tutorial/content
   tracking (three findings). No defect; needs a decision about where such content
   lives rather than a code change."*
2. **The validator retracted it twice** — `20260811-114548` and `20260811-122127`,
   both because the agent asserted "no blog issue on record" for a project with
   no Docs repo configured, a fact it had no way to check.
3. **It is severity-unstable** — `20260810-235908` records the same underlying gap
   filed MEDIUM twice and LOW once by the same agent in one session.
4. **It self-duplicates across subsystems** — `20260811-020844` records the same
   `tls_self_provision` blog finding raised independently in two subsystem passes.

Root cause: both criteria open *"If yes and Docs repo configured, check whether a
… issue exists"* and **neither defines the other branch**. An undefined branch is
not a skip, so the persona filed anyway. And every content-opportunity finding in
the corpus was filed against a project with no Docs repo configured — which is
precisely the one condition under which the check cannot be performed.

### `divisor-sre-code` — keep. Distinct operational lens with no other owner

A `crl_chain_file` read with no timeout that can wedge every replica while holding
the CRL lock; an alert that self-resolves for the one-shot startup failure it
exists to catch; a startup probe budget that undercounts sequential lock-bound
phases; a PSK pipe read on fd 4 that hangs startup on a foreign inherited fd.
Zero strips. Only 3 HIGH, but they are the highest-consequence operational
findings in the dataset.

### `divisor-guard-code` — the consolidation candidate; splits in two, and stays whole

**Half A — PR scope and intent drift (9 of 23, 7 of them HIGH).** *"TLS
self-provisioning bundled into the client-trust-domains PR"*, *"the PR's own
stacking disclosure mislabels the feature"*, *"a correctness fix bundled into the
CertIndex PR"*. Genuinely unique — nothing else in the council asks whether an
inclusion was disclosed.

**This is also where 100% of the Guard's strips came from.**
`20260811-010448` documents the root cause exactly: four findings asserted a PR
bundled work *"with no note explaining the bundling as a deliberate, authorised
decision"* when the PR body carried precisely that — an `[!IMPORTANT]` callout, a
"What this includes" commit-provenance table, and an explicit merge-order
paragraph. Three *later* Guard dispatches in the same session ran
`gh pr view 166 --json body` on their own initiative, found the disclosure, and
filed narrower, correct findings instead.

**Half B — duplication, convention and consistency (14 of 23).** *"writePublicFile
re-implements the storage layer's atomic-write algorithm"*, *"route backend
selection duplicated verbatim across two templates"*, *"new paragraphs skip the
file's own blockquote convention"*. This is the overlap zone: 2 of 2 exact
duplicates with the Curator and 1 with the Operator originate here.

**Owner decision: the Guard stays broad.** Narrowing it to intent-drift only is
the one genuine dedup available, worth roughly 3 findings per 200 — but Half B's
code-duplication findings have **no other owner in the council**. Dropping them
would open a coverage hole rather than close a redundancy. The ~1.5% duplicate
rate is accepted as the cost of the safety net.

## 4. Why low yield is not redundancy

The two lowest-yield personas, Adversary (0.33/dispatch) and Guard (0.50), are
the two whose removal would cost the most coverage. Both are event-driven: they
fire when a PR has a security surface, or when a PR bundles undisclosed work.
Frequency measures how often that condition occurred in this sample of 12 PRs;
it does not measure the value of catching it.

Cutting either saves ~20% of dispatch cost and removes an entire failure class
with nothing else watching it. The right lever on a low-yield persona is charter
precision, not deletion — which is what shipped.

## 5. The spec-side agents are unevaluated

`module/agents/` maintains 10 agents. **Five have zero evidence in this corpus** —
every run is `mode: code` and no `divisor-*-spec.json` verdict exists anywhere in
the cache.

The pairs are not thin variants:

| persona | changed lines between `-code` and `-spec` | `-code` file size |
|---|---|---|
| curator | 270 | 304 |
| sre | 220 | 202 |
| guard | 212 | 190 |
| adversary | 156 | 164 |
| testing | 155 | 162 |

Adversary and Testing are ~95% rewritten between variants. This is half the
maintained agent surface carrying no operational data. **This is not a
recommendation to delete them** — it is a recommendation to run a spec-mode eval
before any consolidation decision touches them, because at present there is
nothing to decide on.

## 6. Data-quality defect found

`20260811-024247/verdicts/documentation/divisor-testing-code.json` carries
`"agent": "divisor-testing-spec"` — a spec-variant identity inside a code-mode
run's code-named verdict file. One occurrence in 230 dispatches. It is why the
Tester's raw count (89) and its pipeline count (90) differ: the pipeline
normalised the mislabelled record back to `divisor-testing-code`. Harmless here,
but it silently corrupts any per-persona attribution keyed on the `agent` field.
Untraced.

## 7. Fixes applied

All three shipped in `1f02287` on `fix/format-gate-feedback`. Each is pinned at
both ends by a doc guard in
[`test-rc-doc-guards.sh`](../../module/tests/test-rc-doc-guards.sh) — none of
them appears in `mutate-check.sh`, whose every entry mutates a script under
`module/skills/review-council/scripts/`; these three changed persona prose under
`module/agents/` and a delegation phase file. Full suite green at that commit:
37 suites, 1169 assertions, 31/31 mutations caught.

### RC-036 — the Guard reads the disclosure before claiming its absence

`rc-prepare.sh` had been writing the PR body into `pr-metadata.txt` between
`--- BODY ---` and `--- END BODY ---` all along, and `prepare-context.sh` had been
reading that block since it landed — but only to harvest linked-issue references.
The prose itself reached no reviewer.

- [`phases/delegate.md`](../../module/skills/review-council/phases/delegate.md)
  now appends a **PR Description** section to code review prompts, carrying that
  block with the same untrusted-data framing every other forge-sourced section
  has.
- [`divisor-guard-code.md`](../../module/agents/divisor-guard-code.md) gains the
  matching duty: read it before reporting an inclusion as undisclosed, quote the
  passage that should have carried the disclosure and does not, and where no such
  section was supplied, say so rather than asserting an absence with no document
  to check.

Wired through the prompt rather than granting the Guard forge access on purpose.
The Guard's Tool Access states *"Network access is not permitted"* — the three
dispatches that got this right did so by reaching for `gh` anyway, i.e. by
breaking their own contract. Routing the data through the prompt keeps least
privilege intact and fixes it for every persona at once.

The untrusted-data framing is load-bearing, not decoration: the PR body is
authored by whoever opened the PR, which on a fork PR is not a maintainer, and it
is now handed to a reviewer as potential grounds for *not* filing a finding —
exactly the direction an injected imperative would want to push.

### RC-037 — content opportunities are defined and capped

[`divisor-curator-code.md`](../../module/agents/divisor-curator-code.md):

- Both criteria now define the no-Docs-repo case as an explicit "do NOT produce
  the finding", closing the undefined branch.
- Both severity rows drop MEDIUM → LOW.

The severity half is separate and equally load-bearing. Disposition suppresses
scoping hints **only at LOW**; rated MEDIUM, a content advisory outranked that
filter, reached the report, and forced a human to argue it down by hand. The
finding did not become less important — its severity had been buying it passage
through a gate built to stop exactly this class.

Gating rather than deleting the mandate is deliberate: it retires 100% of the
observed noise while preserving the feature for projects that do configure a Docs
repo, which no run in this corpus did.

**RC-037 was extended after this evaluation, and this section is not being
retrofitted.** `beb471f` and `7b287e6` on the same fix branch carried the rule
into the Curator's Graceful Degradation table and then restated it for any
cause, so a content finding is now withheld whenever the duplicate check did not
run rather than only when no Docs repo is configured. That is review feedback on
the fix, not a finding of these twenty runs — every content-opportunity finding
in this corpus came from the no-Docs-repo condition, so the degradation path has
no evidence here either way. The later work is recorded in `CHANGELOG.md` and
pinned by two further RC-037 guards in
[`test-rc-doc-guards.sh`](../../module/tests/test-rc-doc-guards.sh); what is
above is what the corpus showed and what shipped in `1f02287`.

### RC-038 — the Tester's HIGH is a property of the change, not of the code

The Tester is the persona the validation gate corrects most: 11 corrections
across the corpus, more than any other, and 8 of them HIGH downgrades. They
converge on one rule the calibration table never stated. *"Untested code paths in
core functionality — HIGH"* describes the code, so the persona applied it to any
uncovered path it could reach, including paths the changeset never touched — a
docs-only diff, `magefile.go` under a repo-wide no-unit-test convention whose
paths a per-variant `dist` job already exercises, `cmd/openvox-ca-ctl/main.go`
twice for code the PR does not modify.

[`divisor-testing-code.md`](../../module/agents/divisor-testing-code.md):

- A **What earns HIGH** rule: HIGH only when the changeset created the gap — the
  untested path is new, or the change newly made an existing path reachable.
  Three named checks drop it to MEDIUM: the gap is pre-existing, another layer
  (integration, end-to-end, CI, or a documented no-unit-test convention) already
  covers it, or the branch carries no correctness, security or data-integrity
  weight. The finding states which of the three was checked.
- The two unqualified HIGH rows now name the condition, and a new MEDIUM row
  takes the untouched or already-covered path.

This sets a ceiling; it suppresses nothing. Every one of those gaps is real and
stays a finding. What changes is that a gap the change did not create stops
counting as evidence the change is likely to break something — on the persona
that already files 43% of all findings and 74% of all HIGHs, which is how a
report stops being read.

Written into the persona rather than into `severity.md`, which is where the
first read of this data put it. `severity.md` needed no edit: its HIGH boundary
already reads *"Significant risk or tech debt causing problems if not fixed
before merge"*, and that is the qualifier the validator kept supplying on each
downgrade. The defect was one persona's table contradicting the pack it
inherits, and moving the boundary in `severity.md` would have re-rated every
persona's HIGH to correct one table.

## 8. Open items

| Item | Why it is open |
|---|---|
| Spec-mode eval | 5 agents, zero runs. Nothing to decide on until data exists. |
| Adversary severity ladder | 1 HIGH in 15 findings; indistinguishable from a low-security-surface target on one repo. |
| `divisor-testing-spec` mislabel | One record in 230; corrupts attribution keyed on `agent`. Untraced. |
| Installed skill drift | `~/.claude/skills/review-council` is missing `scripts/jq` and `scripts/lib` entirely — pre-existing, unrelated to this work, but any run before a refresh uses stale code. |

## 9. Threats to validity

Single target repo (one Go CA server), single model (`claude-sonnet-5`) across
every role, ~12 PRs, 36 hours, deep mode throughout.

Persona yield is a function of the codebase under review: a repo with more attack
surface moves the Adversary's numbers; a repo with no mixin, Helm or CI surface
moves the Operator's. **The overlap results (3.4%, disjoint file territory) are
the transferable finding** — they are structural properties of the charters. The
yield results are the least transferable, and no persona should be cut on the
strength of a frequency measured here.
