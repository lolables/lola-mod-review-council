#!/usr/bin/env bash
set -euo pipefail

if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
  echo '{"status":"skip","message":"Bash 4+ is required. macOS ships Bash 3 — install a modern version: brew install bash"}'
  exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
  echo '{"status":"skip","message":"jq is required but not installed. Install it: apt-get install jq | brew install jq | dnf install jq"}'
  exit 0
fi

# JSON output helper
json_output() {
  jq -n \
    --arg status "$1" \
    --arg message "$2" \
    --argjson extra "${3:-{}}" \
    '$extra + {status: $status, message: $message}'
}

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
done < <(find "$session_dir/verdicts" -name "*.md" -type f -print0 2>/dev/null)

if [[ ${#verdict_files[@]} -eq 0 ]]; then
  json_output "nothing_to_do" "No verdict files found."
  exit 0
fi

# ============================================================================
# Parse Findings from Verdict Files
# ============================================================================

declare -a all_findings

for verdict_file in "${verdict_files[@]}"; do
  agent_name=$(basename "$verdict_file" .md)

  # Parse findings in the format:
  # ### [SEVERITY] Title
  # **File**: `path:line`
  # **Evidence**: `quote`
  # **Constraint**: ...
  # **Description**: ...
  # **Recommendation**: ...

  current_finding=""
  current_severity=""
  current_title=""
  current_file=""
  current_line=""
  current_evidence=""

  while IFS= read -r line; do
    # Detect finding header: ### [SEVERITY] Title
    if [[ "$line" =~ ^###[[:space:]]\[([A-Z]+)\][[:space:]](.+)$ ]]; then
      # Save previous finding if exists
      if [[ -n "$current_title" && -n "$current_file" && -n "$current_evidence" ]]; then
        all_findings+=("$agent_name|$current_severity|$current_title|$current_file|$current_line|$current_evidence")
      fi

      # Start new finding
      current_severity="${BASH_REMATCH[1]}"
      current_title="${BASH_REMATCH[2]}"
      current_file=""
      current_line=""
      current_evidence=""

    # Parse File field
    elif [[ "$line" =~ ^\*\*File\*\*:[[:space:]]*\`([^:]+):?([0-9]*)\` ]]; then
      current_file="${BASH_REMATCH[1]}"
      current_line="${BASH_REMATCH[2]}"

    # Parse Evidence field
    elif [[ "$line" =~ ^\*\*Evidence\*\*:[[:space:]]*\`(.+)\`$ ]]; then
      current_evidence="${BASH_REMATCH[1]}"
    fi
  done < "$verdict_file"

  # Save last finding
  if [[ -n "$current_title" && -n "$current_file" && -n "$current_evidence" ]]; then
    all_findings+=("$agent_name|$current_severity|$current_title|$current_file|$current_line|$current_evidence")
  fi
done

if [[ ${#all_findings[@]} -eq 0 ]]; then
  json_output "nothing_to_do" "No findings parsed from verdict files."
  exit 0
fi

# ============================================================================
# Verify Evidence for Each Finding
# ============================================================================

declare -a verified_findings=()
declare -a stripped_findings=()

for finding in "${all_findings[@]}"; do
  IFS='|' read -r agent severity title file line evidence <<< "$finding"

  # Check if file exists
  if [[ ! -f "$file" ]]; then
    stripped_findings+=("$finding|FILE_NOT_FOUND")
    continue
  fi

  # Check if evidence quote exists in file using grep -F (exact match)
  if ! grep -qF "$evidence" "$file"; then
    stripped_findings+=("$finding|EVIDENCE_NOT_FOUND")
    continue
  fi

  # If line number specified, verify it's within ±5 lines
  if [[ -n "$line" ]]; then
    # Get the actual line number where evidence appears
    actual_line=$(grep -nF "$evidence" "$file" | head -1 | cut -d: -f1)

    if [[ -n "$actual_line" ]]; then
      # Check if within ±5 lines
      lower=$((line - 5))
      upper=$((line + 5))
      [[ $lower -lt 1 ]] && lower=1

      if [[ $actual_line -lt $lower || $actual_line -gt $upper ]]; then
        stripped_findings+=("$finding|LINE_MISMATCH")
        continue
      fi
    fi
  fi

  # Finding verified
  verified_findings+=("$finding")
done

# ============================================================================
# Deduplication
# ============================================================================

declare -a deduplicated_findings=()

# Only deduplicate if there are verified findings
if [[ ${#verified_findings[@]} -gt 0 ]]; then
for finding in "${verified_findings[@]}"; do
  IFS='|' read -r agent severity title file line evidence <<< "$finding"

  is_duplicate=false

  for existing in "${deduplicated_findings[@]}"; do
    IFS='|' read -r ex_agent ex_severity ex_title ex_file ex_line ex_evidence <<< "$existing"

    # Check if same file and within ±5 lines
    if [[ "$file" == "$ex_file" ]]; then
      if [[ -n "$line" && -n "$ex_line" ]]; then
        line_diff=$((line - ex_line))
        line_diff=${line_diff#-}  # absolute value

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

  if [[ "$is_duplicate" == "false" ]]; then
    deduplicated_findings+=("$finding")
  fi
done
fi

# ============================================================================
# Write Detailed Results to evidence-check.json
# ============================================================================

mkdir -p "$session_dir/verdicts"

# Build JSON arrays using jq for proper escaping
verified_json="[]"
for finding in "${deduplicated_findings[@]}"; do
  IFS='|' read -r agent severity title file line evidence <<< "$finding"
  verified_json=$(echo "$verified_json" | jq \
    --arg agent "$agent" \
    --arg severity "$severity" \
    --arg title "$title" \
    --arg file "$file" \
    --arg line "$line" \
    --arg evidence "$evidence" \
    '. + [{agent: $agent, severity: $severity, title: $title, file: $file, line: $line, evidence: $evidence}]')
done

stripped_json="[]"
for finding in "${stripped_findings[@]}"; do
  IFS='|' read -r agent severity title file line evidence reason <<< "$finding"
  stripped_json=$(echo "$stripped_json" | jq \
    --arg agent "$agent" \
    --arg severity "$severity" \
    --arg title "$title" \
    --arg file "$file" \
    --arg reason "$reason" \
    '. + [{agent: $agent, severity: $severity, title: $title, file: $file, reason: $reason}]')
done

jq -n \
  --argjson verified "$verified_json" \
  --argjson stripped "$stripped_json" \
  '{verified: $verified, stripped: $stripped}' \
  > "$session_dir/verdicts/evidence-check.json"

# ============================================================================
# Output Summary JSON
# ============================================================================

verified_count=${#deduplicated_findings[@]}
stripped_count=${#stripped_findings[@]}

jq -n \
  --arg status "ok" \
  --arg message "Evidence verification complete. $verified_count verified, $stripped_count stripped." \
  --argjson verified "$verified_count" \
  --argjson stripped "$stripped_count" \
  '{status: $status, message: $message, verified: $verified, stripped: $stripped}'

exit 0
