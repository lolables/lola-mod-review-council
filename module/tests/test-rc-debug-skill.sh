#!/usr/bin/env bash
# Executes the review-council-debug skill's own bash blocks, as an orchestrator
# would, rather than pinning their prose. Both defects this guards against left
# every block exiting 0: Step 1 ran rc-prepare.sh without AGENTS_DIR, so it
# always answered `skip` and the success path was never exercised; and every
# capture merged stderr into $output, so a validator-fallback warning made the
# JSON the checklist asks about unparseable.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEBUG_SKILL_DIR="$(cd "$SCRIPT_DIR/../skills/review-council-debug" && pwd)"
DEBUG_SKILL="$DEBUG_SKILL_DIR/SKILL.md"
# shellcheck source=module/tests/helpers.sh
source "$SCRIPT_DIR/helpers.sh"

# Print the Nth ```bash block (1-based) under the first heading matching <re>,
# ending at the next heading of the same or higher level.
block_under() {
	local re="$1" n="$2"
	awk -v re="$re" -v n="$n" '
		!in_sec && $0 ~ re { in_sec = 1; match($0, /^#+/); lvl = RLENGTH; next }
		in_sec && /^#+ / { match($0, /^#+/); if (RLENGTH <= lvl) exit }
		in_sec && /^[[:space:]]*```bash/ { k++; if (k == n) { grab = 1; next } }
		grab && /^[[:space:]]*```/ { exit }
		grab { print }
	' "$DEBUG_SKILL"
}

# The anchoring block, with the placeholder substituted the way the skill tells
# the orchestrator to substitute it.
anchoring() {
	local skill_dir="$1"
	block_under '^## Path Anchoring' 1 | sed "s|<this-skill-dir>|${skill_dir}|g"
	block_under '^## Path Anchoring' 3
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export XDG_CACHE_HOME="$work/cache"

echo "Test: Step 1 reaches rc-prepare.sh's success path on a real changeset"
mkdir "$work/repo"
setup_repo "$work/repo" feature-head ""
step1=$(
	anchoring "$DEBUG_SKILL_DIR"
	block_under '^### Step 1:' 1
)
out=$(cd "$work/repo" && env -u AGENTS_DIR bash -c "$step1" 2>/dev/null) || true
if grep -q '^session_dir=/' <<<"$out"; then
	echo "  PASS: Step 1 printed a session_dir"
	PASS=$((PASS + 1))
else
	echo "  FAIL: Step 1 printed no session_dir — rc-prepare.sh did not return ok"
	grep -m1 '"status"' <<<"$out" | sed 's/^/    /' || true
	FAIL=$((FAIL + 1))
fi

echo "Test: the anchoring check rejects a skill dir with no agents beside it"
mkdir -p "$work/bogus/skills/review-council-debug"
ln -s "$DEBUG_SKILL_DIR/../review-council" "$work/bogus/skills/review-council"
bogus_anchoring=$(anchoring "$work/bogus/skills/review-council-debug")
out=$(env -u AGENTS_DIR bash -c "$bogus_anchoring" 2>&1) || true
if grep -q 'AGENTS_DIR wrong' <<<"$out"; then
	echo "  PASS: a missing agents directory is reported"
	PASS=$((PASS + 1))
else
	echo "  FAIL: the anchoring check accepted a skill dir with no agents"
	FAIL=$((FAIL + 1))
fi

echo "Test: Step 2's mock output parses as JSON when the validator falls back"
# Without sourcemeta/jsonschema, rc-extract-verdict.sh warns on stderr. That is
# the default on most hosts, so mask the binary rather than depend on its absence.
nojs_path=$(path_without_command jsonschema "$work")
step2=$(
	anchoring "$DEBUG_SKILL_DIR"
	block_under '^### Step 2:' 2
	# shellcheck disable=SC2016 # expanded by the inner shell
	printf '%s\n' 'printf "%s" "$output" | jq -e ".status == \"ok\"" >/dev/null && echo "parse: PASS" || echo "parse: FAIL"' \
		'rm -rf "$mock_session"'
)
out=$(cd "$work/repo" && PATH="$nojs_path" bash -c "$step2" 2>"$work/step2.err") || true
if grep -q '^parse: PASS' <<<"$out"; then
	echo "  PASS: \$output is the script's JSON alone"
	PASS=$((PASS + 1))
else
	echo "  FAIL: \$output does not parse as an ok payload"
	FAIL=$((FAIL + 1))
fi
if grep -q 'rc-warning:' "$work/step2.err"; then
	echo "  PASS: the fallback warning still reaches the operator, on stderr"
	PASS=$((PASS + 1))
else
	echo "  FAIL: the fallback warning was swallowed (or the fallback never ran)"
	FAIL=$((FAIL + 1))
fi

echo "Test: no step merges a script's stderr into the output it parses"
merged=$(grep -nE 'output=\$\(.*\$\{SCRIPTS_DIR\}/rc-[a-z-]+\.sh[^)]*2>&1' "$DEBUG_SKILL" || true)
merged+=$'\n'$(grep -nE '^[[:space:]]+\$\{SCRIPTS_DIR\}/rc-[a-z-]+\.sh.*2>&1' "$DEBUG_SKILL" || true)
if [[ -z "${merged//$'\n'/}" ]]; then
	echo "  PASS: every capture keeps stderr out of \$output"
	PASS=$((PASS + 1))
else
	echo "  FAIL: captures still merge stderr:"
	printf '    %s\n' "${merged//$'\n'/$'\n'    }"
	FAIL=$((FAIL + 1))
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
