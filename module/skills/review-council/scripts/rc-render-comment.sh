#!/usr/bin/env bash
set -uo pipefail

# Locate self via BASH_SOURCE so rc-lib resolves whether this file is executed
# standalone or sourced by a per-forge post script (or a test).
_RC_RENDER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=module/skills/review-council/scripts/rc-lib.sh
source "$_RC_RENDER_DIR/rc-lib.sh"

# rc-render-comment.sh — forge-NEUTRAL renderer for the Review Council PR
# comment. It owns ALL markdown assembly and computes the neutral facts itself
# (head SHA, forge web host, severity counts, persona labels). It contains ZERO
# forge knowledge: source deep-links and the commit-stamp link are delegated to
# two hook functions a per-forge script defines before calling in:
#
#   rc_url_file   <forge_web> <sha> <file> <line>  -> deep-link URL, or empty
#   rc_url_commit <forge_web> <sha>                -> commit URL,   or empty
#
# When a hook is undefined (standalone render-only fallback) or returns empty,
# the renderer emits a plain `code span` / plain short-sha — a valid
# manual-paste body with no forge assumptions.
#
# Two entry points:
#   - sourced:   rc_render_comment_body <session_dir> <body_file>  (sets globals
#                RC_FORGE_WEB / RC_SHORT_SHA / RC_HEAD_SHA for the caller).
#   - standalone: `rc-render-comment.sh <session_dir>` renders comment-body.md
#                 and prints {"status":"rendered", ...} — the render-only fallback.

MARKER_KEY="review-council:marker"

# --- Neutral helpers (read the globals rc_render_comment_body sets) ---

# Verified-finding count for a severity. Reads $RC_EVIDENCE.
sev_count() { # SEVERITY
	[[ -f "$RC_EVIDENCE" ]] || { echo 0; return; }
	jq -r --arg s "$1" '[.verified[]? | select(.severity==$s)] | length' "$RC_EVIDENCE" 2>/dev/null || echo 0
}

# Per-agent verified-finding summary ("2 MEDIUM, 1 LOW" | "none"). Reads $RC_EVIDENCE.
agent_findings() { # agent-name
	local a="$1" out="" n sev
	[[ -f "$RC_EVIDENCE" ]] || { echo "none"; return; }
	for sev in CRITICAL HIGH MEDIUM LOW; do
		n=$(jq -r --arg a "$a" --arg s "$sev" '[.verified[]? | select(.agent==$a and .severity==$s)] | length' "$RC_EVIDENCE" 2>/dev/null || echo 0)
		[[ "$n" -gt 0 ]] && out="${out:+$out, }${n} ${sev}"
	done
	echo "${out:-none}"
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

# Insert blank-line separation into a dense reviewer body so it renders as
# distinct paragraphs on the forge instead of one <br>-joined wall of text.
# A blank line is inserted before each `**Field**:` label and before each
# opening code fence, unless one already precedes it or we are inside a fence.
reflow_fields() {
	awk '
	BEGIN { infence = 0; prev_blank = 1 }
	{
		is_fence = ($0 ~ /^```/)
		is_label = (!infence && $0 ~ /^\*\*(Constraint|Description|Recommendation|Evidence|Impact|Suggestion|Explanation|Severity)\*\*:/)
		if (!prev_blank && ((is_fence && !infence) || is_label)) print ""
		print
		if (is_fence) infence = !infence
		prev_blank = ($0 ~ /^[[:space:]]*$/)
	}'
}

# In the collapsed analysis, turn a run-on "**Constraint**: body" /
# "**Description**: body" line into a label heading with the body on its own
# bullet below it — easier to scan than a bold prefix buried in prose. Evidence
# and code fences are left untouched (not in scope).
bulletize_cd() {
	awk '
	/^```/ { infence = !infence; print; next }
	!infence && /^\*\*Constraint\*\*:/ { b = $0; sub(/^\*\*Constraint\*\*:[ \t]*/, "", b); print "**Constraint:**"; print "- " b; next }
	!infence && /^\*\*Description\*\*:/ { b = $0; sub(/^\*\*Description\*\*:[ \t]*/, "", b); print "**Description:**"; print "- " b; next }
	{ print }'
}

# Render a label-stripped recommendation body as a bulleted block: the first
# line becomes the bullet; any following lines (e.g. a code snippet) are
# indented two spaces so they nest inside that bullet rather than escaping it.
rec_bulletize() {
	awk '
	NR == 1 { print "- " $0; next }
	/^[[:space:]]*$/ { print ""; next }
	{ print "  " $0 }'
}

# --- Main renderer. Sets globals RC_FORGE_WEB / RC_SHORT_SHA / RC_HEAD_SHA /
# RC_EVIDENCE (no `local`) so the sourcing per-forge script can build its own
# forge-specific links (e.g. #issuecomment-<id>). ---
rc_render_comment_body() { # session_dir body_file
	local session_dir="$1" body_file="$2"
	local owner repo effort rr origin host
	local verdict="APPROVE" v emoji tldr models_bullets=""
	local stamp commit_url repo_url
	local c_crit c_high c_med c_low
	local agent_rows="" vf name av
	local findings_block="" sev n se f l t ev agent detail detail_b64 analysis rec rec_block
	local marker_line

	RC_EVIDENCE="$session_dir/verdicts/evidence-check.json"
	owner=$(rc_parse_kv "$session_dir/session.txt" "Owner")
	repo=$(rc_parse_kv "$session_dir/session.txt" "Repo")
	effort=$(rc_parse_kv "$session_dir/session.txt" "Effort")

	# Verdict (orchestrator writes verdict.txt at report time).
	if [[ -f "$session_dir/verdict.txt" ]]; then
		v=$(head -n1 "$session_dir/verdict.txt" | tr -d '\n')
		[[ -n "$v" ]] && verdict="$v"
	fi
	case "$verdict" in
	*"REQUEST CHANGES"*) emoji="🔴" ;;
	*"ADVISOR"*) emoji="🟡" ;;
	*) emoji="🟢" ;;
	esac

	# Human TL;DR (LLM-authored one-liner; generic fallback).
	tldr="Automated review complete."
	[[ -f "$session_dir/comment-summary.md" ]] && tldr=$(head -n1 "$session_dir/comment-summary.md")

	# LLM provenance: unique model IDs the host recorded, as bullets.
	if [[ -f "$session_dir/models.txt" && -s "$session_dir/models.txt" ]]; then
		while IFS= read -r id; do
			[[ -n "$id" ]] && models_bullets+="> - ${id}"$'\n'
		done < <(sed -E 's/^[^:]*:[[:space:]]*//' "$session_dir/models.txt" | awk 'NF && !seen[$0]++')
	fi

	# Neutral facts: head SHA (materialized checkout or working tree) and forge
	# web host (parsed from the origin remote — GitHub Enterprise safe). Empty
	# head SHA degrades links to plain spans via the hooks.
	RC_HEAD_SHA=""
	RC_FORGE_WEB=""
	rr=$(rc_parse_kv "$session_dir/session.txt" "Review root")
	origin=""
	if [[ -n "$rr" && "$rr" != "." && -d "$rr/.git" ]]; then
		RC_HEAD_SHA=$(git -C "$rr" rev-parse HEAD 2>/dev/null || echo "")
		origin=$(git -C "$rr" remote get-url origin 2>/dev/null || echo "")
	elif [[ "$rr" == "." ]]; then
		RC_HEAD_SHA=$(git rev-parse HEAD 2>/dev/null || echo "")
		origin=$(git remote get-url origin 2>/dev/null || echo "")
	fi
	if [[ -n "$owner" && -n "$repo" ]]; then
		host=$(printf '%s' "$origin" | sed -E 's#^git@([^:]+):.*#\1#; s#^https?://([^/]+)/.*#\1#')
		[[ -z "$host" || "$host" == "$origin" ]] && host="github.com"
		RC_FORGE_WEB="https://${host}/${owner}/${repo}"
	fi
	RC_SHORT_SHA="${RC_HEAD_SHA:0:7}"
	marker_line="<!-- ${MARKER_KEY} sha=${RC_HEAD_SHA:-unknown} -->"

	# Severity counts from verified findings.
	c_crit=$(sev_count CRITICAL); c_high=$(sev_count HIGH)
	c_med=$(sev_count MEDIUM); c_low=$(sev_count LOW)

	# Combined reviewer table rows (divisor personas only).
	if [[ -d "$session_dir/verdicts" ]]; then
		for vf in "$session_dir/verdicts"/*.md; do
			[[ -f "$vf" ]] || continue
			name=$(basename "$vf" .md)
			[[ "$name" == divisor-* ]] || continue
			av="✅ Approve"
			grep -qE '^\*{0,2}Verdict\*{0,2}:.*REQUEST CHANGES|^REQUEST CHANGES$' "$vf" 2>/dev/null && av="❌ Changes"
			agent_rows+="| $(persona_label "$name") | ${av} | $(agent_findings "$name") |"$'\n'
		done
	fi

	# Findings grouped by severity inside <details>.
	if [[ -f "$RC_EVIDENCE" ]]; then
		for sev in CRITICAL HIGH MEDIUM LOW; do
			n=$(sev_count "$sev")
			[[ "$n" -eq 0 ]] && continue
			case "$sev" in
			CRITICAL) se="🔴" ;; HIGH) se="🟠" ;; MEDIUM) se="🟡" ;; *) se="🔵" ;;
			esac
			findings_block+="<details><summary>${se} ${sev} (${n})</summary>"$'\n\n'
			while IFS=$'\t' read -r f l t ev agent detail_b64; do
				findings_block+="- $(persona_emoji "$agent") **${t}** ($(link_location "$f" "$l"))"$'\n\n'"  > \`${ev}\`"$'\n\n'
				detail=""
				[[ -n "$detail_b64" ]] && detail=$(printf '%s' "$detail_b64" | base64 -d 2>/dev/null)
				# Drop the redundant leading preamble — blank lines and the
				# **File**: line (already shown as the finding's deep-link) — so
				# the analysis starts cleanly. Evidence is kept: a fenced
				# evidence block carries more than the one-line teaser above.
				[[ -n "$detail" ]] && detail=$(printf '%s' "$detail" | awk '
					BEGIN { pre = 1 }
					{
						if (pre) {
							if ($0 ~ /^[[:space:]]*$/) next
							if ($0 ~ /^\*\*File\*\*:/) next
							if ($0 ~ /^\*\*Evidence\*\*:[[:space:]]*[^[:space:]]/) next
							pre = 0
						}
						print
					}')
				# Split the mandated **Recommendation** field out of the body: it
				# is the actionable "how to fix", so it is always shown above the
				# collapsed analysis (with a 💡), never buried inside it. The
				# analysis keeps everything before it (Evidence, Constraint,
				# Description). Recommendation is the last field per the reviewer
				# protocol, so capturing it to EOF also carries its code snippet.
				analysis=""; rec=""
				if [[ -n "$detail" ]]; then
					analysis=$(printf '%s\n' "$detail" | awk '/^\*\*Recommendation\*\*:/{exit} {print}')
					rec=$(printf '%s\n' "$detail" | awk 'f{print} /^\*\*Recommendation\*\*:/{f=1; sub(/^\*\*Recommendation\*\*:[[:space:]]*/,""); print}' | awk 'NF||p{print; p=1}')
				fi
				# Recommendation: always visible, lightbulb-tagged, with the body
				# on a bullet below the label so it reads at a glance.
				if [[ -n "$rec" ]]; then
					rec_block=$(printf '%s\n' "$rec" | rec_bulletize)
					findings_block+=$(printf '💡 **Recommendation:**\n%s\n' "$rec_block" | indent2)
					findings_block+=$'\n\n'
				fi
				# Full reviewer analysis: reflowed for readability (blank lines
				# between dense fields), Constraint/Description bodies moved onto
				# bullets, then tucked one disclosure deeper.
				if [[ -n "$analysis" ]]; then
					analysis=$(printf '%s\n' "$analysis" | reflow_fields | bulletize_cd)
					# A <br> spacer: source blank lines collapse in rendered
					# markdown, so this is what actually puts a line of whitespace
					# between the recommendation and the analysis disclosure.
					findings_block+="  <br>"$'\n\n'"  <details><summary>💬 Full reviewer analysis</summary>"$'\n\n'
					findings_block+=$(printf '%s\n' "$analysis" | indent2)
					findings_block+=$'\n'"  </details>"$'\n\n'
				fi
			done < <(jq -r --arg s "$sev" '.verified[]? | select(.severity==$s) | [.file, .line, .title, .evidence, .agent, ((.detail // "") | @base64)] | @tsv' "$RC_EVIDENCE" 2>/dev/null)
			findings_block+="</details>"$'\n\n'
		done
	fi

	# Assemble. Override REVIEW_COUNCIL_REPO to point a fork's footer at its repo.
	repo_url="${REVIEW_COUNCIL_REPO:-https://github.com/lolables/lola-mod-review-council}"
	{
		echo "## ${emoji} Review Council: ${verdict}"
		echo ""
		echo "> **Automated LLM review, not a human sign-off.** Findings are machine-generated, may contain errors, and are advisory input to human judgment."
		echo ">"
		if [[ -n "$models_bullets" ]]; then
			echo "> Models used:"
			printf '%s' "$models_bullets"
		else
			echo "> Reviewer model IDs were not recorded by the host."
		fi
		echo ""
		if [[ -n "$RC_HEAD_SHA" ]]; then
			commit_url=""
			declare -F rc_url_commit >/dev/null 2>&1 && commit_url=$(rc_url_commit "$RC_FORGE_WEB" "$RC_HEAD_SHA")
			if [[ -n "$commit_url" ]]; then
				stamp="Reviewed at commit [\`${RC_SHORT_SHA}\`](${commit_url})"
			else
				stamp="Reviewed at commit \`${RC_SHORT_SHA}\`"
			fi
			[[ -n "$effort" ]] && stamp="${stamp} (${effort} effort)"
			echo "_${stamp}._"
			echo ""
		fi
		echo "**TL;DR:** ${tldr}"
		echo ""
		echo "**Findings:** 🔴 ${c_crit} Critical, 🟠 ${c_high} High, 🟡 ${c_med} Medium, 🔵 ${c_low} Low"
		echo ""
		if [[ -n "$agent_rows" ]]; then
			echo "| Reviewer | Verdict | Findings |"
			echo "|---|---|---|"
			printf '%s' "$agent_rows"
			echo ""
		fi
		printf '%s' "$findings_block"
		echo "---"
		echo "_Produced by [Review Council](${repo_url}), an open-source multi-persona code reviewer. Spot a wrong call or want the source? [File feedback](${repo_url}/issues) or browse the [repository](${repo_url})._"
		echo ""
		echo "$marker_line"
	} >"$body_file"

	# House style: no em/en dashes in posted output (covers static text plus
	# LLM-authored TL;DR and agent-authored finding titles/evidence).
	sed -i 's/—/-/g; s/–/-/g' "$body_file"
}

# --- Standalone entry: render-only fallback (no forge hooks -> plain spans). ---
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	rc_trap_errors
	session_dir="${1:-}"
	if [[ -z "$session_dir" || ! -d "$session_dir" ]]; then
		json_output "skip" "Session directory not found."
		exit 0
	fi
	body_file="$session_dir/comment-body.md"
	rc_render_comment_body "$session_dir" "$body_file"
	json_output "rendered" "Rendered comment body; no posting integration for this forge - post it manually." \
		"$(jq -n --arg b "$body_file" '{body_file:$b}')"
	exit 0
fi
