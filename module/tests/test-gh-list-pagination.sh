#!/usr/bin/env bash
# Guard: every `gh api` call against a GitHub list endpoint paginates.
#
# A list endpoint (`issues/<n>/comments`, `pulls/<n>/reviews`,
# `pulls/<n>/comments`) answers one page at a time, and gh returns only the
# first unless given --paginate. Both council paths read lists like that: the
# adapter read a 110-comment PR as its oldest 30, and the poster, past 100
# comments, missed its own verdicts. Each was fixed by paginating; this scan
# fails on a new call that does not.
#
# A call is one logical line: backslash continuations are joined first, since
# the endpoint often sits on the line after `gh api`. Creating a comment
# (`-f body=`, `--input`) targets the same path but is not a listing, and a single
# comment's path (`issues/comments/<id>`) does not match.
#
# Coverage is limited. Only the comments and reviews list endpoints the council
# calls today are matched, not every GitHub list endpoint. And an endpoint
# passed through a variable from another line, as `_rc_forge_gh_list` in
# lib/forge/github.sh does, is invisible to this scan; such helpers are pinned by
# their behavioural suites and the RC-074 mutations instead.
#
# GH_SCAN_ROOT overrides the tree scanned (default: this repository); the bite
# checks below use it to scan a scratch copy with violations planted.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=module/tests/helpers.sh
source "$SCRIPT_DIR/helpers.sh"

# scan_gh_list_calls <root> -> prints "relpath:line: text" per unpaginated call.
scan_gh_list_calls() {
	local root="$1" files file
	files="$(find "$root/scripts" "$root/module/skills" -name '*.sh' -type f | LC_ALL=C sort)"
	while IFS= read -r file; do
		awk -v rel="${file#"$root"/}" '
			{
				if (cont) { line = line " " $0 } else { line = $0; start = NR }
				if (line ~ /\\$/) { sub(/\\$/, "", line); cont = 1; next }
				cont = 0
				t = line
				sub(/^[[:space:]]+/, "", t)
				# A flag named only in a trailing comment does not paginate.
				c = t
				sub(/[[:space:]]#[^"\047]*$/, "", c)
				if (t ~ /^#/) next
				# Message text, not an invocation.
				if (t ~ /^(echo|printf|json_output)[[:space:]]/) next
				if (t ~ /(^|[^[:alnum:]_-])gh[[:space:]]+api([[:space:]]|$)/ &&
					t ~ /(issues|pulls)\/[^\/"[:space:]]+\/(comments|reviews)/ &&
					t !~ /(-[fF]|--(raw-)?field)[[:space:]]+body=/ && t !~ /--input/ && c !~ /--paginate/) {
					print rel ":" start ": " t
				}
			}
		' "$file"
	done <<<"$files"
}

ROOT="${GH_SCAN_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"

echo "=== gh list calls: current tree ==="
violations="$(scan_gh_list_calls "$ROOT")"
if [[ -z "$violations" ]]; then
	echo "  PASS: every gh api list call paginates"
	PASS=$((PASS + 1))
else
	echo "  FAIL: gh api list calls without --paginate:"
	printf '    %s\n' "${violations//$'\n'/$'\n'    }"
	FAIL=$((FAIL + 1))
fi

echo "=== gh list calls: scanner bites (RC-074) ==="
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/module" "$scratch/scripts"
cp -R "$ROOT/module/skills" "$scratch/module/skills"

# shellcheck disable=SC2016 # literal text planted into a script, not expanded
planted=(
	'gh api "repos/$o/$r/issues/$n/comments"'
	'x=$(gh api "repos/a/b/pulls/1/comments?per_page=100" --jq .)'
	'rc_timeout 30 gh api "repos/a/b/pulls/1/reviews" 2>/dev/null'
	'gh api "repos/a/b/issues/1/comments" # --paginate'
)
for i in "${!planted[@]}"; do
	printf '%s\n' "${planted[$i]}" >"$scratch/scripts/zz-planted-$i.sh"
	report="$(scan_gh_list_calls "$scratch")"
	assert_equals "$(echo "$report" | grep -c "zz-planted-$i.sh:1:" || true)" "1" \
		"reported: ${planted[$i]}"
	rm -f "$scratch/scripts/zz-planted-$i.sh"
done

# The endpoint on a continuation line is still one call, reported at its start.
# shellcheck disable=SC2016 # literal text planted into a script, not expanded
printf '%s\n' "json=\$(rc_timeout 30 gh api \\" '	"repos/$o/$r/issues/$n/comments" 2>/dev/null)' \
	>"$scratch/scripts/zz-continued.sh"
report="$(scan_gh_list_calls "$scratch")"
assert_equals "$(echo "$report" | grep -c 'zz-continued.sh:1:' || true)" "1" \
	"reported: a call continued onto the next line"
rm -f "$scratch/scripts/zz-continued.sh"

echo "=== gh list calls: non-listings ignored ==="
# shellcheck disable=SC2016 # literal text planted into a script, not expanded
cat >"$scratch/scripts/zz-benign.sh" <<'BENIGN'
gh api "repos/a/b/issues/1/comments?per_page=100" --paginate --slurp
gh api "repos/a/b/issues/comments/9" --jq .body
gh api "repos/a/b/issues/1/comments" -f body="$b" --jq .id
gh api "repos/a/b/issues/1/comments" -F body=@f
gh api "repos/a/b/issues/1/comments" --raw-field body="$b"
gh api "repos/a/b/issues/1/comments" --field body="$b"
gh api "repos/a/b/issues/1/comments" --input req.json
gh api "repos/a/b/issues/1/comments#issuecomment" --paginate
# gh api "repos/a/b/issues/1/comments"
echo "see gh api repos/a/b/issues/1/comments"
BENIGN
report="$(scan_gh_list_calls "$scratch")"
assert_equals "$(echo "$report" | grep -c 'zz-benign' || true)" "0" \
	"paginated, single-comment, create, comment and message lines not reported"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
