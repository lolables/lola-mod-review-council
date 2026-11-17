---
rubric_version: "1"
pass_threshold: 0.75
weights:
  no_stale_binding: 0.45
  finding_untouched: 0.2
  reply_understood: 0.15
  check_passed: 0.1
  no_flapping: 0.1
---

# Rubric: case-036-disposition-stale-reply

The agent was asked to run the review-council Disposition phase against a
session with one verified finding, a HIGH at `prune.sh:7`: `rm -rf
$dir/tmp/*` expands an unquoted, unvalidated `$dir`. Its description
mentions the cd on line 5 only in passing. The one PR reply says the cd is
now checked and quoted, "so the Unchecked cd finding should be gone". That
cd finding is not in the session: it was fixed (line 5 now reads
`cd -- "$dir" || exit 1`) and no reviewer raised it again.

`phases/disposition.md` says a reference is to a finding's own defect, not
to a symbol it mentions: a reply about a finding no longer in the list
references none of them and produces no entry. Binding the reply to the
line-7 finding as `kept` is the failure this case exists to catch: the PR
comment then tells the author their correct fix claim was rejected.

Score five components, each in [0.0, 1.0]:

## no_stale_binding (weight 0.45)

Did the agent leave the line-7 finding without a disposition?

- 1.0 — `DISPOSITION_ACTION` is "none" and `DISPOSITION_ENTRIES` is 0.
- 0.0 — any disposition (`kept`, `resolved` or `suppressed-low`) was
  written for the line-7 finding.

## finding_untouched (weight 0.2)

Is the HIGH still verified, unchanged?

- 1.0 — `FINDINGS_AFTER` equals `FINDINGS_BEFORE` (1).
- 0.0 — the finding left `verified`.

## reply_understood (weight 0.15)

Did the agent recognise what the reply was about?

- 1.0 — `REPLY_TOPIC` names the cd on line 5 (checked/quoted) as a
  different defect from the line-7 delete.
- 0.5 — names the cd but treats it as part of the line-7 finding.
- 0.0 — misreads the reply.

## check_passed (weight 0.1)

- 1.0 — `CHECK_STATUS` is "ok".
- 0.5 — "not run".
- 0.0 — any failing status.

## no_flapping (weight 0.1)

Did the agent load `phases/disposition.md` and the session fixture
cleanly on the first attempt, without extensive searching or errors?

- 1.0 — clean load.
- 0.5 — minor searching.
- 0.0 — extensive searching, multiple retries, or errors.

## output

Return strict JSON — the object alone, with no code fence, no preamble and no
trailing prose. A fenced reply is only recoverable by a brace scan that a
quoted source line containing `{` defeats, and this rubric asks the
explanation to quote source.

```
{
  "components": {
    "no_stale_binding": <float>,
    "finding_untouched": <float>,
    "reply_understood": <float>,
    "check_passed": <float>,
    "no_flapping": <float>
  },
  "explanation": "<one-paragraph rationale citing the disposition entries written and the line-7 finding's final state>"
}
```
