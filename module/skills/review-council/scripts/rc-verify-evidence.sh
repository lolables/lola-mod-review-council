#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=module/skills/review-council/scripts/rc-lib.sh
source "$(dirname "$0")/rc-lib.sh"
rc_trap_errors # report script:line on any unhandled failure (never silent)

# ============================================================================
# Parse Input Arguments
# ============================================================================

if [[ $# -lt 1 ]]; then
	json_output "skip" "Usage: rc-verify-evidence.sh <session_dir>"
	exit 0
fi

session_dir="$1"

# Optional review root. When findings reference files that live under a
# materialized checkout (foreign-PR review), reads/greps are prefixed with
# this root. Default "." preserves legacy CWD-relative behavior.
review_root="${2:-${REVIEW_ROOT:-.}}"

# ============================================================================
# Validate Session Directory
# ============================================================================

if [[ ! -d "$session_dir" ]]; then
	json_output "nothing_to_do" "Session directory does not exist."
	exit 0
fi

if [[ ! -d "$session_dir/verdicts" ]]; then
	json_output "nothing_to_do" "No verdicts directory found."
	exit 0
fi

# ============================================================================
# Gather Verdict Files
# ============================================================================

verdict_files=()
while IFS= read -r -d '' file; do
	# Skip verification output files
	basename=$(basename "$file")
	if [[ "$basename" != "verification.txt" && "$basename" != "evidence-check.json" ]]; then
		verdict_files+=("$file")
	fi
done < <(find "$session_dir/verdicts" -name "*.md" -type f -print0 2>/dev/null || true)

if [[ ${#verdict_files[@]} -eq 0 ]]; then
	json_output "nothing_to_do" "No verdict files found."
	exit 0
fi

# ============================================================================
# Parse Findings from Verdict Files
# ============================================================================

declare -a finding_agents=()
declare -a finding_severities=()
declare -a finding_titles=()
declare -a finding_files=()
declare -a finding_lines=()
declare -a finding_evidences=()
declare -a finding_details=()
finding_count=0

# Append a parsed finding to the accumulator arrays.
# Checks that required fields are non-empty before saving.
save_finding() {
	local agent="$1" sev="$2" title="$3" file="$4" line="$5" evidence="$6" detail="$7"
	[[ -n "$title" && -n "$file" && -n "$evidence" ]] || return 0
	finding_agents+=("$agent")
	finding_severities+=("$sev")
	finding_titles+=("$title")
	finding_files+=("$file")
	finding_lines+=("$line")
	finding_evidences+=("$evidence")
	finding_details+=("$detail")
	finding_count=$((finding_count + 1))
}

declare -a format_error_agents=()
declare -a format_error_files=()
declare -a format_warning_agents=()
declare -a format_warning_files=()

for verdict_file in "${verdict_files[@]}"; do
	agent_name=$(basename "$verdict_file" .md)
	count_before=$finding_count

	# Parse findings in the format:
	# ### [SEVERITY] Title
	# **File**: `path:line` or `path:line-line`
	# **Evidence**: inline text, `backtick-wrapped`, or multi-line code block
	# **Constraint**: ...
	# **Description**: ...
	# **Recommendation**: ...

	current_severity=""
	current_title=""
	current_file=""
	current_line=""
	current_evidence=""
	current_detail=""
	in_evidence=false
	in_body=false

	while IFS= read -r line; do
		# Capture the full verbatim finding body into current_detail FIRST, before
		# any field branch can `continue` past it — so fenced-evidence lines (incl.
		# the opening fence) land in detail intact. The header line is excluded;
		# capture stops at a boundary (horizontal rule, a `## ` section header, or
		# a verdict declaration) so trailing verdict/notes never bleed in.
		if [[ "$line" =~ ^###[[:space:]]\[[A-Z]+\] ]]; then
			:
		elif [[ "$line" =~ ^-{3,}[[:space:]]*$ || "$line" =~ ^##[[:space:]] || "$line" =~ ^[[:space:]]*\*{0,2}Verdict\*{0,2}: ]]; then
			in_body=false
		elif [[ "$in_body" == true ]]; then
			current_detail+="$line"$'\n'
		fi

		# Detect finding header: ### [SEVERITY] Title
		if [[ "$line" =~ ^###[[:space:]]\[([A-Z]+)\][[:space:]](.+)$ ]]; then
			in_evidence=false
			# Save previous finding if exists
			save_finding "$agent_name" "$current_severity" "$current_title" "$current_file" "$current_line" "$current_evidence" "$current_detail"

			# Start new finding
			current_severity="${BASH_REMATCH[1]}"
			current_title="${BASH_REMATCH[2]}"
			current_file=""
			current_line=""
			current_evidence=""
			current_detail=""
			in_body=true
			continue

		# Parse File field. Reviewers write this line many ways: backticked
		# `path:line`, a bare path with trailing prose, several paths, or a
		# path mixed with backticked function names. Extract the FIRST real
		# file token — one bearing a filename extension — with an optional
		# :line, ignoring backticks, prose, and non-path tokens. Fall back to
		# the legacy backticked forms for extensionless files (Makefile, etc.).
		elif [[ "$line" =~ ^\*\*File\*\*: ]]; then
			in_evidence=false
			if [[ "$line" =~ ([A-Za-z0-9_./-]+\.[A-Za-z0-9]+):([0-9]+) ]]; then
				# first path-with-extension bearing a :line
				current_file="${BASH_REMATCH[1]}"
				current_line="${BASH_REMATCH[2]}"
			elif [[ "$line" =~ ([A-Za-z0-9_./-]+\.[A-Za-z0-9]+) ]]; then
				# first path-with-extension, no line
				current_file="${BASH_REMATCH[1]}"
				current_line=""
			elif [[ "$line" =~ \`([^:\`]+):([0-9]+)(-[0-9]+)?\` ]]; then
				# legacy: backticked extensionless path:line
				current_file="${BASH_REMATCH[1]}"
				current_line="${BASH_REMATCH[2]}"
			elif [[ "$line" =~ \`([^\`]+)\` ]]; then
				# legacy: backticked extensionless path, no line
				current_file="${BASH_REMATCH[1]}"
				current_line=""
			fi

		# Start Evidence field — handles inline backtick, bare text, or empty (multi-line follows)
		elif [[ "$line" =~ ^\*\*Evidence\*\*:[[:space:]]*(.*) ]]; then
			raw="${BASH_REMATCH[1]}"
			# Try to extract first backtick-delimited segment
			if [[ "$raw" =~ \`([^\`]+)\` ]]; then
				current_evidence="${BASH_REMATCH[1]}"
				in_evidence=false
			elif [[ -n "$raw" && ! "$raw" =~ ^[[:space:]]*$ ]]; then
				# Bare text after the label
				current_evidence="$raw"
				in_evidence=false
			else
				# No inline content — evidence starts on subsequent lines
				current_evidence=""
				in_evidence=true
			fi

		# Known field markers end evidence accumulation
		elif [[ "$line" =~ ^\*\*(Constraint|Description|Recommendation|Impact|Suggestion|Severity|Explanation)\*\*: ]]; then
			in_evidence=false

		# Accumulate multi-line evidence (first non-fence, non-empty line wins)
		elif [[ "$in_evidence" == true && -z "$current_evidence" ]]; then
			# Skip code fence markers and blank lines
			if [[ "$line" =~ ^\`\`\` || -z "$line" ]]; then
				continue
			fi
			# Strip leading/trailing backticks from the line
			stripped="${line#\`}"
			stripped="${stripped%\`}"
			stripped="${stripped#"${stripped%%[![:space:]]*}"}"
			if [[ -n "$stripped" ]]; then
				current_evidence="$stripped"
				in_evidence=false
			fi
		fi
	done <"$verdict_file"

	# Save last finding
	in_evidence=false
	save_finding "$agent_name" "$current_severity" "$current_title" "$current_file" "$current_line" "$current_evidence" "$current_detail"

	# Check for format problems. A finding block that failed to parse is a
	# SILENT DROP — the agent wrote a `### [SEVERITY]` header but its File/Evidence
	# did not parse into a finding. Detect it by comparing headers to findings
	# parsed from this agent; if any header did not become a finding, flag the
	# agent for correction regardless of its APPROVE/REQUEST CHANGES verdict.
	agent_findings=$((finding_count - count_before))
	header_count=$(grep -cE '^###[[:space:]]\[[A-Z]+\][[:space:]]' "$verdict_file" 2>/dev/null || true)
	if [[ "$header_count" -gt "$agent_findings" ]]; then
		# Unparseable finding block(s): headers without a parseable finding.
		format_error_agents+=("$agent_name")
		format_error_files+=("$verdict_file")
	elif [[ $agent_findings -eq 0 ]]; then
		if grep -q 'REQUEST CHANGES' "$verdict_file"; then
			format_error_agents+=("$agent_name")
			format_error_files+=("$verdict_file")
		elif grep -q 'APPROVE' "$verdict_file"; then
			if grep -vE '^###' "$verdict_file" | grep -qE '\b(CRITICAL|HIGH|MEDIUM|LOW)\b'; then
				format_warning_agents+=("$agent_name")
				format_warning_files+=("$verdict_file")
			fi
		fi
	fi
done

# ============================================================================
# Format Validation
# ============================================================================

if [[ ${#format_error_agents[@]} -gt 0 ]]; then
	error_json="[]"
	for ((i = 0; i < ${#format_error_agents[@]}; i++)); do
		error_json=$(echo "$error_json" | jq \
			--arg agent "${format_error_agents[$i]}" \
			--arg file "${format_error_files[$i]}" \
			'. + [{agent: $agent, file: $file}]')
	done

	mkdir -p "$session_dir/verdicts"
	jq -n --argjson format_errors "$error_json" \
		'{format_errors: $format_errors}' \
		>"$session_dir/verdicts/evidence-check.json"

	agent_list=$(printf '%s, ' "${format_error_agents[@]}")
	agent_list="${agent_list%, }"

	read -r -d '' remediation <<'REMEDIATION' || true
Each finding must use this exact structure:

### [SEVERITY] Title

**File**: `path/to/file.ext:line`
**Evidence**: `quoted code from the file`
**Description**: What is wrong
**Recommendation**: How to fix it

The **File** line must be exactly ONE backticked repo-relative `path:line` (or `path`) and nothing else — no prose, no second path, no function names, no parentheticals. Put ranges and cross-references in Description. Re-emit the verdict verbatim with each finding in this structure. Do NOT summarize or reformat. The verification pipeline parses these fields to confirm findings against source files; a finding block it cannot parse is dropped.
REMEDIATION

	jq -n \
		--arg status "format_error" \
		--arg message "Verdict file(s) contain finding blocks the pipeline could not parse (a header without a parseable File/Evidence is a silent drop), or returned REQUEST CHANGES with no parseable findings: ${agent_list}. The affected agent(s) must re-emit each finding in the exact structured format." \
		--arg remediation "$remediation" \
		--argjson format_errors "$error_json" \
		'{status: $status, message: $message, remediation: $remediation, format_errors: $format_errors}'

	exit 0
fi

warning_json="[]"
if [[ ${#format_warning_agents[@]} -gt 0 ]]; then
	for ((i = 0; i < ${#format_warning_agents[@]}; i++)); do
		warning_json=$(echo "$warning_json" | jq \
			--arg agent "${format_warning_agents[$i]}" \
			--arg file "${format_warning_files[$i]}" \
			'. + [{agent: $agent, file: $file, reason: "Verdict contains APPROVE with no structured findings, but mentions severity levels (CRITICAL/HIGH/MEDIUM/LOW) in the body. The agent may have described issues in prose without structuring them. Consider re-examining the verdict."}]')
	done
fi

if [[ $finding_count -eq 0 ]]; then
	if [[ "$warning_json" != "[]" ]]; then
		jq -n \
			--arg status "nothing_to_do" \
			--arg message "No findings parsed from verdict files." \
			--argjson format_warnings "$warning_json" \
			'{status: $status, message: $message, format_warnings: $format_warnings}'
	else
		json_output "nothing_to_do" "No findings parsed from verdict files."
	fi
	exit 0
fi

# ============================================================================
# Verify Evidence for Each Finding
# ============================================================================

declare -a verified_indices=()
declare -a correctable_indices=()
declare -a correctable_reasons=()
declare -a stripped_indices=()
declare -a stripped_reasons=()

for ((i = 0; i < finding_count; i++)); do
	file="${finding_files[$i]}"
	line="${finding_lines[$i]}"
	evidence="${finding_evidences[$i]}"

	# Resolve the on-disk path (prefix with review_root unless it is ".").
	# The stored finding path ($file) stays repo-relative for reporting.
	if [[ "$review_root" == "." ]]; then
		fpath="$file"
	else
		fpath="${review_root%/}/$file"
	fi

	# Check if file exists
	if [[ ! -f "$fpath" ]]; then
		stripped_indices+=("$i")
		stripped_reasons+=("FILE_NOT_FOUND")
		continue
	fi

	# Check if evidence quote exists in file using grep -F (exact match)
	if ! grep -qF "$evidence" "$fpath"; then
		# File exists but evidence not found -> correctable
		correctable_indices+=("$i")
		correctable_reasons+=("EVIDENCE_NOT_FOUND")
		continue
	fi

	# If line number specified, verify it's within +-5 lines
	if [[ -n "$line" ]]; then
		# Get the actual line number where evidence appears
		actual_line=$(grep -nF "$evidence" "$fpath" | head -1 | cut -d: -f1)

		if [[ -n "$actual_line" ]]; then
			# Check if within +-5 lines
			lower=$((line - 5))
			upper=$((line + 5))
			[[ $lower -lt 1 ]] && lower=1

			if [[ $actual_line -lt $lower || $actual_line -gt $upper ]]; then
				# Evidence found in file but at wrong line -> correctable
				correctable_indices+=("$i")
				correctable_reasons+=("LINE_MISMATCH")
				continue
			fi
		fi
	fi

	# Finding verified
	verified_indices+=("$i")
done

# ============================================================================
# Deduplication
# ============================================================================

declare -a deduplicated_indices=()

# Only deduplicate if there are verified findings
if [[ ${#verified_indices[@]} -gt 0 ]]; then
	for idx in "${verified_indices[@]}"; do
		file="${finding_files[$idx]}"
		line="${finding_lines[$idx]}"
		evidence="${finding_evidences[$idx]}"

		is_duplicate=false

		if [[ ${#deduplicated_indices[@]} -gt 0 ]]; then
			for ex_idx in "${deduplicated_indices[@]}"; do
				ex_file="${finding_files[$ex_idx]}"
				ex_line="${finding_lines[$ex_idx]}"
				ex_evidence="${finding_evidences[$ex_idx]}"

				# Check if same file and within +-5 lines
				if [[ "$file" == "$ex_file" ]]; then
					if [[ -n "$line" && -n "$ex_line" ]]; then
						line_diff=$((line - ex_line))
						line_diff=${line_diff#-} # absolute value

						if [[ $line_diff -le 5 ]]; then
							# Same issue if evidence is similar (basic heuristic)
							if [[ "$evidence" == "$ex_evidence" ]]; then
								is_duplicate=true
								break
							fi
						fi
					else
						# No line numbers, check if evidence matches
						if [[ "$evidence" == "$ex_evidence" ]]; then
							is_duplicate=true
							break
						fi
					fi
				fi
			done
		fi

		if [[ "$is_duplicate" == "false" ]]; then
			deduplicated_indices+=("$idx")
		fi
	done
fi

# ============================================================================
# Write Detailed Results to evidence-check.json
# ============================================================================

mkdir -p "$session_dir/verdicts"

# Append a finding to a JSON array, producing the updated array on stdout.
# Usage: json_arr=$(append_finding "$json_arr" idx [reason])
# Includes line/evidence fields when reason is empty; includes reason when set.
append_finding() {
	local arr="$1" idx="$2" reason="${3:-}"
	if [[ -n "$reason" ]]; then
		echo "$arr" | jq \
			--arg agent "${finding_agents[$idx]}" \
			--arg severity "${finding_severities[$idx]}" \
			--arg title "${finding_titles[$idx]}" \
			--arg file "${finding_files[$idx]}" \
			--arg line "${finding_lines[$idx]}" \
			--arg evidence "${finding_evidences[$idx]}" \
			--arg detail "${finding_details[$idx]}" \
			--arg reason "$reason" \
			'. + [{agent: $agent, severity: $severity, title: $title, file: $file, line: $line, evidence: $evidence, detail: $detail, reason: $reason}]'
	else
		echo "$arr" | jq \
			--arg agent "${finding_agents[$idx]}" \
			--arg severity "${finding_severities[$idx]}" \
			--arg title "${finding_titles[$idx]}" \
			--arg file "${finding_files[$idx]}" \
			--arg line "${finding_lines[$idx]}" \
			--arg evidence "${finding_evidences[$idx]}" \
			--arg detail "${finding_details[$idx]}" \
			'. + [{agent: $agent, severity: $severity, title: $title, file: $file, line: $line, evidence: $evidence, detail: $detail}]'
	fi
}

# Build JSON arrays using jq for proper escaping
verified_json="[]"
if [[ ${#deduplicated_indices[@]} -gt 0 ]]; then
	for idx in "${deduplicated_indices[@]}"; do
		verified_json=$(append_finding "$verified_json" "$idx")
	done
fi

correctable_json="[]"
if [[ ${#correctable_indices[@]} -gt 0 ]]; then
	ci=0
	for idx in "${correctable_indices[@]}"; do
		correctable_json=$(append_finding "$correctable_json" "$idx" "${correctable_reasons[$ci]}")
		ci=$((ci + 1))
	done
fi

stripped_json="[]"
if [[ ${#stripped_indices[@]} -gt 0 ]]; then
	si=0
	for idx in "${stripped_indices[@]}"; do
		stripped_json=$(append_finding "$stripped_json" "$idx" "${stripped_reasons[$si]}")
		si=$((si + 1))
	done
fi

# Count duplicates
duplicates_consolidated=$((${#verified_indices[@]} - ${#deduplicated_indices[@]}))
total_findings=$finding_count

if [[ "$warning_json" != "[]" ]]; then
	jq -n \
		--argjson verified "$verified_json" \
		--argjson correctable "$correctable_json" \
		--argjson stripped "$stripped_json" \
		--argjson total_findings "$total_findings" \
		--argjson duplicates_consolidated "$duplicates_consolidated" \
		--argjson format_warnings "$warning_json" \
		'{verified: $verified, correctable: $correctable, stripped: $stripped, total_findings: $total_findings, duplicates_consolidated: $duplicates_consolidated, format_warnings: $format_warnings}' \
		>"$session_dir/verdicts/evidence-check.json"
else
	jq -n \
		--argjson verified "$verified_json" \
		--argjson correctable "$correctable_json" \
		--argjson stripped "$stripped_json" \
		--argjson total_findings "$total_findings" \
		--argjson duplicates_consolidated "$duplicates_consolidated" \
		'{verified: $verified, correctable: $correctable, stripped: $stripped, total_findings: $total_findings, duplicates_consolidated: $duplicates_consolidated}' \
		>"$session_dir/verdicts/evidence-check.json"
fi

# ============================================================================
# Output Summary JSON
# ============================================================================

verified_count=${#deduplicated_indices[@]}
correctable_count=${#correctable_indices[@]}
stripped_count=${#stripped_indices[@]}

if [[ "$warning_json" != "[]" ]]; then
	jq -n \
		--arg status "ok" \
		--arg message "Evidence verification complete. $verified_count verified, $correctable_count correctable, $stripped_count stripped." \
		--argjson verified "$verified_count" \
		--argjson correctable "$correctable_count" \
		--argjson stripped "$stripped_count" \
		--argjson format_warnings "$warning_json" \
		'{status: $status, message: $message, verified: $verified, correctable: $correctable, stripped: $stripped, format_warnings: $format_warnings}'
else
	jq -n \
		--arg status "ok" \
		--arg message "Evidence verification complete. $verified_count verified, $correctable_count correctable, $stripped_count stripped." \
		--argjson verified "$verified_count" \
		--argjson correctable "$correctable_count" \
		--argjson stripped "$stripped_count" \
		'{status: $status, message: $message, verified: $verified, correctable: $correctable, stripped: $stripped}'
fi

exit 0
