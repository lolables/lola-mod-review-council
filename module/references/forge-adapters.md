# Forge Adapters

Forge-specific operations (cloning a target repo, posting/upserting a PR
comment) are dispatched on the `forge` value detected by `rc-prepare.sh`
(Section 2: `github`, `gitlab`, or `local`). This file documents the
adapter contract so new forges can be added without touching orchestration.

## Contract

Each forge adapter provides these operations. GitHub is implemented now;
other forges are documented but not yet implemented and fall back to the
generic path.

| Operation | Inputs | Output | GitHub implementation |
|-----------|--------|--------|-----------------------|
| `find_comment` | owner, repo, pr, marker | comment id or empty | `gh api repos/{o}/{r}/issues/{pr}/comments --jq 'select body contains marker'` |
| `create_comment` | owner, repo, pr, body-file | — | `gh api repos/{o}/{r}/issues/{pr}/comments -f body=...` |
| `update_comment` | owner, repo, comment-id, body-file | — | `gh api repos/{o}/{r}/issues/comments/{id} -X PATCH -f body=...` |
| `clone_target` | owner, repo, pr, dest | checkout at PR head | `git clone --filter=blob:none --no-checkout` + `fetch pull/{pr}/head` |

## Marker

Upsert is keyed on a hidden HTML comment embedded in every posted body:

    <!-- review-council:marker -->

`find_comment` locates the existing council comment by this marker so
re-reviews edit one comment instead of spamming new ones. Both GitHub and
GitLab render HTML comments invisibly, so the marker is portable.

## Generic Fallback

When `forge` is not `github` (or the forge CLI is absent), scripts do **not**
silently no-op. They render the artifact to a file in the session directory
and instruct the user to act manually:

- `clone_target` fallback: skip cloning; reviewers work from the diff only
  (`review_root` stays `.`). Grounding is weaker but the run still completes.
- Comment fallback: write `comment-body.md` and tell the user to paste it
  into the PR themselves.

## Authentication

- Clone: prefer `gh repo clone` when `gh` is present (handles private-repo
  auth); otherwise plain `git clone` of the HTTPS URL (public repos only).
- Comment: requires `gh` authenticated for the target repo. Absent `gh`
  triggers the generic fallback.

## Safety

- Cloning fetches source only. Reviewers never execute cloned project code
  (SKILL.md HARD-GATE).
- Posting is the single permitted external write and is gated by explicit
  user intent plus confirmation (SKILL.md Step 7).
