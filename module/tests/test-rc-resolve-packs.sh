#!/usr/bin/env bash
# rc-resolve-packs.sh: which convention packs a review loads (#76).
#
# Packs declare the files they cover (`extensions:`) or the repository they
# probe (`framework:` + `probe:`) in frontmatter, and the resolver picks among
# the shipped, user and project copies. These cases drive the resolver directly
# over scratch directories; test-rc-prepare-packs.sh covers the same rules
# through rc-prepare.sh.
# shellcheck disable=SC2312 # a failing helper inside an assertion argument must fail that assertion, not abort the suite.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RESOLVE="$SCRIPT_DIR/../skills/review-council/scripts/rc-resolve-packs.sh"
REFS="$SCRIPT_DIR/../skills/review-council/references"
# shellcheck source=module/tests/helpers.sh
source "$SCRIPT_DIR/helpers.sh"

# Per-case scratch tree: refs/ (shipped), user/, project/, root/ (the reviewed
# tree), out/. Removed at the end of each case by discard_fixture.
new_case() {
	local d
	d=$(mktemp -d)
	mkdir -p "$d/refs" "$d/user" "$d/project" "$d/root" "$d/out"
	printf '%s' "$d"
}

# write_pack <file> <kind-line-body...>: frontmatter lines then a body line.
write_pack() {
	local file="$1"
	shift
	{
		echo "---"
		printf '%s\n' "$@"
		echo "---"
		echo
		echo "# Pack"
		echo
		echo "## Calibration Notes"
	} >"$file"
}

# resolve <case-dir> <changeset-lines...>: run the resolver, leave the TSV in
# $TSV and stderr in $ERR. The project directory is passed as `none` when the
# case has no project packs, as the caller does.
resolve() {
	local d="$1"
	shift
	printf '%s\n' "$@" >"$d/changeset.txt"
	local project="$d/project"
	[[ -n "${PROJECT_NONE:-}" ]] && project=none
	bash "$RESOLVE" --refs "$d/refs" --project-packs "$project" --user-packs "$d/user" \
		--changeset "$d/changeset.txt" --review-root "$d/root" --out "$d/out" 2>"$d/err"
	TSV=$(cat "$d/out/packs.tsv")
	ERR=$(cat "$d/err")
}

# row <name> -> the TSV row for that pack name (first match).
row() {
	awk -F'\t' -v n="$1" '$2 == n { print; exit }' <<<"$TSV"
}

# sel <kind> -> the selected row of that kind, empty when none.
sel() {
	awk -F'\t' -v k="$1" '$1 == k && $5 == "selected"' <<<"$TSV"
}

# field <row> <n> -> nth tab-separated field.
field() {
	awk -F'\t' -v n="$2" '{ print $n }' <<<"$1"
}

echo "Test: an unknown contract version is skipped with a reason (RC-294)"
d=$(new_case)
write_pack "$d/user/lang-hcl.md" "pack_id: lang-hcl" "language: HCL" "extensions: [tf]" "contract: 2"
resolve "$d" "main.tf"
r=$(row lang-hcl)
assert_equals "$(field "$r" 5)" "skipped" "the pack is skipped"
assert_match_count "$(field "$r" 6)" "1" "the reason names the contract" -F "contract"
assert_match_count "$ERR" "1" "stderr reports it with the script's prefix" -E '^rc-resolve-packs: .*lang-hcl'
assert_equals "$(awk -F'\t' '$1 == "language" && $5 == "selected"' <<<"$TSV")" "" "no language is selected from it"
rm -rf "$d"

echo "Test: a pack with no contract is skipped, never half-loaded (RC-295)"
d=$(new_case)
write_pack "$d/user/lang-hcl.md" "pack_id: lang-hcl" "language: HCL" "extensions: [tf]"
resolve "$d" "main.tf"
r=$(row lang-hcl)
assert_equals "$(field "$r" 5)" "skipped" "missing contract: skipped"
assert_match_count "$(field "$r" 6)" "1" "the reason says the contract is missing" -F "contract"
write_pack "$d/user/lang-hcl.md" "pack_id: lang-hcl" "language: HCL" "extensions: [tf]" "contract: 1.5"
resolve "$d" "main.tf"
assert_equals "$(field "$(row lang-hcl)" 5)" "skipped" "a non-integer contract: skipped"
write_pack "$d/user/lang-hcl.md" "pack_id: lang-hcl" "language: HCL" "contract: 1"
resolve "$d" "main.tf"
assert_equals "$(field "$(row lang-hcl)" 5)" "skipped" "a language pack with no extensions: skipped"
write_pack "$d/user/lang-hcl.md" "pack_id: lang-hcl" "language: HCL" "extensions: [.tf]" "contract: 1"
resolve "$d" "main.tf"
assert_equals "$(field "$(row lang-hcl)" 5)" "skipped" "an extension with a dot: skipped"
rm -rf "$d"

echo "Test: every shipped language and framework pack declares its contract and coverage (RC-296)"
shipped=0
for f in "$REFS"/lang-*.md "$REFS"/fw-*.md; do
	[[ -e "$f" ]] || continue
	shipped=$((shipped + 1))
	name=$(basename "$f" .md)
	fm=$(awk 'NR == 1 && $0 != "---" { exit } NR > 1 && $0 == "---" { exit } NR > 1 { print }' "$f")
	assert_match_count "$fm" "1" "$name declares contract: 1" -xE 'contract:[[:space:]]*1'
	case "$name" in
	lang-*) assert_match_count "$fm" "1" "$name declares extensions" -E '^extensions:[[:space:]]*\[[a-z0-9, ]+\]$' ;;
	fw-*)
		assert_match_count "$fm" "1" "$name declares a framework slug" -E '^framework:[[:space:]]*[a-z0-9-]+$'
		assert_match_count "$fm" "1" "$name declares a probe" -E '^probe:[[:space:]]*[A-Za-z0-9._-]+[[:space:]]+.+$'
		;;
	*) ;;
	esac
done
assert_equals "$([[ $shipped -ge 3 ]] && echo yes || echo no)" "yes" "the shipped packs were found ($shipped)"

echo "Test: a Go changeset still selects the shipped lang-go (RC-297)"
d=$(new_case)
cp "$REFS"/lang-*.md "$REFS"/fw-*.md "$d/refs/"
cp "$REFS/severity.md" "$REFS/base.md" "$d/refs/"
PROJECT_NONE=1 resolve "$d" "cmd/main.go" "pkg/a.go" "go.mod"
unset PROJECT_NONE
r=$(sel language)
assert_equals "$(field "$r" 2)" "lang-go" "language pack is lang-go"
assert_equals "$(field "$r" 4)" "shipped" "from the shipped directory"
assert_equals "$(field "$r" 3)" "$d/refs/lang-go.md" "with its absolute path"
assert_equals "$(field "$r" 5)" "selected" "marked selected"
assert_equals "$(awk -F'\t' '$2 == "severity" || $2 == "base"' <<<"$TSV")" "" "severity.md and base.md are not packs to resolve"
rm -rf "$d"

echo "Test: a pack without Calibration Notes is skipped and the next copy is tried (RC-334)"
d=$(new_case)
cp "$REFS"/lang-go.md "$d/refs/"
{
	echo "---"
	printf '%s\n' "pack_id: lang-go" "language: Go" "extensions: [go]" "contract: 1"
	echo "---"
	echo
	echo "# No notes here"
} >"$d/user/lang-go.md"
resolve "$d" "a.go"
r=$(sel language)
assert_equals "$(field "$r" 4)" "shipped" "the shipped copy is selected instead"
assert_match_count "$ERR" "1" "stderr names the missing section" -F "Calibration Notes"
skipped=$(awk -F'\t' '$2 == "lang-go" && $5 == "skipped"' <<<"$TSV")
assert_equals "$(field "$skipped" 4)" "user" "the user copy is the skipped row"
rm -rf "$d"

echo "Test: an upper-case file extension still selects its language pack (RC-335)"
d=$(new_case)
cp "$REFS"/lang-go.md "$d/refs/"
resolve "$d" "Main.GO" "util.Go"
assert_equals "$(field "$(sel language)" 2)" "lang-go" "Main.GO and util.Go count as Go"
rm -rf "$d"

echo "Test: files no language pack claims do not outvote one that does (RC-336)"
d=$(new_case)
cp "$REFS"/lang-go.md "$d/refs/"
resolve "$d" "README.md" "docs/a.md" "docs/b.md" "main.go"
assert_equals "$(field "$(sel language)" 2)" "lang-go" "one .go file beats three unclaimed .md files"
rm -rf "$d"

echo "Test: a user lang-hcl covering [tf, hcl] is selected for a .tf-only changeset (RC-298)"
d=$(new_case)
cp "$REFS"/lang-go.md "$d/refs/"
write_pack "$d/user/lang-hcl.md" "pack_id: lang-hcl" "language: HCL" "extensions: [tf, hcl]" "contract: 1"
resolve "$d" "infra/main.tf" "infra/vars.tf"
r=$(sel language)
assert_equals "$(field "$r" 2)" "lang-hcl" "lang-hcl is the language pack"
assert_equals "$(field "$r" 4)" "user" "from the user directory"
rm -rf "$d"

echo "Test: a user lang-go overrides the shipped one, whole-file (RC-299)"
d=$(new_case)
cp "$REFS"/lang-go.md "$d/refs/"
write_pack "$d/user/lang-go.md" "pack_id: lang-go" "language: Go" "extensions: [go]" "contract: 1"
resolve "$d" "a.go"
r=$(sel language)
assert_equals "$(field "$r" 3)" "$d/user/lang-go.md" "the user copy is the pack"
assert_equals "$(field "$r" 4)" "user" "source is user"
assert_equals "$(awk -F'\t' '$2 == "lang-go"' <<<"$TSV" | wc -l | tr -d ' ')" "1" "the shadowed shipped copy has no row"
rm -rf "$d"

echo "Test: a project pack overrides both user and shipped (RC-300)"
d=$(new_case)
cp "$REFS"/lang-go.md "$d/refs/"
write_pack "$d/user/lang-go.md" "pack_id: lang-go" "language: Go" "extensions: [go]" "contract: 1"
write_pack "$d/project/lang-go.md" "pack_id: lang-go" "language: Go" "extensions: [go]" "contract: 1"
resolve "$d" "a.go"
r=$(sel language)
assert_equals "$(field "$r" 3)" "$d/project/lang-go.md" "the project copy wins"
assert_equals "$(field "$r" 4)" "project" "source is project"
rm -rf "$d"

echo "Test: a skipped higher-precedence pack falls back and the skip is reported (RC-301)"
d=$(new_case)
cp "$REFS"/lang-go.md "$d/refs/"
write_pack "$d/project/lang-go.md" "pack_id: lang-go" "language: Go" "extensions: [go]" "contract: 9"
resolve "$d" "a.go"
r=$(sel language)
assert_equals "$(field "$r" 4)" "shipped" "the shipped copy is used"
assert_equals "$(awk -F'\t' '$2 == "lang-go" && $5 == "skipped" && $4 == "project"' <<<"$TSV" | wc -l | tr -d ' ')" "1" "the project skip has its own row"
assert_match_count "$ERR" "1" "and a stderr line" -E '^rc-resolve-packs: .*lang-go'
rm -rf "$d"

echo "Test: a non-language pack from the user or project directory still loads additively (RC-302)"
d=$(new_case)
cp "$REFS"/lang-go.md "$d/refs/"
printf '# Team rules\n' >"$d/user/team-rules.md"
printf '# House rules\n' >"$d/project/house-rules.md"
resolve "$d" "a.go"
assert_equals "$(field "$(row team-rules)" 1)/$(field "$(row team-rules)" 5)/$(field "$(row team-rules)" 4)" "additional/selected/user" "user pack loads"
assert_equals "$(field "$(row house-rules)" 1)/$(field "$(row house-rules)" 5)/$(field "$(row house-rules)" 4)" "additional/selected/project" "project pack loads"
assert_equals "$(field "$(row lang-go)" 1)" "language" "the language pack is still chosen"
rm -rf "$d"

echo "Test: an external lang-python is not loaded for a Go changeset (RC-303)"
d=$(new_case)
cp "$REFS"/lang-go.md "$d/refs/"
write_pack "$d/user/lang-python.md" "pack_id: lang-python" "language: Python" "extensions: [py]" "contract: 1"
resolve "$d" "a.go"
assert_equals "$(field "$(row lang-python)" 5)" "available" "valid but not selected"
assert_equals "$(field "$(sel language)" 2)" "lang-go" "only lang-go is the language"
rm -rf "$d"

echo "Test: symlinked and oddly named packs are ignored (RC-304)"
d=$(new_case)
cp "$REFS"/lang-go.md "$d/refs/"
printf 'secret\n' >"$d/target.md"
ln -s "$d/target.md" "$d/user/linked.md"
ln -s "$REFS/lang-go.md" "$d/user/lang-hcl.md"
printf '# x\n' >"$d/user/bad name.md"
printf '# x\n' >"$d/user/.hidden.md"
printf '# x\n' >"$d/user/-dash.md"
printf '# x\n' >"$d/user/notes.txt"
mkdir "$d/user/dir.md"
resolve "$d" "a.go"
assert_equals "$(awk -F'\t' '$4 == "user"' <<<"$TSV")" "" "no user pack row is produced for any of them"
assert_equals "$(field "$(row lang-go)" 4)" "shipped" "and the shipped pack is unaffected"
rm -rf "$d"

echo "Test: two packs claiming one extension resolve by precedence, then by name (RC-305)"
d=$(new_case)
write_pack "$d/refs/lang-aaa.md" "pack_id: lang-aaa" "language: A" "extensions: [zz]" "contract: 1"
write_pack "$d/user/lang-bbb.md" "pack_id: lang-bbb" "language: B" "extensions: [zz]" "contract: 1"
resolve "$d" "x.zz"
assert_equals "$(field "$(sel language)" 2)" "lang-bbb" "the user pack beats the shipped one"
rm -rf "$d"
d=$(new_case)
write_pack "$d/user/lang-bbb.md" "pack_id: lang-bbb" "language: B" "extensions: [zz]" "contract: 1"
write_pack "$d/user/lang-aaa.md" "pack_id: lang-aaa" "language: A" "extensions: [zz]" "contract: 1"
resolve "$d" "x.zz"
assert_equals "$(field "$(sel language)" 2)" "lang-aaa" "equal precedence: alphabetical"
rm -rf "$d"

echo "Test: the language is the most-claimed pack, ties by name (RC-306)"
d=$(new_case)
cp "$REFS"/lang-go.md "$REFS"/lang-typescript.md "$d/refs/"
resolve "$d" "a.ts" "b.tsx" "c.go"
assert_equals "$(field "$(sel language)" 2)" "lang-typescript" "ts+tsx fold into one vote that beats one .go"
resolve "$d" "a.ts" "c.go"
assert_equals "$(field "$(sel language)" 2)" "lang-go" "a tie goes to the alphabetically first pack"
resolve "$d" "README.md"
assert_equals "$(sel language)" "" "no claimed extension: no language row"
rm -rf "$d"

echo "Test: a framework pack is selected only when its probe file is changed and holds its text (RC-307)"
d=$(new_case)
cp "$REFS"/fw-react.md "$REFS"/lang-typescript.md "$d/refs/"
printf '{"dependencies":{"react":"18.0.0"}}\n' >"$d/root/package.json"
resolve "$d" "src/a.tsx" "package.json"
r=$(sel framework)
assert_equals "$(field "$r" 2)" "fw-react" "react is detected from the probe"
assert_equals "$(field "$r" 5)" "selected" "and selected"
resolve "$d" "src/a.tsx"
assert_equals "$(sel framework)" "" "package.json outside the changeset: no framework"
printf '{"dependencies":{"vue":"3.0.0"}}\n' >"$d/root/package.json"
resolve "$d" "src/a.tsx" "package.json"
assert_equals "$(sel framework)" "" "probe text absent: no framework"
rm -f "$d/root/package.json"
resolve "$d" "src/a.tsx" "package.json"
assert_equals "$(sel framework)" "" "probe file absent from the tree: no framework"
rm -rf "$d"

echo "Test: a probe that is not a plain file name is skipped (RC-308)"
d=$(new_case)
write_pack "$d/user/fw-evil.md" "pack_id: fw-evil" "framework: evil" "probe: ../../etc/passwd root" "contract: 1"
resolve "$d" "a.go"
assert_equals "$(field "$(row fw-evil)" 5)" "skipped" "path traversal in the probe: skipped"
rm -rf "$d"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
