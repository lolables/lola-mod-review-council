#!/usr/bin/env bash
# Pins the decomposition invariants of the Decompose phase.
#
# decompose.md runs only in deep mode (SKILL.md Step 2.1) and is an
# orchestrator-local analysis step: it dispatches no subagent and writes
# subsystems.json by LLM judgment alone. There is no script whose behaviour a
# test could exercise, so every rule that decides which changeset files reach a
# reviewer exists solely as a sentence in that file. Weaken the completeness
# check and files drop out of deep-mode review coverage silently — the same
# failure class the rest of the pipeline hardens against, and one that no other
# suite would surface as a failure. Pinning the sentences is the only protection
# available, and it is the pattern test-rc-disposition-rules.sh and the RC-NNN
# guards in test-rc-doc-guards.sh already use.
#
# Every pinned phrase is markdown lifted verbatim out of that file, so the
# backticks in them are literal characters to search for, never command
# substitution — single quotes are required, not an oversight. The directive
# has to sit immediately before the first command to apply file-wide.
# shellcheck disable=SC2016
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=module/tests/helpers.sh
source "$SCRIPT_DIR/helpers.sh"
DECOMPOSE_MD="$SCRIPT_DIR/../skills/review-council/phases/decompose.md"

# The file is flattened before matching — newlines and runs of spaces collapsed
# to one space — because these rules are wrapped prose and bullet text. Prose
# reflows the moment a word is added ahead of it, and a guard greping the raw
# file would then fail for a reason that has nothing to do with the rule it
# protects, which is the kind of false alarm that teaches maintainers to weaken
# guards. Deleting the sentence is still fatal, which is the property that
# matters.
flat=$(tr '\n' ' ' <"$DECOMPOSE_MD" | tr -s ' ')

# guard <label> <phrase>...
#
# Every phrase must still be present. A rule is usually stated once and then
# restated where it binds (the rule states it, a later step relies on it), and a
# guard that accepts any one of them would go green on a doc that kept the
# restatement while dropping the rule itself.
guard() {
	local label="$1" phrase
	local -a missing=()
	shift
	for phrase in "$@"; do
		grep -qF "$phrase" <<<"$flat" || missing+=("$phrase")
	done
	if [[ ${#missing[@]} -eq 0 ]]; then
		echo "  PASS: $label"
		PASS=$((PASS + 1))
	else
		echo "  FAIL: $label"
		printf '        missing: %s\n' "${missing[@]}"
		FAIL=$((FAIL + 1))
	fi
}

echo "Test: decompose.md still states every rule that bounds deep-mode coverage"

# The load-bearing one. Deep mode delegates per subsystem, so a file absent from
# subsystems.json is a file no reviewer ever sees. Without the mechanical check
# and its no-silent-omission clause, the orchestrator is free to drop whatever
# it judges uninteresting, and the run still reports a clean council verdict
# over a changeset it only partly read.
guard "every changeset file must land in a subsystem" \
	'Verify every file in `changeset.txt` appears in at least one subsystem in `subsystems.json`.' \
	'Mechanical check, not judgment call.' \
	'**No file in changeset.txt silently omitted.**' \
	'Files orchestrator deems low-value (CI config, lockfiles, boilerplate) still get review — agents decide relevance, not decomposition step.'

# The range is what keeps decomposition useful in both directions: the lower
# bound routes a cohesive changeset back to standard delegation instead of
# splitting it into a single degenerate subsystem, and the upper bound keeps an
# over-shredded changeset visible in tracking rather than silently fanning out.
guard "subsystem count stays in the 2-6 target range" \
	'**Target range: 2-6 subsystems.**' \
	'Fewer than 2 means changeset already cohesive — abandon decomposition, signal fallback to standard-mode delegation.' \
	'**More than 6 subsystems** suggests very large changeset. Proceed but note in tracking that decomposition produced high subsystem count.'

# Single-file subsystems are the failure mode a cohesion-based grouping drifts
# into: each one costs a full delegation to review one file with no sibling
# context. The merge rule is what forces that file back next to the code it
# relates to.
guard "single-file subsystems merge into their nearest relative" \
	'**Minimum 2 files per subsystem.** Merge single-file subsystems into nearest related subsystem.'

# The catch-all is what makes the completeness check satisfiable. Without it a
# leftover file has nowhere legal to go — the minimum-2-files rule forbids
# giving it its own subsystem — and the only way to produce a valid
# subsystems.json is to drop it, turning the merge rule into a silent-drop
# mechanism.
guard "unassigned files fall into a catch-all exempt from the minimum" \
	'Group unassigned files into catch-all subsystem named `infrastructure` (CI, build, config, devcontainer) or `other` (anything else).' \
	'Minimum-2-files rule does NOT apply to catch-all — single unassigned file still gets a subsystem.' \
	'Catch-all holds >30% of changeset: log warning — decomposition maybe too narrow.'

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
