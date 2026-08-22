#!/usr/bin/env bash
set -euo pipefail

# rc-cost-estimate.sh <session_dir>
# Prices a review before it is dispatched: personas x subsystems x iteration
# cap, the input tokens that fan-out sends, and the dollar band it lands in.
# Writes cost-estimate.json and a `## Phase: Cost Estimate` block into the
# session; renders the operator-facing table on stdout.

# The two prerequisite guards below run BEFORE rc-lib.sh is sourced, and report
# a missing prerequisite as markdown rather than the JSON every other script
# emits — stdout here is the table an operator reads. Nothing between this line
# and the source can trip the ERR trap: both guards are `if` conditions, which
# bash exempts. Same ordering as rc-render-report.sh, and for the same reason:
# by the time rc-lib.sh loads, its own Bash and jq guards are already satisfied
# and can never fire, so the markdown contract holds by construction.
if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
	echo "**Cost estimate unavailable:** Bash 4+ is required. macOS ships Bash 3; install a modern version: \`brew install bash\`"
	exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
	echo "**Cost estimate unavailable:** jq is required but not installed."
	echo "Install it: \`apt-get install jq\` | \`brew install jq\` | \`dnf install jq\`"
	exit 0
fi

# The library is wanted only for rc_parse_kv and the ERR trap — this script
# makes no forge calls and so never requires GNU timeout.
# shellcheck source=module/skills/review-council/scripts/rc-lib.sh
source "$(dirname "$0")/rc-lib.sh"
rc_trap_errors # report script:line on any unhandled failure (never silent)

session_dir="${1:-}"
if [[ -z "$session_dir" ]] || [[ ! -d "$session_dir" ]]; then
	echo "**Cost estimate unavailable:** session data not found."
	exit 0
fi

tracking_file="$session_dir/tracking.md"
manifest="$session_dir/session-manifest.json"
if [[ ! -f "$tracking_file" ]] || [[ ! -f "$manifest" ]]; then
	echo "**Cost estimate unavailable:** session is missing tracking.md or session-manifest.json."
	exit 0
fi

# Iteration caps as SKILL.md Step 5 states them. An unrecognised effort takes
# the standard cap rather than the deep one: over-stating the bill on a session
# whose effort could not be read would teach operators to dismiss the table.
effort=$(rc_parse_kv "$tracking_file" "Effort")
effort="${effort:-standard}"
case "$effort" in
quick) iteration_cap=1 ;;
deep) iteration_cap=5 ;;
*) iteration_cap=3 ;;
esac

# The council is read from the manifest rather than counted from the agents
# directory, and from `council` rather than `agents`: `agents` is who
# preparation DISCOVERED, `council` is who will actually be DISPATCHED after
# rc-select-council.sh has had its say. Pricing the roster would quote a bill
# for reviewers this run is not going to pay for — and an estimate that
# over-states is one operators learn to dismiss. `// .agents` covers a manifest
# written before the key existed, where the two were the same set.
personas=$(jq -r '((.council // .agents) // []) | length' "$manifest" 2>/dev/null || echo 0)
discovered=$(jq -r '(.agents // []) | length' "$manifest" 2>/dev/null || echo 0)
selection_applied=$(jq -r '.selection.applied // false' "$manifest" 2>/dev/null || echo false)

# Deep mode dispatches a council against every subsystem. Decomposition writes
# subsystems.json only when it splits the changeset (phases/decompose.md deletes
# it and falls back to whole-changeset delegation on a single group), so its
# absence means one subsystem, not zero.
subsystems_file="$session_dir/subsystems.json"
subsystems=1
if [[ -f "$subsystems_file" ]]; then
	subsystems=$(jq -r 'length' "$subsystems_file" 2>/dev/null || echo 1)
	[[ "$subsystems" -lt 1 ]] && subsystems=1
fi

# `grep -c` prints 0 and exits 1 on a file with no matching lines, and prints
# nothing at all when the file is absent, so the count is range-checked rather
# than trusted — an empty string reaching the division below would abort the
# estimate.
changeset_files=$(grep -c . "$session_dir/changeset.txt" 2>/dev/null || true)
[[ "$changeset_files" =~ ^[0-9]+$ ]] || changeset_files=0

# One row per dispatch round: the share of the changeset it carries, and the
# council that reviews it. Shares are measured by file count, the only
# proportion subsystems.json states; a file listed under two subsystems is sent
# twice, and the shares sum above 1 accordingly.
#
# Selection can give each subsystem a DIFFERENT council — one may be docs-only
# while its sibling is code — so the dispatch count is a sum over these rows,
# not a product. The product survives only as the sentence below, and only when
# every row happens to be the same size.
default_council=$(jq -c '(.council // .agents) // []' "$manifest" 2>/dev/null || echo '[]')
if [[ -f "$subsystems_file" ]] && jq -e 'length > 0' "$subsystems_file" >/dev/null 2>&1; then
	rounds_json=$(jq -c -n \
		--slurpfile subs "$subsystems_file" --slurpfile man "$manifest" \
		--argjson total "$changeset_files" --argjson default "$default_council" '
		(($man[0].subsystems // []) | map({key: .name, value: .council}) | from_entries) as $picked
		| $subs[0] | map({
			share: (if $total > 0 then ((.files // []) | length) / $total else 1 end),
			council: ($picked[.name] // $default)})' 2>/dev/null) || rounds_json=""
fi
if [[ -z "${rounds_json:-}" ]]; then
	rounds_json=$(jq -c -n --argjson council "$default_council" '[{share: 1, council: $council}]')
fi

dispatches_first=$(jq -r '[.[].council | length] | add // 0' <<<"$rounds_json")
dispatches_worst=$((dispatches_first * iteration_cap))

# Sizes come from `wc -c`, never from `stat`, whose size flag is `-c %s` on GNU
# and `-f %z` on BSD. A file that is not there contributes nothing rather than
# aborting the estimate: the prompt material below is assembled per session, and
# a pack that does not exist for this language is simply not sent.
bytes_of() { # file... -> total bytes
	local total=0 f size
	for f in "$@"; do
		[[ -f "$f" ]] || continue
		size=$(wc -c <"$f" | tr -d '[:space:]')
		total=$((total + size))
	done
	printf '%s' "$total"
}

# The convention packs every reviewer prompt carries, selected the way
# phases/delegate.md selects them: the three universal ones plus whichever
# language and framework packs preparation recorded. Measuring the files on disk
# rather than assuming a size is what keeps the estimate honest as the packs
# grow.
references_dir=$(cd "$(dirname "$0")/../references" 2>/dev/null && pwd) || references_dir=""
pack_bytes=0
if [[ -n "$references_dir" ]]; then
	language=$(rc_parse_kv "$tracking_file" "Language")
	framework=$(rc_parse_kv "$tracking_file" "Framework")
	packs=("$references_dir/base.md" "$references_dir/reviewer-protocol.md" "$references_dir/severity.md")
	lang_slug=$(printf '%s' "$language" | tr '[:upper:]' '[:lower:]')
	fw_slug=$(printf '%s' "$framework" | tr '[:upper:]' '[:lower:]')
	[[ -n "$lang_slug" ]] && packs+=("$references_dir/lang-${lang_slug}.md")
	[[ -n "$fw_slug" ]] && packs+=("$references_dir/fw-${fw_slug}.md")
	pack_bytes=$(bytes_of "${packs[@]}")
fi

# The persona system prompt is part of every dispatch, and is measurable
# whenever the caller passes the AGENTS_DIR it already passes rc-prepare.sh.
# Without it the estimate is short by one agent file per dispatch, which is the
# smallest of the three terms — a reason to state a lower figure, not to refuse
# one.
#
# Measured per agent rather than as one total, because two rounds of the same
# deep run can now carry different councils and a total cannot be apportioned
# between them. An agent with no readable file contributes nothing.
persona_bytes_json='{}'
if [[ -n "${AGENTS_DIR:-}" ]] && [[ -d "${AGENTS_DIR}" ]]; then
	while IFS= read -r agent; do
		[[ -n "$agent" ]] || continue
		# Sized into a variable first: a command substitution nested in another
		# command has its exit status discarded, so a failing measurement would
		# reach jq as an empty --argjson and abort the whole estimate.
		agent_size=$(bytes_of "${AGENTS_DIR}/${agent}.md")
		persona_bytes_json=$(jq -c --arg a "$agent" --argjson b "$agent_size" \
			'. + {($a): $b}' <<<"$persona_bytes_json")
	done < <(jq -r '(.agents // [])[]' "$manifest" 2>/dev/null || true)
fi

context_bytes=$(bytes_of "$session_dir/diff.patch" "$session_dir/changeset.txt")

# Four bytes per token: the rough industry rule, and the only estimator
# available without shipping a tokenizer. Every figure this script prints is
# labelled an estimate for that reason.
#
# The sum is computed in jq — already a hard prerequisite — rather than in awk
# or bc, which are not. Each round charges its apportioned share of the
# changeset once per reviewer in ITS council, plus the convention packs once per
# reviewer and that reviewer's own persona prompt. A decomposition that halves
# each round's context therefore still pays its own overhead per round, and a
# round whose council was narrowed pays proportionally less of all three terms.
input_tokens_first=$(jq -n \
	--argjson rounds "$rounds_json" \
	--argjson pack "$pack_bytes" \
	--argjson pbytes "$persona_bytes_json" \
	--argjson context "$context_bytes" \
	'[$rounds[]
	  | (.council | length) as $n
	  | (.share * $context * $n) + ($pack * $n)
	    + ([.council[] | $pbytes[.] // 0] | add // 0)]
	 | (add // 0) / 4 | floor')
input_tokens_worst=$((input_tokens_first * iteration_cap))

# Last-resort per-dispatch band, for an install where references/ cannot be
# reached. It is the Sonnet row of that file's Cost Per Review table over the
# council size stated beside it, and test-rc-cost-estimate.sh asserts it still
# is — the table is dated and will be re-measured, and a constant that quietly
# disagrees with the document it was copied from is exactly the drift the
# RC_PERSONAS guard exists to catch elsewhere in this module.
rate_low_default="0.20"
rate_high_default="0.56"
rc_default_class="sonnet"

# Every priced row of the Cost Per Review table, as "<class> <low> <high>".
# The table is read at runtime rather than copied into this script so that
# re-measuring the models moves the price an operator is quoted, without
# anyone having to remember a constant lives here too. Rows are recognised by
# their `$low-$high` cell, which is what keeps the heading and the separator
# rule out of the result.
cost_rows() { # guidance_file -> "<class> <low> <high>" per priced row
	awk -F'|' '
		/^## / { in_table = ($0 == "## Cost Per Review"); next }
		!in_table || NF < 4 { next }
		{
			name = $2
			range = $3
			gsub(/[[:space:]]/, "", name)
			gsub(/[[:space:]]/, "", range)
			if (range !~ /^\$[0-9]+(\.[0-9]+)?-\$[0-9]+(\.[0-9]+)?$/) next
			gsub(/\$/, "", range)
			split(range, band, "-")
			print tolower(name), band[1], band[2]
		}
	' "$1"
}

# Resolve the band the class asks for. The published ranges are per REVIEW —
# one full council pass — so the per-dispatch figure is the row over the
# council size the table names, and the session's own roster multiplies back in
# through dispatches_first_pass. Dividing by the roster this session discovered
# instead would price a three-reviewer council and a five-reviewer one
# identically, which is the one arithmetic error that would make the table
# meaningless.
model_class=$(printf '%s' "${REVIEW_COUNCIL_MODEL_CLASS:-$rc_default_class}" | tr '[:upper:]' '[:lower:]')
rate_source="fallback"
band_low="$rate_low_default"
band_high="$rate_high_default"
council_size=""
guidance_file=""
[[ -n "$references_dir" ]] && guidance_file="$references_dir/model-guidance.md"
if [[ -n "$guidance_file" ]] && [[ -f "$guidance_file" ]]; then
	rows=$(cost_rows "$guidance_file")
	council_size=$(rc_parse_kv "$guidance_file" "Council size")
	if [[ -n "$rows" ]] && [[ "$council_size" =~ ^[1-9][0-9]*$ ]]; then
		row=$(awk -v want="$model_class" '$1 == want { print; exit }' <<<"$rows")
		if [[ -z "$row" ]]; then
			# Naming the classes that do exist is the whole value of the note:
			# an operator who guessed the name wrong cannot find the right one
			# in a message that only says the guess was wrong. Never fatal, for
			# the same reason a malformed rate is not.
			known=$(awk '{ printf "%s%s", sep, $1; sep = ", " } END { print "" }' <<<"$rows")
			echo "rc-cost-estimate: ignoring REVIEW_COUNCIL_MODEL_CLASS='${REVIEW_COUNCIL_MODEL_CLASS:-}' (known classes: ${known}); using ${rc_default_class}" >&2
			model_class="$rc_default_class"
			row=$(awk -v want="$rc_default_class" '$1 == want { print; exit }' <<<"$rows")
		fi
		if [[ -n "$row" ]]; then
			# tonumber rather than --argjson: the figures come from a document
			# people edit, and a hand-typed "07.00" would abort the estimate
			# where jq's own parse accepts it.
			read -r _ row_low row_high <<<"$row"
			# Rounded to a hundredth of a cent, because the division does not
			# land on the figure a reader expects: $2.80 over 5 is
			# 0.5599999999999999 in binary floating point, which would reach
			# both the artifact and the rendered sentence verbatim. Four places
			# is fine enough for a per-dispatch rate an order of magnitude
			# below a cent (haiku is $0.014).
			band=$(jq -rn --arg low "$row_low" --arg high "$row_high" --arg n "$council_size" \
				'def per_dispatch: (. / ($n | tonumber) * 10000 | round) / 10000;
				 [($low | tonumber | per_dispatch),
				  ($high | tonumber | per_dispatch)] | @tsv')
			IFS=$'\t' read -r band_low band_high <<<"$band"
			rate_source="model-guidance"
		fi
	fi
fi
if [[ "$rate_source" == "fallback" ]]; then
	# The constants ARE the sonnet row, so that is the class being priced.
	# Recording the class that was asked for would name a band the operator did
	# not actually get.
	model_class="$rc_default_class"
fi

# An explicit band outranks the class, per rate. The origin travels back with
# the value because the closing sentence must credit model-guidance.md only for
# figures that actually came from it, and the caller cannot re-derive that
# without a second copy of the validation rule below.
read_rate() { # env_name band_rate -> "env|band<TAB>rate"
	local name="$1" fallback="$2" value="${!1:-}"
	if [[ -z "$value" ]]; then
		printf 'band\t%s' "$fallback"
		return 0
	fi
	if [[ "$value" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
		printf 'env\t%s' "$value"
		return 0
	fi
	# Reported and ignored, never fatal: an unusable override is a reason to
	# price the run at the documented rate, not to withhold the estimate. The
	# notice goes to stderr because stdout is the table itself.
	echo "rc-cost-estimate: ignoring ${name}='${value}' (not a non-negative number); using ${fallback}" >&2
	printf 'band\t%s' "$fallback"
}
low_field=$(read_rate REVIEW_COUNCIL_COST_LOW "$band_low")
IFS=$'\t' read -r low_origin rate_low <<<"$low_field"
high_field=$(read_rate REVIEW_COUNCIL_COST_HIGH "$band_high")
IFS=$'\t' read -r high_origin rate_high <<<"$high_field"
# One rate from the environment is enough to stop crediting the reference: the
# band as a whole is no longer the one the table publishes.
if [[ "$low_origin" == "env" ]] || [[ "$high_origin" == "env" ]]; then
	rate_source="env"
fi

# The dollars are computed in the same expression that writes them, so the
# stored figures and the rendered ones cannot disagree. Each band is rounded to
# whole cents: a five-dispatch pass at $0.56 is 2.8000000000000003 in binary
# floating point, and an artifact carrying that is one a reader distrusts.
#
# Rates arrive as strings and are converted with `tonumber + 0` rather than
# passed as --argjson. Two reasons, both about the artifact being stable across
# hosts: jq 1.7 preserves the literal text of a number it parses, so an
# operator's "0.20" would be stored verbatim as 0.20 where jq 1.6 stores 0.2,
# and --argjson rejects outright the leading-zero forms ("007") that the
# validator above accepts.
jq -n \
	--arg effort "$effort" \
	--arg rate_low "$rate_low" \
	--arg rate_high "$rate_high" \
	--arg model_class "$model_class" \
	--arg rate_source "$rate_source" \
	--argjson personas "$personas" \
	--argjson discovered "$discovered" \
	--argjson selection_applied "$selection_applied" \
	--argjson subsystems "$subsystems" \
	--argjson iteration_cap "$iteration_cap" \
	--argjson dispatches_first_pass "$dispatches_first" \
	--argjson dispatches_worst_case "$dispatches_worst" \
	--argjson input_tokens_first_pass "$input_tokens_first" \
	--argjson input_tokens_worst_case "$input_tokens_worst" \
	'def cents: (. * 100 | round) / 100;
	 ($rate_low | tonumber + 0) as $low
	 | ($rate_high | tonumber + 0) as $high
	 | {effort: $effort,
	    personas: $personas,
	    discovered: $discovered,
	    selection_applied: $selection_applied,
	    subsystems: $subsystems,
	    iteration_cap: $iteration_cap,
	    dispatches_first_pass: $dispatches_first_pass,
	    dispatches_worst_case: $dispatches_worst_case,
	    input_tokens_first_pass: $input_tokens_first_pass,
	    input_tokens_worst_case: $input_tokens_worst_case,
	    usd_low_first_pass: (($dispatches_first_pass * $low) | cents),
	    usd_high_first_pass: (($dispatches_first_pass * $high) | cents),
	    usd_low_worst_case: (($dispatches_worst_case * $low) | cents),
	    usd_high_worst_case: (($dispatches_worst_case * $high) | cents),
	    rate_low: $low,
	    rate_high: $high,
	    model_class: $model_class,
	    rate_source: $rate_source}' \
	>"$session_dir/cost-estimate.json"

# Display strings are derived from the artifact just written, so the table and
# the tracking block quote the stored figures rather than re-deriving them. The
# two-decimal money form and the thousands separators are built in jq because
# the shell alternatives are not portable: `printf '%.2f'` reads and writes the
# decimal separator through LC_NUMERIC, and comma grouping with `sed` needs a
# labelled branch, which BSD sed will not accept on one line.
#
# The row is captured first and split afterwards, rather than read straight from
# a process substitution. `read` reports only its own success, so a jq that died
# on a truncated artifact would leave every display field empty and the table
# would render blank cells as though that were the estimate; as an assignment,
# the same failure aborts the run and the ERR trap names the line.
display_row=$(jq -r '
	def money: (. * 100 | round) as $c
		| ($c / 100 | floor) as $whole
		| ($c - $whole * 100) as $rem
		| "\($whole).\(if $rem < 10 then "0" else "" end)\($rem)";
	def commify: tostring | explode | map([.] | implode) | reverse | to_entries
		| map(if .key > 0 and (.key % 3) == 0 then .value + "," else .value end)
		| reverse | join("");
	# A rate is shown to the cent when it survives the trip and verbatim when it
	# does not: a per-dispatch figure divides a per-review one, so a cheap class
	# lands below a cent (haiku is $0.014) and rounding it for display would
	# misstate the basis the whole table rests on.
	def rate_text: if (. * 100 | round) / 100 == . then money else tostring end;
	[(.usd_low_first_pass | money), (.usd_high_first_pass | money),
	 (.usd_low_worst_case | money), (.usd_high_worst_case | money),
	 (.input_tokens_first_pass | commify), (.input_tokens_worst_case | commify),
	 (.rate_low | rate_text), (.rate_high | rate_text)]
	| @tsv' "$session_dir/cost-estimate.json")
IFS=$'\t' read -r usd_low_first usd_high_first usd_low_worst usd_high_worst \
	tokens_first_display tokens_worst_display rate_low_display rate_high_display <<<"$display_row"

# Singular/plural agreement for the four counts the sentence below names. Both
# forms are passed because one of the nouns is "dispatch", whose plural an
# appended "s" gets wrong — and a table that reads "1 personas x 1 subsystems"
# is one an operator stops believing before reaching the numbers that matter.
plural() { # count singular plural -> "1 singular" / "N plural"
	if [[ "$1" -eq 1 ]]; then
		printf '%s %s' "$1" "$2"
	else
		printf '%s %s' "$1" "$3"
	fi
}

# Resolved into variables here rather than called from inside the heredoc: a
# command substitution expanded there reports its status to nobody, so a broken
# helper would silently drop a phrase out of the sentence it renders.
subsystems_phrase=$(plural "$subsystems" subsystem subsystems)
dispatches_phrase=$(plural "$dispatches_first" "reviewer dispatch" "reviewer dispatches")
iterations_phrase=$(plural "$iteration_cap" iteration iterations)

# `personas x subsystems` is only arithmetic when every round carries the same
# council, and since contextual persona selection it may not: one subsystem can
# be docs-only while its sibling is code. Printing a product that does not equal
# the dispatch count beside it is worse than printing no product — the whole
# point of the table is that an operator can check it.
round_sizes=$(jq -r '[.[].council | length] | unique | if length == 1 then .[0] else -1 end' \
	<<<"$rounds_json")
if [[ "$round_sizes" -ge 0 ]]; then
	fanout_sentence="Before dispatch: **$(plural "$round_sizes" persona personas) x ${subsystems_phrase}** =
${dispatches_phrase} per iteration,
up to **${iterations_phrase}**."
else
	fanout_sentence="Before dispatch: **${dispatches_phrase}** per iteration across
${subsystems_phrase} — councils differ by subsystem — up to
**${iterations_phrase}**."
fi

# Named only when it actually happened, and phrased as what it cost rather than
# what it saved: the reviewers that did not run are a coverage fact first and an
# economy second, and `tracking.md` is where the reasons are.
selection_note=""
if [[ "$selection_applied" == "true" ]] && [[ "$discovered" -gt 0 ]]; then
	selection_note="
Change shape narrowed the council: ${personas} of ${discovered} discovered reviewers
are dispatched. See \`## Phase: Council Selection\` in \`tracking.md\` for who was
skipped and why."
fi

# Triage runs BEFORE this estimate, so its dispatch is already spent by the time
# anyone reads the table. Disclosing that is the price of the table describing
# the grid that will actually run: pricing the untriaged grid would over-state
# every triaged review, and an estimate operators learn to discount is worse
# than one that admits a cent has already gone.
triage_note=""
triage_excluded=$(jq -r '.triage.excluded // 0' "$manifest" 2>/dev/null || echo 0)
[[ "$triage_excluded" =~ ^[0-9]+$ ]] || triage_excluded=0
if [[ "$triage_excluded" -gt 0 ]]; then
	triage_note="
Subsystem triage removed ${triage_excluded} further dispatch(es) and has already spent one
cheap dispatch of its own to do so. See \`## Phase: Subsystem Triage\` in
\`tracking.md\` for each cell and for what its invariants refused."
fi

# The reference is credited only for a band that actually came out of it. An
# operator's own numbers presented as the module's measurement is a claim about
# provenance that nobody can check against the artifact afterwards, and one rate
# from the environment is enough to make the band no longer the published one.
#
# The line breaks inside each note are load-bearing: the first line is appended
# to the rate sentence in the heredoc below, so the note starts wrapped short
# and the rendered paragraph holds the same width as the two above it.
case "$rate_source" in
env)
	rate_note="as set in \`REVIEW_COUNCIL_COST_LOW\` /
\`REVIEW_COUNCIL_COST_HIGH\`."
	;;
model-guidance)
	rate_note="the ${model_class^} band in
\`references/model-guidance.md\` over a ${council_size}-dispatch council. Price another
class with \`REVIEW_COUNCIL_MODEL_CLASS\`, or set the band yourself with
\`REVIEW_COUNCIL_COST_LOW\` / \`REVIEW_COUNCIL_COST_HIGH\`."
	;;
*)
	rate_note="the built-in ${model_class^} band —
\`references/model-guidance.md\` could not be read. Set the band yourself with
\`REVIEW_COUNCIL_COST_LOW\` / \`REVIEW_COUNCIL_COST_HIGH\`."
	;;
esac

cat <<EOF
## Cost estimate — ${effort} review

${fanout_sentence}
${selection_note}${triage_note}

| | Dispatches | Est. input tokens | Est. cost |
|---|---:|---:|---:|
| First pass | ${dispatches_first} | ${tokens_first_display} | \$${usd_low_first} - \$${usd_high_first} |
| Worst case (${iterations_phrase}) | ${dispatches_worst} | ${tokens_worst_display} | \$${usd_low_worst} - \$${usd_high_worst} |

Every figure is an estimate. Tokens are prompt bytes / 4 — convention packs,
persona prompts, diff and changeset, as they stand on disk right now. Cost is
\$${rate_low_display} - \$${rate_high_display} per dispatch, ${rate_note}
EOF

# The tracking block is replaced rather than appended to, which is what makes a
# re-run a no-op: awk drops any previous block, from its heading to the next
# `## ` heading or end of file, and the block is written again below from the
# same figures.
#
# The filter and the move are separate statements, not an `awk ... && mv` list:
# in a list the awk failure would be exempt from `set -e`, the move would be
# skipped, and the run would end with the stale block still in place and a
# second one appended beneath it.
if grep -q '^## Phase: Cost Estimate$' "$tracking_file"; then
	tmp="${tracking_file}.tmp"
	awk '
		/^## Phase: Cost Estimate$/ { skip = 1; next }
		skip && /^## / { skip = 0 }
		!skip { print }
	' "$tracking_file" >"$tmp"
	mv "$tmp" "$tracking_file"
fi
{
	echo "## Phase: Cost Estimate"
	echo ""
	echo "- Personas: ${personas}"
	echo "- Personas discovered: ${discovered}"
	echo "- Selection applied: ${selection_applied}"
	echo "- Triage exclusions: ${triage_excluded}"
	echo "- Subsystems: ${subsystems}"
	echo "- Iteration cap: ${iteration_cap}"
	echo "- Dispatches (first pass): ${dispatches_first}"
	echo "- Dispatches (worst case): ${dispatches_worst}"
	echo "- Input tokens (first pass): ${input_tokens_first}"
	echo "- Estimated cost (first pass): \$${usd_low_first} - \$${usd_high_first}"
	echo "- Estimated cost (worst case): \$${usd_low_worst} - \$${usd_high_worst}"
	echo ""
} >>"$tracking_file"

exit 0
