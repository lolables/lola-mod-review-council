#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCHEMA="$SCRIPT_DIR/../skills/review-council/references/verdict-schema.json"
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

echo "Test 5: additionalProperties:false pinned at both levels"
# rc-extract-verdict.sh reimplements this keyword by hand in its jq fallback
# (RC_TOP_KEYS/RC_FINDING_KEYS); nothing else asserts the schema file itself
# still carries it, so dropping it here would silently widen every envelope a
# real validator accepts.
topap=$(jq -rc '.additionalProperties' "$SCHEMA")
itemap=$(jq -rc '.properties.findings.items.additionalProperties' "$SCHEMA")
if jq -e '.additionalProperties == false
          and .properties.findings.items.additionalProperties == false' "$SCHEMA" >/dev/null; then
	echo "  PASS: additionalProperties:false at top level and findings item"
	PASS=$((PASS + 1))
else
	echo "  FAIL: got top=$topap item=$itemap"
	FAIL=$((FAIL + 1))
fi

echo "Test 6: finding severity enum pinned"
# Pins the schema end of the list. Test 8 pins the five external copies to it;
# without that pairing this assertion only proves the schema did not move, and a
# severity the schema accepts but a ranker scores 0 still sorts below LOW.
senum=$(jq -rc '.properties.findings.items.properties.severity.enum' "$SCHEMA")
if [[ "$senum" == '["CRITICAL","HIGH","MEDIUM","LOW"]' ]]; then
	echo "  PASS: severity enum"
	PASS=$((PASS + 1))
else
	echo "  FAIL: got $senum"
	FAIL=$((FAIL + 1))
fi

echo "Test 7: finding line is a bounded integer"
# `integer` alone is defined BY VALUE in draft-07: 12.0 and 1e300 both satisfy
# it, and both reach shell arithmetic in rc-verify-evidence.sh as the literals
# "12.0" and "1E+300". The bounds are what make the type keyword reject the
# exponent form, along with zero and negative line numbers.
ltype=$(jq -rc '.properties.findings.items.properties.line.type' "$SCHEMA")
lmin=$(jq -rc '.properties.findings.items.properties.line.minimum' "$SCHEMA")
lmax=$(jq -rc '.properties.findings.items.properties.line.maximum' "$SCHEMA")
if [[ "$ltype" == '["integer","null"]' && "$lmin" == "1" && "$lmax" == "10000000" ]]; then
	echo "  PASS: line type and bounds"
	PASS=$((PASS + 1))
else
	echo "  FAIL: got type=$ltype minimum=$lmin maximum=$lmax"
	FAIL=$((FAIL + 1))
fi

echo "Test 8: every copy of the severity list outside the schema matches it"
# Five places re-declare the schema's severity names, and none reads the schema
# at runtime: the validator fallback in rc-extract-verdict.sh, the render loops
# in rc-render-report.sh and rc-render-comment.sh, and the two rankers that now
# live as standalone jq programs — jq/dedup-findings.jq and
# jq/consolidate-clusters.jq. Drift between any copy and the schema is silent in both
# directions — a name the schema drops still renders, and a name the schema adds
# ranks 0 and never gets a section — so each copy is compared here rather than
# merely pinned.
#
# Extraction takes every all-caps run off the declaring line, so a rename is
# caught as a changed list rather than slipping past a fixed alternation. The
# anchors are required to match: a declaration that is renamed away or deleted
# yields no line and fails, it does not vacuously pass.
SCRIPTS_DIR="$SCRIPT_DIR/../skills/review-council/scripts"
expected=$(jq -r '.properties.findings.items.properties.severity.enum | join(" ")' "$SCHEMA")

# check_severity_copy <label> <file> <anchor-ERE> <mode>
# mode "exact": every line matching <anchor> must declare exactly the schema
#               enum, in order.
# mode "prefix": every such line must START with the schema enum, in order.
#                consolidate-clusters.jq ranks a trailing council-only INFO below
#                LOW, which is a deliberate superset, not drift.
check_severity_copy() { # label file anchor mode
	local label="$1" file="$2" anchor="$3" mode="$4" lines line toks decl bad=""
	lines=$(grep -E "$anchor" "$file") || lines=""
	if [[ -z "$lines" ]]; then
		echo "  FAIL: $label — no line in $file matches /$anchor/"
		FAIL=$((FAIL + 1))
		return
	fi
	while IFS= read -r line; do
		toks=$(printf '%s\n' "$line" | grep -oE '[A-Z][A-Z]+' | tr '\n' ' ') || toks=""
		decl="${toks% }"
		case "$mode" in
		exact) [[ "$decl" == "$expected" ]] || bad="$bad '$decl'" ;;
		prefix) [[ "$decl" == "$expected" || "$decl" == "$expected "* ]] || bad="$bad '$decl'" ;;
		*)
			echo "  FAIL: $label — unknown comparison mode '$mode'"
			FAIL=$((FAIL + 1))
			return
			;;
		esac
	done <<<"$lines"
	if [[ -z "$bad" ]]; then
		echo "  PASS: $label"
		PASS=$((PASS + 1))
	else
		echo "  FAIL: $label — expected $mode of '$expected', got$bad"
		FAIL=$((FAIL + 1))
	fi
}

check_severity_copy "rc-extract-verdict.sh validator fallback" \
	"$SCRIPTS_DIR/rc-extract-verdict.sh" '[.]severity [|] oneof' exact
check_severity_copy "jq/dedup-findings.jq dedup ranker" \
	"$SCRIPTS_DIR/jq/dedup-findings.jq" 'def sevrank' exact
check_severity_copy "rc-render-report.sh severity sections" \
	"$SCRIPTS_DIR/rc-render-report.sh" '^[[:space:]]*for severity in ' exact
check_severity_copy "rc-render-comment.sh severity loops" \
	"$SCRIPTS_DIR/rc-render-comment.sh" '^[[:space:]]*for sev in ' exact
check_severity_copy "jq/consolidate-clusters.jq cluster ranker" \
	"$SCRIPTS_DIR/jq/consolidate-clusters.jq" 'def rank:' prefix

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
