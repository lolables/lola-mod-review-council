#!/usr/bin/env bash
# End-to-end pipeline test: extract -> verify -> consolidate -> render.
#
# Every other suite here binds a single script and exercises it alone. That
# leaves the seams between them untested, and the seams are where defects hide:
# verification Step 3c instructs the orchestrator to write clusters.json into
# verdicts/, and rc-verify-evidence.sh globbed verdicts/ — neither script wrong
# by itself, the contract between them broken. No unit test could have caught
# it. This suite runs the real scripts in the real order over a session fixture
# shaped like real reviewer output.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
S="$SCRIPT_DIR/../skills/review-council/scripts"
# shellcheck source=module/tests/helpers.sh
source "$SCRIPT_DIR/helpers.sh"

work=$(copy_fixture session-golden)
session="$work/session"
root="$work/repo"
findings="$session/verdicts/findings.json"

echo "Stage 1: extract reviewer verdicts from raw agent output"
result=$(bash "$S/rc-extract-verdict.sh" "$session" 2>/dev/null)
assert_json_field "$result" "status" "ok" "extraction ok"
assert_json_field "$result" "valid" "4" "four verdict blocks extracted"
# The optional `constraint` field the schema permits must survive extraction:
# it is the field most likely to be dropped by an over-strict validator.
assert_jq "$session/verdicts/divisor-sre-code.json" '.findings[0].constraint' \
	"CR-014" "optional constraint field preserved"

echo "Stage 2: verify evidence against the review root"
result=$(REVIEW_ROOT="$root" bash "$S/rc-verify-evidence.sh" "$session")
assert_json_field "$result" "status" "ok" "verification ok"
assert_json_field "$result" "verified" "5" "five findings verified"
assert_json_field "$result" "correctable" "1" "one correctable"
assert_json_field "$result" "stripped" "2" "two stripped"
assert_jq "$findings" '.total_findings' "8" "eight findings accounted for"

# Every finding must land in exactly one bucket — none silently dropped.
buckets=$(jq -r '(.verified|length) + (.correctable|length) + (.stripped|length)' "$findings")
assert_equals "$buckets" "8" "no finding lost between buckets"

echo "Stage 2a: each finding reached its intended disposition"
# A fabricated multi-line block whose last line exists elsewhere in the file.
assert_jq "$findings" '.correctable[0].reason' "EVIDENCE_NOT_FOUND" \
	"fabricated multi-line block rejected"
assert_jq "$findings" '[.stripped[] | select(.file | test("creds.env")) | .reason] | first' \
	"PATH_OUTSIDE_ROOT" "path escaping the review root stripped"
assert_jq "$findings" '[.stripped[] | select(.file | test("missing.go")) | .reason] | first' \
	"FILE_NOT_FOUND" "fabricated file path stripped"
# The accurate citation of the THIRD occurrence of a thrice-repeated block.
assert_jq "$findings" '[.verified[] | select(.agent=="divisor-adversary-code" and .file=="internal/mcp/tools.go")] | length' \
	"1" "third occurrence of a repeated block verified"
# Nothing outside the review root may appear as verified evidence.
assert_jq "$findings" '[.verified[] | select(.file | test("\\.\\."))] | length' \
	"0" "no traversal path survived into verified"

echo "Stage 3: consolidate cross-agent duplicates"
# The orchestrator writes the manifest into verdicts/ at this point in a real
# run. Copying it here — rather than pre-placing it in the fixture — is what
# exercises the ordering: the manifest is present in verdicts/ for everything
# downstream, including a re-run of verification.
mkdir -p "$session/verdicts/_meta"
cp "$work/clusters.json" "$session/verdicts/_meta/clusters.json"
before=$(jq '.verified | length' "$findings")
result=$(bash "$S/rc-consolidate.sh" "$session")
assert_json_field "$result" "status" "ok" "consolidation ok"
after=$(jq '.verified | length' "$findings")
# One 2-member cluster collapses to its primary: exactly one removal.
assert_conserved "$before" "$after" 1 "consolidation removed only the merged secondary"

assert_jq "$findings" '[.verified[] | select(.severity=="HIGH")] | length' "1" \
	"cluster primary kept the higher severity"
assert_jq "$findings" '[.verified[] | select(.agent=="divisor-adversary-code") | .provenance.consolidated_from | length] | first' \
	"1" "secondary reviewer's angle folded into the primary"
# The three bystanders live in files untouched by the cluster. They are the
# reason this stage can detect over-deletion at all.
bystanders=$(jq -rc '[.verified[] | select(.file != "internal/mcp/tools.go") | .file] | sort | join(",")' "$findings")
assert_equals "$bystanders" "cmd/root.go,docs/README.md,internal/auth/token.go" \
	"all three bystanders in unrelated files survived"

echo "Stage 3a: verification is re-entrant with the manifest present"
# SKILL.md Step 2 advertises resuming mid-run. Re-running verification with
# clusters.json sitting in verdicts/ used to feed the manifest to jq as an
# agent verdict and abort the phase.
rc=0
REVIEW_ROOT="$root" bash "$S/rc-verify-evidence.sh" "$session" >/dev/null 2>&1 || rc=$?
assert_equals "$rc" "0" "re-running verification with clusters.json present exits clean"

echo "Stage 4: render the report"
# Restore the consolidated state the re-entrancy check above overwrote.
bash "$S/rc-consolidate.sh" "$session" >/dev/null
# The verification log is the orchestrator's artifact, not any script's —
# phases/verify.md writes it as the record of what was checked and why. Stand in
# for that here, at the point in the pipeline the orchestrator would, because
# rc-render-report.sh now refuses to render without it.
write_verification_log "$session"
echo "REQUEST CHANGES" >"$session/verdict.txt"
report=$(bash "$S/rc-render-report.sh" "$session")

if echo "$report" | grep -q "^## Council Verdict$"; then
	echo "  PASS: council verdict section rendered"
	PASS=$((PASS + 1))
else
	echo "  FAIL: no council verdict section"
	FAIL=$((FAIL + 1))
fi
verdict_section=$(echo "$report" | sed -n '/^## Council Verdict$/,/^## /p')
if echo "$verdict_section" | grep -q "REQUEST CHANGES"; then
	echo "  PASS: verdict value rendered"
	PASS=$((PASS + 1))
else
	echo "  FAIL: verdict value missing"
	FAIL=$((FAIL + 1))
fi
# Exactly the markers phases/report.md instructs the orchestrator to splice —
# one it does not know about would reach a published report as raw HTML, and a
# section with no marker would be silently dropped instead of rendered.
markers=$(echo "$report" | grep -o '<!--[^>]*-->' | sort -u | tr '\n' ' ' || true)
assert_equals "$markers" \
	"<!-- ACCEPTANCE-CRITERIA --> <!-- CI-COMMENTARY --> <!-- DISPOSITION-OUTCOMES --> <!-- LEARNINGS --> <!-- MERGE-ADVISORIES --> <!-- NARRATIVE --> <!-- SUBSYSTEM-ANALYSIS --> <!-- TLDR --> " \
	"exactly the documented splice markers"

# The stripped fabrication must not reappear anywhere in the rendered report:
# stripping a finding and then printing it is the same failure as not
# stripping it.
if ! echo "$report" | grep -q "DROP TABLE"; then
	echo "  PASS: stripped fabrication absent from the report"
	PASS=$((PASS + 1))
else
	echo "  FAIL: fabricated evidence leaked into the rendered report"
	FAIL=$((FAIL + 1))
fi
if ! echo "$report" | grep -q "creds.env"; then
	echo "  PASS: out-of-root path absent from the report"
	PASS=$((PASS + 1))
else
	echo "  FAIL: out-of-root finding leaked into the rendered report"
	FAIL=$((FAIL + 1))
fi
# Per-agent table must reflect verbatim verdicts from the reviewers.
if echo "$report" | grep -qF "| divisor-sre-code | APPROVE |"; then
	echo "  PASS: per-agent verdict rendered verbatim"
	PASS=$((PASS + 1))
else
	echo "  FAIL: per-agent verdict row missing or altered"
	FAIL=$((FAIL + 1))
fi

rm -rf "$work"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
