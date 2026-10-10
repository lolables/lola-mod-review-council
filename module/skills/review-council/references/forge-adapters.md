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
| `rc_forge_fetch_pr <pr> <owner> <repo>`         | `pr_title`, `pr_body`, `pr_base`, `pr_head`, `pr_head_sha`, `pr_url`, `pr_state`, `pr_status_checks` |
| `rc_forge_fetch_diff <pr> <owner> <repo> <out>` | Writes the PR diff to `<out>`                                                |

`pr_head_sha` is the head commit the forge reports (GitHub `headRefOid`,
GitLab `.sha`), kept only when it is a full 40-hex commit id and emptied
otherwise. `prepare-emit.sh` records it in `session.txt` as `Head SHA:` (`none`
when empty); it is the commit the posted marker names (see "Marker and reviewed
commit"), and GitLab hands it to `rc-clone-target.sh` as `--head-sha`.

`prepare-target.sh` passes every one-line value an adapter sets (`pr_title`,
`pr_base`, `pr_head`, `pr_url`, `pr_state`) through `rc_single_line` before
anything is written: each control character, line breaks included, becomes a
space. The values are the PR author's text and land in line-oriented files read
first match wins, so a title holding `\nHead SHA: <sha>` would otherwise add a
line of its own. `Head SHA:` is also written before `PR:` in `session.txt`.

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

GitHub's list endpoints (`pulls/<n>/reviews`, `pulls/<n>/comments`,
`issues/<n>/comments`) are read with `gh api --paginate --slurp` and merged in
order; a failed call or an error page yields `[]`, never a partial list.

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

| Capability                       | `lib/forge/gitlab.sh`                                                   |
|----------------------------------|-------------------------------------------------------------------------|
| Required contract                | implemented; `pr_status_checks` is left empty, so no pipeline status    |
| `rc_forge_fetch_conversation`    | implemented: MR notes, oldest first, system notes dropped, timestamps normalised to UTC |
| `rc_forge_current_user`          | implemented: the GitLab username of the account glab is logged in as    |
| `rc_forge_fetch_reviews` / `rc_forge_fetch_review_comments` | absent, so no `prior-reviews.txt` (known gap) |
| `rc_forge_fetch_issue`           | absent                                                                  |

The review gap is a missing source, not a missing translation: a GitLab
approval carries no body and no timestamp, so filling it means choosing between
approvals and "approved this merge request" system notes. The conversation does
not wait on it.

**Addressing.** Every call names its merge request by host and project:
`--hostname <host>` plus the URL-encoded project path for `glab api`, `-R
<host>/<group…>/<project>` for `glab mr`. Left unaddressed, glab picks the
project from the launch directory's remotes and the host from its own default,
and could read another project's MR with the same number. The host comes from
`forge_host`, which `prepare-repo.sh` sets and `prepare-emit.sh` records in
`session.txt` as `Host:`; the post script and the renderer read it back from
there.

**URL scope.** `--scope url` accepts a `github.com` pull request URL, or a
GitLab merge request URL (`https://<host>/<group…>/<project>/-/merge_requests/N`)
on any host. A GitHub Enterprise or other self-hosted GitHub URL is refused as
an unsupported forge, and a GitLab URL with a port is refused, because glab
addresses a host by name only. Both refusals, and a URL whose project or number
cannot be read, are terminal `skip`s.

**Host refusal gate.** Before any other forge call under `--scope url`,
`rc-prepare.sh` runs `rc_forge_host_refusal <host>`, which passes only when
`glab auth status --hostname <host>` does. For a host absent from glab's config
that check fails locally, without contacting the host, so a pasted MR URL on a
host the user never logged glab in to collects no credentials. Adapter
functions ask again through `rc_forge_glab_admits` (cached per host for the
process, failing closed) rather than trusting that preparation ran;
`gitlab.com` is exempt there.

**Token binding.** glab sends `GITLAB_TOKEN`, `GITLAB_ACCESS_TOKEN` and
`OAUTH_TOKEN` to whichever host a call names. `rc_forge_glab` keeps them only
when the call's host is glab's default host — the first non-empty of
`GITLAB_API_HOST`, `GITLAB_HOST`, `GITLAB_URI`, `GL_HOST`, else `gitlab.com` —
and removes them otherwise, so any other host gets its own stored login.

**Variables stripped from every call.** `GITLAB_API_HOST` and
`GLAB_ENABLE_CI_AUTOLOGIN` are removed from every glab call, set or not. Each
redirects an explicitly addressed call to another instance (the second to the
CI job's own, with the job token), which would aim the host gate at one host
and the calls at another.

## Architecture: shared renderer + per-forge post script

Posting is split along the seam where forges actually differ — URL schemes and
API mechanics — while everything else is shared.

- **`rc-render-comment.sh`** — the forge-NEUTRAL renderer. It owns ALL markdown
  assembly (verdict header, disclaimer, model provenance, reviewed-commit stamp,
  severity summary, reviewer table, findings `<details>`, footer, hidden marker,
  em/en-dash sanitize) and computes the neutral facts itself (head SHA — see "Marker and reviewed
  commit" — forge
  web host from the `Host:` recorded in `session.txt`, else the origin remote,
  severity counts, persona labels). It holds no
  forge knowledge. It is a library-with-main:
  - **sourced:** `rc_render_comment_body <session_dir> <body_file>` renders the
    body and exports `RC_FORGE_WEB` / `RC_SHORT_SHA` / `RC_HEAD_SHA` back to the
    caller.
  - **standalone:** `rc-render-comment.sh <session_dir>` renders `comment-body.md`
    and prints `{"status":"rendered", ...}` — the render-only fallback.
- **`rc-post-comment-<forge>.sh`** — a per-forge post script. It defines the
  three hooks (below), sources the renderer, then owns the auth gate, the upsert
  **policy**, and the forge API mechanics inline.
  - GitHub is implemented in full (`rc-post-comment-github.sh`).
  - GitLab (`rc-post-comment-gitlab.sh`) is a section-by-section port of it,
    posting merge request notes through `glab api`. It sources
    `lib/forge/gitlab.sh` and makes every call through that adapter's
    `rc_forge_glab`, after `rc_forge_glab_admits` has passed the host recorded
    in `session.txt` (`Host:`, default `gitlab.com`). Note bodies travel as a
    JSON file (`--input`), never as an argv field, because a verdict can exceed
    the 128 KiB a single argument may hold. The notes listing is paginated; a
    failed call or a page that is not an array is an error, never "no notes".
- **`rc-post-comment.sh`** — a thin router. Reads `Forge` and `PR` from
  `tracking.md`; skips when there is no PR; execs `rc-post-comment-<forge>.sh`
  (args passed through) when it exists, else execs the renderer standalone. It
  never writes upstream and never interprets `--send`.
- **`rc-clone-target.sh`** — a separate materialization script for GitHub
  pull requests and GitLab merge requests, invoked by `rc-prepare.sh`.

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
- `Max comments: N` (default 3) is **policy**: how many comments one verdict may
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

The `sha=` field identifies the exact commit reviewed. The renderer takes it,
in order, from `session.txt`'s `Head SHA:` (the PR/MR head the forge reported),
from the materialized checkout's `HEAD`, or — for a local review only — from
the working tree's `HEAD`. A review by PR number or URL (`Input:` `pr_number` or
`url`) that runs in `.` without a recorded head writes `sha=unknown` rather
than the launch checkout's `HEAD`, which need not be the PR's. A GitLab
`review_root` is an extracted archive with no `.git`, so there the recorded head
is the only source. `part`/`of` place the
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
nothing rather than fall back to marker-only selection. `rc-post-comment-gitlab.sh`
does the same on `.author.id` against the numeric `id` from `glab api user`,
refusing anything but a positive integer. Both read the marker line through the
one `RC_MARKER_LINE_JQ` in `rc-lib.sh`.

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
forge collapses it. GitLab has no equivalent of hiding, so there the banner is
the whole of it; its first line is byte-identical on both forges, because the
batch status scripts read exactly that line as "collapsed". Nothing is ever
deleted.

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
confirmed. `rc-post-comment-gitlab.sh` is stricter, because GitLab cannot hide
a note and a banner it failed to write leaves a stale verdict reading as
current: it counts only notes it actually retired (or found already retired —
the banner as the FIRST line, never the tag anywhere in the body), and reports
the rest as `retire_failed`, with the status still `posted`.

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

`rc-prepare.sh` calls this to obtain a working tree at the PR or MR head. It
emits `{"status":"in_place|ok|skip","review_root":"…"}`; on every `skip` the
`review_root` stays `.` and reviewers work from the diff. A forge other than
`github` or `gitlab`, or identifiers failing the gate, skip before any git
or glab command runs. The gate is `^[a-zA-Z0-9._-]+$` on `owner` and `repo` for GitHub
and `^[0-9]+$` on `pr` for both. A GitLab `owner` is a namespace that may nest
subgroups (`group/subgroup`), so for GitLab every `/`-separated segment of
`owner/repo` is gated on its own: the same character class, no leading `-`,
and never empty, `.` or `..`. `repo` never holds a `/`. That is
`project_path_ok` in `rc-lib.sh`, the same gate `rc-prepare.sh` applies.

**Which host was asked for.** The target host is the host in `--url` when one is
given, otherwise the forge's canonical host: `github.com` or `gitlab.com`.

A `--url` must name the same repository as `--owner`/`--repo`: its path,
compared case-insensitively with any `.git` dropped, must equal
`<owner>/<repo>`. Otherwise the script skips before any git or glab command
runs.
The URL decides what is cloned and owner/repo decide the cache entry and what
the messages report, so a disagreement would file and report one project's
checkout as another's.

`rc-prepare.sh` invokes the script whenever the forge resolved to `github` or
`gitlab` and a PR/MR number is known. It passes `--forge --owner --repo --pr
--head`, plus `--url https://<host>/<owner>/<repo>.git` whenever the session
has a host, so a self-hosted GitLab is never silently swapped for gitlab.com.
That host has already passed `rc_forge_host_refusal` under `--scope url` before
this script runs. A GitHub Enterprise or other self-hosted GitHub install is
refused earlier and never gets this far, so the non-`github.com` GitHub paths
below document the script's own contract, not a capability the module offers.

The origin remote is never a source for the target host: under URL scope the
checkout we happen to be standing in has nothing to do with the PR being
reviewed, and an `owner/repo` pair is one name collision away from a mirror — or
from a host an attacker controls — serving the same two path segments.

**In place.** The current working tree is reused only when the origin remote's
host and whole project path (`owner/repo`, subgroups included) match the target
(compared case-insensitively) **and** the current branch equals `--head`. Status
is then `in_place` with `review_root` `.`. The host is part of the test, not an
incidental detail: standing in a same-named repository on a different host is
exactly when the tree must not be reused, because `review_root` would then point
at foreign content that the verify phase grounds findings against as though it
were the PR. (A `--url` carrying an explicit port parses to no host at all, so
it never matches a portless origin — and it never reaches the `gh` tier below.)

**GitHub: clone tiers.** The destination is
`${XDG_CACHE_HOME:-$HOME/.cache}/review-council/clones/<key>`, keyed as "Cache
key" below describes.
An existing `.git` there is reused as-is; otherwise these are tried in order,
each bounded by a 120s timeout:

Every network call below (`gh repo clone`, `git clone`, `git fetch`, and the
`git checkout` that downloads a blobless clone's blobs) runs with
`GIT_TERMINAL_PROMPT=0 GCM_INTERACTIVE=never GIT_ASKPASS= SSH_ASKPASS=`. A
private host with no credential helper then fails at once instead of prompting
until the timeout; a configured credential helper still answers.

On github.com, when `gh` is on PATH, the `git` calls also get gh as a
credential helper for `https://github.com`, passed through
`GIT_CONFIG_COUNT`/`GIT_CONFIG_KEY_n`/`GIT_CONFIG_VALUE_n` after any entries
the caller set. `gh repo clone` authenticates only the clone it runs, so
without this a private repository's `pull/N/head` fetch had no credentials
unless the operator had run `gh auth setup-git`. Nothing is written to any git
config file, and no other host ever asks gh for a token.

1. `gh repo clone <owner>/<repo> -- --filter=blob:none --no-checkout` — only
   for `--forge github` when the target host is `github.com` and `gh` is on
   PATH. `gh repo clone`
   resolves `OWNER/REPO` against gh's own default host, so anywhere else it
   would clone a same-named repository from github.com rather than the one asked
   for.
2. `git clone --filter=blob:none --no-checkout -- <clone-url>`.
3. `git clone --depth 50 -- <clone-url>`.

`<clone-url>` is `--url` verbatim, else
`https://<target-host>/<owner>/<repo>.git` — built from the host the caller
named, never from the origin's. Tiers 2 and 3
`rm -rf` the destination first: a failed clone leaves a partial directory behind
and the next `git clone` would abort with "destination exists" instead of
retrying. All three failing is a `skip`.

**GitHub: fetch and checkout.** After a clone (or a cache hit), `git fetch
origin pull/<pr>/head` — the ref lives on the base repo, so pull requests from
forks work — then `git checkout FETCH_HEAD`. Each failure is its own `skip`
message. The checkout is not cosmetic: a blobless `--no-checkout` clone has no
files until it runs, and reporting `ok` over an empty tree would strip every
finding as `FILE_NOT_FOUND`, producing a false-clean review.

The GitHub checkout keeps the symlinks the pull request commits; only the
GitLab path below removes them. Removing them here too is a known follow-up.

**GitLab: the archive at the head sha.** A GitLab merge request is not cloned.
An unauthenticated `git clone` of a private project fails, and the one
credential bound to the host is glab's, which git cannot borrow safely:
`glab auth git-credential get` answers with a token for any host it is asked
about, and `glab repo clone` defaults to SSH. So the tree comes from the GitLab
API through glab, every call made with `rc_forge_glab` after
`rc_forge_glab_admits` (`lib/forge/gitlab.sh`; see "GitLab status" above):
the configured-host gate, `rc_timeout`, environment tokens only
for the host they are bound to, and `GITLAB_API_HOST` and
`GLAB_ENABLE_CI_AUTOLOGIN` removed.

1. The host is `--url`'s, lowercased, else `gitlab.com`. One that is empty (a
   ported `--url`) or not a hostname is a `skip`: glab addresses a host by bare
   name.
2. `rc_forge_glab_admits` refuses a host glab is not logged in to; the `skip`
   message carries its refusal. gitlab.com is exempt, as everywhere in the
   adapter.
3. The head sha is `--head-sha` when preparation passes it (the adapter's
   `pr_head_sha`), else `glab api --hostname <host>
   projects/<enc>/merge_requests/<pr>` reads it (`.sha`). Either way it must
   match `^[0-9a-f]{40}$` — it names a cache directory and goes into the next
   request — and a malformed one is a `skip`.
4. **What is cached.** The cache entry holds the archive file itself,
   `<sha>.tar.gz`, and nothing else; an archive at a sha never changes, so a
   cached one cannot go stale. When the entry has no plain file for this sha,
   `glab api … projects/<enc>/repository/archive.tar.gz?sha=<sha>` (120s)
   downloads into a hidden `.archive.*` directory under the cache root, removed
   on every exit until the archive is moved into the entry. The archive is
   re-checked (steps 5-6) on every run, cached or not: the checks are what make
   it safe to unpack, not a property of how it was fetched.
5. The archive is bounded before anything is unpacked, each by an environment
   cap whose value must be a plain integer (anything else falls back to the
   default; a leading zero is decimal):

   | Variable                                   | Bounds                                     | Default   |
   |--------------------------------------------|--------------------------------------------|-----------|
   | `REVIEW_COUNCIL_ARCHIVE_MAX_BYTES`          | the downloaded archive                     | 200 MiB   |
   | `REVIEW_COUNCIL_ARCHIVE_MAX_ENTRIES`        | its member count                           | 200000    |
   | `REVIEW_COUNCIL_ARCHIVE_MAX_UNPACKED_BYTES` | the bytes it unpacks to, plus step 10's files | 2 GiB  |
   | `REVIEW_COUNCIL_MAX_CHANGED_FILES`          | step 10's changed-file list                | 300       |

   `0` is valid: `REVIEW_COUNCIL_MAX_CHANGED_FILES=0` sends every MR with a
   changed file to the diff-only fallback.

   Every download is piped through `head -c <cap + 1>`, so an oversized
   response stops one byte past its cap instead of filling the disk. The
   unpacked size is measured by streaming every member through `tar -xzOf … |
   head -c … | wc -c` rather than by summing the sizes `tar -tv` prints: GNU tar
   and bsdtar lay that listing out differently, and an owner name holding
   spaces shifts the column in either. Every `tar` run is bounded by
   `rc_timeout`.
6. The member list (`tar -tzf`) is streamed through `awk`, never held — a
   listing of long paths runs to gigabytes — and stops at the first absolute
   member or one with a `..` component, which refuses the whole archive, or at
   the entry past the cap. The members are the MR author's to choose; GNU tar
   and bsdtar both already refuse to extract outside the target by default, and
   this refuses before either is asked. A listing that fails partway is a
   failed read even if every member it reached was fine.
7. **Each run's own tree.** A validated download replaces the whole entry (an
   archive at an older sha, or a tree or clone left by an earlier layout of this
   cache). The run then unpacks the archive into a fresh directory of its own,
   `.runs/<entry>.XXXXXX` under the cache root, with `tar -xzf …
   --strip-components=1 --no-same-owner --no-same-permissions` (flags common to
   GNU tar and bsdtar): GitLab's `<repo>-<sha>-<sha>/` wrapper is dropped, no
   owners are taken from the archive and modes pass through the umask. Neither
   tar extracts through a symlink the archive created, and both refuse a hard
   link whose target leaves the directory. That tree is `review_root`.
8. Everything in the tree that is not a regular file or a directory is deleted
   — symlinks of every shape, FIFOs, devices — and so is any regular file with
   a second hard link (`find`, which does not follow links). A committed symlink
   is the author's to aim, at `/etc/passwd` or a credentials file, and every
   reviewer would read through it as though it were repository content; git
   cannot commit a hard link, so one came from the archive. The count is
   reported as `"special_files_removed": <n>` beside `review_root`, and in the
   message. A consequence: a finding anchored at a file the MR commits as a
   symlink cannot be verified on GitLab, and is stripped `FILE_NOT_FOUND`.
9. GitLab builds the archive with `git archive`, which honours the commit's own
   `.gitattributes`: `export-ignore` leaves a file out and `export-subst`
   rewrites it with commit metadata. Both are the MR author's to set, and a
   file left out strips every finding in it as `FILE_NOT_FOUND` — a false-clean
   review of the author's choosing.
10. So the files THIS merge request changes are listed
    (`merge_requests/<pr>/diffs?per_page=100`, paginated) and each is fetched as
    its exact blob at the head sha (`repository/files/<path, @uri-encoded>/raw?ref=<sha>`)
    into this run's tree, on every run: two merge requests can share a head sha
    (a second MR from the same source branch, or one retargeted) and change
    different files. Deleted files (absent at the head) and submodule bumps
    (mode `160000`, not a file) are skipped. Every listed path must be a string
    with no control character, no leading `/`, and no empty, `.` or `..`
    segment; every directory on its way must be a real directory and the path
    itself must not be one. Each blob is staged beside the tree, bounded by
    what is left of the unpacked cap. A listing that fails, is not a series of
    arrays, holds an unsafe path or more files than the cap, any fetch that
    fails, or the files outgrowing the unpacked cap, refuses the whole tree.
11. An archive with no files is a `skip`, for the same false-clean reason as the
    GitHub checkout.

Two residuals are accepted. Files the merge request does not change can still
be left out or rewritten by `export-ignore`/`export-subst`: they are context for
the reviewers, not where findings are anchored, so the cost is weaker context,
not a false clean. And the changed files are listed after the head sha is read,
so a push landing in between can make the list describe a newer head than the
one fetched; every file is still fetched at the recorded sha, so the tree is
exact for that commit, at worst with one file too many or too few.

Any failure — gate refusal, a failed lookup or download, a malformed sha, a cap
exceeded, an unreadable or unsafe archive, an untrustworthy changed-file
listing — is a `skip` with its own message and `review_root` `.`. No run tree,
staged blob or download survives a failure; a refused archive is never cached.

Every removal of a GitLab tree (replacing an entry, cleaning up a download
directory or a failed run's tree, eviction) first makes its directories
writable: modes pass through the umask, which never adds write permission, so a
directory archived `0555` extracts read-only and a plain `rm -rf` fails inside
it.

**Concurrent runs.** A GitLab run never writes anything another run reads:
each unpacks and fills a tree of its own, and the cached archive is replaced by
rename, so a run already reading the old file keeps it. Two runs over one
project neither see each other's changed files nor pull a tree out from under
each other; the worst a race does is fail a run that finds the entry between
its removal and the new archive's arrival, which is a `skip`. Run trees are
bounded by the prune below: six hours at most, and the newest few only.
The GitHub path still shares one checkout per project: a second run's fetch and
checkout move the first run's working tree, so run GitHub reviews of one
project one at a time.

**Cache LRU.** A successful materialization `touch`es its destination (the cache
entry, for GitLab the directory holding the sha's archive) to mark it
most-recently-used. The clones directory is then listed by mtime with `ls -dt`
(POSIX — `find -printf` is GNU-only and this cap has to hold on macOS too) and
every entry past `REVIEW_COUNCIL_CLONE_CACHE_MAX` (default 10; a non-numeric
value falls back to 10) is removed, skipping the destination just materialized.
Hidden `.archive.*` download directories and `.runs/` trees are not entries
and are never listed, so evicting an entry never removes a tree a review is
reading. A download directory older than an hour (`find -mmin +60`) belongs to
a run killed before its cleanup and is removed. Run trees are bounded twice,
since each can hold up to the unpacked cap and a batch leaves one per review:
one older than six hours (`-mmin +360`; reviews take minutes) is removed, and
past the newest `REVIEW_COUNCIL_MAX_RUN_TREES` (default 8, integer-validated;
`0` keeps only the current run's tree;
by mtime with `ls -dt`, as for entries) the rest are removed too. The tree the
current run returns as `review_root` is never removed, whatever its mtime. A
session resumed after its run tree was swept has lost its `review_root`, and
evidence verification strips every finding as `FILE_NOT_FOUND`: re-run
preparation rather than resuming.

**Cache key.** The entry is named for the endpoint, not for the repository
alone: `<host>-<owner>-<repo>`, so `github.com-acme-widgets` and
`ghe.corp.example-acme-widgets` are separate checkouts. Without the host, a
clone of `acme/widgets` taken from one host would be served back for an
`acme/widgets` named on another; the head-ref fetch above
then runs against the wrong origin and the review grounds every finding in a
foreign repository while still reporting `ok`. That is the `in_place` host
test's failure mode one layer down.

GitLab entries are joined with `+` instead: `<host>+<segment>+…+<repo>`, so
`gitlab.com+g+sub+p` for project `g/sub/p`, holding `<sha>.tar.gz`. A subgroup's `/` must not become a
nested directory, and folding it into `-` would file group `g/sub` project `p`
and group `g-sub` project `p` under one entry. Neither a gated segment nor a
host slug can contain `+`, so the name splits back into exactly one host and
path. GitHub keeps the `-` key so existing cache entries remain valid.

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
  it carries gh's own auth (private repos). The fetch and checkout that follow
  get the same auth through gh as a process-scoped credential helper. Every
  other GitHub host, and the `gh`-less case, falls through to `git clone`,
  which honours the URL and whatever the operator's credential helper
  supplies — public repos without one. A GitLab merge request is fetched as a repository archive through `glab`
  with glab's own auth, so private projects work wherever glab is logged in.
  See "Materializing the target repo".
- Comment: `rc-post-comment-github.sh` requires `gh` authenticated for the
  target repo. Absent `gh`, `--send` degrades to render-only.
  `rc-post-comment-gitlab.sh` requires `glab` logged in to the recorded host,
  checked by the same `rc_forge_glab_admits` gate as preparation. Absent `glab`,
  `--send` degrades to render-only.

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
