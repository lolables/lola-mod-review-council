#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
EXTRACT="$SCRIPT_DIR/../skills/review-council/scripts/rc-extract-verdict.sh"
VERIFY="$SCRIPT_DIR/../skills/review-council/scripts/rc-verify-evidence.sh"
# shellcheck source=module/tests/helpers.sh
source "$SCRIPT_DIR/helpers.sh"

# Regression guard for issue #27: a batched run writes reviewer output to
# verdicts/batch{N}/{agent}.raw.md (see phases/delegate.md "Batching" step c).
#
# That path is load-bearing rather than cosmetic. Both discovery globs recurse —
# rc-extract-verdict.sh finds '*.raw.md' and rc-verify-evidence.sh finds
# 'divisor-*.json' — so nesting a batch directory under verdicts/ reuses the
# same one-agent-many-verdicts handling that carries deep mode's per-subsystem
# nesting, and the convention costs no script change. What it costs instead is a
# standing constraint: anything that narrows either glob (a -maxdepth, or an
# allow-list of subsystem names read from subsystems.json) would still pass
# test-rc-deep-mode.sh while silently dropping every batch after the first.
# These assertions are what makes that break loudly.

echo "Test 1: extract batched — two rounds, same agent name, no clobber"
s=$(new_session)
mkdir -p "$s/verdicts/batch1" "$s/verdicts/batch2"
cat >"$s/verdicts/batch1/divisor-guard-code.raw.md" <<'RAW'
```json
{"agent":"divisor-guard-code","files_read":["cmd/main.go"],"verdict":"REQUEST CHANGES",
 "findings":[{"severity":"HIGH","file":"cmd/main.go","line":1,"evidence":"os.Exit(0)","description":"exits before flush","recommendation":"flush first"}]}
```
RAW
cat >"$s/verdicts/batch2/divisor-guard-code.raw.md" <<'RAW'
```json
{"agent":"divisor-guard-code","files_read":["internal/api/handler.go"],"verdict":"APPROVE","findings":[]}
```
RAW
result=$(bash "$EXTRACT" "$s")
assert_json_field "$result" "status" "ok" "extract batched status ok"
if [[ -f "$s/verdicts/batch1/divisor-guard-code.json" ]]; then
	echo "  PASS: batch1 json written beside its raw"
	PASS=$((PASS + 1))
else
	echo "  FAIL: no batch1 json — the raw glob did not reach verdicts/batch1/"
	FAIL=$((FAIL + 1))
fi
if [[ -f "$s/verdicts/batch2/divisor-guard-code.json" ]]; then
	echo "  PASS: batch2 json written beside its raw"
	PASS=$((PASS + 1))
else
	echo "  FAIL: no batch2 json — the raw glob did not reach verdicts/batch2/"
	FAIL=$((FAIL + 1))
fi
b1=$(jq -r '.verdict' "$s/verdicts/batch1/divisor-guard-code.json" 2>/dev/null || echo MISSING)
if [[ "$b1" == "REQUEST CHANGES" ]]; then
	echo "  PASS: batch1 verdict not clobbered by batch2"
	PASS=$((PASS + 1))
else
	echo "  FAIL: batch1 verdict '$b1'"
	FAIL=$((FAIL + 1))
fi
b2=$(jq -r '.verdict' "$s/verdicts/batch2/divisor-guard-code.json" 2>/dev/null || echo MISSING)
if [[ "$b2" == "APPROVE" ]]; then
	echo "  PASS: batch2 verdict not clobbered by batch1"
	PASS=$((PASS + 1))
else
	echo "  FAIL: batch2 verdict '$b2'"
	FAIL=$((FAIL + 1))
fi

echo "Test 2: verify batched — rounds merge, and a batched agent is not missing"
# The manifest is what makes the missing_verdicts half of this meaningful: the
# agent is dispatched once but returns two files, and the diff that computes
# missing_verdicts reduces paths to basenames. An agent present in both rounds
# must resolve to one name that is accounted for, not to a coverage gap.
cat >"$s/session-manifest.json" <<'MANIFEST'
{"suffix":"code","agents":["divisor-guard-code"],"council":["divisor-guard-code"]}
MANIFEST
src=$(mktemp -d)
mkdir -p "$src/cmd" "$src/internal/api"
echo 'os.Exit(0)' >"$src/cmd/main.go"
echo 'package api' >"$src/internal/api/handler.go"
result=$(cd "$src" && bash "$VERIFY" "$s")
assert_json_field "$result" "status" "ok" "verify batched status ok"
total=$(jq -r '.total_findings' "$s/verdicts/findings.json")
if [[ "$total" -eq 1 ]]; then
	echo "  PASS: total_findings 1 (batch1's finding + batch2's empty findings)"
	PASS=$((PASS + 1))
else
	echo "  FAIL: total_findings $total — a round's verdict was dropped"
	FAIL=$((FAIL + 1))
fi
agg=$(jq -r '.verdicts."divisor-guard-code"' "$s/verdicts/findings.json")
if [[ "$agg" == "REQUEST CHANGES" ]]; then
	echo "  PASS: REQUEST CHANGES in one round outranks APPROVE in the other"
	PASS=$((PASS + 1))
else
	echo "  FAIL: aggregated verdict '$agg' — a batch APPROVE overrode a finding"
	FAIL=$((FAIL + 1))
fi
missing=$(jq -r '.missing_verdicts | length' "$s/verdicts/findings.json")
if [[ "$missing" -eq 0 ]]; then
	echo "  PASS: the batched agent is accounted for, not reported missing"
	PASS=$((PASS + 1))
else
	echo "  FAIL: missing_verdicts $missing — batch nesting hid the agent"
	FAIL=$((FAIL + 1))
fi
rm -rf "$s" "$src"

echo "Test 3: deep and batched together — subsystem outside, batch inside"
# The deepest path the spec permits: `batch` restarts per subsystem, so a deep
# run that also batches nests both (phases/delegate.md, "Batching within
# subsystems"). Neither glob is depth-limited, and nothing downstream reads the
# subsystem out of the verdict path — identity comes from the manifest and from
# the block's own `agent` field — so two levels cost nothing extra. Asserted
# because "one level works" is the weaker claim, and it is the one the
# deep-mode suite already makes.
s=$(new_session)
mkdir -p "$s/verdicts/auth/batch1" "$s/verdicts/auth/batch2"
cat >"$s/verdicts/auth/batch1/divisor-adversary-code.raw.md" <<'RAW'
```json
{"agent":"divisor-adversary-code","files_read":["auth/token.go"],"verdict":"REQUEST CHANGES",
 "findings":[{"severity":"HIGH","file":"auth/token.go","line":1,"evidence":"if exp < now","description":"boundary bug","recommendation":"use <="}]}
```
RAW
cat >"$s/verdicts/auth/batch2/divisor-adversary-code.raw.md" <<'RAW'
```json
{"agent":"divisor-adversary-code","files_read":["auth/keys.go"],"verdict":"APPROVE","findings":[]}
```
RAW
result=$(bash "$EXTRACT" "$s")
assert_json_field "$result" "status" "ok" "extract deep+batched status ok"
if [[ -f "$s/verdicts/auth/batch1/divisor-adversary-code.json" ]] &&
	[[ -f "$s/verdicts/auth/batch2/divisor-adversary-code.json" ]]; then
	echo "  PASS: both rounds extracted two levels down"
	PASS=$((PASS + 1))
else
	echo "  FAIL: a two-level verdict path was not reached"
	FAIL=$((FAIL + 1))
fi
src=$(mktemp -d)
mkdir -p "$src/auth"
echo 'if exp < now' >"$src/auth/token.go"
echo 'package auth' >"$src/auth/keys.go"
result=$(cd "$src" && bash "$VERIFY" "$s")
assert_json_field "$result" "status" "ok" "verify deep+batched status ok"
agg=$(jq -r '.verdicts."divisor-adversary-code"' "$s/verdicts/findings.json")
if [[ "$agg" == "REQUEST CHANGES" ]]; then
	echo "  PASS: rounds aggregate across the subsystem's batches"
	PASS=$((PASS + 1))
else
	echo "  FAIL: aggregated verdict '$agg'"
	FAIL=$((FAIL + 1))
fi
rm -rf "$s" "$src"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
