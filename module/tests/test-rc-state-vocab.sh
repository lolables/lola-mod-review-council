#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
S="$SCRIPT_DIR/../skills/review-council/scripts"
# shellcheck source=module/tests/helpers.sh
source "$SCRIPT_DIR/helpers.sh"

check() { # script token
	if grep -q "\"$2\"" "$1"; then
		echo "  PASS: $(basename "$1") emits $2"
		PASS=$((PASS + 1))
	else
		echo "  FAIL: $(basename "$1") missing $2"
		FAIL=$((FAIL + 1))
	fi
}
echo "Test: documented status tokens exist in scripts"
check "$S/rc-extract-verdict.sh" "extract_error"
check "$S/rc-extract-verdict.sh" "ok"
check "$S/rc-extract-verdict.sh" "nothing_to_do"
check "$S/rc-verify-evidence.sh" "ok"
check "$S/rc-verify-evidence.sh" "nothing_to_do"
check "$S/rc-prepare.sh" "ok"
check "$S/rc-prepare.sh" "skip"
check "$S/rc-prepare.sh" "empty"
check "$S/rc-render-comment.sh" "rendered"
check "$S/rc-render-comment.sh" "skip"
echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
