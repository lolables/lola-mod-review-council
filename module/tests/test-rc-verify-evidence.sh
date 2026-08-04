#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$SCRIPT_DIR/../skills/review-council/scripts/rc-verify-evidence.sh"
# shellcheck source=module/tests/helpers.sh
source "$SCRIPT_DIR/helpers.sh"

# Write an agent verdict JSON into a session.
agent_json() { # session agent verdict findings_json
	printf '{"agent":"%s","files_read":[],"verdict":"%s","findings":%s}\n' "$2" "$3" "$4" >"$1/verdicts/$2.json"
}

echo "Test 1: missing session"
result=$(bash "$SCRIPT" "/nonexistent" 2>/dev/null)
assert_json_field "$result" "status" "nothing_to_do" "nothing_to_do"

echo "Test 2: verified finding + verbatim verdict"
s=$(new_session)
src=$(mktemp -d)
echo 'func main() { fmt.Println("hi") }' >"$src/main.go"
agent_json "$s" "divisor-adversary-code" "REQUEST CHANGES" \
	'[{"severity":"HIGH","file":"main.go","line":1,"evidence":"func main() { fmt.Println(\"hi\") }","description":"d","recommendation":"r"}]'
result=$(cd "$src" && bash "$SCRIPT" "$s")
assert_json_field "$result" "status" "ok" "ok"
vc=$(echo "$result" | jq '.verified')
if [[ "$vc" -eq 1 ]]; then
	echo "  PASS: verified 1"
	PASS=$((PASS + 1))
else
	echo "  FAIL: verified $vc"
	FAIL=$((FAIL + 1))
fi
vv=$(jq -r '.verdicts."divisor-adversary-code"' "$s/verdicts/findings.json")
if [[ "$vv" == "REQUEST CHANGES" ]]; then
	echo "  PASS: verdict verbatim"
	PASS=$((PASS + 1))
else
	echo "  FAIL: verdict '$vv'"
	FAIL=$((FAIL + 1))
fi
rm -rf "$s" "$src"

echo "Test 3: fabricated file stripped"
s=$(new_session)
src=$(mktemp -d)
echo "package main" >"$src/real.go"
agent_json "$s" "divisor-testing-code" "REQUEST CHANGES" \
	'[{"severity":"CRITICAL","file":"fake.go","line":10,"evidence":"db.Query(x)","description":"d","recommendation":"r"}]'
result=$(cd "$src" && bash "$SCRIPT" "$s")
sc=$(echo "$result" | jq '.stripped')
if [[ "$sc" -eq 1 ]]; then
	echo "  PASS: stripped 1"
	PASS=$((PASS + 1))
else
	echo "  FAIL: stripped $sc"
	FAIL=$((FAIL + 1))
fi
rm -rf "$s" "$src"

echo "Test 4: dedup same file/evidence"
s=$(new_session)
src=$(mktemp -d)
echo 'func main() { fmt.Println("hi") }' >"$src/main.go"
agent_json "$s" "divisor-adversary-code" "REQUEST CHANGES" '[{"severity":"HIGH","file":"main.go","line":1,"evidence":"func main() { fmt.Println(\"hi\") }","description":"d","recommendation":"r"}]'
agent_json "$s" "divisor-guard-code" "REQUEST CHANGES" '[{"severity":"MEDIUM","file":"main.go","line":1,"evidence":"func main() { fmt.Println(\"hi\") }","description":"d","recommendation":"r"}]'
result=$(cd "$src" && bash "$SCRIPT" "$s")
vc=$(echo "$result" | jq '.verified')
if [[ "$vc" -eq 1 ]]; then
	echo "  PASS: dedup to 1"
	PASS=$((PASS + 1))
else
	echo "  FAIL: verified $vc"
	FAIL=$((FAIL + 1))
fi
rm -rf "$s" "$src"

echo "Test 5: line outside tolerance -> correctable LINE_MISMATCH"
s=$(new_session)
src=$(mktemp -d)
printf 'func main() {}\n' >"$src/main.go"
for i in $(seq 2 20); do echo "l$i" >>"$src/main.go"; done
agent_json "$s" "divisor-adversary-code" "REQUEST CHANGES" '[{"severity":"HIGH","file":"main.go","line":20,"evidence":"func main() {}","description":"d","recommendation":"r"}]'
result=$(cd "$src" && bash "$SCRIPT" "$s")
cc=$(echo "$result" | jq '.correctable')
if [[ "$cc" -eq 1 ]]; then
	echo "  PASS: correctable 1"
	PASS=$((PASS + 1))
else
	echo "  FAIL: correctable $cc"
	FAIL=$((FAIL + 1))
fi
r=$(jq -r '.correctable[0].reason' "$s/verdicts/findings.json")
if [[ "$r" == "LINE_MISMATCH" ]]; then
	echo "  PASS: LINE_MISMATCH"
	PASS=$((PASS + 1))
else
	echo "  FAIL: reason '$r'"
	FAIL=$((FAIL + 1))
fi
rm -rf "$s" "$src"

echo "Test 6: tabs in evidence verify against real tabs in source"
s=$(new_session)
src=$(mktemp -d)
printf '\tif cfg.TLS {\n' >"$src/c.go"
agent_json "$s" "divisor-adversary-code" "REQUEST CHANGES" '[{"severity":"MEDIUM","file":"c.go","line":1,"evidence":"\tif cfg.TLS {","description":"d","recommendation":"r"}]'
result=$(cd "$src" && bash "$SCRIPT" "$s")
vc=$(echo "$result" | jq '.verified')
if [[ "$vc" -eq 1 ]]; then
	echo "  PASS: tab evidence verified"
	PASS=$((PASS + 1))
else
	echo "  FAIL: verified $vc"
	FAIL=$((FAIL + 1))
fi
rm -rf "$s" "$src"

echo "Test 7: REVIEW_ROOT prefix, stored path repo-relative"
s=$(new_session)
root=$(mktemp -d)
mkdir -p "$root/pkg"
echo 'package pkg' >"$root/pkg/x.go"
agent_json "$s" "divisor-guard-code" "APPROVE" '[{"severity":"LOW","file":"pkg/x.go","line":1,"evidence":"package pkg","description":"d","recommendation":"r"}]'
result=$(REVIEW_ROOT="$root" bash "$SCRIPT" "$s")
stored=$(jq -r '.verified[0].file' "$s/verdicts/findings.json")
if [[ "$stored" == "pkg/x.go" ]]; then
	echo "  PASS: repo-relative path"
	PASS=$((PASS + 1))
else
	echo "  FAIL: '$stored'"
	FAIL=$((FAIL + 1))
fi
rm -rf "$s" "$root"

echo "Test 8: mixed null/non-null line, same file+evidence -> must NOT dedup"
s=$(new_session)
src=$(mktemp -d)
echo 'func main() { fmt.Println("hi") }' >"$src/main.go"
agent_json "$s" "divisor-adversary-code" "REQUEST CHANGES" \
	'[{"severity":"HIGH","file":"main.go","line":null,"evidence":"func main() { fmt.Println(\"hi\") }","description":"d","recommendation":"r"},{"severity":"HIGH","file":"main.go","line":3,"evidence":"func main() { fmt.Println(\"hi\") }","description":"d","recommendation":"r"}]'
result=$(cd "$src" && bash "$SCRIPT" "$s")
vc=$(echo "$result" | jq '.verified')
if [[ "$vc" -eq 2 ]]; then
	echo "  PASS: mixed null/non-null line not deduped (2)"
	PASS=$((PASS + 1))
else
	echo "  FAIL: verified $vc"
	FAIL=$((FAIL + 1))
fi
rm -rf "$s" "$src"

echo "Test 9: two null-line findings, same file+evidence -> DO dedup"
s=$(new_session)
src=$(mktemp -d)
echo 'func main() { fmt.Println("hi") }' >"$src/main.go"
agent_json "$s" "divisor-adversary-code" "REQUEST CHANGES" \
	'[{"severity":"HIGH","file":"main.go","line":null,"evidence":"func main() { fmt.Println(\"hi\") }","description":"d","recommendation":"r"},{"severity":"HIGH","file":"main.go","line":null,"evidence":"func main() { fmt.Println(\"hi\") }","description":"d","recommendation":"r"}]'
result=$(cd "$src" && bash "$SCRIPT" "$s")
vc=$(echo "$result" | jq '.verified')
if [[ "$vc" -eq 1 ]]; then
	echo "  PASS: null/null line dedup to 1"
	PASS=$((PASS + 1))
else
	echo "  FAIL: verified $vc"
	FAIL=$((FAIL + 1))
fi
rm -rf "$s" "$src"

echo "Test 10: evidence beginning with '-' verifies (RC-002: grep must not parse it as an option)"
s=$(new_session)
src=$(mktemp -d)
printf -- '- **Managed** block\n' >"$src/README.md"
agent_json "$s" "divisor-curator-code" "REQUEST CHANGES" \
	'[{"severity":"LOW","file":"README.md","line":1,"evidence":"- **Managed** block","description":"d","recommendation":"r"}]'
result=$(cd "$src" && bash "$SCRIPT" "$s")
vc=$(echo "$result" | jq '.verified')
if [[ "$vc" -eq 1 ]]; then
	echo "  PASS: dash-leading evidence verified"
	PASS=$((PASS + 1))
else
	echo "  FAIL: verified $vc (expected 1)"
	FAIL=$((FAIL + 1))
fi
rm -rf "$s" "$src"

echo "Test 11: dedup keeps MAX severity, HIGH not absorbed into LOW (RC-003)"
s=$(new_session)
src=$(mktemp -d)
echo 'x := install()' >"$src/a.go"
# One agent, LOW first then HIGH, same file+evidence+line -> deterministic merge order.
agent_json "$s" "divisor-guard-code" "REQUEST CHANGES" \
	'[{"severity":"LOW","file":"a.go","line":1,"evidence":"x := install()","description":"low","recommendation":"r"},{"severity":"HIGH","file":"a.go","line":1,"evidence":"x := install()","description":"high","recommendation":"r"}]'
result=$(cd "$src" && bash "$SCRIPT" "$s")
vc=$(echo "$result" | jq '.verified')
sev=$(jq -r '.verified[0].severity' "$s/verdicts/findings.json")
if [[ "$vc" -eq 1 && "$sev" == "HIGH" ]]; then
	echo "  PASS: merged to 1, severity HIGH"
	PASS=$((PASS + 1))
else
	echo "  FAIL: verified=$vc severity='$sev' (expected 1/HIGH)"
	FAIL=$((FAIL + 1))
fi
rm -rf "$s" "$src"

echo "Test 12: fabricated multi-line evidence is rejected (RC-2, false-positive direction)"
# `grep -F` treats each newline in the pattern as a pattern separator, so a
# multi-line quote is searched as N independent literals and succeeds if ANY
# one matches. A fabricated block whose last line is a bare `}` therefore
# verified against any file containing a `}`. Evidence must match as one
# contiguous block or not at all.
s=$(new_session)
src=$(mktemp -d)
printf 'package main\n\nfunc a() {\n\treturn\n}\n\nfunc b() {\n\treturn\n}\n' >"$src/x.go"
agent_json "$s" "divisor-adversary-code" "REQUEST CHANGES" \
	'[{"severity":"CRITICAL","file":"x.go","line":3,"evidence":"\tdb.Exec(\"DROP TABLE users\") // entirely fabricated\n}","description":"d","recommendation":"r"}]'
result=$(cd "$src" && bash "$SCRIPT" "$s")
vc=$(echo "$result" | jq '.verified')
if [[ "$vc" -eq 0 ]]; then
	echo "  PASS: fabricated block not verified"
	PASS=$((PASS + 1))
else
	echo "  FAIL: verified $vc (fabricated evidence accepted)"
	FAIL=$((FAIL + 1))
fi
r=$(jq -r '.correctable[0].reason // "none"' "$s/verdicts/findings.json")
if [[ "$r" == "EVIDENCE_NOT_FOUND" ]]; then
	echo "  PASS: reason EVIDENCE_NOT_FOUND"
	PASS=$((PASS + 1))
else
	echo "  FAIL: reason '$r'"
	FAIL=$((FAIL + 1))
fi
rm -rf "$s" "$src"

echo "Test 13: accurate multi-line evidence verifies at its true start line (RC-2, false-negative direction)"
# The block below genuinely begins at line 7. The old line-number probe took
# the FIRST `grep -nF` hit, which was an incidental match of the pattern's
# short lines near the top of the file, and reported LINE_MISMATCH against a
# perfectly accurate citation.
s=$(new_session)
src=$(mktemp -d)
# The cited block sits at line 30. A bare `}` — the block's last line, and one
# of the separate literals the old multi-pattern grep searched for — appears at
# line 2, far outside the +-5 window, which is what turned an accurate citation
# into LINE_MISMATCH.
{
	printf 'package main\n}\n'
	for i in $(seq 3 29); do printf 'var pad%d = 0\n' "$i"; done
	printf 'func b() {\n\treturn\n}\n'
} >"$src/x.go"
agent_json "$s" "divisor-guard-code" "REQUEST CHANGES" \
	'[{"severity":"MEDIUM","file":"x.go","line":30,"evidence":"func b() {\n\treturn\n}","description":"d","recommendation":"r"}]'
result=$(cd "$src" && bash "$SCRIPT" "$s")
vc=$(echo "$result" | jq '.verified')
if [[ "$vc" -eq 1 ]]; then
	echo "  PASS: verbatim block verified"
	PASS=$((PASS + 1))
else
	reason=$(jq -r '.correctable[0].reason // "none"' "$s/verdicts/findings.json")
	echo "  FAIL: verified $vc, reason $reason"
	FAIL=$((FAIL + 1))
fi
rm -rf "$s" "$src"

echo "Test 14: repeated block verifies against the cited occurrence, not the first (RC-2)"
# Identical blocks legitimately repeat across sibling test functions and
# sibling handlers. Accepting only the first occurrence rejects a citation of
# the second or third.
s=$(new_session)
src=$(mktemp -d)
{
	printf 'package main\n'
	for i in 1 2 3; do
		printf '\nfunc Test%d(t *testing.T) {\n\terr := root.Execute()\n\trequire.Error(t, err)\n}\n' "$i"
	done
} >"$src/m_test.go"
# Occurrences start at lines 4, 9 and 14; cite the third, whose +-5 window
# (9..19) excludes the first occurrence the old probe always returned.
agent_json "$s" "divisor-testing-code" "REQUEST CHANGES" \
	'[{"severity":"LOW","file":"m_test.go","line":14,"evidence":"\terr := root.Execute()\n\trequire.Error(t, err)","description":"d","recommendation":"r"}]'
result=$(cd "$src" && bash "$SCRIPT" "$s")
vc=$(echo "$result" | jq '.verified')
if [[ "$vc" -eq 1 ]]; then
	echo "  PASS: third occurrence accepted"
	PASS=$((PASS + 1))
else
	reason=$(jq -r '.correctable[0].reason // "none"' "$s/verdicts/findings.json")
	echo "  FAIL: verified $vc, reason $reason"
	FAIL=$((FAIL + 1))
fi
# The middle occurrence too: its window (4..14) contains the first occurrence
# as well, so this case passes even under the old first-match probe — it is
# here to pin the documented behaviour, not because it was ever broken.
s3=$(new_session)
agent_json "$s3" "divisor-testing-code" "REQUEST CHANGES" \
	'[{"severity":"LOW","file":"m_test.go","line":9,"evidence":"\terr := root.Execute()\n\trequire.Error(t, err)","description":"d","recommendation":"r"}]'
result=$(cd "$src" && bash "$SCRIPT" "$s3")
vc=$(echo "$result" | jq '.verified')
if [[ "$vc" -eq 1 ]]; then
	echo "  PASS: second occurrence accepted"
	PASS=$((PASS + 1))
else
	reason=$(jq -r '.correctable[0].reason // "none"' "$s3/verdicts/findings.json")
	echo "  FAIL: verified $vc, reason $reason"
	FAIL=$((FAIL + 1))
fi
rm -rf "$s3"
# A citation far from every occurrence must still be caught.
s2=$(new_session)
agent_json "$s2" "divisor-testing-code" "REQUEST CHANGES" \
	'[{"severity":"LOW","file":"m_test.go","line":40,"evidence":"\terr := root.Execute()\n\trequire.Error(t, err)","description":"d","recommendation":"r"}]'
result=$(cd "$src" && bash "$SCRIPT" "$s2")
r=$(jq -r '.correctable[0].reason // "none"' "$s2/verdicts/findings.json")
if [[ "$r" == "LINE_MISMATCH" ]]; then
	echo "  PASS: citation far from every occurrence still LINE_MISMATCH"
	PASS=$((PASS + 1))
else
	echo "  FAIL: reason '$r' (expected LINE_MISMATCH)"
	FAIL=$((FAIL + 1))
fi
rm -rf "$s" "$s2" "$src"

echo "Test 15: evidence matching thousands of times does not abort the phase (RC-3)"
# `grep -nF ... | head -1` under `set -o pipefail` takes SIGPIPE (exit 141)
# once grep produces more output than the pipe buffer holds, killing the whole
# verification phase and leaving no findings.json behind.
s=$(new_session)
src=$(mktemp -d)
for _ in $(seq 1 20000); do printf 'func b() {\n\treturn\n}\n'; done >"$src/big.go"
agent_json "$s" "divisor-sre-code" "APPROVE" \
	'[{"severity":"LOW","file":"big.go","line":1,"evidence":"func b() {\n\treturn\n}","description":"d","recommendation":"r"}]'
rc=0
result=$(cd "$src" && bash "$SCRIPT" "$s" 2>/dev/null) || rc=$?
if [[ $rc -eq 0 && -f "$s/verdicts/findings.json" ]]; then
	echo "  PASS: completed without SIGPIPE abort"
	PASS=$((PASS + 1))
else
	present=no
	[[ -f "$s/verdicts/findings.json" ]] && present=yes
	echo "  FAIL: exit $rc, findings.json present: $present"
	FAIL=$((FAIL + 1))
fi
vc=$(echo "$result" | jq '.verified // 0')
if [[ "$vc" -eq 1 ]]; then
	echo "  PASS: first occurrence still verified"
	PASS=$((PASS + 1))
else
	echo "  FAIL: verified $vc"
	FAIL=$((FAIL + 1))
fi
rm -rf "$s" "$src"

echo "Test 16: partial-line evidence still verifies (substring semantics preserved)"
# Agents quote fragments, not only whole lines. The contiguous-block matcher
# must not tighten into whole-line equality.
s=$(new_session)
src=$(mktemp -d)
printf 'func run() { db.Exec(query); return nil }\n' >"$src/d.go"
agent_json "$s" "divisor-adversary-code" "REQUEST CHANGES" \
	'[{"severity":"HIGH","file":"d.go","line":1,"evidence":"db.Exec(query)","description":"d","recommendation":"r"}]'
result=$(cd "$src" && bash "$SCRIPT" "$s")
vc=$(echo "$result" | jq '.verified')
if [[ "$vc" -eq 1 ]]; then
	echo "  PASS: mid-line fragment verified"
	PASS=$((PASS + 1))
else
	echo "  FAIL: verified $vc"
	FAIL=$((FAIL + 1))
fi
rm -rf "$s" "$src"

echo "Test 17: regex metacharacters in evidence are matched literally"
# The matcher replaces grep -F, so it must stay literal: no pattern in the
# evidence may be interpreted.
s=$(new_session)
src=$(mktemp -d)
printf 'if m[.*] == a|b then\n' >"$src/r.go"
agent_json "$s" "divisor-guard-code" "APPROVE" \
	'[{"severity":"LOW","file":"r.go","line":1,"evidence":"m[.*] == a|b","description":"d","recommendation":"r"}]'
result=$(cd "$src" && bash "$SCRIPT" "$s")
vc=$(echo "$result" | jq '.verified')
if [[ "$vc" -eq 1 ]]; then
	echo "  PASS: metacharacters matched literally"
	PASS=$((PASS + 1))
else
	echo "  FAIL: verified $vc"
	FAIL=$((FAIL + 1))
fi
# The same pattern must NOT match a file that only satisfies it as a regex.
s2=$(new_session)
src2=$(mktemp -d)
printf 'if mX == a then\n' >"$src2/r.go"
agent_json "$s2" "divisor-guard-code" "APPROVE" \
	'[{"severity":"LOW","file":"r.go","line":1,"evidence":"m[.*] == a|b","description":"d","recommendation":"r"}]'
result=$(cd "$src2" && bash "$SCRIPT" "$s2")
vc=$(echo "$result" | jq '.verified')
if [[ "$vc" -eq 0 ]]; then
	echo "  PASS: regex-only match rejected"
	PASS=$((PASS + 1))
else
	echo "  FAIL: verified $vc (evidence treated as a regex)"
	FAIL=$((FAIL + 1))
fi
rm -rf "$s" "$s2" "$src" "$src2"

echo "Test 18: empty evidence never auto-verifies"
# `grep -qF -- ""` matches every file. An evidence-free finding is by
# definition unverifiable and must not pass the gate.
s=$(new_session)
src=$(mktemp -d)
echo 'package main' >"$src/e.go"
agent_json "$s" "divisor-guard-code" "APPROVE" \
	'[{"severity":"LOW","file":"e.go","line":1,"evidence":"","description":"d","recommendation":"r"}]'
result=$(cd "$src" && bash "$SCRIPT" "$s")
vc=$(echo "$result" | jq '.verified')
if [[ "$vc" -eq 0 ]]; then
	echo "  PASS: empty evidence not verified"
	PASS=$((PASS + 1))
else
	echo "  FAIL: verified $vc (empty evidence accepted)"
	FAIL=$((FAIL + 1))
fi
rm -rf "$s" "$src"

echo "Test 19: clusters.json in verdicts/ is not parsed as an agent verdict (RC-4)"
# phases/verify.md Step 3c instructs the orchestrator to write
# verdicts/clusters.json. A later run of this script globbed it as an agent
# verdict and aborted, breaking the resume path SKILL.md Step 2 advertises.
s=$(new_session)
src=$(mktemp -d)
echo 'package main' >"$src/main.go"
agent_json "$s" "divisor-adversary-code" "APPROVE" \
	'[{"severity":"LOW","file":"main.go","line":1,"evidence":"package main","description":"d","recommendation":"r"}]'
cat >"$s/verdicts/clusters.json" <<'CJ'
{"clusters":[{"members":[{"file":"main.go","line":1,"agent":"divisor-adversary-code"}]}]}
CJ
rc=0
result=$(cd "$src" && bash "$SCRIPT" "$s" 2>/dev/null) || rc=$?
if [[ $rc -eq 0 ]]; then
	echo "  PASS: clean exit with clusters.json present"
	PASS=$((PASS + 1))
else
	echo "  FAIL: exit $rc"
	FAIL=$((FAIL + 1))
fi
vc=$(echo "$result" | jq '.verified // -1')
if [[ "$vc" -eq 1 ]]; then
	echo "  PASS: only the agent verdict was ingested"
	PASS=$((PASS + 1))
else
	echo "  FAIL: verified $vc (expected 1)"
	FAIL=$((FAIL + 1))
fi
agents=$(jq -rc '.verdicts | keys' "$s/verdicts/findings.json")
if [[ "$agents" == '["divisor-adversary-code"]' ]]; then
	echo "  PASS: verdict map free of manifest artifacts"
	PASS=$((PASS + 1))
else
	echo "  FAIL: verdict map $agents"
	FAIL=$((FAIL + 1))
fi
rm -rf "$s" "$src"

echo "Test 20: evidence path escaping the review root is stripped (RC-8)"
# The `file` field is LLM-authored. Resolving it unchecked lets a reviewer
# cite content from any file the process can read — outside the changeset,
# outside the repo — and have it verified as evidence.
s=$(new_session)
# Build the escape target as a SIBLING of the review root, so the traversal is
# a fixed single `../` regardless of how deep the temp directory happens to be.
# Deriving it from an absolute $TMPDIR path instead would hardcode the depth:
# `../..` only climbs out of /tmp/tmp.XXXX, and on a host whose TMPDIR is
# deeper (macOS /var/folders/../T, or any container that sets it) the path
# would simply not exist and get stripped FILE_NOT_FOUND — the test would pass
# its first assertion while never reaching the containment check at all.
base=$(mktemp -d)
root="$base/repo"
mkdir -p "$root/pkg"
echo 'package pkg' >"$root/pkg/x.go"
mkdir -p "$base/secrets"
echo 'SECRET_TOKEN=abc123' >"$base/secrets/creds.env"
agent_json "$s" "divisor-adversary-code" "REQUEST CHANGES" \
	'[{"severity":"CRITICAL","file":"../secrets/creds.env","line":1,"evidence":"SECRET_TOKEN=abc123","description":"d","recommendation":"r"}]'
# Guard the fixture itself: the target must exist and be readable, or the
# containment check is never reached and this test proves nothing.
if [[ ! -f "$root/../secrets/creds.env" ]]; then
	echo "  FAIL: fixture broken — escape target does not resolve"
	FAIL=$((FAIL + 1))
fi
result=$(REVIEW_ROOT="$root" bash "$SCRIPT" "$s")
vc=$(echo "$result" | jq '.verified')
sc=$(echo "$result" | jq '.stripped')
if [[ "$vc" -eq 0 && "$sc" -eq 1 ]]; then
	echo "  PASS: traversal path stripped, not verified"
	PASS=$((PASS + 1))
else
	echo "  FAIL: verified=$vc stripped=$sc (expected 0/1)"
	FAIL=$((FAIL + 1))
fi
r=$(jq -r '.stripped[0].reason // "none"' "$s/verdicts/findings.json")
if [[ "$r" == "PATH_OUTSIDE_ROOT" ]]; then
	echo "  PASS: reason PATH_OUTSIDE_ROOT"
	PASS=$((PASS + 1))
else
	echo "  FAIL: reason '$r'"
	FAIL=$((FAIL + 1))
fi
rm -rf "$s" "$base"

echo "Test 21: in-root path containing .. still verifies (RC-8 must not over-reject)"
s=$(new_session)
root=$(mktemp -d)
mkdir -p "$root/pkg" "$root/cmd"
echo 'package cmd' >"$root/cmd/main.go"
agent_json "$s" "divisor-guard-code" "APPROVE" \
	'[{"severity":"LOW","file":"pkg/../cmd/main.go","line":1,"evidence":"package cmd","description":"d","recommendation":"r"}]'
result=$(REVIEW_ROOT="$root" bash "$SCRIPT" "$s")
vc=$(echo "$result" | jq '.verified')
if [[ "$vc" -eq 1 ]]; then
	echo "  PASS: normalized in-root path verified"
	PASS=$((PASS + 1))
else
	echo "  FAIL: verified $vc (over-rejected a legitimate path)"
	FAIL=$((FAIL + 1))
fi
rm -rf "$s" "$root"

echo "Test 22: a verdict too large for one argv entry still assembles (RC-11)"
# Linux caps a SINGLE argv entry at MAX_ARG_STRLEN (131071 bytes), independent
# of the far larger ARG_MAX total. Handing the verified array to `jq -n` as one
# `--argjson` string crossed that limit at 84 findings on a real review and
# killed the phase with "Argument list too long", leaving no findings.json.
s=$(new_session)
root=$(mktemp -d)
printf -v pad '%4000s' ''
pad=${pad// /x}
for i in $(seq 1 60); do printf 'line%02d %s\n' "$i" "$pad"; done >"$root/big.txt"
# Evidence is the cited line verbatim and the citation is exact, so every
# finding belongs in `verified`. A near-miss would file them under
# `correctable` instead and the size assertion would prove nothing.
findings=$(jq -cn --rawfile body "$root/big.txt" '
	[$body | rtrimstr("\n") | split("\n") | to_entries[] |
	 {severity:"LOW", file:"big.txt", line:(.key + 1), evidence:.value,
	  description:"d", recommendation:"r"}]')
agent_json "$s" "divisor-sre-code" "APPROVE" "$findings"
rc=0
result=$(REVIEW_ROOT="$root" bash "$SCRIPT" "$s" 2>"$s/err.log") || rc=$?
if [[ $rc -ne 0 ]]; then
	detail=$(head -1 "$s/err.log")
	echo "  FAIL: exit $rc — $detail"
	FAIL=$((FAIL + 1))
else
	assert_json_field "$result" "status" "ok" "oversized verdict assembled"
	assert_jq "$s/verdicts/findings.json" '.verified | length' "60" "all 60 findings verified"
fi
rm -rf "$s" "$root"

echo "Test 23: a non-integral line does not silently destroy the run (M39)"
# JSON Schema draft-07 defines `integer` BY VALUE, so a model emitting 12.0
# satisfies both the sourcemeta validator and the jq fallback in
# rc-extract-verdict.sh. That value then reaches `$((line - 5))`, which bash
# rejects as an arithmetic syntax error. The failure does not surface as a
# non-zero exit: it tears down the verification loop, so the offending finding
# AND every finding after it vanish from all three buckets while findings.json
# is still written and `total_findings` still reports the full count — a review
# that looks clean and is silently truncated. Hence the trailing finding here:
# asserting only on the 12.0 one would not notice the collateral loss.
s=$(new_session)
root=$(mktemp -d)
for i in $(seq 1 20); do printf 'line%02d\n' "$i"; done >"$root/n.go"
agent_json "$s" "divisor-adversary-code" "REQUEST CHANGES" \
	'[{"severity":"HIGH","file":"n.go","line":12.0,"evidence":"line12","description":"d","recommendation":"r"},
	  {"severity":"LOW","file":"n.go","line":18,"evidence":"line18","description":"d","recommendation":"r"}]'
rc=0
result=$(REVIEW_ROOT="$root" bash "$SCRIPT" "$s" 2>"$s/err.log") || rc=$?
if [[ $rc -ne 0 ]]; then
	detail=$(head -1 "$s/err.log")
	echo "  FAIL: exit $rc — $detail"
	FAIL=$((FAIL + 1))
elif [[ ! -f "$s/verdicts/findings.json" ]]; then
	echo "  FAIL: findings.json was not written"
	FAIL=$((FAIL + 1))
else
	assert_json_field "$result" "status" "ok" "non-integral line survives the phase"
	assert_jq "$s/verdicts/findings.json" '.verified | length' "2" \
		"floored finding and its successor both verified"
fi
rm -rf "$s" "$root"

echo "Test 24: an exponent-form line does not silently destroy the run (M39)"
# `floor` normalises 12.0 to 12 but leaves 1e300 as the literal "1e+300", which
# bash arithmetic rejects exactly as it rejects "12.0". The schema's maximum
# closes this on hosts carrying a real validator; the jq fallback in
# rc-extract-verdict.sh does test integrality, but nothing in it tests
# magnitude, so on every other host 1e300 passes. Anything outside the bounds is
# therefore read as an uncited line: evidence still has to match, the finding
# is simply not line-anchored, and the rest of the run survives.
s=$(new_session)
root=$(mktemp -d)
for i in $(seq 1 20); do printf 'line%02d\n' "$i"; done >"$root/n.go"
agent_json "$s" "divisor-sre-code" "REQUEST CHANGES" \
	'[{"severity":"HIGH","file":"n.go","line":1e300,"evidence":"line12","description":"d","recommendation":"r"},
	  {"severity":"LOW","file":"n.go","line":18,"evidence":"line18","description":"d","recommendation":"r"}]'
rc=0
result=$(REVIEW_ROOT="$root" bash "$SCRIPT" "$s" 2>"$s/err.log") || rc=$?
if [[ $rc -ne 0 ]]; then
	detail=$(head -1 "$s/err.log")
	echo "  FAIL: exit $rc — $detail"
	FAIL=$((FAIL + 1))
else
	assert_jq "$s/verdicts/findings.json" '.verified | length' "2" \
		"out-of-bounds line and its successor both verified"
fi
rm -rf "$s" "$root"

echo "Test 25: a leading-zero line does not silently destroy the run (M39)"
# `08` is a plain run of digits, so it clears a `^[0-9]+$` guard, but bash reads
# a leading-zero token as octal and rejects the 8: "value too great for base".
# That is the same silent teardown as 12.0 and 1e300 — exit 0, findings.json
# written, every finding from the offending one onward gone. Hence the trailing
# finding: asserting only on the `08` one would not notice the collateral loss.
# The value arrives as a string because `floor` only normalises numbers; the
# jq fallback in rc-extract-verdict.sh rejects a string-typed line, so this is
# defense in depth for hosts reaching the script by another route.
s=$(new_session)
root=$(mktemp -d)
for i in $(seq 1 20); do printf 'line%02d\n' "$i"; done >"$root/n.go"
agent_json "$s" "divisor-sre-code" "REQUEST CHANGES" \
	'[{"severity":"HIGH","file":"n.go","line":"08","evidence":"line08","description":"d","recommendation":"r"},
	  {"severity":"LOW","file":"n.go","line":18,"evidence":"line18","description":"d","recommendation":"r"}]'
rc=0
result=$(REVIEW_ROOT="$root" bash "$SCRIPT" "$s" 2>"$s/err.log") || rc=$?
if [[ $rc -ne 0 ]]; then
	detail=$(head -1 "$s/err.log")
	echo "  FAIL: exit $rc — $detail"
	FAIL=$((FAIL + 1))
elif [[ -s "$s/err.log" ]]; then
	detail=$(head -1 "$s/err.log")
	echo "  FAIL: arithmetic error on stderr — $detail"
	FAIL=$((FAIL + 1))
else
	assert_jq "$s/verdicts/findings.json" '.verified | length' "2" \
		"leading-zero line and its successor both verified"
fi
rm -rf "$s" "$root"

echo "Test 26: a leaf symlink pointing outside the review root is stripped (M09)"
# Resolving only the DIRECTORY component leaves the leaf unresolved, so a
# symlink placed at the leaf passes containment and the evidence reader goes on
# to quote a file outside the changeset. Both halves of the input are hostile:
# `file` is LLM-authored and the tree contents are PR-author-controlled.
s=$(new_session)
base=$(mktemp -d)
root="$base/repo"
mkdir -p "$root"
echo 'SECRET_TOKEN=abc123' >"$base/creds.env"
ln -s "$base/creds.env" "$root/leaked.txt"
agent_json "$s" "divisor-adversary-code" "REQUEST CHANGES" \
	'[{"severity":"CRITICAL","file":"leaked.txt","line":1,"evidence":"SECRET_TOKEN=abc123","description":"d","recommendation":"r"}]'
# Guard the fixture: the symlink must resolve to a readable file, or the
# containment check is never reached and this test proves nothing.
if [[ ! -f "$root/leaked.txt" ]]; then
	echo "  FAIL: fixture broken — leaf symlink does not resolve"
	FAIL=$((FAIL + 1))
fi
result=$(REVIEW_ROOT="$root" bash "$SCRIPT" "$s")
vc=$(echo "$result" | jq '.verified')
sc=$(echo "$result" | jq '.stripped')
if [[ "$vc" -eq 0 && "$sc" -eq 1 ]]; then
	echo "  PASS: escaping leaf symlink stripped, not verified"
	PASS=$((PASS + 1))
else
	echo "  FAIL: verified=$vc stripped=$sc (expected 0/1)"
	FAIL=$((FAIL + 1))
fi
r=$(jq -r '.stripped[0].reason // "none"' "$s/verdicts/findings.json")
assert_equals "$r" "PATH_OUTSIDE_ROOT" "reason PATH_OUTSIDE_ROOT"
rm -rf "$s" "$base"

echo "Test 27: a repo-internal symlink still verifies (M09 must not over-reject)"
# Resolving the leaf must not cost legitimate coverage: a symlink tracked
# inside the repository resolves back under the root and stays verifiable.
s=$(new_session)
root=$(mktemp -d)
mkdir -p "$root/pkg" "$root/vendor"
echo 'package pkg' >"$root/pkg/x.go"
ln -s ../pkg/x.go "$root/vendor/x.go"
agent_json "$s" "divisor-guard-code" "APPROVE" \
	'[{"severity":"LOW","file":"vendor/x.go","line":1,"evidence":"package pkg","description":"d","recommendation":"r"}]'
result=$(REVIEW_ROOT="$root" bash "$SCRIPT" "$s")
vc=$(echo "$result" | jq '.verified')
assert_equals "$vc" "1" "repo-internal symlink verified"
rm -rf "$s" "$root"

echo "Test 28: a symlink chain resolves to its final target, both directions (M09)"
# Containment must follow the whole chain, not one hop. A single-hop resolution
# lands on the intermediate link and reports whatever containment that name has
# — which passes an escaping chain whose first hop happens to sit inside the
# root, and rejects an internal chain whose first hop does not.
s=$(new_session)
base=$(mktemp -d)
root="$base/repo"
mkdir -p "$root/pkg"
echo 'package pkg' >"$root/pkg/x.go"
ln -s pkg/x.go "$root/hop1.go"
ln -s hop1.go "$root/chain-in.go"
echo 'SECRET_TOKEN=abc123' >"$base/creds.env"
ln -s "$base/creds.env" "$root/hop2.env"
ln -s hop2.env "$root/chain-out.env"
agent_json "$s" "divisor-guard-code" "REQUEST CHANGES" \
	'[{"severity":"LOW","file":"chain-in.go","line":1,"evidence":"package pkg","description":"d","recommendation":"r"},
	  {"severity":"CRITICAL","file":"chain-out.env","line":1,"evidence":"SECRET_TOKEN=abc123","description":"d","recommendation":"r"}]'
result=$(REVIEW_ROOT="$root" bash "$SCRIPT" "$s")
vc=$(echo "$result" | jq '.verified')
sc=$(echo "$result" | jq '.stripped')
if [[ "$vc" -eq 1 && "$sc" -eq 1 ]]; then
	echo "  PASS: internal chain verified, escaping chain stripped"
	PASS=$((PASS + 1))
else
	echo "  FAIL: verified=$vc stripped=$sc (expected 1/1)"
	FAIL=$((FAIL + 1))
fi
vf=$(jq -r '.verified[0].file // "none"' "$s/verdicts/findings.json")
assert_equals "$vf" "chain-in.go" "internal chain is the survivor"
r=$(jq -r '.stripped[0].reason // "none"' "$s/verdicts/findings.json")
assert_equals "$r" "PATH_OUTSIDE_ROOT" "escaping chain reason PATH_OUTSIDE_ROOT"
rm -rf "$s" "$base"

echo "Test 29: a dangling leaf symlink is stripped as FILE_NOT_FOUND (M09)"
# A broken link must never reach containment resolution: the `-f` test files it
# first, so the reason stays FILE_NOT_FOUND rather than degrading to the
# containment reason once leaf resolution starts failing on it.
s=$(new_session)
root=$(mktemp -d)
ln -s "$root/absent.go" "$root/dangling.go"
agent_json "$s" "divisor-adversary-code" "REQUEST CHANGES" \
	'[{"severity":"HIGH","file":"dangling.go","line":1,"evidence":"package main","description":"d","recommendation":"r"}]'
result=$(REVIEW_ROOT="$root" bash "$SCRIPT" "$s")
sc=$(echo "$result" | jq '.stripped')
assert_equals "$sc" "1" "dangling leaf symlink stripped"
r=$(jq -r '.stripped[0].reason // "none"' "$s/verdicts/findings.json")
assert_equals "$r" "FILE_NOT_FOUND" "reason FILE_NOT_FOUND"
rm -rf "$s" "$root"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
