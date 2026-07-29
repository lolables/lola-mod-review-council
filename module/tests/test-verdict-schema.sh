#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCHEMA="$SCRIPT_DIR/../skills/review-council/references/verdict-schema.json"
# shellcheck source=module/tests/test-helpers.sh
source "$SCRIPT_DIR/test-helpers.sh"

echo "Test 1: schema is valid JSON"
if jq -e . "$SCHEMA" >/dev/null 2>&1; then
	echo "  PASS: valid JSON"
	PASS=$((PASS + 1))
else
	echo "  FAIL: invalid JSON"
	FAIL=$((FAIL + 1))
fi

echo "Test 2: top-level required keys pinned"
req=$(jq -rc '.required' "$SCHEMA")
if [[ "$req" == '["agent","files_read","verdict","findings"]' ]]; then
	echo "  PASS: top required"
	PASS=$((PASS + 1))
else
	echo "  FAIL: got $req"
	FAIL=$((FAIL + 1))
fi

echo "Test 3: finding required keys pinned"
freq=$(jq -rc '.properties.findings.items.required' "$SCHEMA")
if [[ "$freq" == '["severity","file","evidence","description","recommendation"]' ]]; then
	echo "  PASS: finding required"
	PASS=$((PASS + 1))
else
	echo "  FAIL: got $freq"
	FAIL=$((FAIL + 1))
fi

echo "Test 4: reviewer verdict enum is binary (APPROVE WITH ADVISORIES is council-only)"
venum=$(jq -rc '.properties.verdict.enum' "$SCHEMA")
if [[ "$venum" == '["APPROVE","REQUEST CHANGES"]' ]]; then
	echo "  PASS: binary reviewer enum"
	PASS=$((PASS + 1))
else
	echo "  FAIL: got $venum"
	FAIL=$((FAIL + 1))
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
