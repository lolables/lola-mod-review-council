#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCHEMA="$SCRIPT_DIR/../skills/review-council/references/consolidation-schema.json"
# shellcheck source=module/tests/helpers.sh
source "$SCRIPT_DIR/helpers.sh"

echo "Test 1: schema is valid JSON"
if jq -e . "$SCHEMA" >/dev/null 2>&1; then
	echo "  PASS: valid JSON"
	PASS=$((PASS + 1))
else
	echo "  FAIL: invalid JSON"
	FAIL=$((FAIL + 1))
fi

echo "Test 2: top-level requires clusters"
req=$(jq -rc '.required' "$SCHEMA")
if [[ "$req" == '["clusters"]' ]]; then
	echo "  PASS: requires clusters"
	PASS=$((PASS + 1))
else
	echo "  FAIL: got $req"
	FAIL=$((FAIL + 1))
fi

echo "Test 3: members require file+agent and minItems 2"
mreq=$(jq -rc '.properties.clusters.items.properties.members.items.required' "$SCHEMA")
mmin=$(jq -rc '.properties.clusters.items.properties.members.minItems' "$SCHEMA")
if [[ "$mreq" == '["file","agent"]' && "$mmin" == "2" ]]; then
	echo "  PASS: member constraints"
	PASS=$((PASS + 1))
else
	echo "  FAIL: req=$mreq min=$mmin"
	FAIL=$((FAIL + 1))
fi

echo "Test 4: additionalProperties:false pinned at all three levels"
# Nothing validates clusters.json at runtime — the schema is the only contract
# the orchestrator writes against, so an unpinned level lets a hallucinated key
# (most damagingly a cluster-level "primary", which verify.md Step 3c forbids
# because rc-consolidate.sh elects the primary itself) pass review unnoticed.
topap=$(jq -rc '.additionalProperties' "$SCHEMA")
clusterap=$(jq -rc '.properties.clusters.items.additionalProperties' "$SCHEMA")
memberap=$(jq -rc '.properties.clusters.items.properties.members.items.additionalProperties' "$SCHEMA")
if jq -e '.additionalProperties == false
          and .properties.clusters.items.additionalProperties == false
          and .properties.clusters.items.properties.members.items.additionalProperties == false' \
	"$SCHEMA" >/dev/null; then
	echo "  PASS: additionalProperties:false at manifest, cluster, and member"
	PASS=$((PASS + 1))
else
	echo "  FAIL: got top=$topap cluster=$clusterap member=$memberap"
	FAIL=$((FAIL + 1))
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
