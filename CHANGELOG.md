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
- Close review defects and disclose provenance
- Materialize foreign PR targets for review
- Post the council verdict as a PR comment
- Surface full findings, fail loud on parse errors
- Make posted findings scannable
- JSON-native reviewer verdict pipeline
- *(session)* Cap the session cache like the clone cache
- *(scripts)* Add batch reviewer for a repo's open PRs
- *(report)* Give findings the same detail as the PR comment
- *(scripts)* Skip PRs written entirely by dependency bots
- *(consolidate)* Refuse to write a fold that loses findings
- *(scripts)* Stream council progress while a review runs
- *(comment)* Chain oversized verdicts across multiple comments
- Price deep fan-out before dispatch
- Narrow the council by change shape
- *(driver)* Re-review PRs when a write-access account asks in a comment
- *(delegate)* Compute delegation batches on context bytes
- *(scripts)* Add read-only PR status report and --ignore-approved
- *(prepare)* Review paths and all scope outside a git repository
- *(verify)* Apply validator outcomes by finding id
- *(testing)* Flag tests that cost upkeep without catching bugs
- *(verify)* Apply the correction round by script, re-checking each quote
- *(gitlab)* Review and post council verdicts on merge requests
- *(symlinks)* Flag links leaving the repo; never materialise one
- *(report)* Flag review configuration the changeset modifies
- *(release)* Generate the changelog and cut releases with git-cliff
- *(verdict)* Require and show an impact on HIGH and CRITICAL findings
- *(verify)* Calibrate and validate findings in one arbiter dispatch
- *(verify)* Derive each agent's verdict from its findings by script
- *(verify)* Recompute per-agent verdicts instead of hand-editing them
- *(adversary)* Flag fail-open defaults in config and policy changes
- *(release)* Stamp the release version into the installed skill
- *(report)* Name the installed council version in reports and plans
- *(delegate)* Hand reviewers changed-file text and gate bare APPROVEs
