A review-council session for this repository already ran and produced
verified findings. This is a re-review: nobody has replied since the previous
verdict, but that verdict carried settlements from earlier runs. The session
lives at `.rc-session/` (verified findings under
`.rc-session/verdicts/findings.json`, untrusted prior settlements at
`.rc-session/prior-settlements.txt`, review root: this repository, effort:
standard).

Run the review-council Disposition phase against this session, following
`phases/disposition.md` in the installed review-council skill exactly: read
the untrusted settlements and the verified findings, decide what each
settlement means for each finding (a carried deferral may name the defect in different words), then write your decisions back into
`.rc-session/verdicts/findings.json`,
`.rc-session/verdicts/_meta/ledger-revoked.json` if you revoke anything, and
`.rc-session/verdicts/disposition.txt` per that phase's Steps 3-5. The
review-council module is pre-installed in this project's .lola/ directory.
