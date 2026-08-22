#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=module/tests/helpers.sh
source "$SCRIPT_DIR/helpers.sh"
TRIAGE="$SCRIPT_DIR/../skills/review-council/scripts/rc-apply-triage.sh"

# Subsystem triage decides WHERE a persona looks, never WHETHER its lens runs.
# Every case below asserts one half of that: the narrowing the agent asked for,
# or the invariant that refuses it. The refusals matter more than the
# narrowings — a triage that over-narrows produces a verdict that looks exactly
# like a thorough one, and the finding nobody made is the only evidence.

PERSONAS='["divisor-adversary-code","divisor-curator-code","divisor-guard-code","divisor-sre-code","divisor-testing-code"]'

# A prepared deep session: three subsystems, each with the full council, exactly
# as rc-select-council.sh leaves one when no shape licensed a narrowing.
new_session() { # [subsystem_councils_json]
	local dir
	dir=$(mktemp -d)
	{
		echo "# Review Council Session Tracking"
		echo ""
		echo "## Phase: Preparation"
		echo ""
		echo "- Mode: code (test fixture)"
		echo "- Effort: deep"
		echo "- Subsystem triage: on"
		echo ""
	} >"$dir/tracking.md"
	jq -n '[{name:"auth",description:"auth",files:["auth/token.go","auth/session.go"]},
	        {name:"ui",description:"ui",files:["ui/button.tsx","ui/card.tsx"]},
	        {name:"ci",description:"ci",files:[".github/workflows/test.yml","Makefile"]}]' \
		>"$dir/subsystems.json"
	printf 'auth/token.go\nauth/session.go\nui/button.tsx\nui/card.tsx\n.github/workflows/test.yml\nMakefile\n' \
		>"$dir/changeset.txt"
	jq -n --argjson p "$PERSONAS" \
		'{mode:"code", suffix:"code", agents:$p, absent:[], council:$p, deselected:[],
		  selection:{applied:false, shape:"mixed", reason:"not conclusive", pinned:[]},
		  subsystems: [ {name:"auth",shape:"mixed",applied:false,council:$p,deselected:[]},
		                {name:"ui",shape:"mixed",applied:false,council:$p,deselected:[]},
		                {name:"ci",shape:"mixed",applied:false,council:$p,deselected:[]} ]}' \
		>"$dir/session-manifest.json"
	printf '%s' "$dir"
}

# Write the agent's raw output. Wrapped in prose on purpose: the extractor has
# to find the fenced block inside a real reply, not a bare JSON file.
raw() { # dir json
	{
		echo "I reviewed each subsystem against the five lenses."
		echo ""
		echo '```json'
		printf '%s\n' "$2"
		echo '```'
		echo ""
		echo "Every cell not named above should be dispatched."
	} >"$1/triage.raw.md"
}

# A reason long enough to satisfy the schema's minimum. "not relevant" is not a
# reason a maintainer can check, and the schema says so.
R='no input handling, no network calls, no credential material in this subsystem'

# The matrix, built from `<subsystem> <persona>` pairs. The JSON is assembled
# INSIDE the helper rather than substituted into its arguments: a command
# substitution nested in another command has its exit status discarded, and a jq
# that died would write an empty block that the extractor reads as a malformed
# reply — a passing test for the wrong reason.
raw_excl() { # dir [subsystem persona]...
	local dir="$1" json
	shift
	json=$(printf '%s\n' "$@" | jq -R -s -c --arg r "$R" '
		split("\n") | map(select(length > 0))
		| {exclusions: [range(0; length; 2) as $i
		   | {subsystem: .[$i], persona: .[$i + 1], reason: $r}]}')
	raw "$dir" "$json"
}

check() { # label actual expected
	if [[ "$2" == "$3" ]]; then
		echo "  PASS: $1"
		PASS=$((PASS + 1))
	else
		echo "  FAIL: $1"
		echo "         expected: $3"
		echo "         actual:   $2"
		FAIL=$((FAIL + 1))
	fi
}
# Assertions run their command inside the helper: a command substitution nested
# in another command has its exit status discarded, and this suite is linted
# with the optional checks on.
check_manifest() { # dir label filter expected
	local actual
	actual=$(jq -r "$3" "$1/session-manifest.json")
	check "$2" "$actual" "$4"
}
check_out() { # json label filter expected
	local actual
	actual=$(jq -r "$3" <<<"$1")
	check "$2" "$actual" "$4"
}
# The council of one subsystem, sorted and comma-joined.
sub_council() { # dir label name expected
	check_manifest "$1" "$2" \
		"(.subsystems[] | select(.name == \"$3\") | .council) | sort | join(\",\")" "$4"
}

[[ -f "$TRIAGE" ]] || {
	echo "ERROR: rc-apply-triage.sh not found at $TRIAGE" >&2
	exit 1
}

# --- The happy path ----------------------------------------------------------

echo "Test: named cells are excluded and every other cell survives"
d=$(new_session)
raw_excl "$d" ui adversary ui sre ci curator
out=$(bash "$TRIAGE" "$d")
check_out "$out" "status ok" '.status' "ok"
check_out "$out" "applied" '.applied' "true"
check_out "$out" "three cells excluded" '.excluded | length' "3"
sub_council "$d" "auth untouched" auth \
	"divisor-adversary-code,divisor-curator-code,divisor-guard-code,divisor-sre-code,divisor-testing-code"
sub_council "$d" "ui loses two" ui \
	"divisor-curator-code,divisor-guard-code,divisor-testing-code"
sub_council "$d" "ci loses one" ci \
	"divisor-adversary-code,divisor-guard-code,divisor-sre-code,divisor-testing-code"
check_manifest "$d" "dispatch total drops from 15 to 12" \
	'[.subsystems[].council | length] | add' "12"
check_manifest "$d" "each triage skip is sourced" \
	'[.subsystems[].deselected[] | select(.source == "triage")] | length' "3"
check_manifest "$d" "each triage skip carries its reason" \
	'[.subsystems[].deselected[] | select((.reason // "") == "")] | length' "0"
check_manifest "$d" "top-level council is still the union" \
	'.council | length' "5"
rm -rf "$d"

echo "Test: an empty exclusion list is a valid answer that changes nothing"
d=$(new_session)
raw "$d" '{"exclusions":[]}'
out=$(bash "$TRIAGE" "$d")
check_out "$out" "status ok" '.status' "ok"
check_out "$out" "nothing applied" '.applied' "false"
check_manifest "$d" "grid intact" '[.subsystems[].council | length] | add' "15"
rm -rf "$d"

# --- Invariant 1: row coverage ----------------------------------------------

echo "Test: a persona excluded from every subsystem keeps all of them"
# The failure this whole design exists to prevent: a lens removed from the
# council by the back door, one subsystem at a time.
d=$(new_session)
raw_excl "$d" auth curator ui curator ci curator
out=$(bash "$TRIAGE" "$d")
check_out "$out" "status ok" '.status' "ok"
check_manifest "$d" "grid intact" '[.subsystems[].council | length] | add' "15"
check_out "$out" "the refusal is reported" '.refused | length' "1"
check_out "$out" "the refusal names the persona" '.refused[0].persona' "curator"
check_out "$out" "the refusal names its rule" '.refused[0].rule' "row-coverage"
rm -rf "$d"

echo "Test: a persona excluded from all but one subsystem keeps that one"
d=$(new_session)
raw_excl "$d" ui curator ci curator
out=$(bash "$TRIAGE" "$d")
check_out "$out" "applied" '.applied' "true"
sub_council "$d" "auth keeps the Curator" auth \
	"divisor-adversary-code,divisor-curator-code,divisor-guard-code,divisor-sre-code,divisor-testing-code"
check_manifest "$d" "the other two lose it" \
	'[.subsystems[] | select(.name != "auth") | .council[] | select(. == "divisor-curator-code")] | length' "0"
rm -rf "$d"

# --- Invariant 2: column floor ----------------------------------------------

echo "Test: a subsystem may not fall below two reviewers through triage"
d=$(new_session)
raw_excl "$d" ui adversary ui curator ui guard ui sre auth sre
out=$(bash "$TRIAGE" "$d")
sub_council "$d" "ui keeps its whole council" ui \
	"divisor-adversary-code,divisor-curator-code,divisor-guard-code,divisor-sre-code,divisor-testing-code"
sub_council "$d" "auth is still narrowed" auth \
	"divisor-adversary-code,divisor-curator-code,divisor-guard-code,divisor-testing-code"
check_out "$out" "the refusal names the subsystem" \
	'[.refused[] | select(.rule == "column-floor") | .subsystem] | join(",")' "ui"
rm -rf "$d"

echo "Test: exactly two reviewers left is allowed, one is not"
d=$(new_session)
raw_excl "$d" ci adversary ci curator ci guard
bash "$TRIAGE" "$d" >/dev/null
sub_council "$d" "ci is left with two" ci "divisor-sre-code,divisor-testing-code"
rm -rf "$d"

# --- Invariant 3: subtract only ---------------------------------------------

echo "Test: excluding a persona shape selection already skipped is a no-op"
d=$(new_session)
# Shape selection has already taken the Tester and the Operator off `ui`.
jq '(.subsystems[] | select(.name == "ui")) |=
	(.shape = "docs-only" | .applied = true
	 | .council = ["divisor-adversary-code","divisor-curator-code","divisor-guard-code"]
	 | .deselected = [{agent:"divisor-sre-code",persona:"sre",source:"shape",reason:"docs-only changeset"},
	                  {agent:"divisor-testing-code",persona:"testing",source:"shape",reason:"docs-only changeset"}])' \
	"$d/session-manifest.json" >"$d/m.tmp" && mv "$d/m.tmp" "$d/session-manifest.json"
raw_excl "$d" ui sre auth sre
out=$(bash "$TRIAGE" "$d")
sub_council "$d" "ui unchanged" ui \
	"divisor-adversary-code,divisor-curator-code,divisor-guard-code"
check_manifest "$d" "the Operator is skipped once on ui, not twice" \
	'[.subsystems[] | select(.name == "ui") | .deselected[] | select(.persona == "sre")] | length' "1"
check_manifest "$d" "and that skip is still credited to shape" \
	'[.subsystems[] | select(.name == "ui") | .deselected[] | select(.persona == "sre") | .source] | join(",")' "shape"
sub_council "$d" "auth still narrows" auth \
	"divisor-adversary-code,divisor-curator-code,divisor-guard-code,divisor-testing-code"
rm -rf "$d"

# --- Invariant 4: open findings are re-dispatched ---------------------------

echo "Test: a reviewer with an open finding is restored to that subsystem"
# On a re-review the agent that filed a finding has to be present to judge the
# fix. Triage must not be able to remove the only reviewer who knows about it.
d=$(new_session)
mkdir -p "$d/verdicts"
jq -n '{verified:[{agent:"divisor-adversary-code", file:"ui/button.tsx", severity:"HIGH",
                   evidence:"x", description:"d", recommendation:"r"}],
        correctable:[], stripped:[], total_findings:1, duplicates_consolidated:0, verdicts:{}}' \
	>"$d/verdicts/findings.json"
raw_excl "$d" ui adversary ci adversary
out=$(bash "$TRIAGE" "$d")
check_manifest "$d" "the Adversary stays on ui" \
	'[.subsystems[] | select(.name == "ui") | .council[] | select(. == "divisor-adversary-code")] | length' "1"
check_manifest "$d" "but is still excluded from ci" \
	'[.subsystems[] | select(.name == "ci") | .council[] | select(. == "divisor-adversary-code")] | length' "0"
check_out "$out" "the restoration is reported" \
	'[.refused[] | select(.rule == "open-finding") | .subsystem] | join(",")' "ui"
rm -rf "$d"

echo "Test: a stripped finding does not pin a reviewer"
# Only findings that survived verification are open. A stripped one is exactly
# the fabrication the pipeline exists to discard.
d=$(new_session)
mkdir -p "$d/verdicts"
jq -n '{verified:[], correctable:[],
        stripped:[{agent:"divisor-adversary-code", file:"ui/button.tsx", severity:"HIGH",
                   evidence:"x", description:"d", recommendation:"r", reason:"FILE_NOT_FOUND"}],
        total_findings:1, duplicates_consolidated:0, verdicts:{}}' \
	>"$d/verdicts/findings.json"
raw_excl "$d" ui adversary
bash "$TRIAGE" "$d" >/dev/null
check_manifest "$d" "the Adversary is excluded from ui" \
	'[.subsystems[] | select(.name == "ui") | .council[] | select(. == "divisor-adversary-code")] | length' "0"
rm -rf "$d"

# --- Invariant 5: unknown names ---------------------------------------------

echo "Test: an exclusion naming something that does not exist is dropped"
d=$(new_session)
raw_excl "$d" does-not-exist adversary ui archivist ui sre
out=$(bash "$TRIAGE" "$d")
check_out "$out" "only the real cell applied" '.excluded | length' "1"
check_manifest "$d" "grid drops by exactly one" '[.subsystems[].council | length] | add' "14"
rm -rf "$d"

# --- Invariant 6: fail open --------------------------------------------------

echo "Test: a missing raw file applies nothing and does not fail the run"
d=$(new_session)
out=$(bash "$TRIAGE" "$d")
check_out "$out" "status" '.status' "nothing_to_do"
check_manifest "$d" "grid intact" '[.subsystems[].council | length] | add' "15"
rm -rf "$d"

echo "Test: a reply with no fenced JSON block is reported and applies nothing"
d=$(new_session)
printf 'I could not decide, sorry.\n' >"$d/triage.raw.md"
out=$(bash "$TRIAGE" "$d")
check_out "$out" "status" '.status' "triage_error"
check_manifest "$d" "grid intact" '[.subsystems[].council | length] | add' "15"
rm -rf "$d"

echo "Test: a schema-invalid block is refused wholesale, not partially applied"
d=$(new_session)
# One good exclusion and one whose reason is too short to be checkable. The
# block is refused entire: partially honouring a malformed matrix means acting
# on a document the agent did not write. Built into a variable rather than
# substituted into the call, so a jq failure here cannot masquerade as the
# malformed block this case is about.
bad_matrix=$(jq -nc --arg r "$R" '{exclusions:[
	{subsystem:"ui", persona:"sre", reason:$r},
	{subsystem:"ci", persona:"sre", reason:"nah"}]}')
raw "$d" "$bad_matrix"
out=$(bash "$TRIAGE" "$d")
check_out "$out" "status" '.status' "triage_error"
check_manifest "$d" "grid intact" '[.subsystems[].council | length] | add' "15"
rm -rf "$d"

echo "Test: an unexpected top-level key is refused"
d=$(new_session)
raw "$d" '{"exclusions":[],"verdict":"APPROVE"}'
out=$(bash "$TRIAGE" "$d")
check_out "$out" "status" '.status' "triage_error"
rm -rf "$d"

# --- Gates -------------------------------------------------------------------

echo "Test: triage does nothing when it is switched off"
d=$(new_session)
sed -i.bak 's/^- Subsystem triage:.*$/- Subsystem triage: off/' "$d/tracking.md"
rm -f "$d/tracking.md.bak"
raw_excl "$d" ui sre
out=$(bash "$TRIAGE" "$d")
check_out "$out" "status" '.status' "nothing_to_do"
check_manifest "$d" "grid intact" '[.subsystems[].council | length] | add' "15"
rm -rf "$d"

echo "Test: triage does nothing without subsystems"
# Standard mode has one implicit subsystem, where triage would decide whether a
# lens runs at all rather than where it looks.
d=$(new_session)
rm -f "$d/subsystems.json"
raw_excl "$d" ui sre
out=$(bash "$TRIAGE" "$d")
check_out "$out" "status" '.status' "nothing_to_do"
rm -rf "$d"

echo "Test: an unreadable session reports nothing_to_do"
out=$(bash "$TRIAGE" "/nonexistent/session/$$" || true)
check_out "$out" "status" '.status' "nothing_to_do"

# --- Tracking and idempotency ------------------------------------------------

echo "Test: the tracking block records what was applied and what was refused"
d=$(new_session)
raw_excl "$d" ui sre auth curator ui curator ci curator
bash "$TRIAGE" "$d" >/dev/null
blocks=$(grep -c '^## Phase: Subsystem Triage$' "$d/tracking.md" || true)
check "block written" "$blocks" "1"
applied_line=$(grep -c '^- Triage: applied$' "$d/tracking.md" || true)
check "applied line" "$applied_line" "1"
refused_line=$(grep -c '^- Refused: 1$' "$d/tracking.md" || true)
check "refusals counted" "$refused_line" "1"

echo "Test: re-running replaces the tracking block and the councils it wrote"
bash "$TRIAGE" "$d" >/dev/null
blocks=$(grep -c '^## Phase: Subsystem Triage$' "$d/tracking.md" || true)
check "still one block" "$blocks" "1"
check_manifest "$d" "the same cell is not excluded twice" \
	'[.subsystems[].deselected[] | select(.source == "triage")] | length' "1"
check_manifest "$d" "and the grid is unchanged by the second run" \
	'[.subsystems[].council | length] | add' "14"
rm -rf "$d"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
