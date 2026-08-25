#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=module/skills/review-council/scripts/rc-lib.sh
source "$(dirname "$0")/rc-lib.sh"
rc_trap_errors # report script:line on any unhandled failure (never silent)

# rc-select-council.sh <session_dir>
# Narrows the dispatched council to the personas whose concern the changeset
# actually touches, and records every persona it drops as a distinct coverage
# state. Rewrites session-manifest.json, appends a `## Phase: Council Selection`
# block to tracking.md, and emits the decision as JSON on stdout.
#
# The council is REDUCIBLE but never SILENTLY reduced. Three states, not two:
# a persona that ran and found nothing, a persona that was dispatched and
# returned nothing (`missing_verdicts`), and a persona that was deliberately not
# dispatched. The third is new, and every consumer of the manifest — evidence
# verification, the cost estimate, the report, the PR comment — reads it as its
# own state rather than folding it into either of the other two.
#
# Fail open, always. Preparation seeds `council` equal to the discovered roster,
# so a host that never runs this step dispatches everyone; and every guard below
# leaves that seed in place rather than narrowing on a signal it could not read.
# A redundant dispatch costs a few dollars. A false skip costs a finding, and
# nothing downstream can tell that it is missing.
#
# This script makes no forge calls, so it does not require GNU timeout.

session_dir="${1:-}"
if [[ -z "$session_dir" ]] || [[ ! -d "$session_dir" ]]; then
	json_output "nothing_to_do" "Session directory does not exist."
	exit 0
fi

manifest="$session_dir/session-manifest.json"
changeset_file="$session_dir/changeset.txt"
tracking_file="$session_dir/tracking.md"
if [[ ! -f "$manifest" ]] || [[ ! -f "$changeset_file" ]]; then
	json_output "nothing_to_do" "Session is missing session-manifest.json or changeset.txt."
	exit 0
fi

agents_json=$(jq -c '(.agents // [])' "$manifest" 2>/dev/null) || agents_json='[]'
suffix=$(jq -r '.suffix // "code"' "$manifest" 2>/dev/null) || suffix="code"
mode=$(jq -r '.mode // "code"' "$manifest" 2>/dev/null) || mode="code"
agent_count=$(jq -r 'length' <<<"$agents_json")

# ============================================================================
# Path classification
# ============================================================================
#
# Exactly one class per path, first match wins. The classes exist to answer one
# question per persona — is there anything here for it to review — so each is
# drawn as narrowly as the answer allows. A path this cannot place confidently
# lands in `other`, which never narrows anything.

# Generated dependency lockfiles, by exact basename. Dependency MANIFESTS
# (go.mod, package.json, Cargo.toml, pyproject.toml) are deliberately absent:
# a manifest is authored, and its intent is exactly what the Guard reviews. Only
# the generated half of the pair is content no persona wrote.
rc_is_lock() { # basename
	case "$1" in
	package-lock.json | npm-shrinkwrap.json | yarn.lock | pnpm-lock.yaml | bun.lock | bun.lockb) return 0 ;;
	Gemfile.lock | poetry.lock | Pipfile.lock | uv.lock | requirements.lock) return 0 ;;
	Cargo.lock | composer.lock | go.sum | mix.lock | pubspec.lock) return 0 ;;
	packages.lock.json | gradle.lockfile | flake.lock | conan.lock | cabal.project.freeze) return 0 ;;
	*) return 1 ;;
	esac
}

# `spec` and `specs` are NOT in the directory list. In this module they are
# specification directories, and a spec artifact is not a test artifact — the
# `*.spec.*` and `*_spec.rb` basenames below still catch the two languages that
# spell a test file that way.
rc_is_test() { # path basename
	case "/$1/" in
	*/test/* | */tests/* | */__tests__/* | */__mocks__/* | */testdata/* | */e2e/*) return 0 ;;
	*) ;;
	esac
	case "$2" in
	*_test.* | *.test.* | *.spec.*) return 0 ;;
	test_*.py | conftest.py | *_spec.rb) return 0 ;;
	*Test.java | *Tests.java | *Test.cs | *Tests.cs) return 0 ;;
	*.venom.yml | *.venom.yaml) return 0 ;;
	*) return 1 ;;
	esac
}

rc_is_doc() { # basename
	case "$1" in
	*.md | *.markdown | *.rst | *.adoc | *.asciidoc | *.org) return 0 ;;
	LICENSE | NOTICE | COPYING | AUTHORS | CONTRIBUTORS | CHANGELOG) return 0 ;;
	*) return 1 ;;
	esac
}

# Markdown is not always prose. In a prompt-driven repository — and this module
# is one — an agent definition, a skill body and a phase document ARE the
# behaviour under review, so "no code changed" is false about them. A docs-only
# rule that dropped the Tester here would lose "this behaviour change has no
# test", which is a real finding class, not a theoretical one.
#
# The list therefore errs broad: over-matching costs a redundant dispatch,
# under-matching costs a finding. `src/commands/README.md` matching is the
# intended direction of the error.
rc_is_prompt_surface() { # path basename
	case "/$1/" in
	*/agents/* | */skills/* | */prompts/* | */commands/* | */instructions/*) return 0 ;;
	*/.claude/* | */.cursor/* | */.windsurf/* | */.github/copilot/*) return 0 ;;
	*) ;;
	esac
	case "$2" in
	AGENTS.md | CLAUDE.md | GEMINI.md | copilot-instructions.md) return 0 ;;
	*) return 1 ;;
	esac
}

rc_class() { # path -> lock|test|prompt-doc|doc|other
	local path="$1" base="${1##*/}"
	# shellcheck disable=SC2310 # predicates, called for their status in a
	# condition, which is where bash exempts them from `set -e` by design.
	if rc_is_lock "$base"; then
		printf 'lock'
	elif rc_is_test "$path" "$base"; then
		printf 'test'
	elif rc_is_doc "$base"; then
		if rc_is_prompt_surface "$path" "$base"; then printf 'prompt-doc'; else printf 'doc'; fi
	else
		printf 'other'
	fi
}

# The shape of a file list: the single class every file shares, or `mixed`. A
# shape is a claim that one whole category of review surface is absent from the
# changeset, which is the only claim strong enough to justify not dispatching a
# reviewer at all.
rc_shape() { # file... -> shape
	local f cls total=0 n_lock=0 n_test=0 n_doc=0 n_prompt=0
	for f in "$@"; do
		[[ -n "$f" ]] || continue
		total=$((total + 1))
		cls=$(rc_class "$f")
		case "$cls" in
		lock) n_lock=$((n_lock + 1)) ;;
		test) n_test=$((n_test + 1)) ;;
		doc) n_doc=$((n_doc + 1)) ;;
		prompt-doc) n_prompt=$((n_prompt + 1)) ;;
		# `other` is counted only by $total: it is the class that licenses
		# nothing, so no shape below needs its tally.
		*) ;;
		esac
	done
	if [[ $total -eq 0 ]]; then
		printf 'empty'
	elif [[ $n_lock -eq $total ]]; then
		printf 'deps-only'
	elif [[ $n_test -eq $total ]]; then
		printf 'tests-only'
	elif [[ $n_doc -eq $total ]]; then
		printf 'docs-only'
	elif [[ $((n_doc + n_prompt)) -eq $total ]]; then
		printf 'docs-prompt-surface'
	else
		printf 'mixed'
	fi
}

# What each conclusive shape licenses dropping, as `persona<TAB>reason` rows.
# The reason travels with the persona because it is published: it reaches
# `deselected[].reason` in the manifest and the report, where a reader deciding
# whether to re-run with selection off needs to see the argument, not the label.
#
# Every persona named here is in `RC_PERSONAS` (scripts/lib/prepare-target.sh),
# and test-rc-doc-guards.sh fails on any drift between the two.
rc_drops_for_shape() { # shape
	case "$1" in
	docs-only)
		printf 'testing\tdocs-only changeset: no code or test surface to review\n'
		printf 'sre\tdocs-only changeset: no runtime, deployment or permission surface\n'
		;;
	tests-only)
		printf 'curator\ttests-only changeset: no user-facing documentation surface\n'
		;;
	deps-only)
		printf 'guard\tlockfile-only changeset: generated content carries no authored intent\n'
		printf 'curator\tlockfile-only changeset: generated content is not documentation\n'
		printf 'testing\tlockfile-only changeset: no test logic to review\n'
		;;
	# Every other shape licenses nothing. Printing no rows is what makes
	# rc_evaluate report `applied: false` and leave the council whole.
	*) ;;
	esac
}

rc_shape_reason() { # shape
	case "$1" in
	docs-only) printf 'every changed file is prose documentation' ;;
	tests-only) printf 'every changed file is a test artifact' ;;
	deps-only) printf 'every changed file is a generated dependency lockfile' ;;
	docs-prompt-surface) printf 'prose sits under a prompt or instruction surface, where markdown is executable' ;;
	mixed) printf 'changeset shape is not conclusive' ;;
	empty) printf 'changeset is empty' ;;
	*) printf 'changeset shape could not be determined' ;;
	esac
}

# ============================================================================
# Configuration and global guards
# ============================================================================

# `Persona selection` is written by rc-prepare.sh for every session it prepares,
# so its absence means the session was prepared before selection existed. That
# is a missing signal, not a permissive one: such a session also lacks the pin
# list and the review-instructions flag, and narrowing on two of three inputs is
# exactly the guess this script must not make.
selection_config=$(rc_parse_kv "$tracking_file" "Persona selection")
review_instructions=$(rc_parse_kv "$tracking_file" "Review instructions")
pins_raw=$(rc_parse_kv "$tracking_file" "Pin personas")

# Pinned personas: lowercased, split on commas and whitespace, with the literal
# `none` rc-prepare.sh writes for an unset key dropped. A pin that matches no
# discovered persona is reported and otherwise ignored — the same treatment
# rc-cost-estimate.sh gives an unknown model class.
pinned=()
if [[ -n "$pins_raw" ]] && [[ "$pins_raw" != "none" ]]; then
	while IFS= read -r pin; do
		[[ -n "$pin" ]] || continue
		pinned+=("$pin")
	done < <(printf '%s' "${pins_raw,,}" | tr ',' ' ' | tr -s '[:space:]' '\n' | grep -E '^[a-z][a-z0-9-]*$' || true)
fi
pinned_json='[]'
if [[ ${#pinned[@]} -gt 0 ]]; then
	pinned_json=$(printf '%s\n' "${pinned[@]}" | jq -R . | jq -c -s .)
	for pin in "${pinned[@]}"; do
		if ! jq -e --arg a "divisor-${pin}-${suffix}" 'index($a)' <<<"$agents_json" >/dev/null; then
			echo "rc-select-council: pinned persona '${pin}' matches no discovered reviewer; ignoring" >&2
		fi
	done
fi

# One guard, one reason. An empty `guard_reason` means selection may proceed.
guard_reason=""
if [[ -z "$selection_config" ]]; then
	guard_reason="session was prepared before council selection existed, so its inputs are unknown"
elif [[ "${selection_config,,}" == "off" ]]; then
	guard_reason="council selection is disabled by configuration"
elif [[ "${selection_config,,}" != "on" ]]; then
	echo "rc-select-council: ignoring 'Persona selection: ${selection_config}' (expected on or off); using on" >&2
fi
# Spec artifacts are documentation by construction, so a docs shape would fire
# on every spec review and silently halve the council. The spec personas have
# their own mandates — divisor-testing-spec reviews testability and contract
# surface, divisor-sre-spec reviews deployment and operational requirements —
# and neither is answered by "no code changed".
if [[ -z "$guard_reason" ]] && [[ "$mode" != "code" ]]; then
	guard_reason="spec mode reviews documentation by construction, so change shape licenses nothing"
fi
# An explicit focus is a signal this script cannot parse. Widening to full
# coverage is the only reading of it that cannot lose the thing the user asked
# to have looked at.
if [[ -z "$guard_reason" ]] && [[ -n "$review_instructions" ]] && [[ "$review_instructions" != "none" ]]; then
	guard_reason="explicit review instructions widen the council to full coverage"
fi

# ============================================================================
# Evaluation
# ============================================================================

# Decide one council over one file list. Prints
# `{shape, applied, reason, council, deselected}`; the caller supplies the files
# because deep mode asks the same question once per subsystem.
rc_evaluate() { # file...
	local shape drops deselected council reason applied n_deselected n_council
	shape=$(rc_shape "$@")
	drops=$(rc_drops_for_shape "$shape")

	if [[ -z "$drops" ]]; then
		# Resolved into a variable rather than substituted inside the jq call: a
		# command substitution nested in another command has its exit status
		# discarded, so a broken helper would silently supply an empty reason.
		reason=$(rc_shape_reason "$shape")
		jq -n --arg shape "$shape" --arg reason "$reason" \
			--argjson council "$agents_json" \
			'{shape: $shape, applied: false, reason: $reason, council: $council, deselected: []}'
		return 0
	fi

	# Pins are honoured before the empty-council guard below, so a pin can make a
	# narrowing smaller but never turn one into no review at all. A drop naming a
	# persona this host did not install is discarded here too: calling an agent
	# that does not exist "skipped" would invent a coverage gap that the `absent`
	# roster already reports, more accurately.
	deselected=$(printf '%s' "$drops" | jq -R -s -c \
		--argjson agents "$agents_json" --argjson pinned "$pinned_json" --arg suffix "$suffix" '
		split("\n") | map(select(length > 0)) | map(split("\t"))
		| map({persona: .[0], reason: .[1]})
		| map(select(.persona as $p | ($pinned | index($p)) == null))
		| map(. + {agent: ("divisor-" + .persona + "-" + $suffix)})
		| map(select(.agent as $a | ($agents | index($a)) != null))
		| map({agent, persona, reason}) | sort_by(.agent)')

	council=$(jq -n -c --argjson agents "$agents_json" --argjson out "$deselected" \
		'[$agents[] | select(. as $a | ($out | map(.agent) | index($a)) == null)]')

	applied=true
	reason=$(rc_shape_reason "$shape")
	n_deselected=$(jq -r 'length' <<<"$deselected")
	n_council=$(jq -r 'length' <<<"$council")
	if [[ "$n_deselected" -eq 0 ]]; then
		# Every persona the shape licenses dropping is pinned or not installed.
		applied=false
		reason="no discovered reviewer is out of scope for this changeset"
	elif [[ "$n_council" -eq 0 ]]; then
		# A partial install can be narrower than the drop set. Silencing the
		# review entirely is never the answer to "this changeset is cheap".
		applied=false
		reason="narrowing would leave no reviewer, so the full council stands"
		deselected='[]'
		council="$agents_json"
	fi

	jq -n --arg shape "$shape" --argjson applied "$applied" --arg reason "$reason" \
		--argjson council "$council" --argjson deselected "$deselected" \
		'{shape: $shape, applied: $applied, reason: $reason, council: $council, deselected: $deselected}'
}

mapfile -t changeset_files < <(grep -v '^[[:space:]]*$' "$changeset_file" 2>/dev/null || true)

subsystems_file="$session_dir/subsystems.json"
subsystems_json='[]'

if [[ -n "$guard_reason" ]]; then
	result=$(jq -n --arg reason "$guard_reason" --argjson council "$agents_json" \
		'{shape: "not-evaluated", applied: false, reason: $reason, council: $council, deselected: []}')
elif [[ -f "$subsystems_file" ]] && jq -e 'length > 0' "$subsystems_file" >/dev/null 2>&1; then
	# Deep mode. A subsystem may be docs-only while its sibling is code, so the
	# applicable council differs WITHIN one run and each is decided on its own
	# file list. The per-subsystem councils are what delegation dispatches; the
	# top-level council is their UNION, because rc-verify-evidence.sh flattens
	# the subsystem directories when it globs for verdicts — an agent that ran
	# anywhere owes a verdict, and one skipped everywhere owes none.
	sub_results='[]'
	while IFS= read -r sub_name; do
		[[ -n "$sub_name" ]] || continue
		mapfile -t sub_files < <(jq -r --arg n "$sub_name" \
			'.[] | select(.name == $n) | (.files // [])[]' "$subsystems_file" 2>/dev/null || true)
		sub_eval=$(rc_evaluate "${sub_files[@]+"${sub_files[@]}"}")
		sub_results=$(jq -c --arg name "$sub_name" --argjson e "$sub_eval" \
			'. + [{name: $name} + $e]' <<<"$sub_results")
	done < <(jq -r '.[].name // empty' "$subsystems_file" 2>/dev/null || true)

	subsystems_json=$(jq -c 'map({name, shape, applied, council, deselected})' <<<"$sub_results")
	# Top-level `deselected` is the agents skipped in EVERY subsystem — the ones
	# with no coverage anywhere in this run. An agent skipped in one subsystem
	# and dispatched in another has coverage, and listing it here would
	# contradict the union council beside it. Its per-subsystem skip is not lost:
	# `subsystems[]` carries it, and the tracking block prints one line each.
	result=$(jq -n --argjson subs "$sub_results" --argjson agents "$agents_json" '
		($subs | map(select(.applied)) | length) as $narrowed
		| ($subs | map(.council[]) | unique) as $union
		| {shape: ($subs | map(.shape) | unique | sort | join("+")),
		   applied: ($narrowed > 0),
		   reason: (if $narrowed > 0
		            then "\($narrowed) of \($subs | length) subsystems narrowed by change shape"
		            else "no subsystem shape licensed dropping a reviewer" end),
		   council: (if $narrowed > 0 then $union else $agents end),
		   deselected: ($subs | map(.deselected[]) | group_by(.agent) | map(.[0])
		                | map(select(.agent as $a | ($union | index($a)) == null))
		                | sort_by(.agent))}')
else
	result=$(rc_evaluate "${changeset_files[@]+"${changeset_files[@]}"}")
fi

applied=$(jq -r '.applied' <<<"$result")
shape=$(jq -r '.shape' <<<"$result")
reason=$(jq -r '.reason' <<<"$result")
council_json=$(jq -c '.council' <<<"$result")
deselected_json=$(jq -c '.deselected' <<<"$result")
council_count=$(jq -r 'length' <<<"$council_json")

# ============================================================================
# Persist
# ============================================================================

# The manifest is rewritten through a temp file and moved into place: this
# script is re-runnable (SKILL.md Step 2 resumes a session mid-run), and a
# redirect straight onto the file jq is reading truncates it to zero before jq
# opens it, losing the roster with nothing left to recover it from.
manifest_tmp="${manifest}.tmp"
jq --argjson council "$council_json" \
	--argjson deselected "$deselected_json" \
	--argjson applied "$applied" \
	--arg shape "$shape" \
	--arg reason "$reason" \
	--argjson pinned "$pinned_json" \
	--argjson subsystems "$subsystems_json" \
	'. + {council: $council, deselected: $deselected, subsystems: $subsystems,
	      selection: {applied: $applied, shape: $shape, reason: $reason, pinned: $pinned}}' \
	"$manifest" >"$manifest_tmp"
mv "$manifest_tmp" "$manifest"

# Model provenance, seeded from the roster this run just fixed.
#
# phases/delegate.md used to ask the orchestrator to append an entry here as it
# dispatched each reviewer. It never did: across 1785 cached sessions the file
# exists zero times, so every report fell through to the renderer's "not
# recorded" line. Same failure as the batch rule before rc-plan-batches.sh — a
# decision expressed only as prose, competing for the orchestrator's attention
# with the review itself, is a decision that does not happen.
#
# The tier a persona is dispatched at is a fixed property of the persona (the
# table in phases/delegate.md), and the council is already known here, so the
# seed is fully derivable and belongs in a script. What is NOT derivable is the
# concrete model the host chose; that stays the orchestrator's job, narrowed
# from "write this file" to "upgrade an entry when the host names a model".
#
# A seeded entry therefore records the tier REQUESTED, not a model the host
# confirmed — which is exactly the fallback delegate.md already specified, now
# actually produced rather than merely described.
#
# An existing id always wins for a role that is still on the council: a re-run
# (SKILL.md Step 2 resumes mid-run) must not reset an upgraded concrete ID back
# to its tier. Roles that left the council lose their entry, so provenance names
# what ran rather than what was once considered.
models_file="$session_dir/models.json"
models_prev='[]'
if [[ -f "$models_file" ]]; then
	# A hand-damaged file is discarded rather than propagated: the seed below can
	# rebuild every tier from the roster, so the recoverable loss is only the
	# upgraded IDs, and that beats aborting the run over a provenance artifact.
	models_prev=$(jq -c '.' "$models_file" 2>/dev/null || echo '[]')
fi
models_tmp="${models_file}.tmp"
jq -n --argjson council "$council_json" --argjson prev "$models_prev" '
	# Persona segment of divisor-<persona>-<suffix>. Tiers come from the
	# "Model Selection Guidance" table in phases/delegate.md; a persona the
	# table does not name gets a neutral label rather than a guessed tier,
	# because inventing provenance is worse than disclosing less of it.
	def tier(role):
		(role | split("-") | .[1] // "") as $persona
		| if $persona == "adversary" or $persona == "guard" then "Capable tier"
		  elif $persona == "testing" or $persona == "sre" or $persona == "curator"
		  then "Standard tier"
		  else "Tier not specified" end;
	($prev | map({key: .role, value: .id}) | from_entries) as $known
	| [$council[] | {role: ., id: ($known[.] // tier(.))}]
' >"$models_tmp"
mv "$models_tmp" "$models_file"

# Joined for the tracking block; "none" when the list is empty, so a reader
# never has to tell an absent value from an empty one. Resolved into variables
# here rather than substituted inside the `echo`s below: a command substitution
# nested in another command has its exit status discarded, so a jq that died on
# a malformed array would print an empty value as though that were the answer —
# and "Skipped (out of scope):" with nothing after it reads as "nothing was
# skipped", which is the opposite of what happened.
deselected_agents_json=$(jq -c 'map(.agent)' <<<"$deselected_json")
council_line=$(jq -r 'if length == 0 then "none" else join(", ") end' <<<"$council_json")
skipped_line=$(jq -r 'if length == 0 then "none" else join(", ") end' <<<"$deselected_agents_json")
pinned_line=$(jq -r 'if length == 0 then "none" else join(", ") end' <<<"$pinned_json")

if [[ -f "$tracking_file" ]]; then
	# Replaced rather than appended, which is what makes a re-run a no-op: awk
	# drops any previous block from its heading to the next `## ` heading or end
	# of file. The filter and the move are separate statements, not an
	# `awk ... && mv` list — in a list the awk failure would be exempt from
	# `set -e`, the move would be skipped, and the run would end with the stale
	# block in place and a second one appended beneath it. Same shape as
	# rc-cost-estimate.sh, for the same reason.
	if grep -q '^## Phase: Council Selection$' "$tracking_file"; then
		tracking_tmp="${tracking_file}.tmp"
		awk '
			/^## Phase: Council Selection$/ { skip = 1; next }
			skip && /^## / { skip = 0 }
			!skip { print }
		' "$tracking_file" >"$tracking_tmp"
		mv "$tracking_tmp" "$tracking_file"
	fi
	{
		echo "## Phase: Council Selection"
		echo ""
		if [[ "$applied" == "true" ]]; then
			echo "- Selection: applied"
		else
			echo "- Selection: not applied"
		fi
		echo "- Changeset shape: ${shape}"
		echo "- Reason: ${reason}"
		echo "- Council: ${council_line}"
		# The key holds no regex metacharacter, deliberately. rc_parse_kv builds
		# an ERE from the key it is asked for, so a parenthesised key —
		# "Skipped (out of scope)" was the first draft — compiles the parentheses
		# as a group and matches a line that is not there. The reader gets the
		# empty string, which every caller reads as "nothing was skipped": the
		# exact silent full-coverage claim this line exists to prevent. The
		# human phrasing lives in the report label instead.
		echo "- Skipped reviewers: ${skipped_line}"
		echo "- Pinned: ${pinned_line}"
		# One line per subsystem, because a deep run's cost and its coverage are
		# both per-subsystem facts and neither is recoverable from the union above.
		while IFS= read -r line; do
			[[ -n "$line" ]] || continue
			echo "$line"
		done < <(jq -r '.[] | "- Subsystem \(.name): \(.shape) — \(.council | length) reviewer(s)" +
			(if (.deselected | length) > 0
			 then ", skipped \(.deselected | map(.agent) | join(", "))"
			 else "" end)' <<<"$subsystems_json" 2>/dev/null || true)
		echo ""
	} >>"$tracking_file"
fi

if [[ "$applied" == "true" ]]; then
	message="Council narrowed to ${council_count} of ${agent_count} reviewers: ${reason}."
else
	message="Full council of ${council_count} reviewers dispatched: ${reason}."
fi

# Built before the call rather than inside it, so a jq failure aborts here under
# `set -e` instead of being swallowed as an empty payload the orchestrator would
# read as "no council at all".
payload=$(jq -n --argjson applied "$applied" --arg shape "$shape" --arg reason "$reason" \
	--argjson council "$council_json" --argjson deselected "$deselected_json" \
	--argjson subsystems "$subsystems_json" \
	'{applied: $applied, shape: $shape, reason: $reason, council: $council,
	  deselected: $deselected, subsystems: $subsystems}')
json_output "ok" "$message" "$payload"
exit 0
