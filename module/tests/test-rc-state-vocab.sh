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

# rc-prepare.sh is an entry point that sources six stages; the json_output calls
# live in whichever stage reaches that state. Checking the entry point alone
# would report every token missing, so the whole set is searched as one program.
# Globbed rather than listed: a seventh stage must not silently escape the check.
check_prepare() { # token
	local token="$1" hits
	hits=$(grep -l "\"$token\"" "$S/rc-prepare.sh" "$S"/lib/prepare-*.sh 2>/dev/null) || hits=""
	if [[ -n "$hits" ]]; then
		local first
		first=$(head -n1 <<<"$hits")
		echo "  PASS: rc-prepare.sh emits $token (in ${first##*/})"
		PASS=$((PASS + 1))
	else
		echo "  FAIL: rc-prepare.sh and its stages are missing $token"
		FAIL=$((FAIL + 1))
	fi
}
echo "Test: documented status tokens exist in scripts"
check "$S/rc-extract-verdict.sh" "extract_error"
check "$S/rc-extract-verdict.sh" "ok"
check "$S/rc-extract-verdict.sh" "nothing_to_do"
check "$S/rc-verify-evidence.sh" "ok"
check "$S/rc-verify-evidence.sh" "nothing_to_do"
check "$S/rc-consolidate.sh" "consolidate_error"
check_prepare "ok"
check_prepare "skip"
check_prepare "empty"
check "$S/rc-render-comment.sh" "rendered"
check "$S/rc-render-comment.sh" "skip"
echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
