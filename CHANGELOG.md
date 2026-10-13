# Changelog

All notable changes to this project are documented in this file. The format is
generated from [Conventional Commits](https://www.conventionalcommits.org) by
[git-cliff](https://git-cliff.org); do not edit it by hand — run
`task release:bump` instead.

## [unreleased]

### 🚀 Features

- Add forge-aware PR input, CI causality detection, and acceptance criteria tracking
- Harden sub-agent grounding and verification pipeline
- Auto-discover constitution from .specify/memory/constitution.md
- Add lola-eval harness and raise reviewer merge threshold to HIGH
- *(review-council)* Close review defects and disclose provenance
- *(review-council)* Materialize foreign PR targets for review
- *(review-council)* Post the council verdict as a PR comment
- *(review-council)* Surface full findings, fail loud on parse errors
- *(review-council)* Make posted findings scannable
- *(review-council)* JSON-native reviewer verdict pipeline
- *(session)* Cap the session cache like the clone cache
- *(scripts)* Add batch reviewer for a repo's open PRs
- *(report)* Give findings the same detail as the PR comment
- *(scripts)* Skip PRs written entirely by dependency bots
- *(consolidate)* Refuse to write a fold that loses findings
- *(scripts)* Stream council progress while a review runs
- *(comment)* Chain oversized verdicts across multiple comments
- *(review-council)* Price deep fan-out before dispatch
- *(review-council)* Narrow the council by change shape
- *(driver)* Re-review PRs when a write-access account asks in a comment
- *(delegate)* [**breaking**] Compute delegation batches on context bytes
- *(scripts)* Add read-only PR status report and --ignore-approved
- *(prepare)* Review paths and all scope outside a git repository
- *(verify)* Apply validator outcomes by finding id
- *(testing)* Flag tests that cost upkeep without catching bugs
- *(verify)* Apply the correction round by script, re-checking each quote
- *(gitlab)* [**breaking**] Review and post council verdicts on merge requests
- *(symlinks)* Flag links leaving the repo; never materialise one
- *(report)* Flag review configuration the changeset modifies
- *(release)* Generate the changelog and cut releases with git-cliff

### 🐛 Bug Fixes

- *(review-council)* Prevent silent rubber-stamp when verdict files lose structure
- *(review-council)* Make pipeline read-only by default, add effort tiers
- *(review-council)* Enforce read-only pipeline, add effort tiers and recovery
- *(review-council)* Repair the core pipeline paths
- *(review-council)* Close the second round of defects
- *(review-council)* Repair five high-severity defects
- *(eval)* Point lola-eval at the repo's tests directory
- *(review-council)* Sort agent verdict ingestion by name
- *(consolidate)* Leave session state unchanged on re-run
- *(task)* Redirect mktemp into the scratch tree on macOS
- *(schema)* Stop rejecting a verdict over its title length
- *(context)* Stop byte-capping first-party forge context
- *(context)* Match closing keywords in any case
- *(mutate)* Snapshot the module tree once per run
- *(prepare)* Let --scope paths name a file, not only a filter
- *(test)* Stop RC-24 depending on filesystem readdir order
- *(prepare)* Close the config-block sed for BSD sed
- *(report)* State which markers sit under a renderer heading
- *(report)* Decide the council verdict by severity, not by mode
- *(comment)* Stop pointing PR readers at unreachable run artifacts
- *(footer)* Break the line before the feedback invitation
- *(delegate)* Name the artifacts a batched round writes
- *(agents)* Disambiguate -code and -spec reviewer descriptions
- *(verify)* Add three severity calibration rules for non-defect findings
- *(skill)* Stop the deep cost gate from blocking the run
- *(driver)* Stop reporting each turn's result as the run finishing
- *(debug)* Reach rc-prepare's success path and keep stderr out of JSON
- *(prepare)* Classify the mode from the scope actually captured
- *(collect)* Make verdict persistence orchestrator-owned and recoverable
- *(prepare)* Let a range review run without main or master
- *(security)* Refuse a range value that git would read as an option
- *(dedup)* Keep the more severe duplicate whole, not just its severity
- *(verify)* Claim nothing from a wrong-shaped manifest instead of dying
- *(tests)* Keep regex interval bounds within BSD's RE_DUP_MAX
- *(skill)* Hand the orchestrator path values instead of shell variables
- *(lint)* Clear megalinter findings on PR #66
- *(clone-target)* Authenticate github.com fetches through gh
- *(github)* Read every page of a pull request's lists
- *(render)* Refuse a re-review that skipped Disposition
- *(report)* Decide the council verdict by script
- *(clone)* Give each GitHub review its own worktree
- *(review-open-prs)* Report done only when a verdict was posted
- *(prepare)* [**breaking**] Read review configuration from the base revision
- *(security)* Route base-revision review config to reviewers via prompts
- *(clone)* Review in place only at the PR head commit

### 🚜 Refactor

- *(review-council)* Replace LLM procedure files with script+phase hybrid
- Fork to standalone repo, overhaul agents and packs
- *(module)* Make agent definitions host-agnostic
- *(review-council)* Split the oversized units

### 📚 Documentation

- *(readme)* Correct pipeline phases, diagram, and step list
- *(readme)* Fix verification sweep path and agent-file naming
- *(readme)* Resolve first-read contradictions and dead pointers
- *(readme)* Break manual install into steps, name the packs directory
- Extract batch PR reviewing into its own how-to
- *(readme)* Add PR-posting sequence diagram and hero demo spec
- Correct queue-gate diagram, install paths, and lost prerequisite
- Correct review-council doc drift and split oversized guides
- *(agents)* Condense developer guide to rules agents need
- *(dev)* Add an A/B evaluation guide
- *(readme)* Add project banner, icon, and social preview artwork
- *(release)* Document the release procedure

### ⚡ Performance

- *(module)* Compress markdown to caveman style for token savings

### 🧪 Testing

- *(review-council)* Add the test matrix and wire up CI
- *(verify-evidence)* Size the argv fixture for the weaker of two limits
- *(prepare)* Leave a fixture directory before removing it
- *(eval)* Add code-graph pre-pass cases and reject the integration
- *(eval)* Fix judge-output shapes that discarded passing verdicts
- *(eval)* Measure context-mode's cost and quality effect on reviews
- *(eval)* Add CodeGraph arms to the context-mode adoption probe
- *(mutate)* Guard the base-revision configuration rule

### ⚙️ Miscellaneous Tasks

- *(megalinter)* Keep the golden fixture checkout out of the linters
- *(task)* Give lint and fmt one shfmt definition
- Run test layers as parallel jobs and scope the degraded layer
- *(eval)* Record 97 ledger rows and 47 run snapshots
- Run the mutation layer nightly instead of on every PR
- *(release)* Publish releases on tag and test the release tooling
