#!/usr/bin/env bash
# Shared per-finding markdown rendering for the report and the PR comment.
#
# Both artifacts describe the same findings.json, and for a long time they
# described it differently: the comment gave each finding evidence, a
# recommendation and the full reviewer analysis, while the report gave one
# truncated line. Neither was wrong on its own — they had simply drifted,
# because the same block was written twice.
#
# What is shared is the block for ONE finding. What is deliberately NOT shared
# is the severity-group wrapper: the comment opens a group with
# <details><summary>, the report emits a "###" heading, and that is the one
# place the two artifacts should differ. Each renderer keeps its own loop.
#
# Source this file; do not execute it. It defines functions and sets nothing
# beyond the two link globals below.

# link_location reads these. The comment renderer assigns them from the session;
# the report renderer defines no forge hooks and leaves them empty, which
# link_location already handles by emitting a plain code span. Defaulting here
# rather than in each caller keeps `set -u` from turning "no forge" into a crash.
RC_FORGE_WEB="${RC_FORGE_WEB:-}"
RC_HEAD_SHA="${RC_HEAD_SHA:-}"

# Normalise em/en dashes in LLM-authored prose to the house style. Applied per
# field rather than to the assembled body: evidence is verbatim source and must
# keep whatever dashes the file holds, and a body-wide filter made the comment
# and the report disagree about one finding. Static template text in the
# renderers is written without those characters in the first place, so it needs
# no filter at all.
normalize_dashes() { # text
	local t="${1//—/-}"
	printf '%s' "${t//–/-}"
}

# Strip the `divisor-` prefix and one `-code`/`-spec` suffix from an agent file
# name. Parameter expansion rather than a sed call: this runs once per finding
# per render, and the paring ladder re-renders the same set several times over,
# which came to 1,801 sed processes in one suite for a prefix and a suffix.
#
# The case arm removes exactly one suffix, which is what `s/-(code|spec)$//`
# did. Chaining `${p%-code}` and `${p%-spec}` would strip both from a name
# ending `-spec-code` and quietly disagree with the form it replaced.
_persona_stem() { # agent-file-name -> stem
	local p="${1#divisor-}"
	case "$p" in
	*-code) p="${p%-code}" ;;
	*-spec) p="${p%-spec}" ;;
	# A name carrying neither suffix keeps its stem unchanged, which is what
	# the sed this replaces did with a pattern that simply did not match.
	*) ;;
	esac
	printf '%s' "$p"
}

# Reviewer persona label (emoji + focus + mode); host-agnostic.
persona_label() { # agent-file-name
	local p mode="" m=""
	p=$(_persona_stem "$1")
	# The same ERE the sed carried, run by bash itself. `[a-z]+` matches no
	# hyphen, so only the exact divisor-<word>-<mode> shape yields a mode — a
	# glob like `divisor-*-code` would also accept `divisor-a-b-code`, which
	# this deliberately does not.
	if [[ "$1" =~ ^divisor-[a-z]+-(code|spec)$ ]]; then
		mode="${BASH_REMATCH[1]}"
	fi
	[[ -n "$mode" ]] && m=" (${mode})"
	case "$p" in
	adversary) echo "🛡️ Adversary${m}" ;;
	architect) echo "🏛️ Architect${m}" ;;
	guard) echo "🧭 Guard${m}" ;;
	testing) echo "🧪 Tester${m}" ;;
	sre) echo "⚙️ Operator${m}" ;;
	curator) echo "📚 Curator${m}" ;;
	*) echo "🔹 $1" ;;
	esac
}

# Reviewer persona emoji only (matches the table); host-agnostic.
persona_emoji() { # agent-file-name
	local p
	p=$(_persona_stem "$1")
	case "$p" in
	adversary) echo "🛡️" ;;
	architect) echo "🏛️" ;;
	guard) echo "🧭" ;;
	testing) echo "🧪" ;;
	sre) echo "⚙️" ;;
	curator) echo "📚" ;;
	*) echo "🔹" ;;
	esac
}

# Render a finding location as a forge deep-link when a rc_url_file hook is
# defined AND returns a URL, else a plain code span. Reads $RC_FORGE_WEB /
# $RC_HEAD_SHA.
link_location() { # file line
	local f="$1" l="$2" loc="$1" url=""
	[[ -n "$l" && "$l" != "null" ]] && loc="$f:$l"
	declare -F rc_url_file >/dev/null 2>&1 && url=$(rc_url_file "$RC_FORGE_WEB" "$RC_HEAD_SHA" "$f" "$l")
	# shellcheck disable=SC2016 # the backticks are literal markdown code-span
	# delimiters, not command substitution.
	if [[ -n "$url" ]]; then
		printf '[`%s`](%s)' "$loc" "$url"
	else
		printf '`%s`' "$loc"
	fi
}

# Indent every line of stdin by two spaces so multi-line content stays inside
# the enclosing markdown list item. Blank lines stay blank (no trailing spaces).
indent2() {
	local l
	while IFS= read -r l || [[ -n "$l" ]]; do
		[[ -n "$l" ]] && printf '  %s\n' "$l" || printf '\n'
	done
}

# Render a finding's evidence as a fenced code block that cannot bleed into the
# surrounding structure. Evidence is verbatim content copied out of a changeset
# file, so an author controls every byte of it: an inner line beginning with
# `#`/`>`/`-` must not become a real heading/blockquote/list item, and no inner
# line may terminate the block early.
#
# A fence only guarantees the first of those. The two spaces indent2 adds keep
# the fence inside its list item but do NOT neutralise a fence line in the
# evidence — up to three leading spaces is still a valid CommonMark closing
# fence — so the delimiter is sized to the content instead: widen it one
# backtick at a time until no run that long occurs anywhere in the evidence.
# Single-line evidence goes through the same form; it used to render as an
# inline code span, which any backtick in the quoted source terminates.
evidence_block() { # evidence-text
	# shellcheck disable=SC2016 # the backticks are literal markdown fence
	# delimiters, not command substitution.
	local ev="$1" fence='```'
	while [[ "$ev" == *"$fence"* ]]; do
		fence+='`'
	done
	printf '%s\n%s\n%s\n' "$fence" "$ev" "$fence" | indent2
}

# Render one verified finding as a markdown list item and print it.
#
# Takes the finding as compact JSON so the caller does the selecting and this
# does the formatting.
#
# Every field comes out of a single jq call, NUL-framed, rather than one `jq -r`
# per field. Eight jq processes per finding is eight process spawns per finding
# per render, and the comment renderer's paring ladder re-renders the same
# finding set up to eight times looking for a level that fits; on one suite that
# came to 9,354 jq invocations and 28 of its 64 seconds.
#
# The separator has to be a byte the fields cannot contain, which rules out the
# obvious @tsv — evidence is source code and carries real tabs and newlines,
# and a separator that occurs inside a value splices two fields together, which
# surfaces as prose under the wrong label rather than as an error. NUL is the
# one byte that cannot appear: not because JSON forbids it, but because bash
# cannot hold it in a variable at all. `$(...)` discards NUL with a warning, so
# the per-field form this replaces could not have carried one either, and the
# framing gives up nothing that was ever available.
#
# test-rc-render-comment.sh "Test 6b" puts tabs and newlines in four fields at
# once and fails on every assertion if the framing slips.
#
# The variant selects how much of the finding is rendered. It exists for the
# comment renderer's paring ladder, which sheds detail in a fixed order when a
# body would otherwise exceed the forge's comment limit:
#
#   full         headline, evidence, recommendation, constraint, analysis
#   no-analysis  the same, minus the collapsed "Full reviewer analysis" block
#   headline     headline and permalink only
#
# The order is not arbitrary. Evidence is what makes a finding checkable and
# what rc-verify-evidence.sh matched byte-for-byte, so it outlives the analysis
# prose in every variant that keeps the finding at all. The report renderer
# passes no variant and is unaffected.
rc_finding_block() { # finding-json [variant=full]
	local base="$1" variant="${2:-full}" f l t ev agent desc rec constraint emoji loc_link out=""
	local -a _fields=()
	# Process substitution, not `$(...)`: command substitution strips NUL and
	# would collapse the framing. That also hides jq's exit status, so a short
	# read is checked for below rather than surfacing as an unbound-variable
	# abort three lines later.
	#
	# shellcheck disable=SC2312 # The masked status is the point of the check
	# below: the separator rules out a command substitution, so jq's status is
	# recovered from the field count rather than from `$?`.
	mapfile -d '' -t _fields < <(jq -j '
		[ .file,
		  (.line // ""),
		  (.title // (.description | split(". ")[0] | rtrimstr("."))),
		  .agent,
		  .evidence,
		  .description,
		  .recommendation,
		  (.constraint // "")
		] | (map(tostring) | join("\u0000")) + "\u0000"' <<<"$base")
	if [[ "${#_fields[@]}" -lt 8 ]]; then
		echo "rc-error: could not read finding fields; malformed finding JSON" >&2
		return 1
	fi
	f="${_fields[0]}"
	l="${_fields[1]}"
	# First sentence, not first 60 bytes: it ends where the author ended a
	# thought instead of mid-word. A description with no sentence break yields
	# itself whole, which is correct — the uncapped fallback is the point, and a
	# cap here would only move the arbitrary limit rather than remove it.
	# Supplied titles are unbounded too, for the same reason: this headline is a
	# markdown bullet that wraps, so a cut here would discard the reviewer's
	# words to solve a problem the renderer does not have.
	t="${_fields[2]}"
	agent="${_fields[3]}"
	t=$(normalize_dashes "$t")
	emoji=$(persona_emoji "$agent")
	loc_link=$(link_location "$f" "$l")
	out+="- ${emoji} **${t}** (${loc_link})"$'\n\n'

	# A collapsed finding is a pointer, not a summary: headline and permalink,
	# nothing that could read as the whole story. The remaining fields are read
	# but unused: they arrive in the same single jq call, so skipping them would
	# save nothing and only add a second call to avoid.
	if [[ "$variant" == "headline" ]]; then
		printf '%s' "$out"
		return
	fi

	ev="${_fields[4]}"
	desc="${_fields[5]}"
	rec="${_fields[6]}"
	constraint="${_fields[7]}"
	# Prose the reviewer wrote takes the house-style dash pass; `evidence`
	# deliberately does not (see normalize_dashes).
	desc=$(normalize_dashes "$desc")
	rec=$(normalize_dashes "$rec")
	constraint=$(normalize_dashes "$constraint")
	out+="$(evidence_block "$ev")"$'\n\n'
	out+=$(printf '💡 **Recommendation:** %s\n' "$rec" | indent2)
	if [[ -n "$constraint" ]]; then
		out+=$'\n'"$(printf '**Constraint:** %s\n' "$constraint" | indent2)"
	fi
	if [[ "$variant" == "no-analysis" ]]; then
		out+=$'\n\n'
		printf '%s' "$out"
		return
	fi
	# A <details> whose body only repeats the headline is noise dressed as
	# structure. That happens exactly when the headline was DERIVED from a
	# single-sentence description, never when the reviewer supplied a title.
	# Compare with the description's own terminal period removed: the headline
	# had one stripped by rtrimstr, so a bare `!=` reports "different" for two
	# strings that differ by exactly that character and renders the block anyway.
	if [[ "${desc%.}" != "$t" ]]; then
		out+=$'\n\n'"  <details><summary>💬 Full reviewer analysis</summary>"$'\n\n'
		out+=$(printf '%s\n' "$desc" | indent2)
		out+=$'\n'"  </details>"
	fi
	out+=$'\n\n'
	printf '%s' "$out"
}
