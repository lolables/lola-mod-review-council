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

| Hook            | Inputs                    | Returns                      | GitHub                                |
|-----------------|---------------------------|------------------------------|---------------------------------------|
| `rc_url_file`   | `forge_web sha file line` | file deep-link URL, or empty | `${web}/blob/${sha}/${file}#L${line}` |
| `rc_url_commit` | `forge_web sha`           | commit URL, or empty         | `${web}/commit/${sha}`                |

When a hook is undefined (standalone fallback) or returns empty (e.g. no head
SHA), the renderer emits a plain `` `code span` `` / plain short-sha. A future
GitLab script defines the hooks with `/-/blob/…` and `/-/commit/…`. That is the
entire per-forge URL surface.

## Marker and reviewed commit

Every rendered body ends with a hidden tag carrying the reviewed commit SHA:

    <!-- review-council:marker sha=<full-head-sha> -->

The `sha=` field identifies the exact commit reviewed. Both GitHub and GitLab
render HTML comments invisibly, so the marker is portable. The body also shows a
visible `Reviewed at commit <short-sha>` line.

A council comment is one that carries the marker **and** was authored by the
identity doing the posting. The marker on its own is not proof of authorship: it
appears in every verdict comment ever posted and verbatim in this document, so
any PR participant can paste one — including with the current head SHA. Selected
on the marker alone, that comment would be overwritten with the verdict body, or
banner-stamped and hidden as outdated, under the write token of whoever ran the
review. So both listing selectors in `rc-post-comment-github.sh` (the find-by-SHA
lookup and the supersede listing) filter on `.user.login` against the account
resolved from `gh api user`, and every id the update and hide calls act on comes
out of one of those two listings. When that account cannot be resolved, or comes
back in a shape that is not a login, the script emits an `error` status and posts
nothing rather than fall back to marker-only selection.

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

## Materializing the target repo (`rc-clone-target.sh`)

`rc-prepare.sh` calls this to obtain a working tree at the PR head. It emits
`{"status":"in_place|ok|skip","review_root":"…"}`; on every `skip` the
`review_root` stays `.` and reviewers work from the diff. A forge other than
`github`, or an `owner`/`repo`/`pr` failing the `^[a-zA-Z0-9._-]+$` /
`^[0-9]+$` character gate, skips before any git command runs.

**Which host was asked for.** The target host is the host in `--url` when one is
given, otherwise `github.com`.

`--url` is part of this script's interface but no shipped caller passes it.
`rc-prepare.sh` invokes the script only when the forge resolved to `github`, and
passes `--forge --owner --repo --pr --head` and nothing else; under `--scope url`
it emits a terminal `skip` for any host but `github.com` or `gitlab.com`, so a
GitHub Enterprise or other self-hosted install never gets this far. Everything
below describing non-`github.com` targets therefore documents the script's own
contract, not a capability the module currently offers. Read it as the boundary
a direct caller must respect, and as what would have to hold before enterprise
hosts could be supported.

The origin remote is never a source for the target host: under
URL scope the checkout we happen to be standing in has nothing to do with the PR
being reviewed, and an `owner/repo` pair is one name collision away from a mirror
— or from a host an attacker controls — serving the same two path segments.

**In place.** The current working tree is reused only when the origin remote's
host, owner and repo all match the target (compared case-insensitively) **and**
the current branch equals `--head`. Status is then `in_place` with `review_root`
`.`. The host is part of the test, not an incidental detail: standing in a
same-named repository on a different host is exactly when the tree must not be
reused, because `review_root` would then point at foreign content that the
verify phase grounds findings against as though it were the PR. (A `--url`
carrying an explicit port parses to no host at all, so it never matches a
portless origin — and it never reaches the `gh` tier below.)

**Clone tiers.** The destination is
`${XDG_CACHE_HOME:-$HOME/.cache}/review-council/clones/<host>-<owner>-<repo>`.
An existing `.git` there is reused as-is; otherwise these are tried in order,
each bounded by a 120s timeout:

1. `gh repo clone <owner>/<repo> -- --filter=blob:none --no-checkout` — only
   when the target host is `github.com` and `gh` is on PATH. `gh repo clone`
   resolves `OWNER/REPO` against gh's own default host, so anywhere else it
   would clone a same-named repository from github.com rather than the one asked
   for.
2. `git clone --filter=blob:none --no-checkout <clone-url>`.
3. `git clone --depth 50 <clone-url>`.

`<clone-url>` is `--url` verbatim, else `https://<target-host>/<owner>/<repo>.git`
— built from the host the caller named, never from the origin's. Tiers 2 and 3
`rm -rf` the destination first: a failed clone leaves a partial directory behind
and the next `git clone` would abort with "destination exists" instead of
retrying. All three failing is a `skip`.

**Fetch and checkout.** After a clone (or a cache hit), `git fetch origin
pull/<pr>/head` — the ref lives on the base repo, so fork PRs work — then
`git checkout FETCH_HEAD`. Each failure is its own `skip` message. The checkout
is not cosmetic: a blobless `--no-checkout` clone has no files until it runs, and
reporting `ok` over an empty tree would strip every finding as `FILE_NOT_FOUND`,
producing a false-clean review.

**Cache LRU.** A successful materialization `touch`es its destination to mark it
most-recently-used. The clones directory is then listed by mtime with `ls -dt`
(POSIX — `find -printf` is GNU-only and this cap has to hold on macOS too) and
every entry past `REVIEW_COUNCIL_CLONE_CACHE_MAX` (default 10; a non-numeric
value falls back to 10) is removed, skipping the destination just materialized.

**Cache key.** The entry is named for the endpoint, not for the repository
alone: `<host>-<owner>-<repo>`, so `github.com-acme-widgets` and
`ghe.corp.example-acme-widgets` are separate checkouts. Without the host, a
clone of `acme/widgets` taken from one host would be served back for an
`acme/widgets` named on another; the `git fetch origin pull/<pr>/head` above
then runs against the wrong origin and the review grounds every finding in a
foreign repository while still reporting `ok`. That is the `in_place` host
test's failure mode one layer down, and only a direct caller passing `--url`
can name a second host in the first place.

The host is not character-gated the way `<owner>` and `<repo>` are, so it is
lowercased and reduced to their alphabet (`[a-z0-9._-]`, everything else
becomes `_`) before it becomes a path component. `parse_remote` already refuses
a host holding `/` or `:`, and the entry always ends in `-<owner>-<repo>` with
both non-empty, so the name cannot escape the cache root or resolve to `.` or
`..`. A URL `parse_remote` will not name — one carrying a port, for instance —
leaves the host empty, which would file every unnamable endpoint under one key;
those are keyed `url-<cksum of the clone URL>-<owner>-<repo>` instead, which
keeps two ported hosts apart.

Entries written under an earlier key shape are orphaned rather than migrated.
Nothing touches them again, so they sort oldest in the `ls -dt` listing and the
LRU prune evicts them first.

## Generic fallback

When `forge` is not one with a post script (or the forge CLI is absent), scripts
do **not** silently no-op. They render the artifact to `comment-body.md` in the
session directory and instruct the user to post it manually:

- Comment: the router execs the renderer standalone; the body has plain code
  spans (no deep-links) and a "post it manually" message.
- `clone_target` fallback: skip cloning; reviewers work from the diff only
  (`review_root` stays `.`). Grounding is weaker but the run still completes.

## Authentication

- Clone: `gh repo clone` is preferred on github.com when `gh` is present, since
  it carries gh's own auth (private repos). Every other host, and the `gh`-less
  case, falls through to `git clone`, which honours the URL and whatever the
  operator's credential helper supplies — public repos without one. See
  "Materializing the target repo".
- Comment: `rc-post-comment-github.sh` requires `gh` authenticated for the
  target repo. Absent `gh`, `--send` degrades to render-only.

## Safety

- Posting is gated by `REVIEW_COUNCIL_ALLOW_POST=1`, a hard machine backstop to
  the orchestrator's Step 7 confirmation. The router never writes; the
  render-only fallback never writes.
- Cloning fetches source only. Reviewers never execute cloned project code
  (SKILL.md HARD-GATE).
- Superseding a prior review edits and hides earlier council comments on the
  same PR — still posting-scoped writes, never touching project code, and never
  a comment authored by anyone but the posting identity (see "Marker and
  reviewed commit"; the marker alone does not make a comment ours).
