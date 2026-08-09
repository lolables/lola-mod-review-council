#!/usr/bin/env bash
set -uo pipefail

# Locate self via BASH_SOURCE so rc-lib resolves whether this file is executed
# standalone or sourced by a per-forge post script (or a test).
_RC_RENDER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=module/skills/review-council/scripts/rc-lib.sh
source "$_RC_RENDER_DIR/rc-lib.sh"
# shellcheck source=module/skills/review-council/scripts/lib/render-findings.sh
source "$_RC_RENDER_DIR/lib/render-findings.sh"

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
	[[ -f "$RC_EVIDENCE" ]] || {
		echo 0
		return
	}
	jq -r --arg s "$1" '[.verified[]? | select(.severity==$s)] | length' "$RC_EVIDENCE" 2>/dev/null || echo 0
}

# Per-agent verified-finding summary ("2 MEDIUM, 1 LOW" | "none"). Reads $RC_EVIDENCE.
agent_findings() { # agent-name
	local a="$1" out="" n sev
	[[ -f "$RC_EVIDENCE" ]] || {
		echo "none"
		return
	}
	for sev in CRITICAL HIGH MEDIUM LOW; do
		n=$(jq -r --arg a "$a" --arg s "$sev" '[.verified[]? | select(.agent==$a and .severity==$s)] | length' "$RC_EVIDENCE" 2>/dev/null || echo 0)
		[[ "$n" -gt 0 ]] && out="${out:+$out, }${n} ${sev}"
	done
	echo "${out:-none}"
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
	local agent_rows="" name av
	local findings_block="" sev n se
	local marker_line

	RC_EVIDENCE="$session_dir/verdicts/findings.json"
	owner=$(rc_parse_kv "$session_dir/session.txt" "Owner")
	repo=$(rc_parse_kv "$session_dir/session.txt" "Repo")
	effort=$(rc_parse_kv "$session_dir/session.txt" "Effort")

	# Verdict. Single source shared with rc-render-report.sh: the orchestrator
	# writes verdict.txt at the start of the report phase (SKILL.md Step 6), so
	# the posted comment and the rendered report cannot disagree.
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
	if [[ -f "$session_dir/comment-summary.md" ]]; then
		tldr=$(head -n1 "$session_dir/comment-summary.md")
		tldr=$(normalize_dashes "$tldr")
	fi

	# LLM provenance: unique model IDs the host recorded, as bullets.
	if [[ -f "$session_dir/models.json" ]]; then
		local model_ids
		model_ids=$(jq -r '[.[].id] | unique[]' "$session_dir/models.json" 2>/dev/null || true)
		while IFS= read -r id; do
			[[ -n "$id" ]] && models_bullets+="> - ${id}"$'\n'
		done <<<"$model_ids"
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
		# A host that failed to parse (empty, or unchanged from the raw origin)
		# leaves RC_FORGE_WEB empty rather than guessing a forge -- this
		# renderer holds zero forge knowledge. link_location() / rc_url_commit
		# already degrade an empty RC_FORGE_WEB to plain code spans; a
		# per-forge default (if any) belongs in that forge's own post script.
		[[ -n "$host" && "$host" != "$origin" ]] && RC_FORGE_WEB="https://${host}/${owner}/${repo}"
	fi
	RC_SHORT_SHA="${RC_HEAD_SHA:0:7}"
	marker_line="<!-- ${MARKER_KEY} sha=${RC_HEAD_SHA:-unknown} -->"

	# Severity counts from verified findings.
	c_crit=$(sev_count CRITICAL)
	c_high=$(sev_count HIGH)
	c_med=$(sev_count MEDIUM)
	c_low=$(sev_count LOW)

	# Per-agent table: verdict from findings.json .verdicts (verbatim), counts
	# from verified findings. Single source — table cannot disagree with body.
	if [[ -f "$RC_EVIDENCE" ]]; then
		local verdict_agents
		verdict_agents=$(jq -r '.verdicts | keys[]' "$RC_EVIDENCE" 2>/dev/null || true)
		while IFS= read -r name; do
			[[ "$name" == divisor-* ]] || continue
			local raw_v label agent_count
			raw_v=$(jq -r --arg a "$name" '.verdicts[$a] // "APPROVE"' "$RC_EVIDENCE")
			case "$raw_v" in *"REQUEST CHANGES"*) av="❌ Changes" ;; *) av="✅ Approve" ;; esac
			label=$(persona_label "$name")
			agent_count=$(agent_findings "$name")
			agent_rows+="| ${label} | ${av} | ${agent_count} |"$'\n'
		done <<<"$verdict_agents"
	fi

	# Findings grouped by severity inside <details>. Fields come straight
	# from findings.json via jq -r (never @tsv -- evidence may contain real
	# tabs/newlines that would corrupt a TSV row).
	if [[ -f "$RC_EVIDENCE" ]]; then
		for sev in CRITICAL HIGH MEDIUM LOW; do
			n=$(sev_count "$sev")
			[[ "$n" -eq 0 ]] && continue
			case "$sev" in
			CRITICAL) se="🔴" ;; HIGH) se="🟠" ;; MEDIUM) se="🟡" ;; *) se="🔵" ;;
			esac
			findings_block+="<details><summary>${se} ${sev} (${n})</summary>"$'\n\n'
			local count idx
			count=$(jq --arg s "$sev" '[.verified[] | select(.severity==$s)] | length' "$RC_EVIDENCE")
			for ((idx = 0; idx < count; idx++)); do
				local base
				base=$(jq -c --arg s "$sev" "[.verified[] | select(.severity==\$s)][$idx]" "$RC_EVIDENCE")
				# `$(...)` strips trailing newlines, so the block's own closing
				# blank line has to be re-added here. Without it the group's
				# `</details>` lands on the same line as the finding's, and the
				# structure the reader collapses is silently one tag short.
				findings_block+=$(rc_finding_block "$base")
				findings_block+=$'\n\n'
			done
			findings_block+="</details>"$'\n\n'
		done
	fi

	# Assemble. Override REVIEW_COUNCIL_REPO to point a fork's footer at its repo.
	# The house-style dash pass has already run on each LLM-authored prose field
	# above; nothing filters the assembled body, so evidence lands here exactly as
	# the reviewer quoted it.
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
	body_payload=$(jq -n --arg b "$body_file" '{body_file:$b}')
	json_output "rendered" "Rendered comment body; no posting integration for this forge - post it manually." \
		"$body_payload"
	exit 0
fi
