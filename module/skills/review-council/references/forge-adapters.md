# Forge Integration

Forge-specific operations (cloning a target repo, posting/upserting a PR
comment) are selected on the `forge` value detected by `rc-prepare.sh`
(Section 2: `github`, `gitlab`, or `local`). This file documents the posting
architecture so new forges can be added without touching orchestration.

## Architecture: shared renderer + per-forge post script

Posting is split along the seam where forges actually differ — URL schemes and
API mechanics — while everything else is shared.

- **`rc-render-comment.sh`** — the forge-NEUTRAL renderer. It owns ALL markdown
  assembly (verdict header, disclaimer, model provenance, reviewed-commit stamp,
  severity summary, reviewer table, findings `<details>`, footer, hidden marker,
  em/en-dash sanitize) and computes the neutral facts itself (head SHA, forge
  web host from the origin remote, severity counts, persona labels). It holds no
  forge knowledge. It is a library-with-main:
  - **sourced:** `rc_render_comment_body <session_dir> <body_file>` renders the
    body and exports `RC_FORGE_WEB` / `RC_SHORT_SHA` / `RC_HEAD_SHA` back to the
    caller.
  - **standalone:** `rc-render-comment.sh <session_dir>` renders `comment-body.md`
    and prints `{"status":"rendered", ...}` — the render-only fallback.
- **`rc-post-comment-<forge>.sh`** — a per-forge post script. It defines the two
  URL hooks (below), sources the renderer, then owns the auth gate, the upsert
  **policy**, and the forge API mechanics inline. GitHub is implemented
  (`rc-post-comment-github.sh`). Other forges add a sibling.
- **`rc-post-comment.sh`** — a thin router. Reads `Forge` and `PR` from
  `tracking.md`; skips when there is no PR; execs `rc-post-comment-<forge>.sh`
  (args passed through) when it exists, else execs the renderer standalone. It
  never writes upstream and never interprets `--send`.
- **`rc-clone-target.sh`** — a separate materialization script (GitHub-only
  today) invoked by `rc-prepare.sh`.

## The two URL hooks

The renderer delegates every forge-specific URL to two functions the per-forge
script defines before calling in:

| Hook | Inputs | Returns | GitHub |
|------|--------|---------|--------|
| `rc_url_file` | `forge_web sha file line` | file deep-link URL, or empty | `${web}/blob/${sha}/${file}#L${line}` |
| `rc_url_commit` | `forge_web sha` | commit URL, or empty | `${web}/commit/${sha}` |

When a hook is undefined (standalone fallback) or returns empty (e.g. no head
SHA), the renderer emits a plain `` `code span` `` / plain short-sha. A future
GitLab script defines the hooks with `/-/blob/…` and `/-/commit/…`. That is the
entire per-forge URL surface.

## Marker and reviewed commit

Every rendered body ends with a hidden tag carrying the reviewed commit SHA:

    <!-- review-council:marker sha=<full-head-sha> -->

The literal `review-council:marker` identifies any council comment; the `sha=`
field identifies the exact commit reviewed. Both GitHub and GitLab render HTML
comments invisibly, so the marker is portable. The body also shows a visible
`Reviewed at commit <short-sha>` line.

## Re-review policy (owned by each per-forge post script)

An upsert is only correct when the reviewed code is the same. The policy keys on
the head SHA:

1. **A comment already exists for this SHA:**
   - body identical to the freshly rendered one → **no-op** (`action: unchanged`).
   - body differs → **update in place** (`action: updated`).
2. **No comment for this SHA** (new commit, or first review):
   - **create** a fresh comment (`action: created`), then **supersede** every
     prior council comment on a different SHA: edit in an "Obsolete, superseded
     by …" banner (tagged `review-council:obsolete`, idempotent) and hide it as
     OUTDATED so the forge collapses it.

This keeps one authoritative comment per commit, preserves a per-revision trail,
and never swaps a review of commit X onto commit Y (which would also invalidate
the SHA-pinned deep-links). The policy is duplicated per forge — the accepted,
honest cost of not abstracting six API calls behind a plugin layer; it is small
next to the shared rendering.

## Generic fallback

When `forge` is not one with a post script (or the forge CLI is absent), scripts
do **not** silently no-op. They render the artifact to `comment-body.md` in the
session directory and instruct the user to post it manually:

- Comment: the router execs the renderer standalone; the body has plain code
  spans (no deep-links) and a "post it manually" message.
- `clone_target` fallback: skip cloning; reviewers work from the diff only
  (`review_root` stays `.`). Grounding is weaker but the run still completes.

## Authentication

- Clone: prefer `gh repo clone` when `gh` is present (handles private-repo
  auth); otherwise plain `git clone` of the HTTPS URL (public repos only).
- Comment: `rc-post-comment-github.sh` requires `gh` authenticated for the
  target repo. Absent `gh`, `--send` degrades to render-only.

## Safety

- Posting is gated by `REVIEW_COUNCIL_ALLOW_POST=1`, a hard machine backstop to
  the orchestrator's Step 7 confirmation. The router never writes; the
  render-only fallback never writes.
- Cloning fetches source only. Reviewers never execute cloned project code
  (SKILL.md HARD-GATE).
- Superseding a prior review edits and hides earlier council comments on the
  same PR — still posting-scoped writes, never touching project code or
  non-council comments.
