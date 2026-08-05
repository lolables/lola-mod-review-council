#!/usr/bin/env bash
# Run the unit suites once per optional-tool-missing configuration.
#
# The module degrades gracefully when `jsonschema`, `gh` or `glab` is absent —
# it says so in its docs and branches on it in its code. But a fallback branch
# only executes on a host that lacks the tool, so on any given machine it is
# either always taken or never taken, and it is never *deliberately* exercised.
# That is how the jq fallback validator shipped accepting "HIG" as a severity
# and the empty string as a verdict.
#
# Each tool is hidden from PATH in turn (see path_without_command in
# helpers.sh, which mirrors PATH entries rather than rebuilding it, so
# bash and jq stay exactly where the caller's PATH found them).
set -uo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=module/tests/helpers.sh
source "$root/module/tests/helpers.sh"

tools=("$@")
[[ ${#tools[@]} -gt 0 ]] || tools=(jsonschema gh glab)

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

overall=0
for tool in "${tools[@]}"; do
	echo ""
	echo "########################################"
	echo "# Degraded run: '$tool' hidden from PATH"
	echo "########################################"
	if ! command -v "$tool" >/dev/null 2>&1; then
		echo "  (note: '$tool' is not installed here, so this run matches the default environment)"
	fi
	masked=$(path_without_command "$tool" "$workdir/$tool")
	if PATH="$masked" bash "$root/.taskfiles/scripts/run-unit-tests.sh" >"$workdir/$tool.log" 2>&1; then
		echo "PASS: suite green without '$tool'"
		grep -E '^Assertions:' "$workdir/$tool.log" || true
	else
		echo "FAIL: suite red without '$tool'"
		# Only the failing detail — the full log is thousands of PASS lines.
		grep -E '^[[:space:]]+FAIL:|^Failed:|^  - ' "$workdir/$tool.log" | head -40
		overall=1
	fi
done

echo ""
if [[ $overall -eq 0 ]]; then
	echo "All degraded configurations green."
else
	echo "At least one degraded configuration failed."
fi
exit "$overall"
