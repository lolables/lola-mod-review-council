#!/usr/bin/env bash
# Shared provenance block for the verdict header of the PR comment and the
# report: how the review ran, as the scripts recorded it.
#
# Both renderers emit it from rc_render_provenance, so the comment a PR reader
# sees and the report.md the operator keeps cannot describe one run in two
# ways.
#
# Every value comes from a file a script wrote, never from model prose. A
# value that can come from the change (the report's config_changed paths) is
# printed only inside a code span sized to it (rc_md_code_span). Model IDs and
# role names are never escaped: they are checked against an allow-list and
# replaced with `unrecognised` when they fail it, because a value that needs
# escaping is not an ID or a role.
#
# Source this file after rc-lib.sh; do not execute it. It defines functions and
# the jq programs below, and sets nothing else.

# jq definitions shared by every program that prints an ID or an agent name.
# `\A` and `\z`, not `^` and `$`: jq's regex engine lets `$` match before a
# trailing newline, which would pass "claude\n" and print the newline into the
# header. The class admits no backtick, so an allowed value is safe inside a
# single-backtick span.
# Roles get a tighter class than IDs because they are printed bare, not in a
# code span: the ID class admits `@org/team` (a team ping), `http://x/a` and
# `www.x.io` (autolinks) and `_a_` (italics). Real roles are
# divisor-<persona>-<code|spec>, coordinator and validator.
# shellcheck disable=SC2016 # a jq program; the backticks are markdown.
RC_PROV_JQ_DEFS='def allowed: type == "string" and test("\\A[A-Za-z0-9._:@/-]{1,80}\\z");
def allowed_role: type == "string" and test("\\A[a-z0-9-]{1,80}\\z");
def shown_id: if allowed then "`" + . + "`" else "unrecognised" end;
def uniq: reduce .[] as $x ([]; if any(.[]; . == $x) then . else . + [$x] end);
'

# One bullet per (requested, reported) pair, roles in file order. A role shows
# as its persona segment (divisor-adversary-code -> adversary); coordinator and
# validator have no segment to strip. `host default` is the one requested value
# that is not an ID. An entry that is not an object is skipped; one in the old
# {role, id} shape has no `requested` and shows it as unrecognised.
# shellcheck disable=SC2016 # a jq program; $e, $k and $key are jq's.
_RC_PROV_MODELS_JQ='if type != "array" then empty else
	[.[] | select(type == "object")
		| {who: (.role | if allowed_role then sub("\\Adivisor-"; "") | sub("-(code|spec)\\z"; "") else "unrecognised" end),
		   requested: (.requested | if . == "host default" then . else shown_id end),
		   reported: (.reported // [] | if type == "array" then map(shown_id) | uniq else ["unrecognised"] end)}]
	| reduce .[] as $e ([];
		[$e.requested, $e.reported] as $key
		| (first(range(length) as $k | select(.[$k].key == $key) | $k) // null) as $i
		| if $i == null then . + [{key: $key, who: [$e.who]}] else .[$i].who += [$e.who] end)
	| .[]
	| "- \(.who | uniq | join(", ")): requested \(.key[0]) · \(if .key[1] == [] then "not reported" else "reported " + (.key[1] | join(", ")) end)"
end'

# Print <value> as an inline code span that nothing in it can close: the
# delimiter is one backtick longer than the longest backtick run in the value,
# and a value that starts or ends with a backtick is padded with a space so the
# delimiter cannot absorb it. Raw, a value could close the span, inject HTML or
# an image, or pose as a link.
rc_md_code_span() { # value
	local value="$1" delim='`' pad=""
	while [[ "$value" == *"$delim"* ]]; do
		delim+='`'
	done
	if [[ "$value" == '`'* || "$value" == *'`' ]]; then
		pad=" "
	fi
	printf '%s' "${delim}${pad}${value}${pad}${delim}"
}

# The provenance block, as lines with no trailing blank line. A models.json
# that is missing, unreadable or holds no entry renders the not-recorded line.
rc_render_provenance() { # session_dir
	local session_dir="$1" models
	models=$(jq -r "${RC_PROV_JQ_DEFS}${_RC_PROV_MODELS_JQ}" "$session_dir/models.json" 2>/dev/null) || models=""
	if [[ -n "$models" ]]; then
		printf '%s\n%s\n' "**Models:**" "$models"
	else
		printf '%s\n' "**Models:** _Not recorded by the host; reviewer, validator and coordinator model IDs were not exposed._"
	fi
}
