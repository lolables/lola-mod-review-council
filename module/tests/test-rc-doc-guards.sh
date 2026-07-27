#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=module/tests/test-helpers.sh
source "$SCRIPT_DIR/test-helpers.sh"
SKILLS="$SCRIPT_DIR/../skills/review-council"
AGENTS="$SCRIPT_DIR/../agents"
VERIFY_MD="$SKILLS/phases/verify.md"
GUARD_MD="$AGENTS/divisor-guard-code.md"
ADVERSARY_MD="$AGENTS/divisor-adversary-code.md"

# RC-005: the correction-round skip must NOT strip every finding just because an
# agent's findings are all correctable — that is usually a citation-style or
# evidence-matcher artifact, not fabrication.
echo "Test: verify.md no longer strips all findings when all are correctable (RC-005)"
if grep -qiE 'systemic failure[^.]*strip all|all .*correctable.*strip all' "$VERIFY_MD"; then
	echo "  FAIL: strip-all-on-all-correctable rule still present"
	FAIL=$((FAIL + 1))
else
	echo "  PASS: strip-all rule removed"
	PASS=$((PASS + 1))
fi

echo "Test: verify.md still skips the correction round when there are zero correctable"
if grep -qiE 'zero correctable' "$VERIFY_MD"; then
	echo "  PASS: zero-correctable skip retained"
	PASS=$((PASS + 1))
else
	echo "  FAIL: zero-correctable skip lost"
	FAIL=$((FAIL + 1))
fi

# Standards-not-verified-at-source (RC_BUGS.md, PR #439): reviewers must verify
# claims about external standards against the source, not trust the spec's paraphrase.
echo "Test: Guard agent verifies external standards against source"
if grep -qiE 'external standard' "$GUARD_MD"; then
	echo "  PASS: Guard has external-standard verification"
	PASS=$((PASS + 1))
else
	echo "  FAIL: Guard lacks external-standard verification"
	FAIL=$((FAIL + 1))
fi

echo "Test: Adversary agent independently verifies compliance claims"
if grep -qiE 'compliance claim' "$ADVERSARY_MD"; then
	echo "  PASS: Adversary has compliance-claim verification"
	PASS=$((PASS + 1))
else
	echo "  FAIL: Adversary lacks compliance-claim verification"
	FAIL=$((FAIL + 1))
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
