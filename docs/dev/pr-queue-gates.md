# How a PR reaches the queue

This document explains the gates `scripts/review-open-prs.sh` puts between an
open pull request and the review queue: the order they run in, how the two
overrides cross, and what the driver accepts as a prior verdict of its own.
Read it if you are changing the driver's queueing rules or reasoning about why
a particular PR was skipped; running a batch needs only
[Batch-reviewing every open PR](../batch-reviewing-prs.md).

Seven gates decide each PR's fate, and the two overrides cross rather than nest:
naming a PR by number or URL jumps the **ignore list** but still respects the
already-reviewed check, while `--force` jumps the **already-reviewed** check —
and the hourly cap behind it — but never rescues an ignored bot PR. So a named,
unchanged, already-reviewed PR needs `--force` as well. A failed authorship
lookup fails open — the PR carries on to the reviewed check rather than dropping
out.

A PR already reviewed at its head has one more way through: someone with write
access can comment `/review-council review` and ask for another look. That path
has a gate of its own — an hourly cap, set with `--requests-per-hour` or
`REREVIEW_PER_HOUR` and **off unless you set it** — because it is the one route
by which somebody other than you can spend the API budget. `--force` turns the
cap off again: under it every outstanding request is admitted, nothing is
deferred, and no decline reply is posted.

```mermaid
%%{init: {'theme': 'base', 'themeVariables': {
  'primaryColor': '#2f6dab',
  'primaryTextColor': '#1e1e1e',
  'primaryBorderColor': '#7c8ba1',
  'lineColor': '#7c8ba1',
  'edgeLabelBackground': '#eef2f8',
  'tertiaryColor': 'transparent',
  'tertiaryTextColor': '#7c8ba1',
  'tertiaryBorderColor': '#7c8ba1',
  'clusterBkg': 'transparent',
  'clusterBorder': '#7c8ba1',
  'titleColor': '#7c8ba1',
  'noteBkgColor': '#eef2f8',
  'noteTextColor': '#1e1e1e',
  'fontFamily': 'system-ui, sans-serif'
}, 'themeCSS': '.node .nodeLabel{color:#ffffff!important;fill:#ffffff!important;}'}}%%
flowchart TD
  pr["Open PR discovered"]
  named{"Named explicitly by number or URL?"}
  lookup{"Commit-author lookup succeeded?"}
  bots{"Every commit author on the ignore list?"}
  ignored["Ignored - listed on the Ignored line"]
  seen{"Already reviewed at current head?"}
  asked{"Re-review requested since that verdict, by write access?"}
  cap{"Hourly cap set, and within it?"}
  deferred["Deferred - told so on the PR"]
  forced{"--force given?"}
  skipped["Skipped - unchanged since last review"]
  tier["Classify effort tier from PR metadata"]
  queued["Queued with its effort tier"]

  pr --> named
  named -->|yes - ignore list does not apply| seen
  named -->|no| lookup
  lookup -->|failed - fail open| seen
  lookup -->|ok| bots
  bots -->|yes| ignored
  bots -->|no| seen
  seen -->|yes| forced
  seen -->|no| tier
  forced -->|yes| tier
  forced -->|no| asked
  asked -->|yes| cap
  asked -->|no - or unauthorised| skipped
  cap -->|"no cap set, or within it"| tier
  cap -->|"over the cap"| deferred
  tier --> queued

  classDef sysA fill:#2f6dab,color:#ffffff,stroke:#7c8ba1
  classDef sysB fill:#1d7848,color:#ffffff,stroke:#7c8ba1
  classDef sysD fill:#2d747e,color:#ffffff,stroke:#7c8ba1
  classDef sysF fill:#5c6a82,color:#ffffff,stroke:#7c8ba1
  class pr,tier sysA
  class queued sysB
  class ignored,skipped,deferred sysD
  class named,lookup,bots,seen,asked,cap,forced sysF
```

**Queue order.** PRs with no prior council comment go first, then PRs whose last
review was for an older commit, then PRs someone asked to have re-reviewed. A PR
in none of those groups is skipped; `--force` queues it anyway. All of it comes
from the marker the council embeds in every comment it posts — an HTML comment,
so it is hidden from the rendered thread but sits in the comment body in plain
sight (see "Posting the verdict to a PR" in the README). A failed lookup queues the PR
rather than skipping it, so a flaky API call costs you a redundant review
instead of a silently missed one.

**What counts as our verdict.** Hidden is not secret: anyone who quotes a
verdict or views its source has the marker, and anyone can type one. Three
things must hold
before a comment is treated as a prior review:

- the marker starts a **line**, at column 0. GitHub's "Quote reply" copies it
  behind a `> ` prefix, so a quoted verdict is not a verdict.
- the comment was **authored by the account `gh` is authenticated as**.
- the comment is **not collapsed**.

A marker posted by any other account is named in the plan output and the PR is
reviewed anyway. A token that rotated between runs and a forged marker look
identical from the timeline, and reviewing is the safe answer to both — the
worst a forgery achieves is a review that was going to happen regardless.
