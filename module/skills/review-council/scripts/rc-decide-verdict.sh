#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=module/skills/review-council/scripts/rc-lib.sh
source "$(dirname "$0")/rc-lib.sh"
rc_trap_errors

# rc-decide-verdict.sh <session_dir>
# Records the council verdict that verdicts/findings.json decides
# (RC_COUNCIL_VERDICT_JQ) as the single line of verdict.txt. This is SKILL.md
# Step 6's first action, and both renderers check verdict.txt against the same
# rule, so the report and the PR comment can neither disagree with each other
# nor with the findings they show.
#
# No findings.json means nothing was reviewed (the evidence check returned
# nothing_to_do), so no verdict is recorded. A verdict.txt left by an earlier
# iteration is removed, so it cannot be read as this run's decision.
#
# Emits ok {verdict}, nothing_to_do, or validation_error (findings.json
# unreadable; verdict.txt unchanged). Makes no forge calls.

session_dir="${1:-}"
[[ -n "$session_dir" && -d "$session_dir" ]] || {
	json_output "nothing_to_do" "Session directory does not exist."
	exit 0
}
findings="$session_dir/verdicts/findings.json"
verdict_file="$session_dir/verdict.txt"
if [[ ! -f "$findings" ]]; then
	rm -f "$verdict_file"
	json_output "nothing_to_do" "No verdicts/findings.json: nothing was reviewed, so no verdict is recorded."
	exit 0
fi
if ! verdict=$(jq -r "$RC_COUNCIL_VERDICT_JQ" "$findings" 2>/dev/null) || [[ -z "$verdict" ]]; then
	json_output "validation_error" "verdicts/findings.json is not a findings document; verdict.txt is unchanged."
	exit 0
fi
tmp=$(mktemp "$session_dir/.verdict.XXXXXX")
printf '%s\n' "$verdict" >"$tmp"
mv -f "$tmp" "$verdict_file"
payload=$(jq -nc --arg v "$verdict" '{verdict: $v}')
json_output "ok" "Council verdict: ${verdict}." "$payload"
exit 0
