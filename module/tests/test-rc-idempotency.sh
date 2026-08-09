#!/usr/bin/env bash
# Every phase script re-runs against a live session.
#
# SKILL.md Step 6 offers to fix findings and return to Step 3, and says the next
# pass "re-runs Step 6 and overwrites the artifacts". verify.md re-dispatches an
# agent and runs the extractor again. Re-running is part of the contract, so
# each script's state must be a function of its inputs and not of how many times
# it has been called.
#
# The per-script suites cover the specific defects this suite was written for.
# This one covers the class: a phase script added later shows up here or it is
# not covered at all.
#
# rc-prepare.sh is deliberately absent. A session IS a run — re-running must
# produce a new one — and its growth is bounded by the session LRU instead.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS="$SCRIPT_DIR/../skills/review-council/scripts"
# shellcheck source=module/tests/helpers.sh
source "$SCRIPT_DIR/helpers.sh"

# --- rc-consolidate.sh ------------------------------------------------------
echo "Test 1: rc-consolidate.sh is idempotent over a merged cluster"
s=$(new_session)
cat >"$s/verdicts/findings.json" <<'FJ'
{"verified":[
 {"agent":"divisor-adversary-code","severity":"HIGH","file":"svc/load.py","line":42,
  "evidence":"except:","description":"CWE-390 swallow","recommendation":"catch specific",
  "verdict":"REQUEST CHANGES","status":"verified","provenance":{}},
 {"agent":"divisor-testing-code","severity":"MEDIUM","file":"svc/load.py","line":42,
  "evidence":"except:","description":"untested failure path","recommendation":"add a test",
  "verdict":"REQUEST CHANGES","status":"verified","provenance":{}},
 {"agent":"divisor-sre-code","severity":"LOW","file":"other.py","line":3,
  "evidence":"x=1","description":"unrelated","recommendation":"none",
  "verdict":"APPROVE","status":"verified","provenance":{}}
],"correctable":[],"stripped":[],"total_findings":3,"duplicates_consolidated":0,"verdicts":{}}
FJ
cat >"$s/verdicts/_meta/clusters.json" <<'CJ'
{"clusters":[{"members":[
  {"file":"svc/load.py","line":42,"agent":"divisor-adversary-code"},
  {"file":"svc/load.py","line":42,"agent":"divisor-testing-code"}
]}]}
CJ
bash "$SCRIPTS/rc-consolidate.sh" "$s" >/dev/null
assert_idempotent "rc-consolidate.sh" "$s/verdicts/findings.json" \
	bash "$SCRIPTS/rc-consolidate.sh" "$s"
rm -rf "$s"

# --- rc-verify-evidence.sh --------------------------------------------------
echo "Test 2: rc-verify-evidence.sh is idempotent"
# A regenerator: it rebuilds findings.json from the agent JSON every time, so it
# has idempotency for free. Asserted anyway — "for free" is a property of the
# current implementation, not a guarantee about the next one.
s=$(new_session)
mkdir -p "$s/checkout/auth"
printf 'if exp < now\n' >"$s/checkout/auth/token.go"
cat >"$s/verdicts/divisor-adversary-code.json" <<'AJ'
{"agent":"divisor-adversary-code","files_read":["auth/token.go"],"verdict":"REQUEST CHANGES",
 "findings":[{"severity":"HIGH","file":"auth/token.go","line":1,"evidence":"if exp < now",
 "description":"Expiry rejects tokens at the boundary.","recommendation":"Use <=."}]}
AJ
bash "$SCRIPTS/rc-verify-evidence.sh" "$s" "$s/checkout" >/dev/null
assert_idempotent "rc-verify-evidence.sh" "$s/verdicts" \
	bash "$SCRIPTS/rc-verify-evidence.sh" "$s" "$s/checkout"
rm -rf "$s"

# --- rc-extract-verdict.sh --------------------------------------------------
echo "Test 3: rc-extract-verdict.sh leaves the consumed state unchanged on re-run"
# Scoped to verdicts/ on purpose. That is the state the rest of the pipeline
# reads, and it must be stable. gate-firings.jsonl sits at the session root
# precisely so it can grow — see Test 4.
s=$(new_session)
# shellcheck disable=SC2016 # literal markdown fence, not command substitution.
printf '```json\n%s\n```\n' \
	'{"agent":"divisor-guard-code","files_read":["a.go"],"verdict":"APPROVE","findings":[]}' \
	>"$s/verdicts/divisor-guard-code.raw.md"
bash "$SCRIPTS/rc-extract-verdict.sh" "$s" >/dev/null 2>&1
assert_idempotent "rc-extract-verdict.sh (verdicts/)" "$s/verdicts" \
	bash "$SCRIPTS/rc-extract-verdict.sh" "$s"
rm -rf "$s"

echo "Test 4: the gate-firing log is exempt and grows on every evaluation"
# The exemption is the contract, not an oversight: a second firing can be a
# genuine second refusal, and the first record is the only one carrying what was
# originally claimed. verify.md collapses repeats at the reader (RC-030). If
# this assertion ever flips to "stays at 1", someone has deduplicated the
# writer and RC-028's guarantee is gone.
s=$(new_session)
# shellcheck disable=SC2016 # literal markdown fence, not command substitution.
printf '```json\n%s\n```\n' \
	'{"agent":"divisor-guard-code","files_read":["auth/token.go"],"verdict":"APPROVE","findings":[{"severity":"CRITICAL","file":"auth/token.go","line":42,"evidence":"if exp < now","description":"Expired tokens are accepted.","recommendation":"Compare with <=."}]}' \
	>"$s/verdicts/divisor-guard-code.raw.md"
bash "$SCRIPTS/rc-extract-verdict.sh" "$s" >/dev/null 2>&1
bash "$SCRIPTS/rc-extract-verdict.sh" "$s" >/dev/null 2>&1
records=$(jq -s 'length' "$s/gate-firings.jsonl")
assert_equals "$records" "2" "each evaluation appends a record"
distinct=$(jq -s '[.[] | del(.ts)] | unique | length' "$s/gate-firings.jsonl")
assert_equals "$distinct" "1" "the records differ only in ts, which is what the reader collapses on"
rm -rf "$s"

# --- renderers --------------------------------------------------------------
echo "Test 5: rc-render-report.sh is idempotent"
s=$(mktemp -d)
make_review_session "$s"
render_report() { bash "$SCRIPTS/rc-render-report.sh" "$1" >"$1/report.md"; }
render_report "$s"
assert_idempotent "rc-render-report.sh" "$s/report.md" render_report "$s"
rm -rf "$s"

echo "Test 6: rc-render-comment.sh is idempotent"
s=$(mktemp -d)
make_review_session "$s"
bash "$SCRIPTS/rc-render-comment.sh" "$s" >/dev/null 2>&1
assert_idempotent "rc-render-comment.sh" "$s/comment-body.md" \
	bash "$SCRIPTS/rc-render-comment.sh" "$s"
rm -rf "$s"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
