#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ESTIMATE="$SCRIPT_DIR/../skills/review-council/scripts/rc-cost-estimate.sh"
# shellcheck source=module/tests/helpers.sh
source "$SCRIPT_DIR/helpers.sh"

# Build a session with <effort>, <persona count> agents and, for each remaining
# argument, that many changeset files. Prints the session path; the caller owns
# it and removes it. A caller exercising subsystem apportionment writes its own
# subsystems.json over the file counts it asked for here.
mk_session() { # effort personas [subsystem_file_counts...]
	local effort="$1" personas="$2"
	shift 2
	local s agents=() i count n=0
	s=$(new_session)
	for ((i = 1; i <= personas; i++)); do agents+=("divisor-p${i}-code"); done
	printf '%s\n' "${agents[@]}" | jq -R . | jq -s '{mode:"code",suffix:"code",agents:.,absent:[]}' \
		>"$s/session-manifest.json"
	{
		echo "# Review Council Session Tracking"
		echo ""
		echo "## Phase: Preparation"
		echo ""
		echo "- Effort: ${effort}"
		echo "- Language: Go"
		echo "- Framework: none"
		echo ""
	} >"$s/tracking.md"
	: >"$s/changeset.txt"
	for count in "$@"; do
		for ((i = 0; i < count; i++)); do
			n=$((n + 1))
			echo "pkg/file${n}.go" >>"$s/changeset.txt"
		done
	done
	[[ $n -eq 0 ]] && printf 'pkg/only.go\n' >"$s/changeset.txt"
	printf 'diff --git a/pkg/file1.go b/pkg/file1.go\n+x\n' >"$s/diff.patch"
	printf '%s' "$s"
}

echo "Test 1: flat session — one subsystem, deep cap 5"
s=$(mk_session deep 5)
bash "$ESTIMATE" "$s" >/dev/null
assert_jq "$s/cost-estimate.json" '.personas' '5' "personas from manifest"
assert_jq "$s/cost-estimate.json" '.subsystems' '1' "no subsystems.json means one subsystem"
assert_jq "$s/cost-estimate.json" '.iteration_cap' '5' "deep cap is 5"
assert_jq "$s/cost-estimate.json" '.dispatches_first_pass' '5' "first pass is personas x subsystems"
assert_jq "$s/cost-estimate.json" '.dispatches_worst_case' '25' "worst case multiplies by the cap"
discard_fixture "$s"

echo "Test 2: token estimate grows with changeset bytes"
small=$(mk_session deep 5)
big=$(mk_session deep 5)
head -c 40000 /dev/zero | tr '\0' 'x' >>"$big/diff.patch"
bash "$ESTIMATE" "$small" >/dev/null
bash "$ESTIMATE" "$big" >/dev/null
st=$(jq -r '.input_tokens_first_pass' "$small/cost-estimate.json")
bt=$(jq -r '.input_tokens_first_pass' "$big/cost-estimate.json")
if [[ "$bt" -gt "$st" ]]; then
	echo "  PASS: a larger diff estimates more tokens"
	PASS=$((PASS + 1))
else
	echo "  FAIL: tokens did not grow ($st -> $bt)"
	FAIL=$((FAIL + 1))
fi
discard_fixture "$small" "$big"

echo "Test 3: deep apportions context per subsystem rather than counting the whole diff each time"
flat=$(mk_session deep 5 4)
split=$(mk_session deep 5 2 2)
jq -n '[{name:"a",description:"a",files:["pkg/file1.go","pkg/file2.go"]},
        {name:"b",description:"b",files:["pkg/file3.go","pkg/file4.go"]}]' \
	>"$split/subsystems.json"
head -c 40000 /dev/zero | tr '\0' 'x' >>"$flat/diff.patch"
head -c 40000 /dev/zero | tr '\0' 'x' >>"$split/diff.patch"
bash "$ESTIMATE" "$flat" >/dev/null
bash "$ESTIMATE" "$split" >/dev/null
ft=$(jq -r '.input_tokens_first_pass' "$flat/cost-estimate.json")
pt=$(jq -r '.input_tokens_first_pass' "$split/cost-estimate.json")
# Ten dispatches over halved context must not cost ten times the five-dispatch
# whole-changeset pass: only the per-dispatch pack overhead is duplicated.
if [[ "$pt" -lt $((ft * 3)) ]]; then
	echo "  PASS: per-subsystem context is apportioned, not duplicated whole"
	PASS=$((PASS + 1))
else
	echo "  FAIL: split estimate $pt vs flat $ft suggests whole-diff duplication"
	FAIL=$((FAIL + 1))
fi
discard_fixture "$flat" "$split"

echo "Test 4: worst case is the first pass times the iteration cap"
s=$(mk_session deep 5)
bash "$ESTIMATE" "$s" >/dev/null
f=$(jq -r '.input_tokens_first_pass' "$s/cost-estimate.json")
w=$(jq -r '.input_tokens_worst_case' "$s/cost-estimate.json")
assert_equals "$w" "$((f * 5))" "worst-case tokens scale by the cap"
discard_fixture "$s"

echo "Test 5: dollar band multiplies the per-dispatch rate"
s=$(mk_session deep 5)
bash "$ESTIMATE" "$s" >/dev/null
assert_jq "$s/cost-estimate.json" '.usd_low_first_pass' '1' "5 dispatches x \$0.20 low"
assert_jq "$s/cost-estimate.json" '.usd_high_first_pass' '2.8' "5 dispatches x \$0.56 high"
assert_jq "$s/cost-estimate.json" '.usd_low_worst_case' '5' "25 dispatches x \$0.20 low"
discard_fixture "$s"

echo "Test 6: env override replaces the default rate"
s=$(mk_session deep 5)
REVIEW_COUNCIL_COST_LOW=1 REVIEW_COUNCIL_COST_HIGH=2 bash "$ESTIMATE" "$s" >/dev/null
assert_jq "$s/cost-estimate.json" '.rate_low' '1' "rate_low overridden"
assert_jq "$s/cost-estimate.json" '.usd_low_first_pass' '5' "override reaches the total"
discard_fixture "$s"

echo "Test 7: malformed override falls back to the default and says so"
s=$(mk_session deep 5)
err=$(REVIEW_COUNCIL_COST_LOW=free bash "$ESTIMATE" "$s" 2>&1 >/dev/null)
assert_jq "$s/cost-estimate.json" '.rate_low' '0.2' "default rate retained"
case "$err" in
*REVIEW_COUNCIL_COST_LOW*)
	echo "  PASS: malformed override reported on stderr"
	PASS=$((PASS + 1))
	;;
*)
	echo "  FAIL: no stderr notice for a malformed override"
	FAIL=$((FAIL + 1))
	;;
esac
discard_fixture "$s"

echo "Test 8: stdout is a markdown table naming the fan-out"
s=$(mk_session deep 5)
out=$(bash "$ESTIMATE" "$s")
for needle in "Cost estimate" "Dispatches" "5 personas" "estimate"; do
	case "$out" in
	*"$needle"*)
		echo "  PASS: table mentions '$needle'"
		PASS=$((PASS + 1))
		;;
	*)
		echo "  FAIL: table missing '$needle'"
		FAIL=$((FAIL + 1))
		;;
	esac
done
discard_fixture "$s"

echo "Test 9: tracking block records the estimate"
s=$(mk_session deep 5)
bash "$ESTIMATE" "$s" >/dev/null
assert_track "$s" "Personas" "5" "tracking records personas"
assert_track "$s" "Subsystems" "1" "tracking records subsystems"
assert_track "$s" "Iteration cap" "5" "tracking records the cap"
assert_track "$s" "Dispatches \(worst case\)" "25" "tracking records worst-case dispatches"
discard_fixture "$s"

echo "Test 10: re-running replaces the block rather than appending a second one"
s=$(mk_session deep 5)
bash "$ESTIMATE" "$s" >/dev/null
assert_idempotent "estimate is idempotent" "$s/tracking.md" bash "$ESTIMATE" "$s"
blocks=$(grep -c '^## Phase: Cost Estimate$' "$s/tracking.md")
assert_equals "$blocks" "1" "exactly one cost-estimate block"
discard_fixture "$s"

echo "Test 11: degraded inputs print a notice and exit 0"
out=$(bash "$ESTIMATE" /nonexistent-session-dir)
case "$out" in
*"Cost estimate unavailable"*)
	echo "  PASS: missing session reports a notice"
	PASS=$((PASS + 1))
	;;
*)
	echo "  FAIL: missing session printed '$out'"
	FAIL=$((FAIL + 1))
	;;
esac
s=$(new_session)
out=$(bash "$ESTIMATE" "$s")
case "$out" in
*"Cost estimate unavailable"*)
	echo "  PASS: session without tracking.md reports a notice"
	PASS=$((PASS + 1))
	;;
*)
	echo "  FAIL: bare session printed '$out'"
	FAIL=$((FAIL + 1))
	;;
esac
discard_fixture "$s"

echo "Test 12: the iteration cap follows the effort recorded in tracking.md"
s=$(mk_session quick 5)
bash "$ESTIMATE" "$s" >/dev/null
assert_jq "$s/cost-estimate.json" '.iteration_cap' '1' "quick caps at one iteration"
# A quick run has no second pass to pay for, so its worst case IS its first
# pass. Asserted separately from the cap because the multiplication is the
# table's whole purpose: a cap of 1 that still scaled the worst case would
# quote every quick review at five times what it costs.
assert_jq "$s/cost-estimate.json" '.dispatches_worst_case' '5' "quick worst case is the first pass"
discard_fixture "$s"

s=$(mk_session standard 5)
bash "$ESTIMATE" "$s" >/dev/null
assert_jq "$s/cost-estimate.json" '.iteration_cap' '3' "standard caps at three iterations"
assert_jq "$s/cost-estimate.json" '.dispatches_worst_case' '15' "standard worst case is three passes"
discard_fixture "$s"

# An effort word the script does not recognise takes the STANDARD cap, never
# the deep one. Pricing an unreadable session at the deep cap over-states the
# bill by 5/3 on every run that hits it, and a table that cries wolf is one
# operators learn to click past — which is the failure the whole step exists to
# prevent.
s=$(mk_session thorough 5)
bash "$ESTIMATE" "$s" >/dev/null
assert_jq "$s/cost-estimate.json" '.iteration_cap' '3' "an unrecognised effort takes the standard cap"
assert_jq "$s/cost-estimate.json" '.effort' 'thorough' "the unrecognised effort is still recorded verbatim"
discard_fixture "$s"

echo "Test 13: a decomposed changeset multiplies the fan-out by subsystem"
s=$(mk_session deep 5 2 2)
jq -n '[{name:"a",description:"a",files:["pkg/file1.go","pkg/file2.go"]},
        {name:"b",description:"b",files:["pkg/file3.go","pkg/file4.go"]}]' \
	>"$s/subsystems.json"
bash "$ESTIMATE" "$s" >/dev/null
# This multiplication is the reason the step exists: five reviewers over two
# subsystems is ten dispatches before a single iteration has repeated, and
# fifty by the deep cap. Test 3 runs the same fixture for its token arithmetic,
# which leaves the counts an operator is actually asked to approve unpinned.
assert_jq "$s/cost-estimate.json" '.subsystems' '2' "subsystems counted from subsystems.json"
assert_jq "$s/cost-estimate.json" '.dispatches_first_pass' '10' "5 personas x 2 subsystems"
assert_jq "$s/cost-estimate.json" '.dispatches_worst_case' '50' "10 dispatches x the deep cap"
assert_track "$s" "Dispatches \(first pass\)" "10" "tracking records the decomposed first pass"
discard_fixture "$s"

echo "Test 14: persona prompt bytes are measured when the caller passes AGENTS_DIR"
s=$(mk_session deep 5)
agents_dir=$(mktemp -d)
agent_names=$(jq -r '(.agents // [])[]' "$s/session-manifest.json")
while IFS= read -r agent; do
	[[ -n "$agent" ]] || continue
	{
		echo "# ${agent}"
		echo ""
		echo "Reviewer system prompt standing in for a real persona file, long"
		echo "enough that five of them are a visible share of a small session."
	} >"$agents_dir/${agent}.md"
done <<<"$agent_names"
# The three runs share one session so the persona files are the only thing that
# differs between them; every other input the estimate reads is byte-identical.
bash "$ESTIMATE" "$s" >/dev/null
without=$(jq -r '.input_tokens_first_pass' "$s/cost-estimate.json")
AGENTS_DIR="$agents_dir" bash "$ESTIMATE" "$s" >/dev/null
with=$(jq -r '.input_tokens_first_pass' "$s/cost-estimate.json")
# The persona prompt goes out with every dispatch, so an estimate blind to the
# agent files quotes less than the run will spend. Asserted as strictly greater
# rather than as an exact figure: the agent files are the module's own, and
# pinning their size here would fail every time a persona gains a paragraph.
if [[ "$with" -gt "$without" ]]; then
	echo "  PASS: AGENTS_DIR raises the estimate by the persona prompts it can see"
	PASS=$((PASS + 1))
else
	echo "  FAIL: persona files did not reach the estimate ($without -> $with)"
	FAIL=$((FAIL + 1))
fi
# A caller that passes a directory which is not there gets the unmeasured
# estimate, quietly. AGENTS_DIR is optional to this script and always has been:
# refusing to price a run, or grumbling on stderr into an orchestrator's
# transcript, would cost more than the term it could not measure is worth.
err_file="$agents_dir/stderr.txt"
status=0
AGENTS_DIR="$agents_dir/absent" bash "$ESTIMATE" "$s" >/dev/null 2>"$err_file" || status=$?
missing=$(jq -r '.input_tokens_first_pass' "$s/cost-estimate.json")
noise=$(<"$err_file")
assert_equals "$status" "0" "an unreachable AGENTS_DIR is not an error"
assert_equals "$missing" "$without" "an unreachable AGENTS_DIR falls back to the unmeasured estimate"
assert_equals "$noise" "" "an unreachable AGENTS_DIR prints nothing on stderr"
discard_fixture "$s" "$agents_dir"

GUIDANCE="$SCRIPT_DIR/../skills/review-council/references/model-guidance.md"

echo "Test 15: each model class is priced from its row in the shipped table"
# The table's ranges are per REVIEW — one full council pass — so the expected
# per-dispatch band is the row over the council size the table names, and a
# five-persona first pass must land back on the published range to the cent.
while read -r class low high; do
	s=$(mk_session deep 5)
	REVIEW_COUNCIL_MODEL_CLASS="$class" bash "$ESTIMATE" "$s" >/dev/null
	assert_jq "$s/cost-estimate.json" '.model_class' "$class" "${class} is recorded as the class priced"
	assert_jq "$s/cost-estimate.json" '.rate_source' 'model-guidance' "${class} band came from the table"
	assert_jq "$s/cost-estimate.json" '.usd_low_first_pass' "$low" "${class} five-dispatch pass reproduces \$${low} low"
	assert_jq "$s/cost-estimate.json" '.usd_high_first_pass' "$high" "${class} five-dispatch pass reproduces \$${high} high"
	discard_fixture "$s"
done <<'CLASSES'
opus 1.3 8.8
sonnet 1 2.8
haiku 0.07 0.72
CLASSES
# Operators type the class the way the table prints it as often as not, and a
# case-sensitive match would silently price an `Opus` run at the sonnet rate.
s=$(mk_session deep 5)
REVIEW_COUNCIL_MODEL_CLASS=OPUS bash "$ESTIMATE" "$s" >/dev/null
assert_jq "$s/cost-estimate.json" '.model_class' 'opus' "the class name is matched case-insensitively"
discard_fixture "$s"

echo "Test 16: the divisor is the measured council, not the discovered roster"
five=$(mk_session deep 5)
three=$(mk_session deep 3)
REVIEW_COUNCIL_MODEL_CLASS=opus bash "$ESTIMATE" "$five" >/dev/null
REVIEW_COUNCIL_MODEL_CLASS=opus bash "$ESTIMATE" "$three" >/dev/null
assert_jq "$three/cost-estimate.json" '.usd_low_first_pass' '0.78' "three personas cost three fifths of five"
# Dividing the published range by the roster this session happens to have
# discovered would price every council at one published review, whatever it
# dispatches — the one arithmetic slip that makes the whole table meaningless,
# and it is invisible in any fixture with exactly five personas.
f=$(jq -r '.usd_low_first_pass' "$five/cost-estimate.json")
t=$(jq -r '.usd_low_first_pass' "$three/cost-estimate.json")
if [[ "$f" != "$t" ]]; then
	echo "  PASS: a smaller council is priced below a larger one ($t vs $f)"
	PASS=$((PASS + 1))
else
	echo "  FAIL: 3 and 5 personas priced identically at $f — divided by the roster, not the council"
	FAIL=$((FAIL + 1))
fi
discard_fixture "$five" "$three"

echo "Test 17: an unknown model class falls back to sonnet and names the ones that exist"
s=$(mk_session deep 5)
status=0
err=$(REVIEW_COUNCIL_MODEL_CLASS=gpt-9 bash "$ESTIMATE" "$s" 2>&1 >/dev/null) || status=$?
assert_equals "$status" "0" "an unknown class is not fatal"
assert_jq "$s/cost-estimate.json" '.model_class' 'sonnet' "an unknown class is priced as sonnet"
assert_jq "$s/cost-estimate.json" '.usd_low_first_pass' '1' "the sonnet band is what actually applied"
# The note has to carry the vocabulary: an operator who guessed the name wrong
# cannot find the right one in a message that only says the guess was wrong.
missing=""
for class in opus sonnet haiku; do
	case "$err" in
	*"$class"*) ;;
	*) missing="${missing} ${class}" ;;
	esac
done
if [[ -z "$missing" ]]; then
	echo "  PASS: the stderr note names every class the table ships"
	PASS=$((PASS + 1))
else
	echo "  FAIL: stderr note omits:${missing} (said: '$err')"
	FAIL=$((FAIL + 1))
fi
discard_fixture "$s"

echo "Test 18: an explicit band outranks the model class"
s=$(mk_session deep 5)
REVIEW_COUNCIL_MODEL_CLASS=opus REVIEW_COUNCIL_COST_LOW=1 REVIEW_COUNCIL_COST_HIGH=2 \
	bash "$ESTIMATE" "$s" >/dev/null
assert_jq "$s/cost-estimate.json" '.rate_low' '1' "the explicit low rate wins over the opus row"
assert_jq "$s/cost-estimate.json" '.rate_high' '2' "the explicit high rate wins over the opus row"
assert_jq "$s/cost-estimate.json" '.rate_source' 'env' "the artifact records where the band came from"
assert_jq "$s/cost-estimate.json" '.usd_low_first_pass' '5' "the explicit band reaches the total"
discard_fixture "$s"

echo "Test 19: the shipped Cost Per Review table parses"
# The estimator reads this table at runtime. A row reformatted by hand — a
# missing dollar sign, an en dash for the hyphen — costs no test anywhere else
# and silently drops the module back to its fallback constants.
rows=$(sed -nE 's/^[|] *([A-Za-z]+) *[|] *[$]([0-9.]+)-[$]([0-9.]+) *[|].*/\1 \2 \3/p' "$GUIDANCE")
row_count=$(grep -c . <<<"$rows" || true)
assert_equals "$row_count" "3" "three priced model-class rows parse out of the table"
council=$(sed -nE 's/^Council size:[[:space:]]*([0-9]+)[[:space:]]*$/\1/p' "$GUIDANCE")
case "$council" in
'' | *[!0-9]*)
	echo "  FAIL: Council size is missing or not numeric ('$council')"
	FAIL=$((FAIL + 1))
	;;
*)
	echo "  PASS: Council size parses as a number ($council)"
	PASS=$((PASS + 1))
	;;
esac
# The two `READ BY CODE` comments are the only warning an editor gets at the
# point of the edit, and the prose note they replaced sat four paragraphs below
# the table where nobody reformatting a row would ever reach it. Guarded here
# because a warning that can be deleted without consequence is one that
# eventually is: both the table and the `Council size:` line need their own,
# since they are edited independently and break the parse in different ways.
marker_count=$(grep -c 'READ BY CODE' "$GUIDANCE" || true)
assert_equals "$marker_count" "2" "both machine-read sections warn the editor in place"

echo "Test 20: the fallback constants still equal the sonnet row over the council size"
# Same guard as RC_PERSONAS in prepare-target.sh: the constants exist only for
# an install where the reference file is unreachable, and the moment they stop
# agreeing with the table they become a second, wrong source of truth that
# nothing would report.
const_low=$(sed -nE 's/^rate_low_default="([0-9.]+)"$/\1/p' "$ESTIMATE")
const_high=$(sed -nE 's/^rate_high_default="([0-9.]+)"$/\1/p' "$ESTIMATE")
sonnet_row=$(sed -nE 's/^[|] *Sonnet *[|] *[$]([0-9.]+)-[$]([0-9.]+) *[|].*/\1 \2/p' "$GUIDANCE")
read -r row_low row_high <<<"$sonnet_row"
# Compared to a hundredth of a cent rather than bit-for-bit, the same precision
# the script derives its band at: $2.80 over 5 is 0.5599999999999999 in binary
# floating point, and an exact-equality guard would fail on arithmetic instead
# of on the drift it is here to catch.
drift=$(jq -n --arg cl "$const_low" --arg ch "$const_high" \
	--arg rl "$row_low" --arg rh "$row_high" --arg n "$council" '
	def per_dispatch: (. / ($n | tonumber) * 10000 | round) / 10000;
	(($cl | tonumber) == ($rl | tonumber | per_dispatch))
	and (($ch | tonumber) == ($rh | tonumber | per_dispatch))' || echo "unparseable")
assert_equals "$drift" "true" "fallback constants match \$${row_low}-\$${row_high} over ${council}"

echo "Test 21: the rendered sentence says where the band came from"
s=$(mk_session deep 5)
out=$(REVIEW_COUNCIL_MODEL_CLASS=opus bash "$ESTIMATE" "$s")
# Flattened before matching: the closing paragraph is hard-wrapped, so the
# phrase spans a line break in the rendered table.
flat=$(tr '\n' ' ' <<<"$out" | tr -s ' ')
case "$flat" in
*"Opus band in"*"model-guidance.md"*)
	echo "  PASS: the table's own class and file are credited"
	PASS=$((PASS + 1))
	;;
*)
	echo "  FAIL: the sentence does not credit the Opus row: '$flat'"
	FAIL=$((FAIL + 1))
	;;
esac
out=$(REVIEW_COUNCIL_COST_LOW=1 REVIEW_COUNCIL_COST_HIGH=2 bash "$ESTIMATE" "$s")
flat=$(tr '\n' ' ' <<<"$out" | tr -s ' ')
# An operator's own numbers presented as the module's measurement is a claim
# about provenance that nobody can check afterwards from the artifact alone.
case "$flat" in
*"model-guidance.md"*)
	echo "  FAIL: an explicit band is still credited to the reference: '$flat'"
	FAIL=$((FAIL + 1))
	;;
*)
	echo "  PASS: an explicit band is not credited to the reference"
	PASS=$((PASS + 1))
	;;
esac
discard_fixture "$s"

echo "Test 22: SKILL.md carries the pre-dispatch cost gate"
SKILL_MD="$SCRIPT_DIR/../skills/review-council/SKILL.md"
# Scoped to the step, not to the whole document. SKILL.md already says
# "non-interactive" in Step 5, so a file-wide grep would report the gate present
# on a SKILL.md that never gained one — a guard that cannot fail protects
# nothing.
step_22=$(sed -n '/^### Step 2.2/,/^### Step 2.5/p' "$SKILL_MD" | tr '\n' ' ' | tr -s ' ')
if grep -qF 'rc-cost-estimate.sh' <<<"$step_22"; then
	echo "  PASS: SKILL.md runs the estimator"
	PASS=$((PASS + 1))
else
	echo "  FAIL: SKILL.md never runs rc-cost-estimate.sh"
	FAIL=$((FAIL + 1))
fi
# The gate is fail-open by design: a blocking question has twice ended headless
# runs (Step 2.5 and Step 5 both carry the scars), and review-open-prs.sh drives
# deep runs headlessly today. The step has to say so, or the next reader
# "tightens" it back into a run-killer.
if grep -qiE 'never blocks|non-interactive' <<<"$step_22"; then
	echo "  PASS: SKILL.md states the non-interactive behaviour"
	PASS=$((PASS + 1))
else
	echo "  FAIL: SKILL.md does not state the non-interactive behaviour"
	FAIL=$((FAIL + 1))
fi
# All three outcomes must be written out verbatim: tracking.md is the only
# record of whether a deep bill was authorised, and an orchestrator improvising
# the wording makes that record unreadable to anyone grepping it.
for outcome in "Acknowledgement: acknowledged" "Acknowledgement: declined" "Acknowledgement: not acknowledged"; do
	if grep -qF "$outcome" <<<"$step_22"; then
		echo "  PASS: SKILL.md defines '$outcome'"
		PASS=$((PASS + 1))
	else
		echo "  FAIL: SKILL.md omits '$outcome'"
		FAIL=$((FAIL + 1))
	fi
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
