#!/usr/bin/env bash
set -uo pipefail

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

# Error trap: always output valid JSON
# trap 'json_output "skip" "Unexpected error in rc-prepare.sh. Review session was not created."; exit 1' ERR

# ============================================================================
# SECTION 0: Parse Input Arguments
# ============================================================================

mode_override=""
input_type=""
input_value=""

# Extract mode override if first arg is "code" or "specs"
if [[ $# -gt 0 ]] && [[ "$1" == "code" || "$1" == "specs" ]]; then
  mode_override="$1"
  shift
fi

# Classify remaining arguments
if [[ $# -eq 0 ]]; then
  input_type="auto"
elif [[ "$*" =~ :// ]]; then
  input_type="url"
  input_value="$*"
elif [[ "$*" =~ \.\. ]]; then
  input_type="ref_range"
  input_value="$*"
elif [[ "$*" =~ ^[0-9]+$ ]]; then
  input_type="pr_number"
  input_value="$*"
else
  json_output "skip" "Unrecognized input format: $*"
  exit 0
fi

# ============================================================================
# SECTION 1: Verify Git Repository
# ============================================================================

if ! git rev-parse --git-dir >/dev/null 2>&1; then
  json_output "skip" "Not a git repository. Please specify the review mode explicitly."
  exit 0
fi

# ============================================================================
# SECTION 2: Detect Forge
# ============================================================================

forge="local"
forge_owner=""
forge_repo=""

if [[ "$input_type" == "url" ]]; then
  if echo "$input_value" | grep -q "github.com"; then
    forge="github"
    # Parse owner/repo from URL: https://github.com/owner/repo/pull/N
    forge_owner=$(echo "$input_value" | sed -E 's|.*github\.com/([^/]+)/([^/]+)/.*|\1|')
    forge_repo=$(echo "$input_value" | sed -E 's|.*github\.com/([^/]+)/([^/]+)/.*|\2|')
    # Validate owner/repo contain only safe characters
    if [[ ! "$forge_owner" =~ ^[a-zA-Z0-9._-]+$ ]] || [[ ! "$forge_repo" =~ ^[a-zA-Z0-9._-]+$ ]]; then
      forge_owner=""
      forge_repo=""
      forge="local"
    fi
    # Extract PR number from URL
    input_value=$(echo "$input_value" | sed -E 's|.*/pull/([0-9]+).*|\1|')
  elif echo "$input_value" | grep -q "gitlab.com"; then
    forge="gitlab"
    forge_owner=$(echo "$input_value" | sed -E 's|.*gitlab\.com/([^/]+)/([^/]+)/.*|\1|')
    forge_repo=$(echo "$input_value" | sed -E 's|.*gitlab\.com/([^/]+)/([^/]+)/.*|\2|')
    # Validate owner/repo contain only safe characters
    if [[ ! "$forge_owner" =~ ^[a-zA-Z0-9._-]+$ ]] || [[ ! "$forge_repo" =~ ^[a-zA-Z0-9._-]+$ ]]; then
      forge_owner=""
      forge_repo=""
      forge="local"
    fi
    input_value=$(echo "$input_value" | sed -E 's|.*/merge_requests/([0-9]+).*|\1|')
  fi
else
  remote_url=$(git remote get-url origin 2>/dev/null || echo "")
  if echo "$remote_url" | grep -q "github.com"; then
    forge="github"
    # Parse owner/repo from git URL
    forge_owner=$(echo "$remote_url" | sed -E 's|.*github\.com[:/]([^/]+)/([^/]+)(\.git)?|\1|')
    forge_repo=$(echo "$remote_url" | sed -E 's|.*github\.com[:/]([^/]+)/([^/]+)(\.git)?|\2|')
  elif echo "$remote_url" | grep -q "gitlab.com"; then
    forge="gitlab"
    forge_owner=$(echo "$remote_url" | sed -E 's|.*gitlab\.com[:/]([^/]+)/([^/]+)(\.git)?|\1|')
    forge_repo=$(echo "$remote_url" | sed -E 's|.*gitlab\.com[:/]([^/]+)/([^/]+)(\.git)?|\2|')
  fi
fi

# ============================================================================
# SECTION 3: Detect Forge Tooling
# ============================================================================

forge_tool="none"
if [[ "$forge" == "github" ]] && command -v gh >/dev/null 2>&1; then
  forge_tool="gh"
elif [[ "$forge" == "gitlab" ]] && command -v glab >/dev/null 2>&1; then
  forge_tool="glab"
fi

# ============================================================================
# SECTION 4: Determine Base Branch
# ============================================================================

base_branch=""
if git rev-parse --verify main >/dev/null 2>&1; then
  base_branch="main"
elif git rev-parse --verify master >/dev/null 2>&1; then
  base_branch="master"
else
  json_output "skip" "Cannot determine base branch (main and master both not found)."
  exit 0
fi

# ============================================================================
# SECTION 5: Create Session Directory
# ============================================================================

project_id=$(pwd 2>/dev/null | sha256sum 2>/dev/null | head -c 12) || project_id="unknown"
run_id=$(date +%Y%m%d-%H%M%S 2>/dev/null) || run_id="unknown"
session_dir="${XDG_CACHE_HOME:-$HOME/.cache}/review-council/${project_id}/${run_id}"

if ! mkdir -p "${session_dir}/verdicts" 2>/dev/null; then
  json_output "skip" "Cannot create session directory at ${session_dir}. Check permissions and disk space."
  exit 0
fi

# ============================================================================
# SECTION 6: Fetch PR Metadata (if applicable)
# ============================================================================

pr_number=""
pr_title=""
pr_base=""
pr_head=""
pr_url=""
pr_state=""
pr_body=""
pr_status_checks=""

if [[ "$input_type" == "pr_number" ]] || [[ "$input_type" == "url" ]]; then
  pr_number="$input_value"

  if [[ "$forge_tool" != "none" ]]; then
    if [[ "$forge" == "github" ]]; then
      repo_flag=""
      [[ -n "$forge_owner" ]] && [[ -n "$forge_repo" ]] && repo_flag="--repo ${forge_owner}/${forge_repo}"

      pr_json=$(timeout 30 gh pr view "$pr_number" $repo_flag \
        --json number,title,body,baseRefName,headRefName,url,state,statusCheckRollup 2>/dev/null || echo "")

      if [[ -n "$pr_json" ]]; then
        pr_title=$(echo "$pr_json" | jq -r '.title // ""')
        pr_body=$(echo "$pr_json" | jq -r '.body // ""')
        pr_base=$(echo "$pr_json" | jq -r '.baseRefName // ""')
        pr_head=$(echo "$pr_json" | jq -r '.headRefName // ""')
        pr_url=$(echo "$pr_json" | jq -r '.url // ""')
        pr_state=$(echo "$pr_json" | jq -r '.state // ""')

        # Extract status checks
        pr_status_checks=$(echo "$pr_json" | jq -r '
          .statusCheckRollup[]? |
          select(.context != null and .conclusion != null) |
          "\(.context): \(.conclusion)"
        ')
      fi
    elif [[ "$forge" == "gitlab" ]]; then
      pr_json=$(timeout 30 glab mr view "$pr_number" --output json 2>/dev/null || echo "")

      if [[ -n "$pr_json" ]]; then
        pr_title=$(echo "$pr_json" | jq -r '.title // ""')
        pr_body=$(echo "$pr_json" | jq -r '.description // ""')
        pr_base=$(echo "$pr_json" | jq -r '.target_branch // ""')
        pr_head=$(echo "$pr_json" | jq -r '.source_branch // ""')
        pr_url=$(echo "$pr_json" | jq -r '.web_url // ""')
        pr_state=$(echo "$pr_json" | jq -r '.state // ""')
      fi
    fi

    # Write pr-metadata.txt
    if [[ -n "$pr_title" ]]; then
      {
        echo "number: $pr_number"
        echo "title: $pr_title"
        echo "base: $pr_base"
        echo "head: $pr_head"
        echo "url: $pr_url"
        echo "state: $pr_state"
        echo ""
        echo "--- BODY ---"
        echo "$pr_body"
        echo "--- END BODY ---"

        if [[ -n "$pr_status_checks" ]]; then
          echo ""
          echo "--- STATUS CHECKS ---"
          echo "$pr_status_checks"
          echo "--- END STATUS CHECKS ---"
        fi
      } > "${session_dir}/pr-metadata.txt"
    fi
  fi
fi

# ============================================================================
# SECTION 7: Determine Review Mode
# ============================================================================

mode="code"
mode_reason="default"

if [[ -n "$mode_override" ]]; then
  if [[ "$mode_override" == "specs" ]]; then
    mode="spec"
    mode_reason="explicit override"
  else
    mode="code"
    mode_reason="explicit override"
  fi
else
  # Auto-detect mode
  changeset_for_mode_detection=""

  if [[ -f "${session_dir}/pr-metadata.txt" ]] && [[ "$forge_tool" != "none" ]]; then
    # Use PR diff for mode detection
    if [[ "$forge" == "github" ]]; then
      repo_flag=""
      [[ -n "$forge_owner" ]] && [[ -n "$forge_repo" ]] && repo_flag="--repo ${forge_owner}/${forge_repo}"
      changeset_for_mode_detection=$(timeout 30 gh pr diff "$pr_number" $repo_flag 2>/dev/null | \
        grep '^diff --git' | sed -E 's|^diff --git a/(.*) b/.*|\1|' || echo "")
    elif [[ "$forge" == "gitlab" ]]; then
      changeset_for_mode_detection=$(timeout 30 glab mr diff "$pr_number" 2>/dev/null | \
        grep '^diff --git' | sed -E 's|^diff --git a/(.*) b/.*|\1|' || echo "")
    fi
  else
    # Use local git diff
    changeset_for_mode_detection=$(git diff --name-only "${base_branch}...HEAD" 2>/dev/null || echo "")
  fi

  # Check if changeset is empty first
  if [[ -z "$changeset_for_mode_detection" ]]; then
    # Empty changeset - check for spec artifacts to decide mode
    has_specs=false
    for dir in specs docs/specs docs/design docs/superpowers design; do
      if [[ -d "$dir" ]] && find "$dir" -type f \( -name "*.md" -o -name "*.txt" \) -print -quit 2>/dev/null | grep -q .; then
        has_specs=true
        break
      fi
    done

    if $has_specs; then
      mode="spec"
      mode_reason="no changes, spec artifacts present"
    else
      mode="code"
      mode_reason="no changes, no spec artifacts"
    fi
  else
    # Classify files
    spec_files=0
    code_files=0

    while IFS= read -r file; do
      [[ -z "$file" ]] && continue

      if [[ "$file" =~ ^(specs|docs/specs|docs/design|docs/superpowers|design)/ ]] || \
         [[ "$file" =~ (spec|plan|tasks|design|research)\.md$ ]]; then
        ((spec_files++))
      else
        ((code_files++))
      fi
    done <<< "$changeset_for_mode_detection"

    if [[ $code_files -gt 0 ]]; then
      mode="code"
      mode_reason="code files changed"
    else
      mode="spec"
      mode_reason="only spec files changed"
    fi
  fi
fi

# ============================================================================
# SECTION 8: Discover Agents
# ============================================================================

if [[ -z "${AGENTS_DIR:-}" ]]; then
  json_output "skip" "AGENTS_DIR environment variable not set."
  exit 0
fi

agents=()
suffix="code"
[[ "$mode" == "spec" ]] && suffix="spec"

for agent_file in "${AGENTS_DIR}"/divisor-*-${suffix}.md; do
  [[ -f "$agent_file" ]] || continue
  agent_name=$(basename "$agent_file" ".md")
  agents+=("$agent_name")
done

if [[ ${#agents[@]} -eq 0 ]]; then
  json_output "skip" "No ${mode} reviewer agents found in ${AGENTS_DIR}."
  exit 0
fi

# ============================================================================
# SECTION 9: Capture Changeset and Diff
# ============================================================================

changeset_files=""
diff_content=""

if [[ "$mode" == "code" ]]; then
  if [[ -f "${session_dir}/pr-metadata.txt" ]] && [[ "$forge_tool" != "none" ]]; then
    # Fetch PR diff
    if [[ "$forge" == "github" ]]; then
      repo_flag=""
      [[ -n "$forge_owner" ]] && [[ -n "$forge_repo" ]] && repo_flag="--repo ${forge_owner}/${forge_repo}"
      diff_content=$(timeout 30 gh pr diff "$pr_number" $repo_flag 2>/dev/null || echo "")
      changeset_files=$(echo "$diff_content" | grep '^diff --git' | sed -E 's|^diff --git a/(.*) b/.*|\1|' || echo "")
    elif [[ "$forge" == "gitlab" ]]; then
      diff_content=$(timeout 30 glab mr diff "$pr_number" 2>/dev/null || echo "")
      changeset_files=$(echo "$diff_content" | grep '^diff --git' | sed -E 's|^diff --git a/(.*) b/.*|\1|' || echo "")
    fi
  elif [[ "$input_type" == "ref_range" ]]; then
    changeset_files=$(git diff --name-only "$input_value" -- 2>/dev/null || echo "")
    diff_content=$(git diff "$input_value" -- 2>/dev/null || echo "")
  else
    # Local repo: base...HEAD + uncommitted
    changeset_files=$(git diff --name-only "${base_branch}...HEAD" 2>/dev/null || echo "")
    changeset_files+=$'\n'$(git diff --name-only 2>/dev/null || echo "")
    diff_content=$(git diff "${base_branch}...HEAD" 2>/dev/null || echo "")
    diff_content+=$'\n'$(git diff 2>/dev/null || echo "")
  fi

  # Remove empty lines and duplicates
  changeset_files=$(echo "$changeset_files" | grep -v '^$' | sort -u || echo "")

  if [[ -z "$changeset_files" ]]; then
    json_output "empty" "No changes to review. Changeset is empty."
    exit 0
  fi

  echo "$changeset_files" > "${session_dir}/changeset.txt"
  echo "$diff_content" > "${session_dir}/diff.patch"
else
  # Spec mode: scan common locations
  for dir in specs docs/specs docs/design docs/superpowers design; do
    if [[ -d "$dir" ]]; then
      while IFS= read -r file; do
        [[ -f "$file" ]] && changeset_files+="${file}"$'\n'
      done < <(find "$dir" -type f \( -name "*.md" -o -name "*.txt" \) 2>/dev/null)
    fi
  done

  changeset_files=$(echo "$changeset_files" | grep -v '^$' | sort -u || echo "")

  if [[ -z "$changeset_files" ]]; then
    json_output "empty" "No spec artifacts found to review."
    exit 0
  fi

  echo "$changeset_files" > "${session_dir}/changeset.txt"
fi

# ============================================================================
# SECTION 10: Detect Language and Framework
# ============================================================================

language="unknown"
framework="unknown"

# Count file extensions
declare -A ext_count
while IFS= read -r file; do
  [[ -z "$file" ]] && continue
  ext="${file##*.}"
  [[ "$ext" == "$file" ]] && continue  # No extension
  ext_count[$ext]=$((${ext_count[$ext]:-0} + 1))
done <<< "$changeset_files"

# Determine language
max_count=0
for ext in "${!ext_count[@]}"; do
  count=${ext_count[$ext]}
  if [[ $count -gt $max_count ]]; then
    max_count=$count
    case "$ext" in
      go) language="go" ;;
      ts|tsx) language="typescript" ;;
      js|jsx) language="javascript" ;;
      py) language="python" ;;
      rs) language="rust" ;;
      java) language="java" ;;
    esac
  fi
done

# Detect framework
if echo "$changeset_files" | grep -q "package.json"; then
  if [[ -f "package.json" ]]; then
    if grep -q '"react"' package.json 2>/dev/null; then
      framework="react"
    elif grep -q '"vue"' package.json 2>/dev/null; then
      framework="vue"
    elif grep -q '"angular"' package.json 2>/dev/null; then
      framework="angular"
    fi
  fi
elif echo "$changeset_files" | grep -q "go.mod"; then
  framework="go-module"
  [[ -f "go.mod" ]] && grep -q "gin" go.mod 2>/dev/null && framework="gin"
  [[ -f "go.mod" ]] && grep -q "echo" go.mod 2>/dev/null && framework="echo"
elif echo "$changeset_files" | grep -q "Cargo.toml"; then
  framework="rust-cargo"
elif echo "$changeset_files" | grep -q "pyproject.toml\|setup.py"; then
  framework="python"
  if echo "$changeset_files" | grep -q "requirements.txt"; then
    if [[ -f "requirements.txt" ]]; then
      grep -q "flask" requirements.txt 2>/dev/null && framework="flask"
      grep -q "django" requirements.txt 2>/dev/null && framework="django"
    fi
  fi
fi

[[ "$framework" == "unknown" ]] && framework="none"

# ============================================================================
# SECTION 11: Resolve Constitution
# ============================================================================

constitution="none"
constitution_source=""

# Check AGENTS.md and CLAUDE.md for Review Council Configuration
for config_file in AGENTS.md CLAUDE.md; do
  if [[ -f "$config_file" ]]; then
    if grep -A 5 "## Review Council Configuration" "$config_file" 2>/dev/null | grep -q "Constitution:"; then
      constitution=$(grep -A 5 "## Review Council Configuration" "$config_file" | grep "Constitution:" | sed 's/.*Constitution: *//' | head -n1)
      constitution_source="explicit"
      break
    fi
  fi
done

# Fallback: check .specify/memory/constitution.md
if [[ "$constitution" == "none" ]] && [[ -f ".specify/memory/constitution.md" ]]; then
  first_line=$(head -n1 ".specify/memory/constitution.md")
  if ! echo "$first_line" | grep -q "\[PROJECT_NAME\]"; then
    constitution=".specify/memory/constitution.md"
    constitution_source="auto-discovered"
  fi
fi

# ============================================================================
# SECTION 12: Fetch Linked Issues
# ============================================================================

linked_issues_count=0

if [[ -f "${session_dir}/pr-metadata.txt" ]]; then
  # Extract issue references from PR body
  issue_refs=()

  while IFS= read -r line; do
    # Match patterns: Fixes #N, Closes #N, etc.
    while [[ "$line" =~ (fixes|fixed|closes|close|resolves|resolve)[[:space:]]+\#([0-9]+) ]]; do
      issue_refs+=("${BASH_REMATCH[2]}")
      line="${line/${BASH_REMATCH[0]}/}"  # Remove matched portion
    done

    # Match URL patterns
    if [[ "$line" =~ https://github.com/[^/]+/[^/]+/issues/([0-9]+) ]]; then
      issue_refs+=("${BASH_REMATCH[1]}")
    elif [[ "$line" =~ https://gitlab.com/[^/]+/[^/]+/-/issues/([0-9]+) ]]; then
      issue_refs+=("${BASH_REMATCH[1]}")
    fi
  done < <(sed -n '/^--- BODY ---$/,/^--- END BODY ---$/p' "${session_dir}/pr-metadata.txt" | \
           grep -v '^---' || echo "")

  # Remove duplicates and limit to 5
  issue_refs=($(printf '%s\n' "${issue_refs[@]}" | sort -u | head -n5))
  linked_issues_count=${#issue_refs[@]}

  if [[ ${#issue_refs[@]} -gt 0 ]] && [[ "$forge_tool" != "none" ]]; then
    {
      for issue_num in "${issue_refs[@]}"; do
        if [[ "$forge" == "github" ]]; then
          repo_flag=""
          [[ -n "$forge_owner" ]] && [[ -n "$forge_repo" ]] && repo_flag="--repo ${forge_owner}/${forge_repo}"
          issue_json=$(timeout 30 gh issue view "$issue_num" $repo_flag --json title,body,state 2>/dev/null || echo "")

          if [[ -n "$issue_json" ]]; then
            issue_title=$(echo "$issue_json" | jq -r '.title // ""')
            issue_body=$(echo "$issue_json" | jq -r '.body // ""' | head -c 2000)
            issue_state=$(echo "$issue_json" | jq -r '.state // ""')

            echo "## Issue #${issue_num}: ${issue_title}"
            echo "State: ${issue_state}"
            echo ""
            echo "### Body (truncated)"
            echo "$issue_body"
            echo ""
            echo "### Acceptance Criteria"

            # Extract acceptance criteria
            criteria=$(echo "$issue_body" | grep -E '^\s*-\s+\[[ x]\]' || echo "")
            if [[ -z "$criteria" ]]; then
              criteria=$(echo "$issue_body" | sed -n '/[Aa]cceptance [Cc]riteria/,/^##/p' | grep -v '^##' || echo "")
            fi

            if [[ -n "$criteria" ]]; then
              echo "$criteria"
            else
              echo "(none found)"
            fi
            echo ""
            echo "---"
            echo ""
          fi
        fi
      done
    } > "${session_dir}/linked-issues.txt"
  fi
fi

# ============================================================================
# SECTION 13: Fetch Prior Reviews
# ============================================================================

prior_reviews_count=0

if [[ -f "${session_dir}/pr-metadata.txt" ]] && [[ "$forge_tool" != "none" ]]; then
  if [[ "$forge" == "github" ]]; then
    repo_flag=""
    [[ -n "$forge_owner" ]] && [[ -n "$forge_repo" ]] && repo_flag="--repo ${forge_owner}/${forge_repo}"

    reviews_json=$(timeout 30 gh api "repos/${forge_owner}/${forge_repo}/pulls/${pr_number}/reviews" 2>/dev/null || echo "[]")
    comments_json=$(timeout 30 gh api "repos/${forge_owner}/${forge_repo}/pulls/${pr_number}/comments" 2>/dev/null || echo "[]")

    {
      echo "## Reviews"
      echo ""

      review_count=$(echo "$reviews_json" | jq '. | length' 2>/dev/null || echo "0")
      if [[ $review_count -gt 0 ]]; then
        echo "$reviews_json" | jq -r '.[] |
          "### @\(.user.login) (\(.state), \(.submitted_at // "unknown"))\n\(.body // "")\n"
        ' | head -c 5000
      fi

      echo ""
      echo "## Inline Comments"
      echo ""
      echo "| File | Line | Author | Body |"
      echo "|------|------|--------|------|"

      comment_count=$(echo "$comments_json" | jq '. | length' 2>/dev/null || echo "0")
      if [[ $comment_count -gt 0 ]]; then
        echo "$comments_json" | jq -r '.[] |
          "| \(.path) | \(.line // .original_line // "?") | @\(.user.login) | \"\(.body | .[0:300])\" |"
        ' | head -c 5000
      fi
    } > "${session_dir}/prior-reviews.txt"

    prior_reviews_count=$review_count
  fi
fi

# ============================================================================
# SECTION 14: Write Session Metadata
# ============================================================================

current_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
iso_timestamp=$(date -Iseconds 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%S+00:00)

{
  echo "Review Council Session"
  echo "======================"
  echo "Project:      $(pwd)"
  echo "Branch:       ${current_branch}"
  echo "Base:         ${base_branch}"
  echo "Mode:         ${mode} (${mode_reason})"
  echo "Started:      ${iso_timestamp}"
  echo "Agents:       $(IFS=,; echo "${agents[*]}")"
  echo "Input:        ${input_type}"
  echo "Forge:        ${forge}"
  echo "PR:           ${pr_number:+#${pr_number} \"${pr_title}\" (${pr_url})}"
  [[ -z "$pr_number" ]] && echo "PR:           none"
  echo "Tooling:      ${forge_tool}"
  echo "Issues:       ${linked_issues_count} linked"
  echo "Reviews:      ${prior_reviews_count} prior"
  echo "Constitution: ${constitution} ${constitution_source:+(${constitution_source})}"
  echo "Language:     ${language}"
  echo "Framework:    ${framework}"
} > "${session_dir}/session.txt"

# ============================================================================
# SECTION 15: Initialize Tracking File
# ============================================================================

{
  echo "# Review Council Session Tracking"
  echo ""
  echo "## Phase: Preparation"
  echo ""
  echo "- Input type: ${input_type}"
  echo "- Forge: ${forge}"
  echo "- Tooling: ${forge_tool}"
  echo "- PR: ${pr_number:-none}"
  echo "- Linked issues: ${linked_issues_count}"
  echo "- Prior reviews: ${prior_reviews_count}"
  echo "- Constitution: ${constitution} ${constitution_source:+(${constitution_source})}"
  echo "- Mode: ${mode} (${mode_reason})"
  echo "- Branch: ${current_branch}"
  echo "- Base: ${base_branch}"
  echo "- Language: ${language}"
  echo "- Framework: ${framework}"
  echo "- Agents discovered: ${#agents[@]}"
  echo "- Agents absent: none"
  echo "- Changeset size: $(wc -l < "${session_dir}/changeset.txt") files"
  echo ""
} > "${session_dir}/tracking.md"

# ============================================================================
# SECTION 16: Process CI Status Checks (Quality Gates - Code Mode Only)
# ============================================================================

if [[ "$mode" == "code" ]] && [[ -f "${session_dir}/pr-metadata.txt" ]]; then
  if grep -q '^--- STATUS CHECKS ---$' "${session_dir}/pr-metadata.txt"; then
    {
      echo "## Forge CI Status"
      echo ""
      echo "| Check | Status |"
      echo "|-------|--------|"

      failing_checks=()

      while IFS=': ' read -r check_name conclusion; do
        [[ -z "$check_name" ]] && continue

        status="unknown"
        case "$conclusion" in
          SUCCESS) status="pass" ;;
          FAILURE) status="fail"; failing_checks+=("$check_name|$conclusion") ;;
          NEUTRAL) status="pass" ;;
          SKIPPED) status="skipped" ;;
          PENDING|null|"") status="pending" ;;
        esac

        echo "| $check_name | $status |"
      done < <(sed -n '/^--- STATUS CHECKS ---$/,/^--- END STATUS CHECKS ---$/p' "${session_dir}/pr-metadata.txt" | \
               grep -v '^---' | grep -v '^$')

      if [[ ${#failing_checks[@]} -gt 0 ]]; then
        echo ""
        echo "## Failing Checks"
        echo ""

        for check_info in "${failing_checks[@]}"; do
          check_name="${check_info%%|*}"
          conclusion="${check_info##*|}"
          echo "### $check_name"
          echo "Conclusion: $conclusion"
          echo "(Full output is available in the forge — check the PR's CI tab for details.)"
          echo ""
        done
      fi
    } > "${session_dir}/ci-status.txt"

    {
      echo "## Phase: Quality Gates"
      echo ""
      echo "- Forge CI: available"
      echo "- Forge CI failures: ${#failing_checks[@]}"
      echo ""
    } >> "${session_dir}/tracking.md"
  else
    {
      echo "## Phase: Quality Gates"
      echo ""
      echo "- Forge CI: unavailable"
      echo ""
    } >> "${session_dir}/tracking.md"
  fi
fi

# ============================================================================
# SECTION 17: Output JSON Result
# ============================================================================

# Build agents JSON array safely - write to temp file to avoid truncation
agents_temp="${session_dir}/agents.json.tmp"
if [[ ${#agents[@]} -gt 0 ]]; then
  printf '%s\n' "${agents[@]}" | jq -R . | jq -s . > "$agents_temp" 2>/dev/null || echo "[]" > "$agents_temp"
else
  echo "[]" > "$agents_temp"
fi
agents_json=$(cat "$agents_temp")
rm -f "$agents_temp"

# Build the result JSON
jq -n \
  --arg status "ok" \
  --arg message "Review session prepared: ${session_dir}" \
  --arg session_dir "$session_dir" \
  --arg mode "$mode" \
  --arg language "$language" \
  --arg framework "$framework" \
  --argjson agents "$agents_json" \
  '{
    status: $status,
    message: $message,
    session_dir: $session_dir,
    mode: $mode,
    language: $language,
    framework: $framework,
    agents: $agents
  }'
