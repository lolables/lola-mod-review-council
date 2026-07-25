#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCHEMA="$SCRIPT_DIR/../skills/review-council/references/consolidation-schema.json"
source "$SCRIPT_DIR/test-helpers.sh"

echo "Test 1: schema is valid JSON"
if jq -e . "$SCHEMA" >/dev/null 2>&1; then echo "  PASS: valid JSON"; PASS=$((PASS+1)); else echo "  FAIL: invalid JSON"; FAIL=$((FAIL+1)); fi

echo "Test 2: top-level requires clusters"
req=$(jq -rc '.required' "$SCHEMA")
[[ "$req" == '["clusters"]' ]] && { echo "  PASS: requires clusters"; PASS=$((PASS+1)); } || { echo "  FAIL: got $req"; FAIL=$((FAIL+1)); }

echo "Test 3: members require file+agent and minItems 2"
mreq=$(jq -rc '.properties.clusters.items.properties.members.items.required' "$SCHEMA")
mmin=$(jq -rc '.properties.clusters.items.properties.members.minItems' "$SCHEMA")
[[ "$mreq" == '["file","agent"]' && "$mmin" == "2" ]] && { echo "  PASS: member constraints"; PASS=$((PASS+1)); } || { echo "  FAIL: req=$mreq min=$mmin"; FAIL=$((FAIL+1)); }

echo ""; echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
