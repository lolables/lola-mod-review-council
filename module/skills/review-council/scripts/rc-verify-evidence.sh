#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=module/skills/review-council/scripts/rc-lib.sh
source "$(dirname "$0")/rc-lib.sh"

# ============================================================================
# Parse Input Arguments
# ============================================================================

if [[ $# -lt 1 ]]; then
	json_output "skip" "Usage: rc-verify-evidence.sh <session_dir>"
	exit 0
fi

session_dir="$1"

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
finding_count=0

# Append a parsed finding to the accumulator arrays.
# Checks that required fields are non-empty before saving.
save_finding() {
	local agent="$1" sev="$2" title="$3" file="$4" line="$5" evidence="$6"
	[[ -n "$title" && -n "$file" && -n "$evidence" ]] || return 0
	finding_agents+=("$agent")
	finding_severities+=("$sev")
	finding_titles+=("$title")
	finding_files+=("$file")
	finding_lines+=("$line")
	finding_evidences+=("$evidence")
	((finding_count++)) || true
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
	in_evidence=false

	while IFS= read -r line; do
		# Detect finding header: ### [SEVERITY] Title
		if [[ "$line" =~ ^###[[:space:]]\[([A-Z]+)\][[:space:]](.+)$ ]]; then
			in_evidence=false
			# Save previous finding if exists
			save_finding "$agent_name" "$current_severity" "$current_title" "$current_file" "$current_line" "$current_evidence"

			# Start new finding
			current_severity="${BASH_REMATCH[1]}"
			current_title="${BASH_REMATCH[2]}"
			current_file=""
			current_line=""
			current_evidence=""

		# Parse File field — handles :line, :line-line ranges, and bare paths
		elif [[ "$line" =~ ^\*\*File\*\*: ]]; then
			in_evidence=false
			if [[ "$line" =~ \`([^:\`]+):([0-9]+)(-[0-9]+)?\` ]]; then
				# path:line or path:line-line — capture start number only
				current_file="${BASH_REMATCH[1]}"
				current_line="${BASH_REMATCH[2]}"
			elif [[ "$line" =~ \`([^:\`]+)\` ]]; then
				# path with no line number
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
	save_finding "$agent_name" "$current_severity" "$current_title" "$current_file" "$current_line" "$current_evidence"

	# Check for format problems when this agent produced zero parseable findings
	agent_findings=$((finding_count - count_before))
	if [[ $agent_findings -eq 0 ]]; then
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

**File**: `path:line`
**Evidence**: `quoted code from the file`
**Description**: What is wrong
**Recommendation**: How to fix it

Re-write the verdict file(s) with the agent's verbatim output. Do NOT summarize, paraphrase, or reformat the agent's response. The verification pipeline parses these fields to confirm findings against source files.
REMEDIATION

	jq -n \
		--arg status "format_error" \
		--arg message "Agent(s) returned REQUEST CHANGES but verdict file(s) contain no parseable findings: ${agent_list}. The verdict was likely summarized or reformatted, destroying the structured format needed for verification." \
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

	# Check if file exists
	if [[ ! -f "$file" ]]; then
		stripped_indices+=("$i")
		stripped_reasons+=("FILE_NOT_FOUND")
		continue
	fi

	# Check if evidence quote exists in file using grep -F (exact match)
	if ! grep -qF "$evidence" "$file"; then
		# File exists but evidence not found -> correctable
		correctable_indices+=("$i")
		correctable_reasons+=("EVIDENCE_NOT_FOUND")
		continue
	fi

	# If line number specified, verify it's within +-5 lines
	if [[ -n "$line" ]]; then
		# Get the actual line number where evidence appears
		actual_line=$(grep -nF "$evidence" "$file" | head -1 | cut -d: -f1)

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
			--arg reason "$reason" \
			'. + [{agent: $agent, severity: $severity, title: $title, file: $file, line: $line, evidence: $evidence, reason: $reason}]'
	else
		echo "$arr" | jq \
			--arg agent "${finding_agents[$idx]}" \
			--arg severity "${finding_severities[$idx]}" \
			--arg title "${finding_titles[$idx]}" \
			--arg file "${finding_files[$idx]}" \
			--arg line "${finding_lines[$idx]}" \
			--arg evidence "${finding_evidences[$idx]}" \
			'. + [{agent: $agent, severity: $severity, title: $title, file: $file, line: $line, evidence: $evidence}]'
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
		((ci++)) || true
	done
fi

stripped_json="[]"
if [[ ${#stripped_indices[@]} -gt 0 ]]; then
	si=0
	for idx in "${stripped_indices[@]}"; do
		stripped_json=$(append_finding "$stripped_json" "$idx" "${stripped_reasons[$si]}")
		((si++)) || true
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
