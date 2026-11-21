#!/usr/bin/env bash
# rc-prepare.sh records which convention packs the review loads (#76).
#
# Language and framework come from packs' own frontmatter, through
# rc-resolve-packs.sh, rather than from a table in prepare-changes.sh. These
# cases run rc-prepare.sh end to end over throwaway repositories and read the
# answer back from tracking.md and the JSON result, as the later stages do.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$SCRIPT_DIR/../skills/review-council/scripts/rc-prepare.sh"
REFS="$(cd "$SCRIPT_DIR/../skills/review-council/references" && pwd)"
# shellcheck source=module/tests/helpers.sh
source "$SCRIPT_DIR/helpers.sh"

# make_repo <dir> <base-files...> -- <branch-files...>: `main` holds the base
# files, `feature` commits the branch files on top. Files are path=content
# pairs; content goes through printf %b, so `\n` is a newline.
make_repo() {
	local dir="$1" pair side=base
	shift
	[[ -n "$dir" && "$dir" == "${TMPDIR:-/tmp}"/* ]] || {
		echo "make_repo: refusing non-scratch dir '$dir'" >&2
		exit 1
	}
	(
		cd "$dir" || exit 1
		git_init_sandbox
		git checkout -q -b main
		git commit -q --allow-empty -m init
		for pair in "$@"; do
			if [[ "$pair" == "--" ]]; then
				git add -A
				git commit -q --allow-empty -m base
				git checkout -q -b feature
				side=branch
				continue
			fi
			mkdir -p "$(dirname "${pair%%=*}")"
			printf '%b' "${pair#*=}" >"${pair%%=*}"
		done
		git add -A
		git commit -q --allow-empty -m "$side"
	)
}

# prepare <repo> <config-home>: run rc-prepare.sh over the branch's changes and
# print the JSON. Stderr is kept in $repo.err.
prepare() {
	local repo="$1" cfg="$2" cache
	cache=$(mktemp -d)
	(cd "$repo" && AGENTS_DIR="$SCRIPT_DIR/../agents" XDG_CACHE_HOME="$cache" XDG_CONFIG_HOME="$cfg" \
		"$RC_TIMEOUT_BIN" 60 bash "$SCRIPT" --scope changed --mode code 2>"$repo.err")
}

hcl_pack='---\npack_id: lang-hcl\nlanguage: HCL\nextensions: [tf, hcl]\ncontract: 1\n---\n\n# HCL\n\n## Calibration Notes\n\n> n\n'

echo "Test: a Go changeset still selects the shipped lang-go (RC-309)"
work=$(mktemp -d)
cfg=$(mktemp -d)
make_repo "$work" "README.md=x\n" -- "cmd/main.go=package main\n" "go.mod=module x\n"
result=$(prepare "$work" "$cfg")
sess=$(jq -r '.session_dir // empty' <<<"$result")
assert_json_field "$result" "language" "go" "the JSON names go"
assert_track "$sess" "Language" "go" "tracking.md names go"
assert_track "$sess" "Language pack" "$REFS/lang-go.md (shipped)" "the pack is the shipped one, by absolute path"
assert_track "$sess" "Framework pack" "none" "no framework pack"
assert_track "$sess" "Additional packs" "none" "no additional packs"
assert_track "$sess" "Skipped packs" "none" "nothing skipped"
rm -rf "$work" "$cfg" "$work.err"

echo "Test: a user lang-hcl is selected for a .tf-only changeset and recorded (RC-310)"
work=$(mktemp -d)
cfg=$(mktemp -d)
mkdir -p "$cfg/review-council/packs"
printf '%b' "$hcl_pack" >"$cfg/review-council/packs/lang-hcl.md"
make_repo "$work" "README.md=x\n" -- "infra/main.tf=resource {}\n" "infra/vars.tf=variable {}\n"
result=$(prepare "$work" "$cfg")
sess=$(jq -r '.session_dir // empty' <<<"$result")
assert_json_field "$result" "language" "hcl" "the JSON names hcl"
assert_track "$sess" "Language" "hcl" "tracking.md names hcl"
assert_track "$sess" "Language pack" "$cfg/review-council/packs/lang-hcl.md (user)" "the user pack, with its source"
rm -rf "$work" "$cfg" "$work.err"

echo "Test: a user lang-go overrides the shipped pack (RC-311)"
work=$(mktemp -d)
cfg=$(mktemp -d)
mkdir -p "$cfg/review-council/packs"
printf '%b' '---\npack_id: lang-go\nlanguage: Go\nextensions: [go]\ncontract: 1\n---\n\n# Mine\n\n## Calibration Notes\n\n> n\n' >"$cfg/review-council/packs/lang-go.md"
make_repo "$work" "README.md=x\n" -- "a.go=package a\n"
result=$(prepare "$work" "$cfg")
sess=$(jq -r '.session_dir // empty' <<<"$result")
assert_track "$sess" "Language pack" "$cfg/review-council/packs/lang-go.md (user)" "the user copy replaces the shipped one"
rm -rf "$work" "$cfg" "$work.err"

echo "Test: project packs come from the base revision, never from the change (RC-312)"
work=$(mktemp -d)
cfg=$(mktemp -d)
make_repo "$work" ".review-council/packs/lang-hcl.md=$hcl_pack" -- \
	"main.tf=resource {}\n" \
	".review-council/packs/lang-hcl.md=---\\npack_id: lang-hcl\\nlanguage: HCL\\nextensions: [tf]\\ncontract: 9\\n---\\n" \
	".review-council/packs/lang-evil.md=---\\npack_id: lang-evil\\nlanguage: Evil\\nextensions: [tf]\\ncontract: 1\\n---\\n"
result=$(prepare "$work" "$cfg")
sess=$(jq -r '.session_dir // empty' <<<"$result")
assert_track "$sess" "Language" "hcl" "the base's lang-hcl decides the language"
assert_track "$sess" "Language pack" "$sess/review-config/packs/lang-hcl.md (project)" "it is the session's copy of the base's pack"
# shellcheck disable=SC2312 # the false test is the outcome asserted.
assert_equals "$([[ -e "$sess/review-config/packs/lang-evil.md" ]] && echo present || echo absent)" "absent" "the branch's added pack is not loaded"
rm -rf "$work" "$cfg" "$work.err"

echo "Test: a skipped external pack falls back and is named in tracking.md (RC-313)"
work=$(mktemp -d)
cfg=$(mktemp -d)
mkdir -p "$cfg/review-council/packs"
printf '%b' '---\npack_id: lang-go\nlanguage: Go\nextensions: [go]\ncontract: 7\n---\n' >"$cfg/review-council/packs/lang-go.md"
make_repo "$work" "README.md=x\n" -- "a.go=package a\n"
result=$(prepare "$work" "$cfg")
sess=$(jq -r '.session_dir // empty' <<<"$result")
assert_track "$sess" "Language pack" "$REFS/lang-go.md (shipped)" "the shipped pack is used"
skipped=$(sed -nE '/^- Skipped packs:/{s/^- Skipped packs:[[:space:]]*//;p;q;}' "$sess/tracking.md")
assert_match_count "$skipped" "1" "the skip is recorded with its name and reason" -E '^lang-go \(.*contract.*\)'
# shellcheck disable=SC2312 # a missing file must fail this assertion, not abort the suite.
assert_match_count "$(cat "$work.err")" "1" "and reported on stderr" -F "rc-resolve-packs:"
rm -rf "$work" "$cfg" "$work.err"

echo "Test: a non-language user pack loads additively and an external lang-python stays out of a Go review (RC-314)"
work=$(mktemp -d)
cfg=$(mktemp -d)
mkdir -p "$cfg/review-council/packs"
printf '# Team\n' >"$cfg/review-council/packs/team-rules.md"
printf '%b' '---\npack_id: lang-python\nlanguage: Python\nextensions: [py]\ncontract: 1\n---\n\n## Calibration Notes\n\n> n\n' >"$cfg/review-council/packs/lang-python.md"
make_repo "$work" "README.md=x\n" -- "a.go=package a\n"
result=$(prepare "$work" "$cfg")
sess=$(jq -r '.session_dir // empty' <<<"$result")
assert_track "$sess" "Additional packs" "$cfg/review-council/packs/team-rules.md (user)" "the additive pack is recorded"
assert_track "$sess" "Language pack" "$REFS/lang-go.md (shipped)" "the language is still Go's"
# shellcheck disable=SC2312 # a missing file must fail this assertion, not abort the suite.
assert_match_count "$(cat "$sess/tracking.md")" "0" "lang-python is not loaded anywhere" -F "lang-python"
rm -rf "$work" "$cfg" "$work.err"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
