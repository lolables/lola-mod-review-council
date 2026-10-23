#!/usr/bin/env bash
# Shared provenance block for the verdict header of the PR comment and the
# report: how the review ran, as the scripts recorded it.
#
# Both renderers emit it from rc_render_provenance, so the comment a PR reader
# sees and the report.md the operator keeps cannot describe one run in two
# ways. They differ only in links: the comment passes its forge's rc_url_commit
# hook and the SHAs become links; the report passes no hook.
#
# Every value comes from a file a script wrote, except in models.json:
# `requested` is written by the orchestrator and `reported` is each agent's
# self-claim. Those are trusted only through the allow-lists below. A
# value that can come from the change or the forge (the base branch name, the
# configured constitution path, pack names, the effort, the report's
# config_changed paths) is printed only inside a code span sized to it
# (rc_md_code_span). A SHA is printed only when it is 40 lowercase hex
# characters, shortened to 12; any other value is left out, never shown raw.
# Model IDs (`allowed`, printed code-spanned) and role names (`allowed_role`,
# printed bare) are never escaped: they are replaced with `unrecognised` when
# they fail their allow-list, because a value that needs escaping is not an ID
# or a role.
# The Council version line is rc_council_version's (lib/council-version.sh):
# fixed words and the digits of the skill's VERSION stamp, and only when the
# stamp has a shape release-bump.sh writes.
# The Verdict format check line is one of three fixed strings chosen from
# verdicts/_meta/schema-validation.txt; that file's text is never interpolated.
# The Coverage gap line names findings.json .missing_verdicts through
# allowed_role.
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
def shown_name: if allowed_role then . else "unrecognised" end;
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

# rc_council_version, for the Council version line.
# shellcheck source=module/skills/review-council/scripts/lib/council-version.sh
source "$(dirname "${BASH_SOURCE[0]}")/council-version.sh"

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

# The commit a session reviewed, or nothing, in order: the PR/MR head the forge
# reported ("Head SHA:", recorded by prepare-emit.sh), the materialized
# checkout's HEAD, else the working tree's HEAD, but only for a local review.
# A review by PR number or URL ("Input:" pr_number/url) standing in "." was
# launched from some checkout that need not be the PR's, so its HEAD would name
# a commit nobody reviewed; it stays unknown instead. A GitLab review root is
# an extracted archive with no .git, so only the recorded head names it.
rc_session_head_sha() { # session_dir
	local session_txt="$1/session.txt" rr recorded input_type head=""
	rr=$(rc_parse_kv "$session_txt" "Review root")
	recorded=$(rc_parse_kv "$session_txt" "Head SHA")
	input_type=$(rc_parse_kv "$session_txt" "Input")
	if [[ "$recorded" =~ ^[0-9a-f]{40}$ ]]; then
		head="$recorded"
	elif [[ -n "$rr" && "$rr" != "." && -d "$rr/.git" ]]; then
		head=$(git -C "$rr" rev-parse HEAD 2>/dev/null || echo "")
	elif [[ "$rr" == "." && "$input_type" != "pr_number" && "$input_type" != "url" ]]; then
		head=$(git rev-parse HEAD 2>/dev/null || echo "")
	fi
	printf '%s' "$head"
}

# A SHA as a 12-character code span, linked when the hook returns a URL.
_rc_prov_sha() { # sha link_hook forge_web
	local sha="$1" hook="$2" web="$3" url=""
	if [[ -n "$hook" ]] && declare -F "$hook" >/dev/null 2>&1; then
		url=$("$hook" "$web" "$sha")
	fi
	if [[ -n "$url" ]]; then
		printf '[`%s`](%s)' "${sha:0:12}" "$url"
	else
		printf '`%s`' "${sha:0:12}"
	fi
}

# "**Reviewed:** <base> (<branch>) → <head> · effort <effort>", from whatever of
# those is known. A SHA that is not 40 hex characters is left out, never
# printed: it is either absent or not a commit. Without a base SHA the line
# reads "at <head>", and the branch name is shown only beside the base it
# names. Prints nothing when nothing is known.
_rc_prov_reviewed() { # session_dir head_sha link_hook forge_web
	local session_txt="$1/session.txt" head="$2" hook="$3" web="$4"
	local base_sha base effort base_span effort_span shown commit="" line=""
	base_sha=$(rc_parse_kv "$session_txt" "Base SHA")
	base=$(rc_parse_kv "$session_txt" "Base")
	effort=$(rc_parse_kv "$session_txt" "Effort")
	[[ "$base_sha" =~ ^[0-9a-f]{40}$ ]] || base_sha=""
	[[ "$head" =~ ^[0-9a-f]{40}$ ]] || head=""
	if [[ -n "$base_sha" ]]; then
		commit=$(_rc_prov_sha "$base_sha" "$hook" "$web")
		# "none" and "none (explicit range)" are prepare-emit.sh's words for
		# a run with no base branch, not a branch name.
		if [[ -n "$base" && "$base" != none* ]]; then
			base_span=$(rc_md_code_span "$base")
			commit+=" (${base_span})"
		fi
		if [[ -n "$head" ]]; then
			shown=$(_rc_prov_sha "$head" "$hook" "$web")
			commit+=" → ${shown}"
		else
			commit+=" → head unknown"
		fi
	elif [[ -n "$head" ]]; then
		shown=$(_rc_prov_sha "$head" "$hook" "$web")
		commit="at ${shown}"
	fi
	line="$commit"
	if [[ -n "$effort" ]]; then
		effort_span=$(rc_md_code_span "$effort")
		line+="${line:+ · }effort ${effort_span}"
	fi
	if [[ -n "$line" ]]; then
		printf '%s' "**Reviewed:** ${line}"
	fi
}

# "**Rules:** constitution <path> · packs <name>, <name>". Always printed: a
# review with no constitution and no packs says so rather than leaving the
# reader to guess. The constitution is read from "Constitution path:", which
# prepare-emit.sh writes only for an accepted constitution and which holds the
# path as configured, the one a reader recognises. The "Constitution:" line is
# never parsed here: it embeds the session path, which the caller's session_dir
# need not spell the same way, and for a refusal it holds the refusal text,
# which is security posture and stays off the forge.
_rc_prov_rules() { # session_dir
	local session_txt="$1/session.txt" constitution packs name span shown="none" packs_shown=""
	constitution=$(rc_parse_kv "$session_txt" "Constitution path")
	if [[ -n "$constitution" ]]; then
		shown=$(rc_md_code_span "$constitution")
	fi
	packs=$(rc_parse_kv "$session_txt" "Packs")
	if [[ -n "$packs" && "$packs" != "none" ]]; then
		while IFS= read -r name; do
			[[ -n "$name" ]] || continue
			span=$(rc_md_code_span "$name")
			packs_shown+="${packs_shown:+, }${span}"
		done < <(printf '%s\n' "${packs//, /$'\n'}")
	fi
	printf '%s' "**Rules:** constitution ${shown} · packs ${packs_shown:-none}"
}

# The verdict-format check rc-extract-verdict.sh ran, worst of every run in the
# session. Printed only when the extractor recorded one; anything but its two
# words is shown as unknown rather than echoed.
_rc_prov_format_check() { # session_dir
	local f="$1/verdicts/_meta/schema-validation.txt" mode
	[[ -f "$f" ]] || return 0
	mode=$(head -n1 "$f" 2>/dev/null) || mode=""
	case "$mode" in
	full) printf '%s' "**Verdict format check:** full (jsonschema validator)" ;;
	minimal) printf '%s' "**Verdict format check:** minimal (jq fallback; jsonschema validator unavailable)" ;;
	*) printf '%s' "**Verdict format check:** unknown" ;;
	esac
}

# A blank line and a quoted warning naming every dispatched reviewer that
# returned no verdict, or nothing. Names are agent roles and pass the role
# allow-list before they are put in a code span, the same check the reviewer
# table applies to the rows it prints bare. The cap sentence is added only when
# the cap decided the verdict: it is APPROVE WITH ADVISORIES and no finding was
# verified (RC_COUNCIL_VERDICT_JQ lowers APPROVE for a missing verdict; verified
# findings give ADVISORIES on their own, and a blocking verdict is left alone).
# A missing or non-array .verified counts as empty, as it does there.
_rc_prov_coverage() { # session_dir
	local f="$1/verdicts/findings.json" names verdict line verified
	[[ -f "$f" ]] || return 0
	names=$(jq -r "${RC_PROV_JQ_DEFS}"'[(.missing_verdicts // []) | if type == "array" then .[] | (if allowed_role then "`" + . + "`" else "unrecognised" end) else empty end] | join(", ")' "$f" 2>/dev/null) || names=""
	[[ -n "$names" ]] || return 0
	line="> ⚠️ **Coverage gap:** no verdict from ${names}."
	# shellcheck disable=SC2154 # set by rc-lib.sh, which every caller sources first.
	verdict=$(jq -r "$RC_COUNCIL_VERDICT_JQ" "$f" 2>/dev/null) || verdict=""
	verified=$(jq -r '(.verified // []) | if type == "array" then length else 0 end' "$f" 2>/dev/null) || verified=""
	if [[ "$verdict" == "APPROVE WITH ADVISORIES" && "$verified" == "0" ]]; then
		line+=" Verdict capped at APPROVE WITH ADVISORIES."
	fi
	printf '\n%s' "$line"
}

# The provenance block, as lines with no trailing blank line. Every line above
# the Models line ends in <br>, so the block reads as one line per fact under
# any markdown renderer: <br> rather than a trailing backslash because that hard
# break is CommonMark-only and <br> renders on both forges, and rather than two
# trailing spaces because editors strip those. A models.json that is missing, unreadable or
# holds no entry renders the not-recorded line.
rc_render_provenance() { # session_dir head_sha [commit_link_hook] [forge_web]
	local session_dir="$1" head="$2" hook="${3:-}" web="${4:-}" line models skill_dir
	line=$(_rc_prov_reviewed "$session_dir" "$head" "$hook" "$web")
	if [[ -n "$line" ]]; then
		printf '%s<br>\n' "$line"
	fi
	line=$(_rc_prov_rules "$session_dir")
	printf '%s<br>\n' "$line"
	# This file is scripts/lib/ of the skill that is running, so the stamp
	# two levels up is the one installed beside the code rendering the report.
	skill_dir=$(dirname "${BASH_SOURCE[0]}")/../..
	line=$(rc_council_version "$skill_dir/VERSION")
	printf '%s<br>\n' "**Council version:** ${line}"
	line=$(_rc_prov_format_check "$session_dir")
	if [[ -n "$line" ]]; then
		printf '%s<br>\n' "$line"
	fi
	models=$(jq -r "${RC_PROV_JQ_DEFS}${_RC_PROV_MODELS_JQ}" "$session_dir/models.json" 2>/dev/null) || models=""
	if [[ -n "$models" ]]; then
		printf '%s\n%s\n' "**Models:**" "$models"
	else
		printf '%s\n' "**Models:** _Not recorded by the host; reviewer, validator and coordinator model IDs were not exposed._"
	fi
	line=$(_rc_prov_coverage "$session_dir")
	if [[ -n "$line" ]]; then
		printf '%s\n' "$line"
	fi
}
