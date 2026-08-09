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

# Reviewer persona label (emoji + focus + mode); host-agnostic.
persona_label() { # agent-file-name
	local p mode m=""
	p=$(printf '%s' "$1" | sed -E 's/^divisor-//; s/-(code|spec)$//')
	mode=$(printf '%s' "$1" | sed -nE 's/^divisor-[a-z]+-(code|spec)$/\1/p')
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
	p=$(printf '%s' "$1" | sed -E 's/^divisor-//; s/-(code|spec)$//')
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
# does the formatting. Fields are read with `jq -r` one at a time, never @tsv:
# evidence may contain real tabs and newlines that would corrupt a TSV row.
rc_finding_block() { # finding-json
	local base="$1" f l t ev agent desc rec constraint emoji loc_link out=""
	f=$(jq -r '.file' <<<"$base")
	l=$(jq -r '.line // ""' <<<"$base")
	# First sentence, not first 60 bytes: it ends where the author ended a
	# thought instead of mid-word. A description with no sentence break yields
	# itself whole, which is correct — the uncapped fallback is the point, and a
	# cap here would only move the arbitrary limit rather than remove it.
	# Supplied titles are bounded at the schema instead (max 120).
	t=$(jq -r '.title // (.description | split(". ")[0] | rtrimstr("."))' <<<"$base")
	ev=$(jq -r '.evidence' <<<"$base")
	agent=$(jq -r '.agent' <<<"$base")
	desc=$(jq -r '.description' <<<"$base")
	rec=$(jq -r '.recommendation' <<<"$base")
	constraint=$(jq -r '.constraint // ""' <<<"$base")
	# Prose the reviewer wrote takes the house-style dash pass; `evidence`
	# deliberately does not (see normalize_dashes).
	t=$(normalize_dashes "$t")
	desc=$(normalize_dashes "$desc")
	rec=$(normalize_dashes "$rec")
	constraint=$(normalize_dashes "$constraint")
	emoji=$(persona_emoji "$agent")
	loc_link=$(link_location "$f" "$l")
	out+="- ${emoji} **${t}** (${loc_link})"$'\n\n'
	out+="$(evidence_block "$ev")"$'\n\n'
	out+=$(printf '💡 **Recommendation:** %s\n' "$rec" | indent2)
	if [[ -n "$constraint" ]]; then
		out+=$'\n'"$(printf '**Constraint:** %s\n' "$constraint" | indent2)"
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
