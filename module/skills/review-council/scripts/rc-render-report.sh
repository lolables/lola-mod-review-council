#!/usr/bin/env bash
set -euo pipefail

# The two prerequisite guards below run BEFORE rc-lib.sh is sourced, and report
# a missing prerequisite as markdown rather than the JSON every other script
# emits — stdout here is the report itself. Nothing between this line and the
# source can trip the ERR trap: both guards are `if` conditions, which bash
# exempts. The trap is therefore installed from the library afterwards, via
# rc_trap_errors, instead of being hand-rolled here and then silently
# overwritten by the library's identical definition at source time.
if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
	echo "# Review Council Report"
	echo ""
	echo "**Error:** Bash 4+ is required. macOS ships Bash 3; install a modern version: \`brew install bash\`"
	exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
	echo "# Review Council Report"
	echo ""
	echo "**Error:** jq is required but not installed."
	echo "Install it: \`apt-get install jq\` | \`brew install jq\` | \`dnf install jq\`"
	exit 0
fi

# Sourced AFTER the two guards above, never before. Those guards report a
# missing prerequisite as markdown, because stdout here is the report; rc-lib.sh
# reports it as JSON, because stdout in every other script is a JSON payload.
# Ordering them this way means rc-lib.sh's own Bash and jq guards are already
# satisfied by the time it loads and can never fire, so the markdown contract
# holds by construction rather than by coincidence. The library is wanted only
# for rc_parse_kv — this script makes no forge calls and so never requires GNU
# timeout.
# shellcheck source=module/skills/review-council/scripts/rc-lib.sh
source "$(dirname "$0")/rc-lib.sh"
rc_trap_errors # report script:line on any unhandled failure (never silent)

# rc-render-report.sh: renders structured markdown report template
# Usage: rc-render-report.sh <session_dir>
# Outputs: structured markdown report to stdout

session_dir="${1:-}"

# Graceful handling of missing session
if [[ -z "$session_dir" ]] || [[ ! -d "$session_dir" ]]; then
	echo "# Review Council Report"
	echo ""
	echo "Session data not available."
	exit 0
fi

tracking_file="$session_dir/tracking.md"
if [[ ! -f "$tracking_file" ]]; then
	echo "# Review Council Report"
	echo ""
	echo "Session tracking data not found."
	exit 0
fi

# ---------------------------------------------------------------------------
# Verification pre-condition
#
# phases/report.md has always carried this gate, and phases/verify.md has always
# described it as one this renderer enforces — "it refuses unconditionally [...]
# because such an exemption would rest on the orchestrator's own account of a
# status only it observed". That was true of the instructions and of nothing
# else: no check existed here, so an orchestrator that skipped Verification got
# a full report. Observed on a real zero-finding run — empty _meta/, complete
# report.md, verdict.txt and comment-summary.md, no verification log ever
# written. A control the constrained party can skip is not a control, so the
# three mechanical checks now live in the script.
#
# The two remaining checks in report.md stay prose because they are judgements a
# grep cannot make: whether the recorded evidence checks reflect real tool calls
# rather than recollection.
#
# There is no exemption for a review that found nothing. verify.md's
# `nothing_to_do` path writes an abbreviated log precisely so it can pass here.
verification_file="$session_dir/verdicts/_meta/verification.txt"
verification_refusal=""
if [[ ! -s "$verification_file" ]]; then
	verification_refusal="verification.txt is missing or empty — the Verification phase was not executed."
elif ! grep -qF "=== SUMMARY ===" "$verification_file"; then
	verification_refusal="verification.txt has no \`=== SUMMARY ===\` section — the Verification phase did not run to completion."
elif grep -qE '\{[A-Za-z_][A-Za-z0-9_]*\}' "$verification_file"; then
	# A summary still holding {N}-shaped placeholders was copied from the
	# template and never filled in: verification was described, not performed.
	verification_refusal="verification.txt still contains template placeholders — the Verification phase was templated, not executed."
fi

if [[ -n "$verification_refusal" ]]; then
	echo "# Review Council Report"
	echo ""
	echo "**Not rendered.** $verification_refusal"
	echo ""
	echo "Return to the Verification phase and execute it, then render again."
	echo "Expected at: \`${verification_file}\`"
	exit 0
fi

evidence_file="$session_dir/verdicts/findings.json"

# Parse tracking.md through the shared reader, which trims with sed. These were
# read with `grep | cut | xargs`, and xargs applies SHELL QUOTING to its input:
# a value carrying a quote is rewritten or rejected outright. Git permits both
# `'` and `"` in a refname, so a branch named `feature/don't-panic` made xargs
# exit non-zero and the report published `Branch: unknown` — the wrong branch,
# stated as fact, with the only warning going to stderr where nobody reads it.
#
# The `|| echo <default>` fallbacks those lines carried never fired either:
# xargs exits 0 on empty input, so an absent key yielded an empty pipeline that
# succeeded, and the value rendered blank rather than falling back. The defaults
# are applied here as parameter expansions, where an empty result is what
# actually triggers them.
mode=$(rc_parse_kv "$tracking_file" "Mode")
branch=$(rc_parse_kv "$tracking_file" "Branch")
base=$(rc_parse_kv "$tracking_file" "Base")
pr_line=$(rc_parse_kv "$tracking_file" "PR")
agents_discovered=$(rc_parse_kv "$tracking_file" "Agents discovered")
agents_absent=$(rc_parse_kv "$tracking_file" "Agents absent")
changeset=$(rc_parse_kv "$tracking_file" "Changeset size")
mode="${mode:-Unknown}"
branch="${branch:-unknown}"
base="${base:-main}"
pr_line="${pr_line:-none}"
agents_discovered="${agents_discovered:-0}"
agents_absent="${agents_absent:-none}"
changeset="${changeset:-unknown}"

# Parse findings.json if exists
total_findings=0
verified_count=0
correctable_count=0
stripped_count=0
dedup_count=0
if [[ -f "$evidence_file" ]]; then
	total_findings=$(jq -r '.total_findings // 0' "$evidence_file" 2>/dev/null || echo 0)
	verified_count=$(jq -r '.verified | length' "$evidence_file" 2>/dev/null || echo 0)
	correctable_count=$(jq -r '.correctable | length' "$evidence_file" 2>/dev/null || echo 0)
	stripped_count=$(jq -r '.stripped | length' "$evidence_file" 2>/dev/null || echo 0)
	dedup_count=$(jq -r '.duplicates_consolidated // 0' "$evidence_file" 2>/dev/null || echo 0)
fi

# LLM provenance — models used, to the extent the host recorded them.
# Orchestrator writes [{"role":"...","id":"..."}, ...] to models.json before
# rendering (see phases/report.md). Absent file means the host did not
# expose model identity — state that rather than inventing names.
models_file="$session_dir/models.json"
models_block=""
if [[ -f "$models_file" ]]; then
	# Dedup, preserving order: deep mode dispatches the same agent per
	# subsystem, so models.json may carry repeated role/id pairs. Under
	# pipefail a jq parse failure on malformed input would otherwise abort
	# the whole report (jq's exit code is the "last non-zero" in the pipe
	# even though awk/sed still exit 0) — `|| true` degrades to the
	# "not recorded" fallback below instead of aborting the render.
	models_block=$(jq -r '.[]? | "\(.role): \(.id)"' "$models_file" 2>/dev/null | awk 'NF && !seen[$0]++' | sed 's/^/- /' || true)
fi
if [[ -z "$models_block" ]]; then
	models_block="_Not recorded by the host — reviewer, validator, and coordinator model IDs were not exposed to the report renderer._"
fi

# Council verdict. The orchestrator decides it (phases/report.md, "Final
# Verdict Determination") and records it as the first line of verdict.txt; this
# script renders it. Keeping the render here rather than asking the
# orchestrator to append a section keeps SKILL.md's EXECUTION-CONTRACT intact —
# the model fills the markers this script emits and nothing else — and
# gives the report and the PR comment (rc-render-comment.sh) one shared source
# for the verdict, so the two can never disagree.
#
# Resolved before the header heredoc because the verdict leads the report
# (AGENTS.md Output Principle 1): the reader must reach the outcome before any
# table or detail dump.
verdict_file="$session_dir/verdict.txt"
council_verdict=""
if [[ -f "$verdict_file" ]]; then
	# `head` is the producer here, so this is not the `producer | head` shape
	# that takes SIGPIPE and, under this script's `set -euo pipefail`, would
	# abort the render (exit 141). Keep it that way if this line grows.
	council_verdict=$(head -n1 "$verdict_file" | tr -d '\r\n')
fi
if [[ -n "$council_verdict" ]]; then
	case "$council_verdict" in
	*"REQUEST CHANGES"*) verdict_emoji="🔴" ;;
	*"ADVISOR"*) verdict_emoji="🟡" ;;
	*) verdict_emoji="🟢" ;;
	esac
	council_verdict_line="$verdict_emoji **$council_verdict**"
else
	# Never infer a verdict from the findings here: a silent default would read
	# as a council decision that was never made, and APPROVE is the unsafe
	# direction to guess in.
	council_verdict_line="_Not recorded — the orchestrator did not write \`verdict.txt\` before rendering._"
fi

# Start rendering report. The TLDR marker is the one splice point that is never
# dropped: the one-line TL;DR is written to comment-summary.md at report.md
# Step 2, after this script has already run at Step 1, so the renderer cannot
# read it and can only anchor it.
cat <<EOF
# Review Council Report

> **This report was generated by an LLM, not a human reviewer.** It was
> produced by the Review Council automated agent panel. Findings are
> machine-generated, may contain errors, and are advisory input to human
> judgment, not a substitute for it.

**Models used** (to the best of the host's disclosure):

$models_block

## Council Verdict

$council_verdict_line

<!-- TLDR -->

## Session Information
- **Mode**: $mode
- **Branch**: $branch
- **Base**: $base
- **PR**: $pr_line
- **Session Directory**: $session_dir

## Discovery Summary
- **Agents discovered**: $agents_discovered
- **Agents absent**: $agents_absent
- **Changeset**: $changeset

EOF

# CI Status section if available
ci_status_file="$session_dir/ci-status.txt"
if [[ -f "$ci_status_file" ]]; then
	# Drop the `# UNTRUSTED` envelope rc-prepare.sh writes at the head of the
	# file. It exists to frame the content for a reviewer reading it inside a
	# prompt; here it would render as two H1s sitting alongside the report
	# title. Only an envelope starting at line 1 is stripped, and only up to
	# its terminating blank line, so a `#` line in a check summary survives.
	awk 'NR == 1 && /^# UNTRUSTED/ { skip = 1 }
	     skip && /^#/ { next }
	     skip && /^$/ { skip = 0; next }
	     { print }' "$ci_status_file"
	echo ""
fi

# Verification Summary
cat <<EOF
## Verification Summary
- **Total findings**: $total_findings
- **Verified**: $verified_count
- **Correctable**: $correctable_count
- **Stripped**: $stripped_count
- **Duplicates consolidated**: $dedup_count

EOF

# Anchor for the deep-mode subsystem tree (phases/report.md, "Subsystem
# Analysis"), which introduces the findings list. Emitted with no placeholder
# sentence, unlike the NARRATIVE and LEARNINGS markers below: this section is
# usually absent, and a bare marker left unspliced is invisible in rendered
# markdown, where "The LLM will add ..." would publish as content.
cat <<'EOF'
<!-- SUBSYSTEM-ANALYSIS -->

EOF

# Findings by Severity (from verified list)
if [[ -f "$evidence_file" ]] && [[ $verified_count -gt 0 ]]; then
	echo "## Findings by Severity"
	echo ""

	# Extract verified findings and group by severity
	for severity in CRITICAL HIGH MEDIUM LOW; do
		count=$(jq -r --arg sev "$severity" '[.verified[] | select(.severity == $sev)] | length' "$evidence_file" 2>/dev/null || echo 0)
		if [[ $count -gt 0 ]]; then
			echo "### $severity ($count)"
			echo ""
			# Cross-agent consolidation folds secondary findings into a surviving
			# primary and records each fold in provenance.consolidated_from. Emit
			# those folded angles as a sub-list under the primary so no reviewer's
			# perspective is silently dropped from the report.
			jq -r --arg sev "$severity" '
				.verified[] | select(.severity == $sev) |
				"- **\(.title // .description[0:60])** (\(.file), \(.agent))"
				+ (
					if ((.provenance.consolidated_from // []) | length) > 0 then
						"\n  Also flagged by:\n" +
						((.provenance.consolidated_from // []) | map("  - \(.agent) (\(.severity)): \(.angle) — \(.recommendation)") | join("\n"))
					else
						""
					end
				)
			' "$evidence_file" 2>/dev/null || true
			echo ""
		fi
	done
fi

# Per-agent verdict table
echo "## Per-Agent Verdicts"
echo ""
echo "| Agent | Verdict | Findings |"
echo "|-------|---------|----------|"

# Read the verdict map from findings.json: verdict verbatim, count from
# verified findings. Single source — table cannot disagree with the findings
# listed above.
verdict_map="$session_dir/verdicts/findings.json"
if [[ -f "$verdict_map" ]]; then
	agent_names=$(jq -r '.verdicts | keys[]' "$verdict_map" 2>/dev/null || true)
	while IFS= read -r agent_name; do
		[[ -n "$agent_name" ]] || continue
		verdict=$(jq -r --arg a "$agent_name" '.verdicts[$a] // "UNKNOWN"' "$verdict_map")
		finding_count=$(jq -r --arg a "$agent_name" '[.verified[] | select(.agent==$a)] | length' "$verdict_map")
		echo "| $agent_name | $verdict | $finding_count |"
	done <<<"$agent_names"
fi

echo ""

# The findings-context slot: sections that qualify the findings above without
# being findings themselves, so the reader has them before reaching the
# verdict. Each is anchored here because the EXECUTION-CONTRACT lets the
# orchestrator fill markers and nothing else — an unanchored section is one it
# has to either drop or hand-append, and both are defects. Bare markers, no
# placeholder prose, for the reason given at SUBSYSTEM-ANALYSIS above; every
# one of these sections is conditional on a phase having run.
#
# CI-COMMENTARY, not FORGE-CI-STATUS: the `## Forge CI Status` table is already
# script-rendered from ci-status.txt further up. A marker sharing that name
# reads as an invitation to paste the table a second time, which is how the
# file's `# UNTRUSTED` envelope reaches a maintainer-facing report.
cat <<'EOF'
<!-- MERGE-ADVISORIES -->

<!-- ACCEPTANCE-CRITERIA -->

<!-- DISPOSITION-OUTCOMES -->

<!-- CI-COMMENTARY -->

EOF

# Narrative and learnings markers
cat <<'EOF'
## Council Synthesis

<!-- NARRATIVE -->

The LLM will add narrative synthesis here based on the findings and verdicts above.

## Prior Learnings

<!-- LEARNINGS -->

The LLM will record false positives, validated patterns, and evidence quality feedback here.

EOF

# Source / issue-tracker footer. Override REVIEW_COUNCIL_REPO to point a
# fork's reports at its own repository.
repo_url="${REVIEW_COUNCIL_REPO:-https://github.com/lolables/lola-mod-review-council}"
cat <<EOF
---

_Produced by [Review Council]($repo_url). Found a problem with this review, or want the source? [Open an issue]($repo_url/issues) or browse the [repository]($repo_url)._
EOF

exit 0
