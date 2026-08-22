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
# forge knowledge: source deep-links, the commit-stamp link and the comment size
# limit are delegated to three hook functions a per-forge script defines before
# calling in:
#
#   rc_url_file    <forge_web> <sha> <file> <line>  -> deep-link URL, or empty
#   rc_url_commit  <forge_web> <sha>                -> commit URL,   or empty
#   rc_comment_limit                                -> max chars per comment
#
# When a hook is undefined (standalone render-only fallback) or returns empty,
# the renderer emits a plain `code span` / plain short-sha — a valid
# manual-paste body with no forge assumptions. An undefined rc_comment_limit
# means NO limit: the manual-paste fallback has no API to reject it, so it stays
# full fidelity rather than being trimmed to satisfy a forge it never reaches.
#
# Two entry points:
#   - sourced:   rc_render_comment_body <session_dir> <body_file>  (sets globals
#                RC_FORGE_WEB / RC_SHORT_SHA / RC_HEAD_SHA, plus the part and
#                paring results RC_COMMENT_PARTS / RC_COMMENT_PART_FILES /
#                RC_COMMENT_LEVEL / RC_COMMENT_DROPPED, for the caller).
#   - standalone: `rc-render-comment.sh <session_dir>` renders comment-body.md
#                 and prints {"status":"rendered", ...} — the render-only fallback.

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

# --- Paring ladder and comment chaining --------------------------------------
#
# A review that produces enough findings renders a body the forge will not
# accept: GitHub caps an issue comment at 65,536 characters, and a 30-finding
# review already reaches 58k. Two mechanisms keep it postable, and they are
# applied in that order:
#
#   chaining  splits the body across up to `Max comments` comments, raising the
#             ceiling to limit x max_comments
#   paring    sheds detail one class at a time until what is left fits
#
# Chaining is tried first, at full fidelity, because a split body loses nothing.
# Paring only starts when even the multiplied budget is exceeded.
#
# The ladder:
#
#   0  full fidelity
#   1  drop analysis: LOW
#   2  drop analysis: LOW, MEDIUM
#   3  collapse LOW findings to headline + permalink
#   4  drop analysis: LOW, MEDIUM, HIGH        (CRITICAL analysis survives)
#   5  collapse MEDIUM findings to headline + permalink
#   6  drop whole findings, lowest severity first, never a CRITICAL
#   7  terminal: CRITICAL analysis yields, then CRITICAL findings, then the
#      body is cut at a line boundary
#
# Levels 5-7 should be unreachable in practice. They exist so the renderer has a
# defined terminal state instead of emitting an over-limit body and letting the
# API reject it after the whole review has been paid for.
#
# Level 4 says CRITICAL analysis is never dropped and level 6 drops findings
# lowest-severity-first; if the CRITICAL findings alone exceed the budget both
# rules cannot hold. Level 7 resolves it explicitly: CRITICAL analysis yields
# last, after everything else has already gone.
#
# EVERY level that fires adds a disclosure line. A pared comment that reads as
# complete is worse than an overflow error, because the maintainer cannot tell
# the difference.

# Byte length of a string. Bytes, not characters: `${#var}` counts characters
# under a UTF-8 locale and bytes under C, and the forge limits are on
# characters. For UTF-8 a string's byte count is never below its character
# count, so measuring bytes can only pare EARLY — never post over the limit.
# Bash applies an LC_ALL assignment immediately, including a `local` one, and
# restores it on return, so this costs no subprocess.
_rc_bytes() { # string
	local LC_ALL=C
	printf '%s' "${#1}"
}

# Findings in render order (CRITICAL, HIGH, MEDIUM, LOW), one compact JSON
# object per entry. One jq call per severity rather than one per finding: the
# ladder may re-pack a 30-finding body a dozen times and must not re-read the
# file to do it.
_RC_F_JSON=()
_RC_F_SEV=()
_RC_N_CRIT=0
_rc_load_findings() { # evidence_file
	_RC_F_JSON=()
	_RC_F_SEV=()
	_RC_N_CRIT=0
	_RC_BLOCK=()
	[[ -f "$1" ]] || return 0
	local sev line
	for sev in CRITICAL HIGH MEDIUM LOW; do
		while IFS= read -r line; do
			[[ -n "$line" ]] || continue
			_RC_F_JSON+=("$line")
			_RC_F_SEV+=("$sev")
			# `if`, not `[[ ]] && ...`: a trailing conditional would hand its own
			# false status to the read loop, then to the for loop, then to this
			# function -- and every caller runs under `set -e`.
			if [[ "$sev" == "CRITICAL" ]]; then
				_RC_N_CRIT=$((_RC_N_CRIT + 1))
			fi
		done < <(jq -c --arg s "$sev" '.verified[]? | select(.severity==$s)' "$1" 2>/dev/null || true)
	done
}

# Which rc_finding_block variant a severity renders as at a given level.
_rc_variant() { # level severity
	case "$2" in
	CRITICAL)
		if [[ "$1" -ge 7 ]]; then echo "no-analysis"; else echo "full"; fi
		;;
	HIGH)
		if [[ "$1" -ge 7 ]]; then echo "headline"; elif [[ "$1" -ge 4 ]]; then echo "no-analysis"; else echo "full"; fi
		;;
	MEDIUM)
		if [[ "$1" -ge 5 ]]; then echo "headline"; elif [[ "$1" -ge 2 ]]; then echo "no-analysis"; else echo "full"; fi
		;;
	*)
		if [[ "$1" -ge 3 ]]; then echo "headline"; elif [[ "$1" -ge 1 ]]; then echo "no-analysis"; else echo "full"; fi
		;;
	esac
}

# Rendered block for one finding, memoised per (index, variant). Re-packing is
# pure string work once a variant has been rendered; without the cache the
# terminal levels would re-run jq thousands of times.
#
# The key is an index into the CURRENTLY loaded finding set and says nothing
# about which findings.json produced it, so the cache is scoped to one load and
# _rc_load_findings clears it.
declare -A _RC_BLOCK=()
_rc_block() { # index variant -> _RC_OUT
	local key="$1:$2"
	if [[ -z "${_RC_BLOCK[$key]+set}" ]]; then
		_RC_BLOCK[$key]="$(rc_finding_block "${_RC_F_JSON[$1]}" "$2")"$'\n\n'
	fi
	_RC_OUT="${_RC_BLOCK[$key]}"
}

# Where part 1 carries links to the rest of the chain. It is an HTML comment so
# that a body posted without substitution -- the manual-paste path, or a forge
# with no post script -- renders as if it were never there. The per-forge poster
# replaces it once the other parts exist and their URLs are known.
# shellcheck disable=SC2034 # read by rc-post-comment-<forge>.sh, which sources
# this file, and written into the head part by _rc_prelude below.
RC_PART_LINKS_TOKEN="<!-- review-council:part-links -->"

# Severity-group wrapper. The comment groups findings inside <details>; the
# report uses headings instead, which is why this is not in render-findings.sh.
_RC_GROUP_CLOSE="</details>"$'\n\n'
_rc_group_open() { # severity count -> _RC_OUT
	local se
	case "$1" in
	CRITICAL) se="🔴" ;; HIGH) se="🟠" ;; MEDIUM) se="🟡" ;; *) se="🔵" ;;
	esac
	_RC_OUT="<details><summary>${se} ${1} (${2})</summary>"$'\n\n'
}

# The disclosure line, or empty when nothing was trimmed.
#
# The operative prefix "Trimmed to fit the" is pinned by a doc guard (RC-040)
# and appears nowhere else in the body, so it stays a literal here rather than
# being assembled from parts.
_rc_disclosure() { # level keep -> _RC_OUT
	local level="$1" keep="$2" i sev variant
	local n_analysis=0 n_collapsed=0 n_dropped=$((${#_RC_F_JSON[@]} - keep))
	local clauses=""
	_RC_OUT=""
	for ((i = 0; i < keep; i++)); do
		sev="${_RC_F_SEV[i]}"
		variant=$(_rc_variant "$level" "$sev")
		case "$variant" in
		no-analysis) n_analysis=$((n_analysis + 1)) ;;
		headline) n_collapsed=$((n_collapsed + 1)) ;;
		# `full` keeps everything and so contributes to no clause.
		*) ;;
		esac
	done
	[[ "$n_analysis" -gt 0 ]] && clauses="full reviewer analysis omitted for ${n_analysis} finding(s)"
	[[ "$n_collapsed" -gt 0 ]] && clauses="${clauses:+$clauses; }${n_collapsed} finding(s) collapsed to a headline and permalink"
	[[ "$n_dropped" -gt 0 ]] && clauses="${clauses:+$clauses; }${n_dropped} finding(s) omitted entirely"
	[[ -n "$clauses" ]] || return 0
	_RC_OUT="_Trimmed to fit the ${_RC_FORGE_NAME:-forge} comment limit: ${clauses}. The complete report is in the run artifacts._"$'\n\n'
}

# One part's findings section, covering findings [start, end). Severity groups
# are opened and closed within the part, so a part that holds four of ten HIGH
# findings is still valid markdown on its own.
_rc_section() { # level start end -> _RC_OUT
	local level="$1" start="$2" end="$3"
	local i j sev variant open_sev="" cnt out=""
	for ((i = start; i < end; i++)); do
		sev="${_RC_F_SEV[i]}"
		if [[ "$sev" != "$open_sev" ]]; then
			[[ -n "$open_sev" ]] && out+="$_RC_GROUP_CLOSE"
			# Findings are severity-ordered, so this group runs to the first
			# entry of a different severity or to the end of the part. Counted
			# with a while loop: an arithmetic `for` cannot compare strings.
			cnt=0
			j=$i
			while [[ "$j" -lt "$end" && "${_RC_F_SEV[j]}" == "$sev" ]]; do
				cnt=$((cnt + 1))
				j=$((j + 1))
			done
			_rc_group_open "$sev" "$cnt"
			out+="$_RC_OUT"
			open_sev="$sev"
		fi
		variant=$(_rc_variant "$level" "$sev")
		_rc_block "$i" "$variant"
		out+="$_RC_OUT"
	done
	[[ -n "$open_sev" ]] && out+="$_RC_GROUP_CLOSE"
	_RC_OUT="$out"
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
	local limit max_parts

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

	# Reviewers the council deliberately did not dispatch, as their own rows.
	# The table above is built from verdicts, so a skipped persona is simply not
	# in it — and a three-row table on a five-persona council reads as a full
	# council that happened to be small. This is the artifact a maintainer
	# actually sees on the PR, so it is the one that most needs to distinguish
	# "found nothing" from "was not asked". The reason travels with the row; a
	# reader who disagrees with the narrowing can turn it off (README, "Council
	# selection") and re-run.
	# The reason goes in the Verdict cell, where "why this outcome" belongs, and
	# the Findings cell stays a dash: a count column holding prose is a column
	# that has stopped meaning anything. Pipes are re-encoded for the same reason
	# the inline-comment table re-encodes them — one would open a column.
	if [[ -f "$session_dir/session-manifest.json" ]]; then
		local skipped_rows reason
		skipped_rows=$(jq -r '(.deselected // [])[]
			| "\(.agent)\t\(.reason // "out of scope" | gsub("\\|"; "&#124;") | gsub("\r?\n"; " "))"' \
			"$session_dir/session-manifest.json" 2>/dev/null || true)
		while IFS=$'\t' read -r name reason; do
			[[ "$name" == divisor-* ]] || continue
			# ASCII hyphen and plain colon: the assembled body carries no em or en
			# dash (the house-style pass strips them everywhere else, and it does
			# not run over this table).
			agent_rows+="| $(persona_label "$name") | ⏭️ Skipped: ${reason} | - |"$'\n'
		done <<<"$skipped_rows"
	fi

	# --- Fixed regions of a part body -------------------------------------
	#
	# Split at the point the disclosure line goes, so the ladder can re-assemble
	# a part without recomputing anything above it. Override REVIEW_COUNCIL_REPO
	# to point a fork's footer at its repo. The house-style dash pass has already
	# run on each LLM-authored prose field above; nothing filters the assembled
	# body, so evidence lands here exactly as the reviewer quoted it.
	repo_url="${REVIEW_COUNCIL_REPO:-https://github.com/lolables/lola-mod-review-council}"
	_RC_HEAD_TOP=$(
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
		# Two newlines, not one: `$(...)` strips every trailing newline, so the
		# blank line that separates the counts from whatever follows has to be put
		# back here. Without it a markdown table on the next line is not a table --
		# it is more of the same paragraph.
	)$'\n\n'
	_RC_HEAD_TABLE=""
	if [[ -n "$agent_rows" ]]; then
		_RC_HEAD_TABLE="| Reviewer | Verdict | Findings |"$'\n'"|---|---|---|"$'\n'"${agent_rows}"$'\n'
	fi
	_RC_FOOTER="---"$'\n'"_Produced by [Review Council](${repo_url}), an open-source multi-persona code reviewer. Spot a wrong call or want the source? [File feedback](${repo_url}/issues) or browse the [repository](${repo_url})._"$'\n\n'

	# --- Resolve the budget -----------------------------------------------
	#
	# Precedence: the recorded `Comment limit` (a user override, for self-hosted
	# GitLab or GHE behind a proxy that imposes a smaller body than the forge
	# does), then the per-forge rc_comment_limit hook, then no limit at all.
	#
	# The recorded value is what makes this work on the standalone path: the hook
	# is a shell function and cannot survive the `exec` in rc-post-comment.sh, so
	# rc-prepare.sh writes the resolved numbers into tracking.md and both paths
	# read them from there.
	_RC_FORGE_NAME=$(rc_parse_kv "$session_dir/tracking.md" "Forge")
	limit=$(rc_parse_kv "$session_dir/tracking.md" "Comment limit")
	# A limit is a POSITIVE character count, so zero is rejected alongside the
	# obvious junk -- the same shape `max_parts` below and rc-prepare.sh's own
	# validation already use. Accepting it produced a defined, silent disaster:
	# nothing fits a zero-byte comment, so the ladder walked to its terminal
	# state and wrote an empty file, and the run reported `status: rendered`
	# over a verdict that had been deleted rather than trimmed.
	[[ "$limit" =~ ^[1-9][0-9]*$ ]] || limit=""
	if [[ -z "$limit" ]] && declare -F rc_comment_limit >/dev/null 2>&1; then
		limit=$(rc_comment_limit)
		[[ "$limit" =~ ^[1-9][0-9]*$ ]] || limit=""
	fi
	# No limit means no paring and no chaining. A bound far above any forge's
	# stands in for "unbounded" so the packer needs no special case; the manual
	# paste fallback that lands here has no API to reject the body anyway.
	[[ -n "$limit" ]] || limit=$((1 << 40))
	# Exported: the poster substitutes the part links into the head AFTER this
	# renders it, and has to measure the result against the same number this did
	# rather than re-resolve it and risk disagreeing.
	# shellcheck disable=SC2034 # read by rc-post-comment-<forge>.sh, which
	# sources this file rather than calling into it.
	RC_COMMENT_LIMIT="$limit"
	max_parts=$(rc_parse_kv "$session_dir/tracking.md" "Max comments")
	[[ "$max_parts" =~ ^[1-9][0-9]*$ ]] || max_parts=1

	_rc_load_findings "$RC_EVIDENCE"
	_rc_solve "$limit" "$max_parts"

	# --- Write the parts ---------------------------------------------------
	#
	# Stale parts from an earlier render are removed first: a run that needed
	# three comments followed by one that needs two must not leave the third on
	# disk for the poster to find.
	local base="${body_file%.md}" idx=1 part_file
	rm -f "${base}".part[0-9]*.md
	RC_COMMENT_PART_FILES=()
	for ((idx = 1; idx <= RC_COMMENT_PARTS; idx++)); do
		if [[ "$idx" -eq 1 ]]; then part_file="$body_file"; else part_file="${base}.part${idx}.md"; fi
		printf '%s' "${_RC_PART_BODIES[idx - 1]}" >"$part_file"
		RC_COMMENT_PART_FILES+=("$part_file")
	done
}

# Find the cheapest ladder level whose body fits, and pack it.
#
# Sets RC_COMMENT_PARTS, RC_COMMENT_LEVEL, RC_COMMENT_DROPPED and
# _RC_PART_BODIES. Level 0 with every finding is tried first, so a review that
# fits pays for exactly one packing pass.
_rc_solve() { # limit max_parts
	local limit="$1" max_parts="$2" n=${#_RC_F_JSON[@]} level keep
	for level in 0 1 2 3 4 5; do
		if _rc_pack "$level" "$n" "$limit" "$max_parts"; then
			RC_COMMENT_LEVEL="$level"
			RC_COMMENT_DROPPED=0
			return 0
		fi
	done
	# Level 6: drop whole findings, lowest severity first, never a CRITICAL.
	for ((keep = n - 1; keep >= _RC_N_CRIT; keep--)); do
		if _rc_pack 6 "$keep" "$limit" "$max_parts"; then
			RC_COMMENT_LEVEL=6
			RC_COMMENT_DROPPED=$((n - keep))
			return 0
		fi
	done
	# Level 7: CRITICAL analysis yields last, then the CRITICAL findings go too.
	for ((keep = _RC_N_CRIT; keep >= 0; keep--)); do
		if _rc_pack 7 "$keep" "$limit" "$max_parts"; then
			RC_COMMENT_LEVEL=7
			RC_COMMENT_DROPPED=$((n - keep))
			return 0
		fi
	done
	# Not even an empty body fits: the limit is below the header the verdict
	# needs. A limit that low is the recorded `Comment limit` rather than any
	# forge's, and nothing measures the body against it before posting, so the
	# choice here is not between a comment and an API error -- it is between a
	# comment a human can read part of and one that is all header. Cut at a line
	# boundary, keeping the marker and the disclosure (see _rc_truncate).
	_rc_pack 7 0 $((1 << 40)) 1
	RC_COMMENT_LEVEL=7
	RC_COMMENT_DROPPED="$n"
	_rc_truncate "$limit"
	return 0
}

# Greedy fill at a fixed level. Returns 1 when the findings need more than
# max_parts comments, which is the signal to climb the ladder.
_rc_pack() { # level keep limit max_parts
	local level="$1" keep="$2" limit="$3" max_parts="$4"
	local -a starts=() ends=()
	local i j part=1 start=0 used=0 open_sev="" sev variant add extra
	local disc prelude_len close_len n_sev
	_rc_disclosure "$level" "$keep"
	disc="$_RC_OUT"
	close_len=$(_rc_bytes "$_RC_GROUP_CLOSE")

	_rc_prelude 1 "$max_parts" "$disc"
	used=$(_rc_bytes "${_RC_OUT}${_RC_FOOTER}")
	for ((i = 0; i < keep; i++)); do
		sev="${_RC_F_SEV[i]}"
		variant=$(_rc_variant "$level" "$sev")
		_rc_block "$i" "$variant"
		add=$(_rc_bytes "$_RC_OUT")
		extra=0
		if [[ "$sev" != "$open_sev" ]]; then
			[[ -n "$open_sev" ]] && extra=$((extra + close_len))
			# The group header carries the count of findings of that severity in
			# THIS part, which is not known until the part is closed. Costed with
			# the whole run's count, whose decimal width is never smaller -- so
			# the estimate can only over-reserve.
			n_sev=0
			for ((j = 0; j < keep; j++)); do [[ "${_RC_F_SEV[j]}" == "$sev" ]] && n_sev=$((n_sev + 1)); done
			_rc_group_open "$sev" "$n_sev"
			extra=$((extra + $(_rc_bytes "$_RC_OUT")))
		fi
		if [[ $((used + extra + add + close_len)) -gt "$limit" ]]; then
			[[ "$part" -lt "$max_parts" ]] || return 1
			starts[part - 1]=$start
			ends[part - 1]=$i
			part=$((part + 1))
			start=$i
			open_sev=""
			_rc_prelude "$part" "$max_parts" "$disc"
			prelude_len=$(_rc_bytes "${_RC_OUT}${_RC_FOOTER}")
			_rc_group_open "$sev" "$n_sev"
			extra=$(_rc_bytes "$_RC_OUT")
			used=$prelude_len
			# One finding that cannot fit an empty part is not a packing problem;
			# only a higher ladder level can fix it.
			[[ $((used + extra + add + close_len)) -le "$limit" ]] || return 1
		fi
		used=$((used + extra + add))
		open_sev="$sev"
	done
	starts[part - 1]=$start
	ends[part - 1]=$keep

	# Render exactly. The accounting above bounds each part from above, so this
	# can only come out shorter -- but it is verified rather than assumed,
	# because an over-limit body is the one outcome this whole path exists to
	# prevent.
	local p body body_len
	_RC_PART_BODIES=()
	for ((p = 1; p <= part; p++)); do
		_rc_prelude "$p" "$part" "$disc"
		body="$_RC_OUT"
		_rc_section "$level" "${starts[p - 1]}" "${ends[p - 1]}"
		body+="$_RC_OUT"
		body+="$_RC_FOOTER"
		_rc_marker "$p" "$part"
		body+="$_RC_OUT"
		body_len=$(_rc_bytes "$body")
		[[ "$body_len" -le "$limit" ]] || return 1
		_RC_PART_BODIES+=("$body")
	done
	RC_COMMENT_PARTS="$part"
	return 0
}

# Everything above a part's findings. Part 1 carries the verdict, the TL;DR and
# the reviewer table; the rest carry a banner naming their place in the chain,
# so a reader who lands on one knows where the summary is.
_rc_prelude() { # part_index part_count disclosure -> _RC_OUT
	local p="$1" total="$2" disc="$3"
	if [[ "$p" -eq 1 ]]; then
		_RC_OUT="${_RC_HEAD_TOP}${disc}${_RC_HEAD_TABLE}"
		# Placeholder for the links to the other parts. The poster substitutes
		# it once those comments exist and their URLs are known; left alone it
		# is an HTML comment and renders as nothing, which is what the
		# manual-paste path wants.
		if [[ "$total" -gt 1 ]]; then
			_RC_OUT+="${RC_PART_LINKS_TOKEN}"$'\n\n'
		fi
	else
		_RC_OUT="_Part ${p} of ${total} of the Review Council verdict for commit \`${RC_SHORT_SHA}\`. The verdict and summary are in part 1._"$'\n\n'"${disc}"
	fi
}

# The identity tag every part carries. `part`/`of` let the poster match a
# re-render against the comments it wrote last time, one part at a time.
_rc_marker() { # part_index part_count -> _RC_OUT
	_RC_OUT="<!-- ${RC_MARKER_KEY} sha=${RC_HEAD_SHA:-unknown} part=${1} of=${2} -->"$'\n'
}

# Last resort: keep whole lines until the limit is reached. Cutting on a line
# boundary rather than a byte offset keeps the result valid UTF-8 and stops the
# cut landing inside a markdown structure the reader would then see unclosed.
#
# Two lines outlive the cut, because the cut takes the tail and both of them
# live there or past it. They are reserved out of the fill budget and appended
# afterwards:
#
#   the marker      the only thing a poster's listings select on, and the last
#                   line of every part. A part that loses it is invisible to the
#                   next run, which posts a fresh comment beside the orphan and
#                   supersedes nothing, once more on every run after that. It
#                   goes back LAST: the listings take the last line that opens a
#                   marker, and the counterfeit a finding's evidence can carry
#                   is only harmless while it sits above the real one.
#
#   the disclosure  the line that stops a cut body reading as a complete review.
#                   Without it the reader gets a header announcing 30 findings,
#                   no findings, and no hint that anything was removed -- which
#                   the ladder above calls worse than an overflow error, for the
#                   same reason at every other level.
#
# Below their combined length the fill budget goes negative and the body is the
# two of them, over the limit. Nothing rejects it: that limit is the user's
# `Comment limit` rather than the forge's, and no poster measures a body against
# it before posting, so the visible outcome is a near-empty comment and not an
# error. It is still the better one. Nothing readable fits at such a limit under
# any policy, and a comment that keeps its identity is one the next run can
# replace or retire; one that loses it stays on the pull request for good.
_rc_truncate() { # limit
	local limit="$1" out="" line len=0 add marker disc fill_budget
	_rc_marker 1 1
	marker="$_RC_OUT"
	# The disclosure the terminal pack computed: this cut consumes that pack's
	# body, and level 7 keeping nothing is what produced it. Empty when there
	# was nothing to disclose, which is a review that found nothing.
	_rc_disclosure 7 0
	disc="$_RC_OUT"
	fill_budget=$((limit - $(_rc_bytes "${disc}${marker}")))
	while IFS= read -r line; do
		add=$(_rc_bytes "${line}"$'\n')
		[[ $((len + add)) -le "$fill_budget" ]] || break
		out+="${line}"$'\n'
		len=$((len + add))
	done <<<"${_RC_PART_BODIES[0]}"
	# The disclosure sits near the top of the packed body, above everything the
	# reserve makes room for, so a cut deep enough to have kept it must not be
	# handed a second copy. Matched on its text line rather than on `$disc`,
	# whose trailing blank line the cut can land in front of -- one budget in
	# this fixture stops in exactly that gap, and matching the whole thing
	# disclosed twice, on adjacent lines.
	if [[ -n "$disc" && "$out" != *"${disc%%$'\n'*}"* ]]; then
		out+="$disc"
	fi
	_RC_PART_BODIES=("${out}${marker}")
	RC_COMMENT_PARTS=1
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
	# The part files and the ladder level are reported, not just the head body:
	# a caller pasting the review by hand needs to know there is more than one
	# file, and a run that had to trim needs to say so in its own status too, not
	# only inside the body a human may never open.
	body_payload=$(jq -n --arg b "$body_file" \
		--argjson parts "$RC_COMMENT_PARTS" \
		--argjson level "$RC_COMMENT_LEVEL" \
		--argjson dropped "$RC_COMMENT_DROPPED" \
		--args '{body_file:$b, parts:$parts, pare_level:$level, findings_dropped:$dropped, part_files:$ARGS.positional}' \
		"${RC_COMMENT_PART_FILES[@]}")
	msg="Rendered comment body; no posting integration for this forge - post it manually."
	[[ "$RC_COMMENT_PARTS" -gt 1 ]] && msg="Rendered comment body in ${RC_COMMENT_PARTS} parts; no posting integration for this forge - post them in order, manually."
	[[ "$RC_COMMENT_LEVEL" -gt 0 ]] && msg="${msg} Trimmed to fit the comment limit (level ${RC_COMMENT_LEVEL}, ${RC_COMMENT_DROPPED} finding(s) omitted); the full report is in the run artifacts."
	json_output "rendered" "$msg" "$body_payload"
	exit 0
fi
