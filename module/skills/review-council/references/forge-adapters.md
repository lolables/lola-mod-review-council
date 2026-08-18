# Forge Integration

Forge-specific operations (cloning a target repo, posting/upserting a PR
comment) are selected on the `forge` value detected by `rc-prepare.sh`
(Section 2: `github`, `gitlab`, or `local`). This file documents the posting
architecture so new forges can be added without touching orchestration.

## Preparation: one adapter per forge

Everything preparation needs from a forge goes through `lib/forge/<forge>.sh`,
sourced once by `rc-prepare.sh` on the `forge` value `prepare-repo.sh` detected,
before the stages that call it. `forge=local`, and any forge with no adapter
file, has none sourced — the stages test for each function with `declare -F` and
skip forge enrichment rather than branching on a forge name. Adding a forge is
adding a file.

### Required contract

Both must exist or the adapter is not usable:

| Function                                        | Sets / does                                                                  |
|-------------------------------------------------|------------------------------------------------------------------------------|
| `rc_forge_fetch_pr <pr> <owner> <repo>`         | `pr_title`, `pr_body`, `pr_base`, `pr_head`, `pr_url`, `pr_state`, `pr_status_checks` |
| `rc_forge_fetch_diff <pr> <owner> <repo> <out>` | Writes the PR diff to `<out>`                                                |

`pr_status_checks` is one `<name>: <grade>` line per check. Grades use the
vocabulary `prepare-emit.sh` Section 16 grades — GitHub's two enums are covered
there; a forge whose CI vocabulary differs maps to those tokens in its adapter,
not by adding arms to Section 16. Leaving it empty writes no `--- STATUS
CHECKS ---` section, and Quality Gates degrades to "no CI data" exactly as a
repository with no CI does.

### Optional capabilities

Omit any of these and the corresponding artifact is not written; the review
proceeds with less context. That is how a forge ships partial support without a
stub that pretends to work.

| Function                                             | Returns (normalized JSON)                | Artifact                |
|------------------------------------------------------|------------------------------------------|-------------------------|
| `rc_forge_fetch_issue <n> <owner> <repo>`            | `{title, body, state}`                   | `linked-issues.txt`     |
| `rc_forge_fetch_reviews <pr> <owner> <repo>`         | `[{author, state, submitted_at, body}]`  | `prior-reviews.txt`     |
| `rc_forge_fetch_review_comments <pr> <owner> <repo>` | `[{file, line, author, body}]`           | `prior-reviews.txt`     |
| `rc_forge_fetch_conversation <pr> <owner> <repo>`    | `[{author, created_at, body}]`           | `pr-conversation.txt`   |
| `rc_forge_current_user`                              | `<login>` (bare string, or empty)        | (no artifact; see below)|

`prior-reviews.txt` needs both review functions and is skipped unless both
exist, so a half-implemented adapter cannot report "no inline comments" for a
call it never makes.

`rc_forge_current_user` names the account the council posts as. It writes no
artifact; it decides whether the council's own verdict comment can be told apart
from a participant's reply that merely quotes it. Council identity is **marker
AND author** — the marker ships in every verdict this tool has ever posted, so
it is public by construction, and GitHub's "Quote reply" copies it into a
reply without anyone intending to. `rc-post-comment-<forge>.sh` has always
required both before it will update or hide a comment; the re-review filter in
`prepare-context.sh` now does too.

Three things send the filter back to marker-only, and an adapter author should
expect all three: omitting the function, implementing it and having the call
fail (on GitHub, a token without `read:user`), and returning a login that
authored none of the marker comments on the PR. The last is ordinary operation
rather than a fault — CI posts the verdict as a bot and a maintainer re-runs the
council under their own token, or the token rotates between runs — so a login
that matches nothing is treated as a wrong answer about identity, not as
evidence that no verdict was ever posted. Each fallback is **disclosed in
`pr-conversation.txt`**, naming which of the three it was, so the Disposition
phase can see that its input may be short and a maintainer knows what to repair.

The marker literal lives once, as `RC_MARKER_KEY` in `rc-lib.sh`, and the
opening that is actually matched lives beside it as `RC_MARKER_OPEN`. Match a
**line that starts with** that opening — never the key anywhere in the body.
`rc-render-comment.sh` emits the marker as the first thing on its own line, and
a quote of a verdict carries it behind a `> ` prefix, so column 0 is what
separates the two when there is no author to compare against. The poster matches
this way too (`RC_MARKER_LINE_JQ`); they are one contract, so they use one test.

`rc_forge_fetch_conversation` **must** return the timeline oldest first. The
re-review path takes `last` of the comments carrying the council's marker **and
authored by that login** to locate the most recent posted verdict, then selects
replies at or after that timestamp. Newest-first would pick the oldest verdict
ever posted and sweep in every reply since.

Do not anchor on `last` of a body merely *containing* the marker. A quote of the
verdict contains it and is posted *after* it, so such a `last` lands on the
quote and moves the window past every comment filed in between — and on the
fallback the exclusion then drops that same quote as the council's own, leaving
nothing to write and taking the disclosure with it.

Matching at column 0 leaves one genuinely ambiguous case: a body the council did
not write that puts a marker at the start of a line, which takes deliberate
effort rather than clicking "Quote reply". On the fallback that comment is read
as the verdict; with a login to compare against it is not.

### Why normalized shapes

Adapters return the module's field names, never the forge's. The stages that
render these files must not learn that GitHub spells an author `.user.login` and
a comment's file `.path` — otherwise the next forge has to impersonate GitHub's
REST vocabulary to reuse the renderer, which is the coupling this seam exists to
prevent.

### Degradation

Every function returns empty output, or an empty array, on failure — never a
non-zero exit. A forge that is down, rate-limiting or refusing auth costs the
review its context, not its life.

### GitLab status

`lib/forge/gitlab.sh` implements the required contract only, and reports no
pipeline status. Closing either gap is editing that one file.

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
- **`rc-post-comment-<forge>.sh`** — a per-forge post script. It defines the
  three hooks (below), sources the renderer, then owns the auth gate, the upsert
  **policy**, and the forge API mechanics inline. GitHub is implemented in full
  (`rc-post-comment-github.sh`). GitLab (`rc-post-comment-gitlab.sh`) declares
  its hooks and renders, but does not post: the upsert, supersede and identity
  policy has no `glab` equivalent yet, and a poster that creates a comment but
  cannot find its own on the next run leaves duplicate verdicts on the merge
  request. It exists anyway because the hooks live here — without a post script
  a GitLab review would get no permalinks and no size budget at all.
- **`rc-post-comment.sh`** — a thin router. Reads `Forge` and `PR` from
  `tracking.md`; skips when there is no PR; execs `rc-post-comment-<forge>.sh`
  (args passed through) when it exists, else execs the renderer standalone. It
  never writes upstream and never interprets `--send`.
- **`rc-clone-target.sh`** — a separate materialization script (GitHub-only
  today) invoked by `rc-prepare.sh`.

## The three forge hooks

The renderer delegates every forge-specific fact to functions the per-forge
script defines before calling in:

| Hook               | Inputs                    | Returns                      | GitHub                                | GitLab                                    |
|--------------------|---------------------------|------------------------------|---------------------------------------|-------------------------------------------|
| `rc_url_file`      | `forge_web sha file line` | file deep-link URL, or empty | `${web}/blob/${sha}/${file}#L${line}` | `${web}/-/blob/${sha}/${file}#L${line}`   |
| `rc_url_commit`    | `forge_web sha`           | commit URL, or empty         | `${web}/commit/${sha}`                | `${web}/-/commit/${sha}`                  |
| `rc_comment_limit` | none                      | max characters per comment   | `65536`                               | `1000000`                                 |

When a URL hook is undefined (standalone fallback) or returns empty (e.g. no
head SHA), the renderer emits a plain `` `code span` `` / plain short-sha. That
is the entire per-forge URL surface.

`rc_comment_limit` is a **fact about the API**, not a policy. GitHub rejects an
issue comment over 65,536 characters, and a 30-finding review already renders
58k of markdown — so the limit has to reach the renderer before it assembles a
body, not after the forge refuses one. GitLab's note cap is roughly fifteen
times larger, which is precisely why this is a hook: hardcoding the smaller
number in the neutral renderer would trim GitLab bodies that would have posted
whole.

An **undefined** `rc_comment_limit` means no limit. That is the manual-paste
fallback, which has no API to reject the body, so it stays full fidelity.

Two configuration keys sit on top of the hook (see the README's Extension
Points):

- `Comment limit: N` overrides the hook. It is for an effective limit smaller
  than the forge's own — self-hosted GitLab, or GHE behind a proxy that
  truncates bodies.
- `Max comments: N` (default 1) is **policy**: how many comments one verdict may
  be spread across. The budget is `comment_limit x max_comments`.

Both are resolved by `rc-prepare.sh` and written into `tracking.md`. That is not
duplication of the hook — it is the only way the numbers reach the renderer when
`rc-post-comment.sh` reaches it by `exec` rather than by `source`, because a
shell function cannot cross a process boundary. A standalone render with no
recorded limit does not pare.

## Oversized bodies: chaining, then paring

When a body exceeds the budget the renderer splits it across up to `Max
comments` parts at full fidelity, because a split body loses nothing. Only when
even the multiplied budget is exceeded does it start shedding detail, one class
at a time, analysis prose first and evidence last. Every level that fires adds a
disclosure line beginning `Trimmed to fit the` — a pared comment that reads as
complete is worse than an overflow error, because the maintainer cannot tell the
difference. That holds at the terminal case too: the cut reserves the disclosure
and the marker before it fills, so both outlive it even when nothing else does.
The ladder and its terminal case are documented at the top of
`scripts/rc-render-comment.sh`.

## Marker and reviewed commit

Every rendered body ends with a hidden tag carrying the reviewed commit SHA:

    <!-- review-council:marker sha=<full-head-sha> part=<n> of=<m> -->

The `sha=` field identifies the exact commit reviewed. `part`/`of` place the
comment in a chain; an unsplit verdict carries `part=1 of=1`. Both GitHub and GitLab
render HTML comments invisibly, so the marker is portable. The body also shows a
visible `Reviewed at commit <short-sha>` line.

A renderer writes the marker as the body's final line, alone. A reader scans back
for the **last** line that opens one, and matches only against that line — never
against the body at large.

Both halves earn their keep:

- **Reading a line, not the body.** A finding's evidence is a verbatim quote of
  the source under review, so it can reproduce the line above exactly, key and
  all. jq's `capture` returns the first match in its subject, so a selector that
  searched the whole body would read the quote and never reach the marker. The
  quote always sits above the marker, so the last marker line is the real one.
- **Scanning back, not taking the final line.** A maintainer may edit the
  comment and append a note, which pushes the marker off the end. A reader that
  insisted on the final line would stop recognising its own comment: it would
  post the verdict again beside the edited copy, and never retire that copy once
  the commit moved on.

`sha=` is one space-delimited token, not necessarily hex — an unresolvable HEAD
renders `sha=unknown` — so patterns that read it must accept the whole token.
The trimming ladder's terminal truncation cuts the body at a line boundary from
the top, which would take the marker with the rest of the tail. It reserves the
marker's length and re-appends it, so even a cut body stays identifiable to both
listings — a part that lost it would be orphaned, and the next run would post a
fresh comment beside it rather than supersede it.

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

An upsert is only correct when the reviewed code is the same, and a verdict now
spans up to `Max comments` comments. So the policy keys on **the head SHA and
the part within it**: this run's parts are matched against the last run's part by
part. Keyed on the SHA alone, part 2 of the re-render is written over part 1.

**Finding what is already there.** The find-by-SHA listing returns one row per
part — comment id, node id, part number — for the council comments carrying this
SHA, ordered by part; `rc-post-comment-github.sh` is the worked example. Its
selector reads the marker exactly as "Marker and reviewed commit" requires — the
**last** body line that opens one, matched as a whole line, `sha=` taken as an
opaque token rather than as hex, and the comment claimed as the council's only
when the author matches too. Chaining adds one rule of its own: a marker with
**no `part=`** is part 1, which is what it was, since comments posted before
chaining existed carry none.

Getting any of that wrong costs more here than in a lookup, because this listing
has to come back complete. A capture insisting on hex reads nothing out of a
`sha=unknown` marker, so every part of the chain falls back to part 1 — and the
supersede sweep below then reads an empty sha for the comments this run has just
posted, and retires them.

A **find-by-SHA listing that fails is an error, not an empty list**. Read as
"nothing posted yet" it posts the whole chain a second time, so the script
reports `error` and writes nothing. The supersede listing under "Retiring" takes
the opposite policy; the two are not interchangeable.

**Writing the parts.** For each part of the freshly rendered verdict:

1. **A comment exists for this SHA at this part:**
   - body identical to the rendered part → **no-op** (counted `unchanged`).
   - body differs → **update in place** (counted `updated`). A failed update ends
     the run with `error`; a half-written chain that says so beats one that
     reports success.
2. **No comment for this SHA at this part** (new commit, first review, or a
   verdict that grew a part) → **create** (counted `created`). A failed create
   ends the run the same way a failed update does.

Parts are written **tail first, head last**. The head carries the verdict, the
TL;DR and the links to the other parts, so it must not exist before the parts it
points at do — the links replace a placeholder line the renderer left for them
(`RC_PART_LINKS_TOKEN`) once the tail comments exist and their URLs are known. A
run that dies halfway then leaves detail comments with no verdict, which reads as
incomplete, rather than a verdict summarising findings nobody can see.

Substituting **grows a head the renderer already sized against the limit
exactly**, so the grown body is measured again and the substitution is discarded
whole if it no longer fits: the links go rather than the findings, since they are
navigation and the parts sit adjacent in the thread regardless. An adapter that
substitutes without re-measuring hands the forge an over-limit body and has it
rejected — the outcome chaining exists to avoid, arrived at one step later.

**Retiring.** Two disjoint sets, both swept **after** the new parts land;
superseding first opens a window in which the PR carries no verdict at all.

- **Surplus parts on this SHA.** A verdict needing fewer comments than the last
  run leaves parts behind. They carry the current SHA, so the prior-SHA sweep
  will not touch them — every part past the new total is retired explicitly, or
  the PR keeps showing findings the verdict no longer contains.
- **Every part of every prior SHA.** Selected on "not this SHA" rather than "not
  the comment I just wrote", because there are now several of those.

Retiring a comment is: edit an "Obsolete, superseded by …" banner above the
original body (tagged `review-council:obsolete`, skipped when one is already
there so a repeat run does not stack banners) and hide it as OUTDATED so the
forge collapses it.

Everything in this phase is **best-effort, and none of it is fatal** — the
opposite of the find-by-SHA listing above, and for a reason an adapter has to
keep: the current commit's verdict is already posted by the time any of it runs,
so a failure here has nothing left to protect and refusing would report a failed
run over a verdict that did post. Concretely, in `rc-post-comment-github.sh`: the
supersede listing degrades to zero rows rather than aborting, so a query that
fails retires nothing and the run still reports `posted`; a body it cannot read
gets no banner; and the banner edit and the hide are swallowed separately, so a
comment can end up unbannered, uncollapsed, or both, and the run says nothing
about it. The `superseded` count is therefore comments swept, not writes
confirmed.

**What gets reported.** `action` is one word for the whole chain — `created` if
any part was created, else `updated` if any was updated, else `unchanged` — so a
single-comment run reads exactly as it always did. The per-part counts ride
alongside: `parts`, `created`, `updated`, `unchanged` and `superseded`.

This keeps one authoritative chain per commit, preserves a per-revision trail,
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
