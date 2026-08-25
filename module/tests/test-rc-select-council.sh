#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=module/tests/helpers.sh
source "$SCRIPT_DIR/helpers.sh"
SELECT="$SCRIPT_DIR/../skills/review-council/scripts/rc-select-council.sh"

# Contextual persona selection (issue #20). The council is REDUCIBLE but never
# SILENTLY reduced: every case below asserts both halves — who is dispatched,
# and that the skip is recorded as its own coverage state rather than as full
# coverage or as a dropped verdict.
#
# Sessions are built by hand rather than by running rc-prepare.sh. The selector's
# whole contract is "given these artifacts, produce this council", and a fixture
# that has to survive a git checkout, a forge probe and language detection to
# reach it would fail for reasons that say nothing about the rules under test.

FULL_AGENTS='["divisor-adversary-code","divisor-curator-code","divisor-guard-code","divisor-sre-code","divisor-testing-code"]'

# A prepared session, exactly as rc-prepare.sh leaves one: tracking keys the
# selector reads, an empty changeset for the caller to fill, and a manifest whose
# council is already the full roster (the fail-open seed).
new_session() { # [mode] [agents_json]
	local mode="${1:-code}" agents="${2:-$FULL_AGENTS}" suffix dir
	suffix="code"
	[[ "$mode" == "spec" ]] && suffix="spec"
	dir=$(mktemp -d)
	{
		echo "# Review Council Session Tracking"
		echo ""
		echo "## Phase: Preparation"
		echo ""
		echo "- Mode: ${mode} (test fixture)"
		echo "- Effort: standard"
		echo "- Review instructions: none"
		echo "- Persona selection: on"
		echo "- Pin personas: none"
		echo ""
	} >"$dir/tracking.md"
	: >"$dir/changeset.txt"
	jq -n --arg mode "$mode" --arg suffix "$suffix" --argjson agents "$agents" \
		'{mode: $mode, suffix: $suffix, agents: $agents, absent: [],
		  council: $agents, deselected: [],
		  selection: {applied: false, shape: "unevaluated",
		              reason: "council selection has not run", pinned: []},
		  subsystems: []}' >"$dir/session-manifest.json"
	printf '%s' "$dir"
}

# Replace a tracking key in place, for the cases that turn a guard on.
set_tracking() { # dir key value
	local dir="$1" key="$2" value="$3"
	sed -i.bak -E "s|^- ${key}:.*$|- ${key}: ${value}|" "$dir/tracking.md"
	rm -f "$dir/tracking.md.bak"
}

changeset() { # dir file...
	local dir="$1"
	shift
	printf '%s\n' "$@" >"$dir/changeset.txt"
}

# Comma-joined council from the manifest, sorted, so an assertion pins the set
# rather than the order the selector happens to emit.
#
# Every assertion below runs its command INSIDE its helper rather than as
# `check "..." "$(jq ...)"`. A command substitution nested in another command
# has its exit status discarded, and this suite is linted with the optional
# checks on: a jq that died on a truncated manifest would compare an empty
# string, which is exactly the value several of these cases expect to see fail.
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

# Assert over the manifest a run just wrote.
check_manifest() { # dir label filter expected
	local actual
	actual=$(jq -r "$3" "$1/session-manifest.json")
	check "$2" "$actual" "$4"
}
check_council() { # dir label expected
	check_manifest "$1" "$2" '(.council // []) | sort | join(",")' "$3"
}
check_deselected() { # dir label expected
	check_manifest "$1" "$2" '(.deselected // []) | map(.agent) | sort | join(",")' "$3"
}
# Assert over the JSON the run printed on stdout.
check_out() { # json label filter expected
	local actual
	actual=$(jq -r "$3" <<<"$1")
	check "$2" "$actual" "$4"
}
# Assert how many lines of tracking.md match a pattern. `grep -c` exits 1 on
# zero matches, so the status is discarded deliberately here — the count is the
# assertion, and zero is a legitimate (failing) answer rather than an error.
check_tracking() { # dir label pattern expected_count
	local actual
	actual=$(grep -c "$3" "$1/tracking.md" || true)
	check "$2" "$actual" "$4"
}

[[ -f "$SELECT" ]] || {
	echo "ERROR: rc-select-council.sh not found at $SELECT" >&2
	exit 1
}

# --- Shape: docs-only --------------------------------------------------------

echo "Test: a prose-only changeset drops the Tester and the Operator"
d=$(new_session)
changeset "$d" "README.md" "docs/usage.md" "CHANGELOG"
out=$(bash "$SELECT" "$d")
check_out "$out" "status ok" '.status' "ok"
check_out "$out" "shape docs-only" '.shape' "docs-only"
check_out "$out" "selection applied" '.applied' "true"
check_council "$d" "council" "divisor-adversary-code,divisor-curator-code,divisor-guard-code"
check_deselected "$d" "deselected" "divisor-sre-code,divisor-testing-code"
check_manifest "$d" "every deselection carries a reason" '[.deselected[] | select((.reason // "") == "")] | length' "0"
check_manifest "$d" "discovered roster untouched" '.agents | tojson' "$FULL_AGENTS"
rm -rf "$d"

echo "Test: prose under a prompt surface fails open to the full council"
for prompt_doc in "module/agents/divisor-guard-code.md" "AGENTS.md" ".claude/skills/x/SKILL.md" "prompts/review.md"; do
	d=$(new_session)
	changeset "$d" "README.md" "$prompt_doc"
	out=$(bash "$SELECT" "$d")
	check_out "$out" "shape for $prompt_doc" '.shape' "docs-prompt-surface"
	check_manifest "$d" "full council for $prompt_doc" '.council | length' "5"
	rm -rf "$d"
done

# --- Shape: tests-only -------------------------------------------------------

echo "Test: a tests-only changeset drops the Curator"
for test_file in "internal/auth/token_test.go" "src/api.test.ts" "src/api.spec.ts" \
	"tests/helpers.sh" "__tests__/render.js" "testdata/fixture.json" \
	"test_login.py" "spec/models/user_spec.rb" "module/tests/e2e/pipeline.venom.yml"; do
	d=$(new_session)
	changeset "$d" "$test_file"
	out=$(bash "$SELECT" "$d")
	check_out "$out" "shape for $test_file" '.shape' "tests-only"
	check_council "$d" "council for $test_file" \
		"divisor-adversary-code,divisor-guard-code,divisor-sre-code,divisor-testing-code"
	rm -rf "$d"
done

# --- Shape: deps-only --------------------------------------------------------

echo "Test: a lockfile-only changeset keeps only the Adversary and the Operator"
d=$(new_session)
changeset "$d" "go.sum" "package-lock.json" "Cargo.lock"
out=$(bash "$SELECT" "$d")
check_out "$out" "shape deps-only" '.shape' "deps-only"
check_council "$d" "council" "divisor-adversary-code,divisor-sre-code"
check_deselected "$d" "deselected" \
	"divisor-curator-code,divisor-guard-code,divisor-testing-code"
rm -rf "$d"

echo "Test: a dependency MANIFEST is not a lockfile — go.mod + go.sum stays mixed"
d=$(new_session)
changeset "$d" "go.mod" "go.sum"
out=$(bash "$SELECT" "$d")
check_out "$out" "shape mixed" '.shape' "mixed"
check_manifest "$d" "full council" '.council | length' "5"
check_out "$out" "not applied" '.applied' "false"
rm -rf "$d"

# --- Inconclusive shapes -----------------------------------------------------

echo "Test: a mixed changeset dispatches the full council"
d=$(new_session)
changeset "$d" "README.md" "internal/auth/token.go"
out=$(bash "$SELECT" "$d")
check_out "$out" "shape mixed" '.shape' "mixed"
check_manifest "$d" "full council" '.council | length' "5"
rm -rf "$d"

echo "Test: an empty changeset dispatches the full council"
d=$(new_session)
: >"$d/changeset.txt"
out=$(bash "$SELECT" "$d")
check_out "$out" "shape empty" '.shape' "empty"
check_manifest "$d" "full council" '.council | length' "5"
rm -rf "$d"

# --- Fail-open guards --------------------------------------------------------

echo "Test: spec mode never narrows — spec artifacts are prose by construction"
d=$(new_session spec '["divisor-adversary-spec","divisor-curator-spec","divisor-guard-spec","divisor-sre-spec","divisor-testing-spec"]')
changeset "$d" "docs/specs/plan.md" "docs/design/architecture.md"
out=$(bash "$SELECT" "$d")
check_out "$out" "not applied" '.applied' "false"
check_manifest "$d" "full council" '.council | length' "5"
check_out "$out" "reason names the mode" '.reason | test("spec")' "true"
rm -rf "$d"

echo "Test: 'Persona selection: off' disables selection entirely"
d=$(new_session)
set_tracking "$d" "Persona selection" "off"
changeset "$d" "README.md"
out=$(bash "$SELECT" "$d")
check_out "$out" "not applied" '.applied' "false"
check_manifest "$d" "full council" '.council | length' "5"
rm -rf "$d"

echo "Test: explicit review instructions widen the council back to full"
d=$(new_session)
set_tracking "$d" "Review instructions" "present"
changeset "$d" "README.md"
out=$(bash "$SELECT" "$d")
check_out "$out" "not applied" '.applied' "false"
check_manifest "$d" "full council" '.council | length' "5"
rm -rf "$d"

echo "Test: a pinned persona survives a shape that would drop it"
d=$(new_session)
set_tracking "$d" "Pin personas" "testing"
changeset "$d" "README.md"
out=$(bash "$SELECT" "$d")
check_out "$out" "applied" '.applied' "true"
check_council "$d" "pinned Tester kept" \
	"divisor-adversary-code,divisor-curator-code,divisor-guard-code,divisor-testing-code"
check_deselected "$d" "only the Operator dropped" "divisor-sre-code"
check_manifest "$d" "pin recorded" '.selection.pinned | join(",")' "testing"
rm -rf "$d"

echo "Test: selection never empties the council on a partial install"
d=$(new_session code '["divisor-curator-code","divisor-testing-code"]')
changeset "$d" "go.sum"
out=$(bash "$SELECT" "$d")
check_out "$out" "not applied" '.applied' "false"
check_council "$d" "both reviewers kept" "divisor-curator-code,divisor-testing-code"
check_out "$out" "reason names the empty council" '.reason | test("no reviewer")' "true"
rm -rf "$d"

echo "Test: an unreadable session changes nothing and reports nothing_to_do"
out=$(bash "$SELECT" "/nonexistent/session/$$" || true)
check_out "$out" "status" '.status' "nothing_to_do"
d=$(new_session)
rm -f "$d/session-manifest.json"
changeset "$d" "README.md"
out=$(bash "$SELECT" "$d")
check_out "$out" "status without a manifest" '.status' "nothing_to_do"
rm -rf "$d"

# --- Deep mode ---------------------------------------------------------------

echo "Test: deep mode selects per subsystem and unions the result"
d=$(new_session)
changeset "$d" "docs/usage.md" "docs/install.md" "internal/auth/token.go" "go.sum"
jq -n '[{name: "documentation", description: "user docs",
         files: ["docs/usage.md", "docs/install.md"]},
        {name: "auth", description: "auth core", files: ["internal/auth/token.go"]},
        {name: "dependencies", description: "lockfiles", files: ["go.sum"]}]' \
	>"$d/subsystems.json"
out=$(bash "$SELECT" "$d")
check_manifest "$d" "documentation subsystem narrows" '.subsystems[] | select(.name == "documentation") | .council | sort | join(",")' \
	"divisor-adversary-code,divisor-curator-code,divisor-guard-code"
check_manifest "$d" "auth subsystem stays whole" '.subsystems[] | select(.name == "auth") | .council | length' "5"
check_manifest "$d" "dependencies subsystem narrows hardest" '.subsystems[] | select(.name == "dependencies") | .council | sort | join(",")' \
	"divisor-adversary-code,divisor-sre-code"
check_council "$d" "top-level council is the union" \
	"divisor-adversary-code,divisor-curator-code,divisor-guard-code,divisor-sre-code,divisor-testing-code"
check_manifest "$d" "dispatch total is the sum of the subsystem councils" '[.subsystems[].council | length] | add' "10"
check_out "$out" "applied" '.applied' "true"
rm -rf "$d"

echo "Test: deep mode with no subsystem narrowed reports not applied"
d=$(new_session)
changeset "$d" "internal/auth/token.go" "cmd/root.go"
jq -n '[{name: "auth", description: "auth", files: ["internal/auth/token.go"]},
        {name: "cmd", description: "entry", files: ["cmd/root.go"]}]' >"$d/subsystems.json"
out=$(bash "$SELECT" "$d")
check_out "$out" "not applied" '.applied' "false"
check_manifest "$d" "full council" '.council | length' "5"
rm -rf "$d"

# --- Tracking output ---------------------------------------------------------

echo "Test: the tracking block records the three coverage states"
d=$(new_session)
changeset "$d" "README.md"
bash "$SELECT" "$d" >/dev/null
check_tracking "$d" "block written" '^## Phase: Council Selection$' "1"
check_tracking "$d" "council line" '^- Council: divisor-adversary-code, divisor-curator-code, divisor-guard-code$' "1"
check_tracking "$d" "skipped line" '^- Skipped reviewers: divisor-sre-code, divisor-testing-code$' "1"
check_tracking "$d" "shape line" '^- Changeset shape: docs-only$' "1"

echo "Test: re-running replaces the tracking block rather than appending"
bash "$SELECT" "$d" >/dev/null
check_tracking "$d" "still one block" '^## Phase: Council Selection$' "1"
check_tracking "$d" "still one council line" '^- Council: ' "1"
check_council "$d" "council unchanged on re-run" \
	"divisor-adversary-code,divisor-curator-code,divisor-guard-code"
rm -rf "$d"

echo "Test: a not-applied run still records why, so the report cannot claim narrowing"
d=$(new_session)
changeset "$d" "internal/auth/token.go"
bash "$SELECT" "$d" >/dev/null
check_tracking "$d" "selection line" '^- Selection: not applied$' "1"
check_tracking "$d" "skipped line says none" '^- Skipped reviewers: none$' "1"
rm -rf "$d"

# --- Model provenance --------------------------------------------------------

# `models.json` used to be the orchestrator's job: phases/delegate.md asked it to
# append an entry as it dispatched each reviewer. Across 1785 cached sessions the
# file exists zero times, so every report rendered the renderer's "not recorded"
# fallback instead of the provenance it promised. The tier a persona is dispatched
# at is a fixed property of the persona, so the selector — which already knows the
# roster — seeds the file, and the orchestrator's remaining job is the narrower
# one of UPGRADING an entry when the host names a concrete model.
#
# Entries are asserted sorted by role, so a case pins the set rather than the
# order the seeding happens to emit.
# An absent models.json is the exact regression this section guards, so a missing
# file has to read as a failed assertion rather than abort the suite under `set
# -e` and take the remaining cases with it. Same handling as check_tracking.
check_models() { # dir label filter expected
	local actual
	actual=$(jq -r "$3" "$1/models.json" 2>/dev/null || true)
	check "$2" "$actual" "$4"
}

echo "Test: a full-council run seeds one provenance entry per dispatched reviewer"
d=$(new_session)
changeset "$d" "internal/auth/token.go"
bash "$SELECT" "$d" >/dev/null
check_models "$d" "one entry per reviewer" 'length' "5"
check_models "$d" "roles are the dispatched council" \
	'map(.role) | sort | join(",")' \
	"divisor-adversary-code,divisor-curator-code,divisor-guard-code,divisor-sre-code,divisor-testing-code"

echo "Test: seeded tiers follow the delegate.md table"
check_models "$d" "adversary is Capable" 'map(select(.role == "divisor-adversary-code")) | .[0].id' "Capable tier"
check_models "$d" "guard is Capable" 'map(select(.role == "divisor-guard-code")) | .[0].id' "Capable tier"
check_models "$d" "testing is Standard" 'map(select(.role == "divisor-testing-code")) | .[0].id' "Standard tier"
check_models "$d" "sre is Standard" 'map(select(.role == "divisor-sre-code")) | .[0].id' "Standard tier"
check_models "$d" "curator is Standard" 'map(select(.role == "divisor-curator-code")) | .[0].id' "Standard tier"
rm -rf "$d"

echo "Test: a deselected reviewer gets no entry, so provenance names only what ran"
d=$(new_session)
changeset "$d" "README.md"
bash "$SELECT" "$d" >/dev/null
check_council "$d" "docs-only council" \
	"divisor-adversary-code,divisor-curator-code,divisor-guard-code"
check_models "$d" "entries match the narrowed council" \
	'map(.role) | sort | join(",")' \
	"divisor-adversary-code,divisor-curator-code,divisor-guard-code"
rm -rf "$d"

echo "Test: re-running neither duplicates entries nor clobbers a host-supplied model ID"
d=$(new_session)
changeset "$d" "internal/auth/token.go"
bash "$SELECT" "$d" >/dev/null
# Stand in for the orchestrator upgrading a seeded tier once the host named the
# model it actually dispatched on. A re-run that reset this to "Capable tier"
# would silently downgrade a true record to a requested one.
jq '(.[] | select(.role == "divisor-guard-code") | .id) = "claude-sonnet-5"' \
	"$d/models.json" >"$d/models.json.edited"
mv "$d/models.json.edited" "$d/models.json"
bash "$SELECT" "$d" >/dev/null
check_models "$d" "no duplicate entries on re-run" 'length' "5"
check_models "$d" "concrete ID survives" \
	'map(select(.role == "divisor-guard-code")) | .[0].id' "claude-sonnet-5"
check_models "$d" "unupgraded roles keep their tier" \
	'map(select(.role == "divisor-adversary-code")) | .[0].id' "Capable tier"
rm -rf "$d"

echo "Test: a spec-mode council seeds spec personas at the same tiers"
d=$(new_session spec '["divisor-adversary-spec","divisor-guard-spec","divisor-testing-spec"]')
changeset "$d" "specs/auth.md"
bash "$SELECT" "$d" >/dev/null
check_models "$d" "adversary-spec is Capable" \
	'map(select(.role == "divisor-adversary-spec")) | .[0].id' "Capable tier"
check_models "$d" "testing-spec is Standard" \
	'map(select(.role == "divisor-testing-spec")) | .[0].id' "Standard tier"
rm -rf "$d"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
