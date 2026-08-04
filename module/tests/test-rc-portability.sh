#!/usr/bin/env bash
# Guards the shipped scripts and the test suite against Linux-only assumptions.
# The CI matrix runs on macOS, whose userland is BSD: it has no `timeout` (GNU
# coreutils), its grep has no PCRE, its sed takes `-i EXTENSION` as a separate
# argument, and its regex engine treats `\|` and `\s` as literal characters
# rather than alternation and whitespace. Its filesystem layout differs too:
# bash lives in /bin, and everything installed by Homebrew sits outside the
# system directories entirely.
#
# The literal-regex cases are the reason this guard exists: they do not fail
# loudly on macOS, they silently never match, so a reviewer's framework
# detection or acceptance-criteria extraction just quietly returns nothing.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=module/tests/helpers.sh
source "$SCRIPT_DIR/helpers.sh"

# Scan every shell file in the repository except this one — the rule patterns
# below are themselves examples of what they forbid.
#
# Both roots are listed explicitly. Scanning module/ alone left the drivers in
# .taskfiles/scripts/ (which `task check` runs on the macOS leg of the CI
# matrix) outside the gate entirely, and they had accumulated `sed -i`,
# `md5sum` and a `\s` regex by the time anyone noticed.
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
self=$(basename "$0")
targets_list=$(find "$REPO_ROOT/module" "$REPO_ROOT/.taskfiles/scripts" -name '*.sh' ! -name "$self" | sort)
# A here-string always yields one line, so an empty result would otherwise
# produce a single empty element and grep would read stdin.
TARGETS=()
[[ -n "$targets_list" ]] && mapfile -t TARGETS <<<"$targets_list"

# forbid <pattern> <label> <remedy>
# Whole-line comments are excluded: the remedies below have to name the very
# constructs they forbid, and a commented-out call is not an executed one.
forbid() {
	local pattern="$1" label="$2" remedy="$3" hits
	hits=$(grep -nE "$pattern" "${TARGETS[@]}" 2>/dev/null |
		grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true)
	if [[ -z "$hits" ]]; then
		echo "  PASS: $label"
		PASS=$((PASS + 1))
	else
		echo "  FAIL: $label — $remedy"
		while IFS= read -r hit; do
			echo "        ${hit#"$REPO_ROOT"/}"
		done <<<"$hits"
		FAIL=$((FAIL + 1))
	fi
}

echo "Test: no Linux-only shell constructs or path assumptions (macOS ships a BSD userland)"

forbid '/(usr/)?s?bin/\*' \
	"no system bindir enumeration" \
	"macOS keeps bash in /bin and Homebrew tools outside /usr/bin, so such a set cannot even resolve the interpreter; derive from \$PATH (see path_without_command in helpers.sh)"

forbid '(^|[;&|(]|[[:space:]])g?timeout[[:space:]]+[0-9]' \
	"no direct 'timeout' invocation" \
	"macOS has no GNU timeout; call rc_timeout (scripts) or \$RC_TIMEOUT_BIN (tests)"

forbid 'grep[[:space:]]+-[A-Za-z]*P' \
	"no 'grep -P'" \
	"BSD grep has no PCRE; use POSIX classes, grep -F, or bash pattern matching"

forbid 'sed[[:space:]]+(-[A-Za-z]+[[:space:]]+)*-i([[:space:]]|$)' \
	"no in-place 'sed -i'" \
	"BSD sed requires '-i EXTENSION' as a separate argument; filter on write instead"

forbid '(grep|sed)[^#]*\\[|swdb+<>]' \
	"no GNU regex escapes in grep/sed patterns" \
	"BSD regex reads \\| \\s \\w \\+ as literals; use -E with POSIX [[:class:]]"

forbid 'touch[[:space:]]+(-[A-Za-z]+[[:space:]]+)*-d([[:space:]]|$)' \
	"no free-form 'touch -d' timestamps" \
	"BSD touch -d demands strict ISO-8601; use POSIX 'touch -t CCYYMMDDhhmm'"

forbid 'readlink[[:space:]]+(-[A-Za-z]+[[:space:]]+)*-[A-Za-z]*[efm]([[:space:]]|$)' \
	"no canonicalising 'readlink -f/-e/-m'" \
	"canonicalisation flags are GNU extensions and older BSD readlink has none of them; Homebrew coreutils installs GNU readlink as 'greadlink' and leaves BSD readlink on PATH, so this fails on the macOS CI leg rather than degrading. Follow the chain a hop at a time with flagless 'readlink' plus 'cd ... && pwd -P' (see path_in_root in rc-verify-evidence.sh)"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
