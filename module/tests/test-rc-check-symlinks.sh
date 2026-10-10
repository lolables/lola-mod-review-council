#!/usr/bin/env bash
# rc-check-symlinks.sh reads diff.patch and files every symlink the change adds
# or retargets that leads out of the repository as a HIGH finding of its own.
# Diffs come from real git, the format both forges serve.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS="$SCRIPT_DIR/../skills/review-council/scripts"
SCRIPT="$SCRIPTS/rc-check-symlinks.sh"
# shellcheck source=module/tests/helpers.sh
source "$SCRIPT_DIR/helpers.sh"

# A session whose diff.patch is what `git diff base..HEAD` prints after
# <setup> runs in a repository holding one committed README.
# Usage: sess=$(session_from_change '<shell commands run in the repo>')
session_from_change() {
	local repo sess
	repo=$(mktemp -d)
	sess=$(new_session)
	(
		cd "$repo"
		git_init_sandbox
		echo base >README
		git add README
		git commit -qm base
		git tag base
		eval "$1"
		git add -A
		git commit -qm change
		git diff -M base HEAD >"$sess/diff.patch"
	)
	rm -rf "$repo"
	echo "$sess"
}

verdict_of() { echo "$1/verdicts/rc-check-symlinks.json"; }

echo "Test 1: an added link out of the repository is a HIGH finding (RC-076)"
sess=$(session_from_change 'ln -s /tmp/rc-canary.txt leak')
result=$(bash "$SCRIPT" "$sess")
assert_json_field "$result" "status" "ok" "status is ok"
assert_json_field "$result" "escaping" "1" "one escaping link counted"
v=$(verdict_of "$sess")
assert_jq "$v" '.agent' "rc-check-symlinks" "verdict names the script agent"
assert_jq "$v" '.verdict' "REQUEST CHANGES" "verdict is REQUEST CHANGES"
assert_jq "$v" '.findings | length' "1" "one finding"
assert_jq "$v" '.findings[0].severity' "HIGH" "severity HIGH"
assert_jq "$v" '.findings[0].file' "leak" "file is the link path"
assert_jq "$v" '.findings[0].line' "1" "line is 1"
assert_jq "$v" '.findings[0].evidence' "/tmp/rc-canary.txt" "evidence is the target text"
if grep -qF '"leak" -> "/tmp/rc-canary.txt" (escapes)' "$sess/symlinks.txt" &&
	head -1 "$sess/symlinks.txt" | grep -q '^# UNTRUSTED'; then
	echo "  PASS: symlinks.txt lists it under an UNTRUSTED header"
	PASS=$((PASS + 1))
else
	echo "  FAIL: symlinks.txt missing, unheaded, or wrong"
	FAIL=$((FAIL + 1))
fi

echo "Test 2: the verdict passes extraction's own schema and coherence checks"
# Written directly, so rc-extract-verdict.sh never sees it in a real run; run
# it through that script here so the shape cannot drift from the schema. The
# extractor refuses the script's own name (RESERVED_AGENT), so the block goes
# through under a reviewer's.
scratch=$(new_session)
{
	echo '```json'
	jq '.agent = "divisor-guard-code"' "$v"
	echo '```'
} >"$scratch/verdicts/divisor-guard-code.raw.md"
ext=$(bash "$SCRIPTS/rc-extract-verdict.sh" "$scratch" 2>/dev/null)
assert_json_field "$ext" "status" "ok" "rc-extract-verdict.sh accepts it"
rm -f "$scratch/verdicts/divisor-guard-code.raw.md" "$scratch/verdicts/divisor-guard-code.json"
{
	echo '```json'
	cat "$v"
	echo '```'
} >"$scratch/verdicts/rc-check-symlinks.raw.md"
ext=$(bash "$SCRIPTS/rc-extract-verdict.sh" "$scratch" 2>/dev/null)
assert_jq_str "$ext" '[.invalid[].reason] | join(",")' "RESERVED_AGENT" "under the script's own name it is refused"
rm -rf "$scratch" "$sess"

echo "Test 3: links that stay inside are listed, not reported"
sess=$(session_from_change 'mkdir -p docs && ln -s ../README docs/readme-link')
result=$(bash "$SCRIPT" "$sess")
assert_json_field "$result" "escaping" "0" "nothing escapes"
v=$(verdict_of "$sess")
assert_jq "$v" '.verdict' "APPROVE" "verdict is APPROVE"
assert_jq "$v" '.findings | length' "0" "no findings"
if grep -qF '"docs/readme-link" -> "../README" (inside)' "$sess/symlinks.txt"; then
	echo "  PASS: listed as inside"
	PASS=$((PASS + 1))
else
	echo "  FAIL: not listed as inside"
	FAIL=$((FAIL + 1))
fi
rm -rf "$sess"

echo "Test 4: no links, no artifacts; stale ones from an earlier run are removed"
sess=$(session_from_change 'echo more >>README')
echo '{"stale":true}' >"$(verdict_of "$sess")"
echo stale >"$sess/symlinks.txt"
result=$(bash "$SCRIPT" "$sess")
assert_json_field "$result" "links" "0" "no links counted"
v=$(verdict_of "$sess")
if [[ ! -e "$v" && ! -e "$sess/symlinks.txt" ]]; then
	echo "  PASS: no verdict, no list, stale copies gone"
	PASS=$((PASS + 1))
else
	echo "  FAIL: an artifact remains"
	FAIL=$((FAIL + 1))
fi
rm -f "$sess/diff.patch"
result=$(bash "$SCRIPT" "$sess")
assert_json_field "$result" "links" "0" "a missing diff.patch is no links"
rm -rf "$sess"

echo "Test 5: retargets and moved links are judged; deletions are not"
# The setup commits three links and moves the base tag onto that commit, so
# the diff shows `keep` retargeted (mode on the index line), `gone` deleted,
# and `mv1` moved to d/mv1 with a new target. Git shows that move as a deletion
# of mv1 and an addition of d/mv1, not as a rename: a one-line link is never
# similar enough to its retargeted self. What matters is that the link is
# judged where it now lives.
sess=$(session_from_change 'ln -s README keep && ln -s README gone && ln -s README mv1 &&
	git add -A && git commit -qm links && git tag -f base >/dev/null &&
	rm keep gone && ln -s /etc/shadow keep &&
	mkdir d && git mv mv1 d/mv1 && rm d/mv1 && ln -s ../../up d/mv1')
bash "$SCRIPT" "$sess" >/dev/null
v=$(verdict_of "$sess")
assert_jq "$v" '[.findings[].file] | sort | join(",")' "d/mv1,keep" \
	"a retarget and a moved link are reported, a deletion is not"
if grep -qE '"(gone|mv1)"' "$sess/symlinks.txt"; then
	echo "  FAIL: a deleted link, or the moved link's old path, was judged"
	FAIL=$((FAIL + 1))
else
	echo "  PASS: neither the deleted link nor the moved link's old path is listed"
	PASS=$((PASS + 1))
fi
rm -rf "$sess"

echo "Test 6: chains through links in the same diff"
sess=$(session_from_change 'ln -s /etc a && ln -s a/passwd b && ln -s c2 c1 && ln -s c1 c2')
bash "$SCRIPT" "$sess" >/dev/null
v=$(verdict_of "$sess")
assert_jq "$v" '[.findings[].file] | sort | join(",")' "a,b,c1,c2" "a link through an escaping link, and a cycle, escape"
rm -rf "$sess"

echo "Test 7: quoted paths are unquoted; a ++-prefixed target is a target"
sess=$(session_from_change "ln -s /etc/passwd 'é-link' && ln -s '++ evil' plus")
bash "$SCRIPT" "$sess" >/dev/null
v=$(verdict_of "$sess")
assert_jq "$v" '.findings[0].file' "é-link" "the path is the file's real name"
if grep -qF '"plus" -> "++ evil" (inside)' "$sess/symlinks.txt"; then
	echo "  PASS: +++ inside a hunk read as content"
	PASS=$((PASS + 1))
else
	echo "  FAIL: a +++ content line was misread"
	FAIL=$((FAIL + 1))
fi
rm -rf "$sess"

echo "Test 8: re-running on its own output changes nothing"
sess=$(session_from_change 'ln -s /tmp/x leak')
v=$(verdict_of "$sess")
bash "$SCRIPT" "$sess" >/dev/null
first=$(cat "$v" "$sess/symlinks.txt")
bash "$SCRIPT" "$sess" >/dev/null
again=$(cat "$v" "$sess/symlinks.txt")
assert_equals "$again" "$first" "idempotent"
leftover=$(find "$sess" -maxdepth 1 -name '.symlinks.*')
assert_equals "$leftover" "" "the work directory inside the session is removed"
rm -rf "$sess"

echo "Test 9: a link whose target the diff does not show is reported, not dropped"
# A target holding a NUL byte makes git print `Binary files ... differ` with
# no hunk, and an empty target prints no hunk at all; either used to drop the
# link unjudged. The index entries are written directly (no filesystem can
# hold such a link) and kept out of `git add -A` with skip-worktree.
unshown="(symlink target not readable from the diff)"
# shellcheck disable=SC2016 # a script for the fixture repository, expanded there.
sess=$(session_from_change 'nul=$(printf "/etc/shadow\0junk" | git hash-object -w --stdin) &&
	empty=$(git hash-object -w --stdin </dev/null) &&
	git update-index --add --cacheinfo "120000,$nul,nul" --cacheinfo "120000,$nul,é nul" \
		--cacheinfo "120000,$empty,empty" &&
	git update-index --skip-worktree nul "é nul" empty &&
	ln -s nul/x via')
result=$(bash "$SCRIPT" "$sess")
assert_json_field "$result" "escaping" "4" "all four links escape"
v=$(verdict_of "$sess")
assert_jq "$v" '[.findings[].file] | sort | join(",")' "empty,nul,via,é nul" \
	"each unshown link is named, as is a chain through one"
assert_jq "$v" '[.findings[] | select(.file == "nul") | .evidence] | join("")' "$unshown" \
	"evidence is the fixed marker, never empty"
assert_jq "$v" '[.findings[] | select(.file == "nul") | .description | test("could not be read from the diff")] | all' \
	"true" "the description says why"
if grep -qF "\"nul\" -> $unshown (escapes)" "$sess/symlinks.txt"; then
	echo "  PASS: symlinks.txt lists it as escaping with the marker"
	PASS=$((PASS + 1))
else
	echo "  FAIL: symlinks.txt does not list the unshown link with the marker"
	FAIL=$((FAIL + 1))
fi
rm -rf "$sess"

echo "Test 10: without the head tree's list, a pure rename shows no link"
# A similarity-100% rename carries neither target nor mode in the diff; only
# head-links.json can say the new path is a link (Test 14).
sess=$(session_from_change 'ln -s /etc/passwd l1 && git add -A && git commit -qm l &&
	git tag -f base >/dev/null && git mv l1 l2')
result=$(bash "$SCRIPT" "$sess")
assert_json_field "$result" "links" "0" "a similarity-100% rename shows no link"
assert_json_field "$result" "head_links" "unavailable" "the payload says the list was missing"
rm -rf "$sess"

echo "Test 11: a path holding a space keys the link map without git's trailing TAB"
# Git ends a +++ line with a raw TAB when the path holds a space. Kept, it made
# `sub/d sp` a different key from the one `x` walks through, so x was judged
# lexically (sub/d sp/.. is sub, inside) instead of through the link (.. from
# sub is the root, and one more .. leaves it).
sess=$(session_from_change 'mkdir sub && ln -s .. "sub/d sp" && ln -s "sub/d sp/.." x')
bash "$SCRIPT" "$sess" >/dev/null
v=$(verdict_of "$sess")
assert_jq "$v" '[.findings[].file] | join(",")' "x" "the chain through the spaced link escapes"
if grep -qF '"sub/d sp" -> ".." (inside)' "$sess/symlinks.txt"; then
	echo "  PASS: the spaced path is listed without a TAB"
	PASS=$((PASS + 1))
else
	echo "  FAIL: the spaced path is listed wrongly"
	FAIL=$((FAIL + 1))
fi
rm -rf "$sess"

echo "Test 12: a CRLF diff.patch is read like an LF one"
sess=$(session_from_change 'ln -s /etc/passwd leak')
awk '{ printf "%s\r\n", $0 }' "$sess/diff.patch" >"$sess/crlf.patch"
mv "$sess/crlf.patch" "$sess/diff.patch"
result=$(bash "$SCRIPT" "$sess")
assert_json_field "$result" "escaping" "1" "the link is still reported"
v=$(verdict_of "$sess")
assert_jq "$v" '.findings[0].evidence' "/etc/passwd" "the target carries no CR"
rm -rf "$sess"

echo "Test 13: the target stays out of the Markdown-rendered description"
# The description is rendered as Markdown in the PR comment, where the change
# author's text could @mention or link; the evidence is rendered as code.
sess=$(session_from_change 'ln -s "/x @someone [a](http://evil)" leak')
bash "$SCRIPT" "$sess" >/dev/null
v=$(verdict_of "$sess")
assert_jq "$v" '.findings[0].evidence' "/x @someone [a](http://evil)" "the target is the evidence"
assert_jq "$v" '.findings[0].description | test("@someone|evil")' "false" "the description does not quote it"
rm -rf "$sess"

# head-links.json fixtures are written by hand: they are the contract
# rc_forge_fetch_links and the index listing in lib/prepare-links.sh must meet.

echo "Test 14: a pure rename is judged at its new path from the head tree's list (RC-078)"
# docs/l -> ../secret stays inside; moved to the root, the same text escapes.
# The diff shows only `rename from`/`rename to`, with no mode and no hunk.
sess=$(session_from_change 'mkdir docs && ln -s ../secret docs/l && git add -A && git commit -qm l &&
	git tag -f base >/dev/null && git mv docs/l l')
if grep -qx 'similarity index 100%' "$sess/diff.patch" && ! grep -q '^@@' "$sess/diff.patch"; then
	echo "  PASS: the fixture is a pure rename"
	PASS=$((PASS + 1))
else
	echo "  FAIL: the fixture diff is not a pure rename"
	FAIL=$((FAIL + 1))
fi
echo '[{"path": "l", "target": "../secret"}]' >"$sess/head-links.json"
result=$(bash "$SCRIPT" "$sess")
assert_json_field "$result" "links" "1" "the moved link is a changed link"
assert_json_field "$result" "head_links" "available" "the payload says the list was read"
v=$(verdict_of "$sess")
assert_jq "$v" '[.findings[] | "\(.severity) \(.file)"] | join(",")' "HIGH l" "a HIGH at the new path"
assert_jq "$v" '.findings[0].evidence' "../secret" "the target comes from the list"
rm -rf "$sess"
# A renamed ordinary file is not in the list, so it is not a link.
sess=$(session_from_change 'echo hi >f1 && git add -A && git commit -qm f &&
	git tag -f base >/dev/null && git mv f1 f2')
echo '[]' >"$sess/head-links.json"
result=$(bash "$SCRIPT" "$sess")
assert_json_field "$result" "links" "0" "a renamed file absent from the list is ignored"
rm -rf "$sess"

echo "Test 15: a chain through a link the change does not touch (RC-078)"
# sub/up -> .. is on the base and stays inside; x -> sub/up/.. resolves to the
# repository's parent. Planted in an earlier PR, sub/up is not in this diff.
sess=$(session_from_change 'mkdir sub && ln -s .. sub/up && git add -A && git commit -qm up &&
	git tag -f base >/dev/null && ln -s sub/up/.. x')
echo '[{"path": "sub/up", "target": ".."}, {"path": "x", "target": "sub/up/.."}]' >"$sess/head-links.json"
v=$(verdict_of "$sess")
bash "$SCRIPT" "$sess" >/dev/null
assert_jq "$v" '[.findings[].file] | join(",")' "x" "x is reported, the untouched sub/up is not"
rm -rf "$sess"

echo "Test 16: an untouched link a retarget makes escape is reported through it (RC-078)"
# a -> b/../.. stays inside while b -> sub/deep; retargeting b -> sub makes a
# leave the repository. old -> /etc escaped on the base already, depends on no
# change, and is out of scope.
sess=$(session_from_change 'mkdir -p sub/deep && touch sub/deep/f && ln -s sub/deep b && ln -s b/../.. a &&
	git add -A && git commit -qm links && git tag -f base >/dev/null && rm b && ln -s sub b')
echo '[{"path": "a", "target": "b/../.."}, {"path": "b", "target": "sub"}, {"path": "old", "target": "/etc"}]' \
	>"$sess/head-links.json"
result=$(bash "$SCRIPT" "$sess")
assert_json_field "$result" "links" "1" "only b is a changed link"
assert_json_field "$result" "escaping" "1" "one link reported"
v=$(verdict_of "$sess")
assert_jq "$v" '[.findings[].file] | join(",")' "a" "a is reported; b stays inside; old is not reported"
assert_jq "$v" '.findings[0].evidence' "b/../.." "a's target is the evidence"
# shellcheck disable=SC2016 # a jq program; the backticks are literal Markdown.
assert_jq "$v" '.findings[0].description | test("does not touch") and test("`\"b\"`")' "true" \
	"the description says the change made it escape, naming b"
if grep -qF '"a" -> "b/../.." (escapes through changed link "b")' "$sess/symlinks.txt"; then
	echo "  PASS: symlinks.txt names the changed link it follows"
	PASS=$((PASS + 1))
else
	echo "  FAIL: symlinks.txt does not list a through b"
	FAIL=$((FAIL + 1))
fi
rm -rf "$sess"

echo "Test 17: a link whose target the list could not read counts as escaping (RC-078)"
sess=$(session_from_change 'ln -s n/x y')
echo '[{"path": "n", "target": null}, {"path": "y", "target": "n/x"}]' >"$sess/head-links.json"
v=$(verdict_of "$sess")
bash "$SCRIPT" "$sess" >/dev/null
assert_jq "$v" '[.findings[].file] | join(",")' "y" "a chain through the unknown link is reported"
rm -rf "$sess"
sess=$(session_from_change 'ln -s README l1 && git add -A && git commit -qm l &&
	git tag -f base >/dev/null && git mv l1 l2')
echo '[{"path": "l2", "target": null}]' >"$sess/head-links.json"
v=$(verdict_of "$sess")
bash "$SCRIPT" "$sess" >/dev/null
assert_jq "$v" '[.findings[] | "\(.file) \(.evidence)"] | join(",")' \
	"l2 (symlink target not readable from the head tree)" "a moved link with an unknown target is reported"
rm -rf "$sess"

echo "Test 18: without the list the check says so; a malformed list stops it (RC-078)"
disclosure="# The head tree's link list was unavailable: pure renames and chains through links this change does not touch were not judged."
sess=$(session_from_change 'ln -s /tmp/rc-canary.txt leak')
result=$(bash "$SCRIPT" "$sess")
assert_json_field "$result" "head_links" "unavailable" "the payload says the list was missing"
assert_json_field "$result" "escaping" "1" "the diff's own link is still judged"
if grep -qxF "$disclosure" "$sess/symlinks.txt"; then
	echo "  PASS: symlinks.txt discloses the missing list"
	PASS=$((PASS + 1))
else
	echo "  FAIL: symlinks.txt does not disclose the missing list"
	FAIL=$((FAIL + 1))
fi
echo '[]' >"$sess/head-links.json"
bash "$SCRIPT" "$sess" >/dev/null
if grep -qF "link list was unavailable" "$sess/symlinks.txt"; then
	echo "  FAIL: the disclosure is written although the list was read"
	FAIL=$((FAIL + 1))
else
	echo "  PASS: no disclosure when the list was read"
	PASS=$((PASS + 1))
fi
echo '[{"path": "leak", "target": 7}]' >"$sess/head-links.json"
result=$(bash "$SCRIPT" "$sess")
assert_json_field "$result" "status" "error" "a list that is not {path, target} links is an error"
rm -rf "$sess"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
