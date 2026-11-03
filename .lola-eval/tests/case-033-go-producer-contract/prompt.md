Review this Go codebase using /review-council code main..feat. Report all findings.

This is a small job runner that checks each step of a job spec against an
allowlist before executing it. The feature branch hardens the check that
refuses shell expansion in a step. Focus on security, correctness, and
operational concerns. The review-council module is pre-installed in this
project's .lola/ directory.
