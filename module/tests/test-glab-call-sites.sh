#!/usr/bin/env bash
# Guard: every glab invocation must go through a hardened helper.
#
# glab sends GitLab env tokens (GITLAB_TOKEN, ...) to whatever host it is
# pointed at, and GITLAB_API_HOST / GLAB_ENABLE_CI_AUTOLOGIN redirect it. The
# helpers strip or bind those per call: `_gl` (scripts/lib/forge-gitlab.sh) and
# `rc_forge_glab` (module/skills/review-council/scripts/lib/forge/gitlab.sh).
# A bare `glab ...` anywhere else bypasses that, so this scan fails on it.
#
# GLAB_SCAN_ROOT overrides the tree scanned (default: this repository); the
# bite checks below use it to scan a scratch copy with violations planted.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=module/tests/helpers.sh
source "$SCRIPT_DIR/helpers.sh"

HELPER_FILES=(
	"scripts/lib/forge-gitlab.sh"
	"module/skills/review-council/scripts/lib/forge/gitlab.sh"
)

# `glab` in command position: line start, after a separator or control
# keyword, or behind a wrapper (env/rc_timeout/timeout/xargs/command/exec...).
CALL_RE='(^|[;&|(!{]|(then|do|else|if|while|until|command|exec|xargs|nohup|sudo)[[:space:]]+|(^|[[:space:]])env[[:space:]][^#]*|(rc_timeout|timeout)[[:space:]]+[^[:space:]]+)[[:space:]]*glab([[:space:]]|$)'

# scan_glab_calls <root> -> prints "relpath:line: text" per violation.
scan_glab_calls() {
	local root="$1" files file rel n text trimmed helper is_helper
	files="$(find "$root/scripts" "$root/module/skills" -name '*.sh' -type f)"
	while IFS= read -r file; do
		rel="${file#"$root"/}"
		is_helper=0
		for helper in "${HELPER_FILES[@]}"; do
			[[ "$rel" == "$helper" ]] && is_helper=1
		done
		while IFS= read -r hit; do
			n="${hit%%:*}"
			text="${hit#*:}"
			trimmed="${text#"${text%%[![:space:]]*}"}"
			case "$trimmed" in
			'#'*) continue ;; # comment
			# Message text, not an invocation.
			echo\ * | printf\ * | json_output\ * | emit\ * | require_commands\ *) continue ;;
			*) ;;
			esac
			# The one sanctioned call line inside each helper.
			if [[ "$is_helper" -eq 1 && "$trimmed" == *' glab "$@"' ]]; then
				continue
			fi
			echo "$rel:$n: $trimmed"
		done < <(grep -nE "$CALL_RE" "$file" || true)
	done <<<"$files"
}

ROOT="${GLAB_SCAN_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"

echo "=== glab call sites: current tree ==="
violations="$(scan_glab_calls "$ROOT")"
if [[ -z "$violations" ]]; then
	echo "  PASS: no glab call outside _gl / rc_forge_glab"
	PASS=$((PASS + 1))
else
	echo "  FAIL: glab called outside the hardened helpers:"
	printf '    %s\n' "${violations//$'\n'/$'\n'    }"
	FAIL=$((FAIL + 1))
fi

echo "=== glab call sites: scanner bites ==="
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/module"
cp -R "$ROOT/scripts" "$scratch/scripts"
cp -R "$ROOT/module/skills" "$scratch/module/skills"

# shellcheck disable=SC2016 # literal text planted into a script, not expanded
planted=(
	'glab api user'
	'  out=$(glab api user)'
	'curl x | glab api user'
	'timeout 5 glab api user'
	'env -u FOO glab api user'
	'rc_timeout 5 glab api user'
	'if glab auth status; then :; fi'
	'cd x && glab mr view'
)
for i in "${!planted[@]}"; do
	printf '%s\n' "${planted[$i]}" >>"$scratch/scripts/zz-planted-$i.sh"
	report="$(scan_glab_calls "$scratch")"
	assert_equals "$(echo "$report" | grep -c "zz-planted-$i.sh:1:" || true)" "1" \
		"reported: ${planted[$i]}"
done

# A bare helper-style line is only sanctioned inside the two helpers.
printf '%s\n' 'env -u GITLAB_API_HOST glab "$@"' >"$scratch/scripts/zz-helperlike.sh"
report="$(scan_glab_calls "$scratch")"
assert_equals "$(echo "$report" | grep -c 'zz-helperlike.sh:1:' || true)" "1" \
	"reported: helper-style call outside a helper"

echo "=== glab call sites: non-invocations ignored ==="
rm -f "$scratch"/scripts/zz-*.sh
cat >"$scratch/scripts/zz-benign.sh" <<'BENIGN'
# run glab api user here
  # glab api user
if ! command -v glab >/dev/null 2>&1; then
forge_tool="glab"
FORGE_CLI="glab"
echo "glab is not installed; run 'glab auth login'"
json_output "error" "\`glab api user\` returned nothing"
require_commands git glab
BENIGN
report="$(scan_glab_calls "$scratch")"
assert_equals "$report" "$(printf '%s' "$report" | grep -v zz-benign || true)" \
	"benign glab mentions not reported"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
