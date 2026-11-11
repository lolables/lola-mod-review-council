#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=module/skills/review-council/scripts/rc-lib.sh
source "$(dirname "$0")/rc-lib.sh"
rc_trap_errors

# rc-assemble-prompts.sh <session_dir> [--inline-persona] [--keep-receipts]
# Renders every reviewer's complete prompt into a file, so the orchestrator
# hands each reviewer a path instead of retyping ~60 KB into its dispatch call.
# On openvox-ca#570 a hand-copied prompt garbled four diff hunks and the run
# was discarded. Writes, under <session_dir>:
#
#   prompts/dispatch/[<verdict_dir>/]<agent>.md  one prompt per reviewer per round
#   dispatch.json                                the index: agent, raw verdict
#                                                path, prompt path, receipt
#
# and a `## Phase: Prompts` block in tracking.md. The index sits at the session
# root, not in prompts/, because rc-build-context.sh replaces prompts/ whole:
# a recovery re-run of Step 2.7 must not take the receipts with it. Runs after rc-build-context.sh
# (SKILL.md Step 2.7) and reads what it wrote. The prose comes from
# references/dispatch-prompt.md; this script only picks the sections and renders
# headings, fences, file lists and session values around them.
#
# Every prompt ends with a receipt token unique to that dispatch: the reviewer
# copies it into its verdict, which shows it reached the end of the file.
# Each code prompt also closes with its round's lines inside diff hunks, because
# reviewers quoted those for context_check when the list was only in the bundle.
# A spec reviewer (divisor-*-spec) gets the spec prompt instead: no preamble,
# bundle, diff or context check, but its artifact list and severity pack path.
# Deep mode renders one set per subsystem round, each with that subsystem's
# council and files, framed by its name and description from subsystems.json.
#
# --inline-persona puts the agent's persona file (from AGENTS_DIR, as
# rc-prepare.sh discovers it) right after the preamble, for hosts that cannot
# dispatch a named agent type.
#
# --keep-receipts is for recovery once reviewers have been dispatched: each
# dispatch whose raw path the existing index lists keeps that receipt, so the
# verdicts already collected still match; any other dispatch gets a fresh one.
# A malformed index is an error rather than a fresh start, since minting new
# receipts there would reject every collected verdict without saying why.
# Without the flag every receipt is fresh.

# bash 5.2 expands `&` in a ${var//pat/rep} replacement to the match. Values
# substituted here include paths, so the option is turned off where it exists.
if shopt -q patsub_replacement 2>/dev/null; then
	shopt -u patsub_replacement
fi

session_dir=""
inline_persona="no"
keep_receipts="no"
for arg in "$@"; do
	case "$arg" in
	--inline-persona) inline_persona="yes" ;;
	--keep-receipts) keep_receipts="yes" ;;
	-*)
		json_output "error" "Unknown option: $arg. The options are --inline-persona and --keep-receipts."
		exit 1
		;;
	*)
		if [[ -n "$session_dir" ]]; then
			json_output "error" "Unexpected argument: $arg. Usage: rc-assemble-prompts.sh <session_dir> [--inline-persona] [--keep-receipts]"
			exit 1
		fi
		session_dir="$arg"
		;;
	esac
done
if [[ -z "$session_dir" ]] || [[ ! -d "$session_dir" ]]; then
	json_output "nothing_to_do" "Session directory does not exist."
	exit 0
fi
session_dir=$(cd "$session_dir" && pwd)
refs_dir="$(cd "$(dirname "$0")/../references" && pwd)"
tracking_file="$session_dir/tracking.md"
manifest="$session_dir/session-manifest.json"
context_file="$session_dir/prompts/context.json"
preamble_file="$session_dir/prompts/preamble.md"
diff_file="$session_dir/diff.patch"
# The session copy preparation resolved; a spec prompt names it in full.
severity_pack="$session_dir/review-config/severity.md"
prompt_md="$refs_dir/dispatch-prompt.md"
dispatch_index="$session_dir/dispatch.json"

for f in "$context_file" "$preamble_file"; do
	if [[ ! -f "$f" ]]; then
		json_output "error" "prompts/$(basename "$f") is missing: run rc-build-context.sh (SKILL.md Step 2.7) first."
		exit 1
	fi
done
for f in "$tracking_file" "$manifest" "$session_dir/session.txt"; do
	if [[ ! -f "$f" ]]; then
		json_output "error" "$(basename "$f") is missing: re-run preparation (rc-prepare.sh writes it)."
		exit 1
	fi
done
if [[ ! -f "$prompt_md" ]]; then
	json_output "error" "references/dispatch-prompt.md is missing: the skill install is incomplete; reinstall the module."
	exit 1
fi

if [[ "$inline_persona" == "yes" ]] && [[ -z "${AGENTS_DIR:-}" || ! -d "${AGENTS_DIR:-}" ]]; then
	json_output "error" "--inline-persona needs AGENTS_DIR set to the agents directory rc-prepare.sh was given."
	exit 1
fi

# Receipts to keep, by raw path; the first entry for a path wins. Index values
# are data: they are looked up by the raw paths this run computes and never
# opened. An absent index leaves nothing to keep.
declare -A kept_receipts=()
if [[ "$keep_receipts" == "yes" ]] && [[ -e "$dispatch_index" || -L "$dispatch_index" ]]; then
	if ! kept=$(jq -r "if ($RC_DISPATCH_INDEX_OK) then .dispatches[] | [.raw, .receipt] | @tsv else error end" "$dispatch_index" 2>/dev/null); then
		json_output "error" "dispatch.json is unreadable or malformed, so --keep-receipts has no receipts to keep. Restore it and re-run with --keep-receipts; otherwise re-run without it and re-dispatch every reviewer, as the new prompts carry new receipts."
		exit 1
	fi
	# Only a path this run could compute is kept: anything else would match no
	# dispatch, and bash re-expands a subscript that `-v` tests.
	safe_raw='^verdicts/([A-Za-z0-9][A-Za-z0-9._-]*/)*[A-Za-z0-9][A-Za-z0-9._-]*\.raw\.md$'
	while IFS=$'\t' read -r kraw kreceipt; do
		[[ "$kraw" =~ $safe_raw && ! -v "kept_receipts[$kraw]" ]] || continue
		kept_receipts["$kraw"]="$kreceipt"
	done <<<"$kept"
fi

# ============================================================================
# Session values
# ============================================================================

# Review root as rc-build-context.sh and rc-verify-evidence.sh read it.
review_root=$(rc_parse_kv "$session_dir/session.txt" "Review root")
if [[ -z "$review_root" ]]; then
	json_output "error" "session.txt records no Review root; re-run preparation."
	exit 1
fi

# Every field a prompt states. A missing one is an error rather than a blank:
# delegate.md "Forge tooling" explains how a reviewer told nothing guesses.
scope=$(rc_parse_kv "$tracking_file" "Scope")
tooling=$(rc_parse_kv "$tracking_file" "Tooling")
docs_repo=$(rc_parse_kv "$tracking_file" "Docs repo")
packs_raw=$(rc_parse_kv "$tracking_file" "Project packs")
constitution_raw=$(rc_parse_kv "$tracking_file" "Constitution")
language=$(rc_parse_kv "$tracking_file" "Language")
framework=$(rc_parse_kv "$tracking_file" "Framework")
scope_dir=$(rc_parse_kv "$tracking_file" "Scope dir")
missing=()
for pair in "Scope=$scope" "Tooling=$tooling" "Docs repo=$docs_repo" "Project packs=$packs_raw" \
	"Constitution=$constitution_raw" "Language=$language" "Framework=$framework" "Scope dir=$scope_dir"; do
	[[ -n "${pair#*=}" ]] || missing+=("${pair%%=*}")
done
scope_value=$(rc_parse_kv "$tracking_file" "Scope value")
branch=$(rc_parse_kv "$tracking_file" "Branch")
base=$(rc_parse_kv "$tracking_file" "Base")
pr_number=$(rc_parse_kv "$tracking_file" "PR")

# delegate.md "Project packs and Constitution": the directory without its
# ` (N)` count, and the session-copy path without the parenthesised source.
if [[ "$packs_raw" =~ ^(.+)\ \([0-9]+\)$ ]]; then
	packs_dir="${BASH_REMATCH[1]}"
else
	packs_dir="$packs_raw"
fi
case "$constitution_raw" in
none | "none "*) constitution="none" ;;
*) constitution="${constitution_raw%% (*}" ;;
esac

# ============================================================================
# Prose sections
# ============================================================================

# Body of `## <name>` in dispatch-prompt.md, without its heading and without
# leading or trailing blank lines. Exits 2 when the heading is absent.
section_body() { # name
	awk -v h="## $1" '
		$0 == h { on = 1; found = 1; next }
		on && /^## / { exit }
		on { buf[++n] = $0 }
		END {
			if (!found) exit 2
			s = 1
			while (s <= n && buf[s] ~ /^[[:space:]]*$/) s++
			e = n
			while (e >= s && buf[e] ~ /^[[:space:]]*$/) e--
			for (i = s; i <= e; i++) print buf[i]
		}' "$prompt_md"
}

# Loaded up front, every one of them, so a broken install fails on every run
# rather than only on the run that happens to need the missing section.
declare -A sec=()
for name in \
	'Review root: checkout' 'Review root: in place' \
	'Changeset framing: changed' 'Changeset framing: range' 'Changeset framing: all' \
	'Changeset framing: pr' 'Changeset framing: subsystem' 'Changeset framing: path filter' \
	'Diff: none' 'Bundle' 'Changeset untrusted' 'Convention packs: code' 'Convention packs: spec' \
	'PR Description untrusted' 'Linked Issues untrusted' 'Prior Reviews untrusted' \
	'CI Status untrusted' 'Symlinks untrusted' 'Prior run context' \
	'Verdict instruction' 'Output contract: code' 'Output contract: spec' 'Context check' \
	'Grounding: code' 'Grounding: spec' 'Severity calibration: code' 'Severity calibration: spec' \
	'Model self-report' 'Review artifacts' 'Review artifacts: in place' 'Spec scope' 'Severity pack line' \
	'Framework hints' 'Focus areas'; do
	# shellcheck disable=SC2310 # the failure is handled: it names the section.
	if ! body=$(section_body "$name"); then
		json_output "error" "references/dispatch-prompt.md has no '## $name' section; restore it from the module."
		exit 1
	fi
	sec["$name"]="$body"
done

# The artifact list goes after the first paragraph of `Review artifacts` (the
# file's intro says so), which is the spec prompt's framing sentence.
artifacts_body="${sec["Review artifacts"]}"
if [[ "$artifacts_body" != *$'\n\n'* ]]; then
	json_output "error" "references/dispatch-prompt.md '## Review artifacts' has no paragraph to follow the artifact list; restore it from the module."
	exit 1
fi
artifacts_intro="${artifacts_body%%$'\n\n'*}"
artifacts_rest="${artifacts_body#*$'\n\n'}"

# The values fill() substitutes, by placeholder name. Global so the helper
# below can read them and return its result without a subshell, which would
# strip the trailing newlines of a text segment.
declare -A fill_vals=()

# Set fill_plain to <text> with each known {key} replaced in one pass, so a
# value holding another placeholder's name is never expanded again. Anything
# else in braces (a JSON example) is left as it is.
fill_text() { # text
	local rest="$1" key
	fill_plain=""
	while [[ "$rest" == *"{"* ]]; do
		fill_plain+="${rest%%\{*}"
		rest="${rest#*\{}"
		key="${rest%%\}*}"
		if [[ "$rest" == *"}"* && "$key" =~ ^[a-z][a-z_-]*$ ]] && [[ -v "fill_vals[$key]" ]]; then
			fill_plain+="${fill_vals[$key]}"
			rest="${rest#*\}}"
		else
			fill_plain+="{"
		fi
	done
	fill_plain+="$rest"
}

# Print <text> with its placeholders filled. A single-backtick code span that
# holds a placeholder (`{review_root}/<path>`) is rendered whole as a code span
# no backtick in the filled text can close: branch names and paths come from
# the change. Longer backtick runs (a ```json mention) are prose, copied as is.
fill() { # text key=value...
	local rest="$1" out="" kv inner span bt='`'
	shift
	fill_vals=()
	for kv in "$@"; do fill_vals["${kv%%=*}"]="${kv#*=}"; done
	while [[ "$rest" == *"$bt"* ]]; do
		fill_text "${rest%%"$bt"*}"
		out+="$fill_plain$bt"
		rest="${rest#*"$bt"}"
		if [[ "$rest" == "$bt"* ]]; then
			while [[ "$rest" == "$bt"* ]]; do
				out+="$bt"
				rest="${rest#"$bt"}"
			done
			continue
		fi
		[[ "$rest" == *"$bt"* ]] || continue
		inner="${rest%%"$bt"*}"
		rest="${rest#*"$bt"}"
		fill_text "$inner"
		if [[ "$fill_plain" == "$inner" ]]; then
			out+="$inner$bt"
		else
			span=$(code_span "$fill_plain")
			out="${out%"$bt"}$span"
		fi
	done
	fill_text "$rest"
	printf '%s' "$out$fill_plain"
}

# <text> in a code fence one backtick longer than its longest backtick run, so
# nothing in an untrusted block can close it and pass for prompt text.
fenced() { # info text
	local fence='```'
	while [[ "$2" == *"$fence"* ]]; do fence+='`'; done
	printf '%s%s\n%s\n%s\n' "$fence" "$1" "$2" "$fence"
}

# The agent's focus cell from the Focus areas table, if it has a row: the Code
# Review Focus column for a code reviewer, Spec Review Focus for a spec one.
focus_for() { # base code|spec
	local col=4
	[[ "$2" != spec ]] || col=5
	awk -F'|' -v want="\`$1\`" -v col="$col" '
		function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
		NF >= 6 && trim($2) == want { print trim($col); exit }' <<<"${sec["Focus areas"]}"
}

# Framework hints rows for this persona whose Language/Framework cell matches
# the session: `Go` matches language go, `TypeScript/React` needs framework
# react too. Persona Tester is the divisor-testing-* agents.
hints_for() { # base
	awk -F'|' -v base="$1" -v lang="${language,,}" -v fw="${framework,,}" '
		function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
		NF < 5 { next }
		{
			label = trim($2); key = label; gsub(/\*/, "", key); key = tolower(key)
			p = tolower(trim($3)); if (p == "tester") p = "testing"
			if ("divisor-" p != base) next
			n = split(key, kp, "/")
			if (kp[1] != lang || (n > 1 && kp[2] != fw)) next
			hint = $4
			for (i = 5; i < NF; i++) hint = hint "|" $i
			print "- " label ": " trim(hint)
		}' <<<"${sec["Framework hints"]}"
}

if [[ "$review_root" == "." ]]; then
	root_text=$(fill "${sec["Review root: in place"]}" "references_dir=$refs_dir")
else
	root_text=$(fill "${sec["Review root: checkout"]}" "review_root=$review_root" "references_dir=$refs_dir")
fi

# delegate.md "Scope framing". A changed-files or paths review compares the
# branch with its base; outside git (`--scope paths` on a plain directory)
# there is no base, so the files are framed as in scope, as --scope all is.
# A url review is a PR review, and both need the PR number preparation
# recorded: "PR #<url>" would misstate what is under review.
case "$scope" in
changed | paths)
	if [[ -z "$base" ]]; then
		scope_framing="${sec["Changeset framing: all"]}"
	else
		[[ -n "$branch" ]] || missing+=("Branch")
		scope_framing=$(fill "${sec["Changeset framing: changed"]}" "branch=$branch" "base=$base")
	fi
	;;
range)
	[[ -n "$scope_value" ]] || missing+=("Scope value")
	scope_framing=$(fill "${sec["Changeset framing: range"]}" "scope_value=$scope_value")
	;;
all) scope_framing="${sec["Changeset framing: all"]}" ;;
pr | url)
	if [[ ! "$pr_number" =~ ^[0-9]+$ ]]; then
		json_output "error" "tracking.md records no PR number (PR: ${pr_number:-absent}) for a $scope review. Re-run preparation."
		exit 1
	fi
	scope_framing=$(fill "${sec["Changeset framing: pr"]}" "scope_value=$pr_number")
	;;
"") scope_framing="" ;;
*)
	json_output "error" "tracking.md records an unknown Scope: $scope. Re-run preparation."
	exit 1
	;;
esac
if [[ "${#missing[@]}" -gt 0 ]]; then
	json_output "error" "tracking.md records no value for: $(
		IFS=,
		echo "${missing[*]}"
	). Re-run preparation (rc-prepare.sh writes them)."
	exit 1
fi
# The path filter, primary or secondary, narrows whichever scope it applies to,
# so each round appends it to its own framing sentence.
filter_text=""
if [[ "$scope_dir" != "none" ]]; then
	filter_text=$(fill "${sec["Changeset framing: path filter"]}" "scope_dir=$scope_dir")
fi

# ============================================================================
# Optional context, the same for every prompt
# ============================================================================

# The PR body: the lines between the first `--- BODY ---` and the next
# `--- END BODY ---`, read the way prepare-context.sh reads it.
pr_body=""
if [[ -f "$session_dir/pr-metadata.txt" ]]; then
	pr_body=$(awk '
		!on && $0 == "--- BODY ---" { on = 1; next }
		on && $0 == "--- END BODY ---" { exit }
		on { print }' "$session_dir/pr-metadata.txt")
fi
# Each block is a heading, the fenced data and the section telling the reviewer
# the data is untrusted, followed by a blank line.
optional_text=""
optional_block() { # heading info text untrusted_section
	[[ -n "$3" ]] || return 0
	optional_text+="## $1"$'\n\n'"$(fenced "$2" "$3")"$'\n\n'"${sec[$4]}"$'\n\n'
}
optional_block "PR Description" "" "$pr_body" "PR Description untrusted"
# delegate.md "Spec Review Delegation" gives spec reviewers every optional block
# but the PR description, so it is kept apart from the rest.
pr_text="$optional_text"
optional_text=""
for pair in "Linked Issues:linked-issues.txt" "Prior Reviews:prior-reviews.txt" \
	"CI Status:ci-status.txt" "Symlinks:symlinks.txt"; do
	label="${pair%%:*}"
	file="$session_dir/${pair#*:}"
	[[ -s "$file" ]] || continue
	optional_block "$label" "" "$(<"$file")" "$label untrusted"
done

# On a re-review iteration (SKILL.md Step 5 back to Step 2.7), the previous
# pass's findings.json is still on disk until verification moves it aside. The
# pass count comes from the `## Phase: Verification (iteration N)` blocks the
# orchestrator writes; on the first pass any findings.json is stale and unused.
passes=$(awk '/^## Phase: Verification \(iteration [0-9]+\)$/ {
	n = $0; gsub(/[^0-9]/, "", n); if (n + 0 > m) m = n + 0 } END { print m + 0 }' "$tracking_file")
findings_file="$session_dir/verdicts/findings.json"
if [[ "$passes" -ge 1 && -f "$findings_file" ]]; then
	if ! prior=$(jq '[(.verified // [])[] | {severity, file, line, title}]' "$findings_file" 2>/dev/null); then
		json_output "error" "verdicts/findings.json is not a findings document; restore it or move it aside before re-running."
		exit 1
	fi
	prior_count=$(jq 'length' <<<"$prior")
	if [[ "$prior_count" -gt 0 ]]; then
		optional_block "Prior Run Context" json "$prior" "Prior run context"
	fi
fi

# ============================================================================
# Prompts
# ============================================================================

# Every path diff.patch has a section for, as a JSON array.
diff_paths=$(rc_diff_index "$diff_file" | jq -Rn '[inputs | split("\t") | select(.[0] == "F") | .[1]] | unique')
diff_empty=0
[[ -s "$diff_file" ]] || diff_empty=1

round_count=$(jq '.rounds | length' "$context_file")
rounds=$(jq -c '.rounds[]' "$context_file")
if [[ "$round_count" -eq 0 ]]; then
	json_output "error" "prompts/context.json has no rounds, so no reviewer would be dispatched: the batch plan is empty. Re-run rc-plan-batches.sh and rc-build-context.sh (SKILL.md Steps 2.6 and 2.7) on a non-empty changeset."
	exit 1
fi

deep=$(jq '[.rounds[] | select(.subsystem != null)] | length > 0' "$context_file")

# Deep mode frames each round with its subsystem's name and description.
subsystems_file="$session_dir/subsystems.json"
if [[ "$deep" == "true" && ! -f "$subsystems_file" ]]; then
	json_output "error" "prompts/context.json has subsystem rounds but subsystems.json is missing; re-run decomposition (SKILL.md Step 2.1), then Steps 2.6 and 2.7."
	exit 1
fi

stage=$(mktemp -d "$session_dir/prompts/.dispatch.XXXXXX")
# A failed run must not leave the staging directory behind. rc_trap_errors uses
# ERR, so this EXIT trap is separate.
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/dispatch"
: >"$stage/entries.jsonl"
count=0
code_prompts=0

while IFS= read -r round; do
	[[ -n "$round" ]] || continue
	sub=$(jq -r '.subsystem // ""' <<<"$round")
	verdict_dir=$(jq -r '.verdict_dir // ""' <<<"$round")
	bundle=$(jq -r '.bundle // ""' <<<"$round")
	gate=$(jq -r '.gate // ""' <<<"$round")
	# verdict_dir becomes a directory under prompts/dispatch/ and verdicts/.
	if [[ -n "$verdict_dir" ]]; then
		IFS=/ read -ra parts <<<"$verdict_dir"
		for part in "${parts[@]}"; do
			if [[ ! "$part" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
				json_output "error" "prompts/context.json carries an unsafe verdict_dir \"$verdict_dir\"; re-run rc-build-context.sh (SKILL.md Step 2.7)."
				exit 1
			fi
		done
	fi
	if [[ -z "$bundle" || ("$gate" != "required" && "$gate" != "waived") ]]; then
		json_output "error" "prompts/context.json has a round without a bundle or gate; re-run rc-build-context.sh (SKILL.md Step 2.7)."
		exit 1
	fi

	# A code prompt frames its changeset by scope and a spec prompt by the
	# first paragraph of `Review artifacts`; a deep round frames both by its
	# subsystem instead (delegate.md "Deep Mode").
	if [[ -n "$sub" ]]; then
		# The same check rc-build-context.sh makes; the name is printed bare.
		if [[ ! "$sub" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
			json_output "error" "Subsystem name \"$sub\" is not a safe path component ([A-Za-z0-9._-]); fix subsystems.json and re-plan."
			exit 1
		fi
		if ! sub_entry=$(jq -c --arg s "$sub" 'first(.[] | select(.name == $s)) // null' "$subsystems_file" 2>/dev/null); then
			json_output "error" "subsystems.json is not a list of subsystems; re-run decomposition (SKILL.md Step 2.1)."
			exit 1
		fi
		if [[ "$sub_entry" == "null" ]]; then
			json_output "error" "subsystems.json has no subsystem \"$sub\", which prompts/context.json has a round for; re-run Steps 2.6 and 2.7."
			exit 1
		fi
		# The description is written from the change, so it is printed only
		# as one line of text, a line break could start a heading of its own,
		# and in a code span (dispatch-prompt.md puts its placeholder in one),
		# so markdown in it stays text.
		sub_desc=$(jq -r 'if (.description | type) == "string" and (.description | test("[[:cntrl:]]") | not)
			then .description else "" end' <<<"$sub_entry")
		if [[ -z "$sub_desc" ]]; then
			json_output "error" "subsystems.json gives subsystem \"$sub\" no one-line description; fix it (phases/decompose.md \"Output\") and re-run Step 2.7."
			exit 1
		fi
		code_framing=$(fill "${sec["Changeset framing: subsystem"]}" "subsystem_name=$sub" "subsystem_description=$sub_desc")
		spec_framing="$code_framing"
	else
		code_framing="$scope_framing"
		spec_framing="$artifacts_intro"
	fi
	if [[ -n "$filter_text" ]]; then
		code_framing="${code_framing%:}, ${filter_text}:"
		spec_framing="${spec_framing%:}, ${filter_text}:"
	fi

	# delegate.md "Deep Mode": a subsystem's own council, else the top level.
	council=$(jq -r --arg s "$sub" '
		(.council // .agents // []) as $top
		| (if $s == "" then $top
		   else ([(.subsystems // [])[] | select(.name == $s)][0].council // $top) end)[]' "$manifest")
	if [[ -z "$council" ]]; then
		batch=$(jq -r '.batch' <<<"$round")
		json_output "error" "session-manifest.json gives round ${sub:+$sub }batch ${batch} no reviewers to dispatch; re-run council selection (SKILL.md Step 2.2)."
		exit 1
	fi

	file_list=$(jq -r '.files[].path' <<<"$round")
	# One unbatched round outside deep mode is the whole diff, verbatim;
	# otherwise the sections of this round's files, in diff order.
	if [[ "$round_count" -eq 1 && -z "$sub" ]]; then
		diff_body=""
		[[ "$diff_empty" -eq 1 ]] || diff_body=$(<"$diff_file")
	else
		mapfile -t round_files <<<"$file_list"
		diff_body=$(rc_diff_sections "$diff_file" "${round_files[@]}")
	fi

	# The round's lines inside diff hunks, or why the context check is waived.
	if [[ "$gate" == "required" ]]; then
		hunk_text="Lines inside diff hunks — never quote these for \`context_check\`:"$'\n'
		ranged=$(jq -c '.files[] | select(has("ranges"))' <<<"$round")
		# build-context requires a round only when a file has lines outside
		# its hunks, which it learns while computing that file's ranges.
		if [[ -z "$ranged" ]]; then
			json_output "error" "prompts/context.json requires a context check in a round whose files record no hunk ranges; re-run rc-build-context.sh (SKILL.md Step 2.7)."
			exit 1
		fi
		while IFS= read -r entry; do
			[[ -n "$entry" ]] || continue
			path=$(jq -r '.path' <<<"$entry")
			ranges=$(jq -r '.ranges' <<<"$entry")
			span=$(code_span "$path")
			hunk_text+=$'\n'"- ${span}: ${ranges}"
		done <<<"$ranged"
	elif [[ "$diff_empty" -eq 1 ]]; then
		hunk_text="$RC_CONTEXT_WAIVED_NO_DIFF"
	else
		hunk_text="$RC_CONTEXT_WAIVED_INSIDE"
	fi

	while IFS= read -r agent; do
		[[ -n "$agent" ]] || continue
		if [[ ! "$agent" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
			json_output "error" "session-manifest.json names an agent \"$agent\" that is not a safe file name; re-run preparation."
			exit 1
		fi
		persona=""
		if [[ "$inline_persona" == "yes" ]]; then
			if [[ ! -f "$AGENTS_DIR/$agent.md" ]]; then
				json_output "error" "--inline-persona: no persona file $agent.md in AGENTS_DIR ($AGENTS_DIR)."
				exit 1
			fi
			persona=$(<"$AGENTS_DIR/$agent.md")
		fi
		rel="${verdict_dir:+$verdict_dir/}$agent"
		if [[ -v "kept_receipts[verdicts/$rel.raw.md]" ]]; then
			receipt="${kept_receipts["verdicts/$rel.raw.md"]}"
		else
			receipt=$(od -An -N8 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n') || receipt=""
			if [[ ! "$receipt" =~ ^[0-9a-f]{16}$ ]]; then
				json_output "error" "Could not read 8 random bytes from /dev/urandom for a dispatch receipt."
				exit 1
			fi
			receipt="rcpt-$receipt"
		fi
		# Spec reviewers (divisor-*-spec) get the spec prompt and code
		# reviewers the code one, per agent: a deep run can hand one subsystem
		# a spec council and its sibling a code council (SKILL.md Step 2.7).
		case "$agent" in
		*-code) kind="code" ;;
		*-spec) kind="spec" ;;
		*)
			json_output "error" "session-manifest.json names an agent \"$agent\" that is neither a code (-code) nor a spec (-spec) reviewer; re-run council selection (SKILL.md Step 2.2)."
			exit 1
			;;
		esac
		if [[ "$kind" == "spec" && ! -f "$severity_pack" ]]; then
			json_output "error" "review-config/severity.md is missing, and every spec prompt names it; re-run preparation (rc-prepare.sh copies it)."
			exit 1
		fi
		agent_base="${agent%-"$kind"}"
		focus=$(focus_for "$agent_base" "$kind")
		hints=""
		[[ "$kind" == "spec" ]] || hints=$(hints_for "$agent_base")
		agent_span=$(code_span "$agent")
		mkdir -p "$(dirname "$stage/dispatch/$rel.md")"
		{
			# The preamble is byte-identical across every code prompt of the
			# run and must stay their common prefix (#30), so it comes first,
			# copied as bytes. Spec reviewers get no preamble.
			if [[ "$kind" == "code" ]]; then
				cat "$preamble_file"
				echo ""
			fi
			if [[ -n "$persona" ]]; then
				printf '%s\n\n' "$persona"
			fi
			echo "# Your review"
			echo ""
			echo "You are ${agent_span}."
			if [[ -n "$focus" ]]; then
				echo ""
				echo "Your focus: ${focus}."
			fi
			if [[ -n "$hints" ]]; then
				echo ""
				echo "Detection hints for this change's language and framework, in addition to your focus (patterns to check for, not findings to report):"
				echo ""
				printf '%s\n' "$hints"
			fi
			echo ""
			if [[ "$kind" == "code" ]]; then
				printf '%s\n' "$root_text"
				echo ""
				echo "Forge tooling: $tooling"
				# Only the Curator's contract searches the docs repository.
				if [[ "$agent" == "divisor-curator-code" ]]; then
					echo "Docs repo: $docs_repo"
				fi
				echo ""
				echo "Project packs: $packs_dir"
				echo "Constitution: $constitution"
				echo ""
				echo "## Changeset"
				echo ""
				if [[ -n "$code_framing" ]]; then
					printf '%s\n\n' "$code_framing"
				fi
				fenced "" "$file_list"
				echo ""
				echo "## Diff"
				echo ""
				if [[ -n "$diff_body" ]]; then
					fenced diff "$diff_body"
				else
					printf '%s\n' "${sec["Diff: none"]}"
				fi
				echo ""
				echo "## Bundle"
				echo ""
				fill "${sec["Bundle"]}" "bundle_path=$session_dir/$bundle"
				echo ""
				echo ""
				fill "${sec["Changeset untrusted"]}" "references_dir=$refs_dir"
				echo ""
				echo ""
				echo "## Convention packs"
				echo ""
				fill "${sec["Convention packs: code"]}" "references_dir=$refs_dir" "language=$language" "framework=$framework"
				echo ""
				echo ""
				printf '%s' "$pr_text$optional_text"
				echo "## Verdict"
				echo ""
				printf '%s\n\n' "${sec["Verdict instruction"]}"
				fill "${sec["Output contract: code"]}" "agent-name=$agent"
				echo ""
				echo ""
				printf '%s\n\n' "${sec["Grounding: code"]}"
				printf '%s\n\n' "${sec["Severity calibration: code"]}"
				printf '%s\n' "${sec["Model self-report"]}"
				echo ""
				echo "## Context check"
				echo ""
				printf '%s\n\n' "${sec["Context check"]}"
				printf '%s\n' "$hunk_text"
			else
				# A checkout says where the artifacts are; in place, the
				# `Review artifacts: in place` paragraph below covers it.
				if [[ "$review_root" != "." ]]; then
					printf '%s\n\n' "$root_text"
				fi
				echo "Project packs: $packs_dir"
				echo "Constitution: $constitution"
				fill "${sec["Severity pack line"]}" "severity_pack_path=$severity_pack"
				echo ""
				echo ""
				echo "## Review Artifacts"
				echo ""
				printf '%s\n\n' "$spec_framing"
				fenced "" "$file_list"
				echo ""
				fill "$artifacts_rest" "references_dir=$refs_dir"
				echo ""
				echo ""
				if [[ "$review_root" == "." ]]; then
					fill "${sec["Review artifacts: in place"]}" "references_dir=$refs_dir"
					echo ""
					echo ""
				fi
				echo "## Spec Scope"
				echo ""
				printf '%s\n\n' "${sec["Spec scope"]}"
				echo "## Convention packs"
				echo ""
				fill "${sec["Convention packs: spec"]}" "references_dir=$refs_dir" "language=$language" "framework=$framework"
				echo ""
				echo ""
				printf '%s' "$optional_text"
				echo "## Verdict"
				echo ""
				fill "${sec["Output contract: spec"]}" "agent-name=$agent"
				echo ""
				echo ""
				printf '%s\n\n' "${sec["Grounding: spec"]}"
				printf '%s\n\n' "${sec["Severity calibration: spec"]}"
				printf '%s\n' "${sec["Model self-report"]}"
			fi
			echo ""
			echo "## Receipt"
			echo ""
			echo "Your verdict's top-level \`receipt\` field is \`$receipt\`. It is the last line of this file; a verdict without it is returned to you."
		} >"$stage/dispatch/$rel.md"
		jq -nc --arg a "$agent" --arg raw "verdicts/$rel.raw.md" --arg p "prompts/dispatch/$rel.md" --arg r "$receipt" \
			'{agent: $a, raw: $raw, prompt: $p, receipt: $r}' >>"$stage/entries.jsonl"
		count=$((count + 1))
		[[ "$kind" != "code" ]] || code_prompts=$((code_prompts + 1))
	done <<<"$council"
done <<<"$rounds"

# The rounds cover the changeset: batches partition it, and in deep mode
# phases/decompose.md "Completeness Check" puts every changed file in at least
# one subsystem. So each section of a split diff belongs to some round. One no
# round names (a path spelled one way in changeset.txt and another in
# diff.patch, or a file decomposition left out) would be cut from every prompt,
# so it is refused rather than dropped. A single round outside deep mode gets
# the whole diff and cannot lose a section.
#
# Only a code prompt shows a diff, so the check runs only when one was
# rendered. A spec review's changeset.txt holds just the spec files while
# diff.patch holds the whole range or PR, so its code files are in no round by
# design. Every round still claims its files, whatever its council: in a deep
# code review a prose subsystem's spec council reviews its files, diff or not.
if [[ "$code_prompts" -gt 0 ]] && [[ "$round_count" -gt 1 || "$deep" == "true" ]]; then
	unclaimed=$(jq -r --argjson d "$diff_paths" '
		[.rounds[].files[].path] as $p
		| [$d[] | select(. as $k | $p | any(. == $k) | not)] | join(", ")' "$context_file")
	if [[ -n "$unclaimed" ]]; then
		if [[ "$deep" == "true" ]]; then
			fix="Check that subsystems.json assigns every changed file to a subsystem, named as the diff names it (SKILL.md Step 2.1), then re-run Steps 2.6 and 2.7."
		else
			fix="Check that changeset.txt names each file as the diff does, then re-run Steps 2.6 and 2.7."
		fi
		json_output "error" "diff.patch has changes to ${unclaimed}, which no round in prompts/context.json names, so their diff would reach no reviewer. $fix"
		exit 1
	fi
fi

jq -s '{dispatches: .}' "$stage/entries.jsonl" >"$stage/dispatch.json"

# Replace the previous prompts only now that the new set is complete, so a
# failed run leaves the last good set in place.
rm -rf "$session_dir/prompts/dispatch" "$dispatch_index"
mv "$stage/dispatch" "$session_dir/prompts/dispatch"
mv "$stage/dispatch.json" "$dispatch_index"
rm -rf "$stage"
trap - EXIT

# Replaced rather than appended, so a re-run leaves one block, as
# rc-build-context.sh does with `## Phase: Context`.
if grep -q '^## Phase: Prompts$' "$tracking_file"; then
	tracking_tmp="${tracking_file}.tmp"
	awk '
		/^## Phase: Prompts$/ { skip = 1; next }
		skip && /^## / { skip = 0 }
		!skip { print }
	' "$tracking_file" >"$tracking_tmp"
	mv "$tracking_tmp" "$tracking_file"
fi
{
	echo "## Phase: Prompts"
	echo ""
	echo "- Prompts: $count"
	echo "- Persona inlined: $inline_persona"
	echo ""
} >>"$tracking_file"

summary=$(jq -n --argjson n "$count" '{prompts: $n, index: "dispatch.json"}')
json_output "ok" "Reviewer prompts assembled." "$summary"
