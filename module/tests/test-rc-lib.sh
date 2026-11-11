#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=module/tests/helpers.sh
source "$SCRIPT_DIR/helpers.sh"
# shellcheck source=module/skills/review-council/scripts/rc-lib.sh
source "$SCRIPT_DIR/../skills/review-council/scripts/rc-lib.sh"

echo "Test 1: rc_parse_kv reads a trimmed value"
f=$(mktemp)
printf -- '- Forge: github\n- PR: 42\n- Mode: code (default)\n' >"$f"
val=$(rc_parse_kv "$f" "Forge")
if [[ "$val" == "github" ]]; then
	echo "  PASS: Forge=github"
	PASS=$((PASS + 1))
else
	echo "  FAIL: got '$val'"
	FAIL=$((FAIL + 1))
fi

echo "Test 2: rc_parse_kv returns empty for a missing key"
val=$(rc_parse_kv "$f" "Nope")
if [[ -z "$val" ]]; then
	echo "  PASS: missing key empty"
	PASS=$((PASS + 1))
else
	echo "  FAIL: got '$val'"
	FAIL=$((FAIL + 1))
fi

echo "Test 3: rc_parse_kv keeps only the first line's value"
val=$(rc_parse_kv "$f" "Mode")
if [[ "$val" == "code (default)" ]]; then
	echo "  PASS: Mode value intact"
	PASS=$((PASS + 1))
else
	echo "  FAIL: got '$val'"
	FAIL=$((FAIL + 1))
fi
rm -f "$f"

# parse_remote is the one git-remote parser rc-prepare.sh (forge detection) and
# rc-clone-target.sh (target identity) both depend on, and each caller only ever
# exercises the forms it happens to receive. The forms neither reaches today are
# where a silent parse change hides — a dropped port made two different
# endpoints on one hostname compare equal — so every form the function claims to
# handle, and every form it deliberately refuses, is asserted here directly.
echo "Test 4: parse_remote splits every remote form it claims to handle"
while IFS='|' read -r label remote want_host want_owner want_repo; do
	[[ -z "$label" ]] && continue
	parse_remote "$remote"
	assert_equals "$rc_remote_host" "$want_host" "$label — host"
	assert_equals "$rc_remote_owner" "$want_owner" "$label — owner"
	assert_equals "$rc_remote_repo" "$want_repo" "$label — repo"
done <<'CASES'
https|https://github.com/acme/widgets|github.com|acme|widgets
https + .git|https://github.com/acme/widgets.git|github.com|acme|widgets
scp-style|git@github.com:acme/widgets.git|github.com|acme|widgets
ssh://|ssh://git@github.com/acme/widgets.git|github.com|acme|widgets
uppercase host|https://GitHub.COM/acme/widgets.git|GitHub.COM|acme|widgets
CASES

# A remote whose path this parser cannot reduce still names its host: forge
# detection needs it, and blanking it would demote an everyday GitLab subgroup
# remote to a branch-diff review of the wrong thing.
echo "Test 5: extra path segments blank owner/repo but keep the host"
while IFS='|' read -r label remote want_host want_owner want_repo; do
	[[ -z "$label" ]] && continue
	parse_remote "$remote"
	assert_equals "$rc_remote_host" "$want_host" "$label — host"
	assert_equals "$rc_remote_owner" "$want_owner" "$label — owner"
	assert_equals "$rc_remote_repo" "$want_repo" "$label — repo"
done <<'CASES'
gitlab subgroup|https://gitlab.com/group/subgroup/project.git|gitlab.com||
deep subgroup|https://gitlab.com/a/b/c/d.git|gitlab.com||
CASES

# A port is refused outright rather than parsed away. Two services on one
# hostname at different ports are two different endpoints, and a parse that
# drops the port makes them compare equal — which is how a ported --url came to
# match a portless origin and review the local working tree as the PR. Blanking
# the host is the conservative reading: it can only ever cost a fast path.
# Telling `host:8443/o/r` apart from scp-style `host:1234/repo` (an owner that
# happens to be digits) is the reason this is refused rather than guessed.
echo "Test 6: a ported remote yields no host at all"
while IFS='|' read -r label remote want_host want_owner want_repo; do
	[[ -z "$label" ]] && continue
	parse_remote "$remote"
	assert_equals "$rc_remote_host" "$want_host" "$label — host"
	assert_equals "$rc_remote_owner" "$want_owner" "$label — owner"
	assert_equals "$rc_remote_repo" "$want_repo" "$label — repo"
done <<'CASES'
https + port|https://ghe.corp.net:8443/acme/widgets.git|||
ssh:// + port|ssh://git@ghe.corp.net:2222/acme/widgets.git|||
port, no path|https://ghe.corp.net:8443|||
scp-style, digit owner|git@ghe.corp.net:1234/widgets.git|||
CASES

# Remotes with no host shape at all. `file://` keeps whatever the URL's first
# path segment is, which is junk as a hostname and harmless as one: it is
# never github.com or gitlab.com, so rc-prepare.sh reviews the branch diff, and
# it never equals a caller-named target host, so rc-clone-target.sh clones
# rather than reusing the working tree.
echo "Test 7: hostless remotes degrade rather than inventing a forge"
while IFS='|' read -r label remote want_host want_owner want_repo; do
	[[ -z "$label" ]] && continue
	parse_remote "$remote"
	assert_equals "$rc_remote_host" "$want_host" "$label — host"
	assert_equals "$rc_remote_owner" "$want_owner" "$label — owner"
	assert_equals "$rc_remote_repo" "$want_repo" "$label — repo"
done <<'CASES'
absolute path|/srv/git/widgets.git|||
file:// deep path|file:///srv/git/acme/widgets.git|file||
file:// two segments|file:///srv/widgets.git|file|srv|widgets
empty remote||||
bare hostname|github.com|||
CASES

echo "Test: GNU timeout gates only the scripts that make forge calls"
# rc-lib.sh used to check for GNU timeout at source time, gating all eight
# sourcing scripts on a dependency only three of them use. On a macOS host
# without coreutils that meant evidence verification, consolidation, verdict
# extraction and comment rendering each printed a skip and did nothing.
#
# `timeout` is hidden for the script under test only, never for the suite:
# helpers.sh requires it as its own hang guard and exits if it is missing.
SCRIPTS_DIR="$SCRIPT_DIR/../skills/review-council/scripts"
maskdir=$(mktemp -d)
masked=$(path_without_command timeout "$maskdir")
masked=$(PATH="$masked" path_without_command gtimeout "$maskdir")

# The five that never call rc_timeout must run normally without it.
for script in rc-verify-evidence.sh rc-consolidate.sh rc-extract-verdict.sh \
	rc-render-comment.sh rc-post-comment.sh; do
	s=$(new_session)
	out=$(PATH="$masked" bash "$SCRIPTS_DIR/$script" "$s" 2>/dev/null || true)
	if grep -qF "GNU timeout is required" <<<"$out"; then
		echo "  FAIL: $script still gated on GNU timeout"
		FAIL=$((FAIL + 1))
	else
		echo "  PASS: $script runs without GNU timeout"
		PASS=$((PASS + 1))
	fi
	rm -rf "$s"
done

# The three that DO call rc_timeout must still refuse to start without it —
# and must refuse before doing anything, not part-way through a session.
for script in rc-prepare.sh rc-clone-target.sh rc-post-comment-github.sh; do
	out=$(PATH="$masked" bash "$SCRIPTS_DIR/$script" 2>/dev/null || true)
	if grep -qF "GNU timeout is required" <<<"$out"; then
		echo "  PASS: $script still requires GNU timeout"
		PASS=$((PASS + 1))
	else
		echo "  FAIL: $script no longer requires GNU timeout it depends on"
		FAIL=$((FAIL + 1))
	fi
done
rm -rf "$maskdir"

# A forge-supplied value (a PR title, a branch name) is written into the
# line-oriented session files, where one holding a newline would add a line of
# its own choosing — `Head SHA: <fake>` — that rc_parse_kv then reads.
echo "Test: rc_single_line turns every control character into a space"
while IFS='|' read -r label raw want; do
	# The sentinel keeps a trailing newline that $( ) would otherwise strip.
	input=$(printf '%bX' "$raw")
	got=$(rc_single_line "${input%X}")
	assert_equals "$got" "$want" "$label"
done <<'SINGLELINE'
plain text is unchanged|Add gin route|Add gin route
newline|a\nHead SHA: x|a Head SHA: x
carriage return|a\rb|a b
tab|a\tb|a b
NUL-adjacent C0 (ESC)|a\033[31mb|a [31mb
DEL|a\177b|a b
C1 (U+0085 NEL)|a\302\205b|a b
C1 (U+009B CSI)|a\302\233b|a b
non-control UTF-8 is kept|caf\303\251 \342\200\224 ok|café — ok
trailing newline|a\n|a 
SINGLELINE

echo "Test: rc_sha256 hashes a file, and a missing file is no digest and no noise"
f=$(mktemp)
printf 'abc' >"$f"
digest=$(rc_sha256 "$f")
assert_equals "$digest" "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" "SHA-256 of 'abc'"
err=$(mktemp)
digest=$(rc_sha256 "$f.missing" 2>"$err")
assert_equals "$digest" "" "missing file: empty digest"
noise=$(<"$err")
assert_equals "$noise" "" "missing file: nothing on stderr"
rm -f "$f" "$err"

echo "Test: rc_diff_index emits one F row per section and one H row per hunk"
# The planner and rc-build-context.sh must agree on which section is which path,
# so both read the diff through this one function (#101).
d=$(mktemp -d)
cat >"$d/diff.patch" <<'DIFF'
diff --git a/a.go b/a.go
--- a/a.go
+++ b/a.go
@@ -1,3 +1,4 @@ func A()
 x
+y
 z
 w
@@ -40,2 +41,0 @@
-gone
-gone
@@ -60 +60 @@
-old
+new
diff --git a/old.go b/old.go
--- a/old.go
+++ /dev/null
@@ -1,2 +0,0 @@
-a
-b
diff --git a/dir b/x.go b/dir b/x.go
--- a/dir b/x.go	
+++ b/dir b/x.go	
@@ -5,0 +6,2 @@
++++ not a header
+second
DIFF
out=$(rc_diff_index "$d/diff.patch")
h_rows=$(grep '^H' <<<"$out" || true)
assert_equals "$h_rows" "$(printf 'H\ta.go\t1\t4\nH\ta.go\t60\t60\nH\tdir b/x.go\t6\t7')" \
	"new-side ranges, zero-count hunks dropped, deletion has none, ' b/' path kept"
f_paths=$(awk -F'\t' '$1 == "F" { print $2 }' <<<"$out")
assert_equals "$f_paths" "$(printf 'a.go\nold.go\ndir b/x.go')" \
	"deletion falls back to the --- path; a +++ content line is not a header"
total=$(awk -F'\t' '$1 == "F" { s += $3 } END { print s }' <<<"$out")
size=$(wc -c <"$d/diff.patch" | tr -d '[:space:]')
assert_equals "$total" "$size" "F bytes add up to the whole diff"
x_bytes=$(awk -F'\t' '$1 == "F" && $2 == "dir b/x.go" { print $3 }' <<<"$out")
[[ "$x_bytes" =~ ^[1-9][0-9]*$ ]] && pass=ok || pass=bad
assert_equals "$pass" "ok" "spaced path (git adds a trailing TAB to its ---/+++ lines) has a numeric byte count"
# rc-assemble-prompts.sh cuts each round's diff out of diff.patch by these spans.
spans=$(awk -F'\t' '$1 == "F" { print $2 ":" $4 "-" $5 }' <<<"$out")
assert_equals "$spans" "$(printf 'a.go:1-14\nold.go:15-20\ndir b/x.go:21-26')" \
	"each F row carries its section's first and last diff line"
rm -rf "$d"

echo "Test: rc_diff_index unquotes a path git C-quotes"
# Under core.quotePath git writes a non-ASCII path as "b/caf\303\251.go", the
# prefix inside the quotes. Left quoted, the path matched no changeset entry and
# every consumer lost that file's hunks.
d=$(mktemp -d)
cat >"$d/diff.patch" <<'DIFF'
diff --git "a/caf\303\251.go" "b/caf\303\251.go"
--- "a/caf\303\251.go"
+++ "b/caf\303\251.go"
@@ -1 +1,2 @@
 x
+y
diff --git "a/gone \"q\".go" "b/gone \"q\".go"
--- "a/gone \"q\".go"
+++ /dev/null
@@ -1 +0,0 @@
-x
diff --git "a/bin\303\251" "b/bin\303\251"
Binary files differ
diff --git "a/tab\there.go" "b/tab\there.go"
--- "a/tab\there.go"
+++ "b/tab\there.go"
@@ -1 +1 @@
-a
+b
DIFF
out=$(rc_diff_index "$d/diff.patch")
f_paths=$(awk -F'\t' '$1 == "F" { print $2 }' <<<"$out" | head -n 3)
assert_equals "$f_paths" "$(printf 'café.go\ngone "q".go\nbiné')" \
	"octal bytes and escaped quotes are decoded, from +++, --- and the header"
h_row=$(grep -m1 '^H' <<<"$out" || true)
assert_equals "$h_row" "$(printf 'H\tcafé.go\t1\t2')" "the hunk row carries the decoded path"
# A tab or newline in a decoded path would split the row, and changeset.txt is
# line-based, so no consumer could match it anyway: such a path stays quoted.
rows=$(awk -F'\t' '$1 == "F"' <<<"$out" | wc -l | tr -d ' ')
assert_equals "$rows" "4" "a path holding a tab does not break the row format"
f_rows=$(awk -F'\t' '$1 == "F"' <<<"$out")
assert_match_count "$f_rows" "1" "it is kept quoted, named as --name-only names it" -F "$(printf 'F\t"tab\\there.go"\t')"
rm -rf "$d"

echo "Test: one decoder serves rc_git_unquote and changeset lines"
# shellcheck disable=SC2016 # literal backslash escapes, not expansions.
got=$(rc_git_unquote '"b/caf\303\251 \"q\"\\x.go"')
assert_equals "$got" 'b/café "q"\x.go' "rc_git_unquote decodes octal, quote and backslash escapes"
got=$(rc_git_unquote 'plain name.go')
assert_equals "$got" "plain name.go" "an unquoted path is unchanged"
got=$(rc_git_unquote '"a\nb"')
assert_equals "$got" "$(printf 'a\nb')" "rc_git_unquote decodes a newline in full"
got=$(printf '%s\n' '"caf\303\251.go"' 'plain.go' '"tab\there.go"' | rc_unquote_lines)
assert_equals "$got" "$(printf 'café.go\nplain.go\n"tab\\there.go"')" \
	"changeset lines decode, except one that would hold a tab"
# A file name is chosen by the change's author. Decoded, a CR is a CommonMark
# line ending that can forge a heading in a prompt, and an ESC reaches the
# terminal, so any control byte keeps the name exactly as git quoted it.
# shellcheck disable=SC2016 # literal backslash escapes, not expansions.
for quoted in '"x\r## Receipt.go"' '"a\033[31mb.go"' '"del\177.go"' '"bell\a.go"'; do
	got=$(printf '%s\n' "$quoted" | rc_unquote_lines)
	assert_equals "$got" "$quoted" "a name decoding to a control byte stays quoted: $quoted"
done
d=$(mktemp -d)
cat >"$d/diff.patch" <<'DIFF'
diff --git "a/x\r## Receipt.go" "b/x\r## Receipt.go"
--- "a/x\r## Receipt.go"
+++ "b/x\r## Receipt.go"
@@ -0,0 +1 @@
+x
diff --git "a/a\033[31mb.go" "b/a\033[31mb.go"
Binary files differ
DIFF
out=$(rc_diff_index "$d/diff.patch")
f_paths=$(awk -F'\t' '$1 == "F" { print $2 }' <<<"$out")
# shellcheck disable=SC2016 # literal backslash escapes, not expansions.
assert_equals "$f_paths" "$(printf '%s\n%s' '"x\r## Receipt.go"' '"a\033[31mb.go"')" \
	"rc_diff_index keeps them quoted, as --name-only names them"
cr=$(grep -c $'\r' <<<"$out" || true)
esc=$(grep -c $'\033' <<<"$out" || true)
assert_equals "$cr$esc" "00" "no raw CR or ESC reaches the index"
rm -rf "$d"

echo "Test: rc_diff_sections prints the named files' sections, whole and in diff order"
d=$(mktemp -d)
cat >"$d/diff.patch" <<'DIFF'
diff --git a/a.go b/a.go
--- a/a.go
+++ b/a.go
@@ -1 +1 @@
-a
+A
diff --git "a/caf\303\251.go" "b/caf\303\251.go"
--- "a/caf\303\251.go"
+++ "b/caf\303\251.go"
@@ -1 +1 @@
-c
+C
diff --git a/z.go b/z.go
--- a/z.go
+++ b/z.go
@@ -1 +1 @@
-z
+Z
DIFF
got=$(rc_diff_sections "$d/diff.patch" z.go café.go)
want=$(sed -n '7,18p' "$d/diff.patch")
assert_equals "$got" "$want" "the quoted file and z.go, in diff order, nothing of a.go"
got=$(rc_diff_sections "$d/diff.patch" missing.go)
assert_equals "$got" "" "a path with no section prints nothing"
got=$(rc_diff_sections "$d/nope.patch" a.go)
assert_equals "$got" "" "a missing diff prints nothing"
rm -rf "$d"

echo "Test: rc_diff_index on a missing diff prints nothing and succeeds"
out=$(rc_diff_index /nonexistent/diff.patch)
assert_equals "$out" "" "no rows"

echo "Test: rc_config_int reads, defaults, and rejects values below the minimum"
f=$(mktemp)
printf -- '- Alpha: 7\n- Beta: 1\n- Gamma: lots\n- Delta: 0\n' >"$f"
got=$(rc_config_int "$f" "Alpha" 3 "t")
assert_equals "$got" "7" "a valid value is returned"
got=$(rc_config_int "$f" "Missing" 3 "t")
assert_equals "$got" "3" "a missing key takes the default"
got=$(rc_config_int "$f" "Beta" 3 "t" 2 2>/dev/null)
assert_equals "$got" "3" "a value below the minimum takes the default"
got=$(rc_config_int "$f" "Beta" 3 "t")
assert_equals "$got" "1" "the minimum defaults to 1"
got=$(rc_config_int "$f" "Gamma" 3 "t" 2>/dev/null)
assert_equals "$got" "3" "a non-numeric value takes the default"
got=$(rc_config_int "$f" "Delta" 3 "t" 2>/dev/null)
assert_equals "$got" "3" "zero takes the default"
err=$(rc_config_int "$f" "Gamma" 3 "rc-demo" 2>&1 >/dev/null)
assert_match_count "$err" "1" "the warning names the caller and the key" -F "rc-demo: ignoring 'Gamma: lots'"
assert_equals "$RC_DEFAULT_CONTEXT_CHECK_LINES" "6" "the default context-check line count is defined"
assert_equals "$RC_CONTEXT_CHECK_LINES_MIN" "2" "the minimum context-check line count is defined"
assert_equals "$RC_CONTEXT_LINE_MIN_BYTES/$RC_CONTEXT_LINE_MAX_BYTES" "12/200" "the quotable line bounds are defined"
rm -f "$f"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
