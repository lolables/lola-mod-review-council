#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
JQ_DIR="$SCRIPT_DIR/../skills/review-council/scripts/jq"
# shellcheck source=module/tests/helpers.sh
source "$SCRIPT_DIR/helpers.sh"

# The two reducers below carry the pipeline's only two silent-data-loss paths:
# RC-1 deleted every finding outside the cluster being reduced, and RC-20
# dropped a second reviewer's angle on an exact duplicate. Both survived for as
# long as they did because reaching them meant building a session directory and
# running a shell script over it, so no test ever addressed the transformation
# on its own. Driven directly from fixture JSON, each is a pure function from
# input to output and the interesting cases cost three lines apiece.

# Run a jq program over an inline JSON document. Extra args (--argjson ...) are
# forwarded. Usage: run_jq <program.jq> <input-json> [jq args...]
run_jq() {
	local prog="$1" input="$2"
	shift 2
	printf '%s' "$input" | jq -c "$@" -f "$JQ_DIR/$prog"
}

# ---------------------------------------------------------------------------
echo "Test 1: dedup keeps findings that are not duplicates of each other"
# The conservation case RC-1's sibling bug needed: bystanders in the input, so
# a reducer that over-deletes cannot pass by accident.
input='[
 {"file":"a.go","line":1,"evidence":"e1","severity":"LOW","agent":"x","description":"d1","recommendation":"r1"},
 {"file":"b.go","line":9,"evidence":"e2","severity":"HIGH","agent":"y","description":"d2","recommendation":"r2"},
 {"file":"c.go","line":4,"evidence":"e3","severity":"LOW","agent":"z","description":"d3","recommendation":"r3"}
]'
out=$(run_jq dedup-findings.jq "$input")
assert_jq_str "$out" 'length' "3" "three distinct findings all survive"
assert_jq_str "$out" '[.[].file] | join(",")' "a.go,b.go,c.go" "order and identity preserved"

echo "Test 2: same file, same evidence, line within +-5 merges"
input='[
 {"file":"a.go","line":10,"evidence":"e","severity":"LOW","agent":"x","description":"d1","recommendation":"r1"},
 {"file":"a.go","line":14,"evidence":"e","severity":"LOW","agent":"y","description":"d2","recommendation":"r2"}
]'
out=$(run_jq dedup-findings.jq "$input")
assert_jq_str "$out" 'length' "1" "within the window, merged"

echo "Test 3: the same evidence beyond the +-5 window is left alone"
# The window is the whole reason a citation can be slightly off and still
# verify; widening it silently would merge unrelated findings.
input='[
 {"file":"a.go","line":10,"evidence":"e","severity":"LOW","agent":"x","description":"d1","recommendation":"r1"},
 {"file":"a.go","line":16,"evidence":"e","severity":"LOW","agent":"y","description":"d2","recommendation":"r2"}
]'
out=$(run_jq dedup-findings.jq "$input")
assert_jq_str "$out" 'length' "2" "outside the window, kept separate"

echo "Test 4: two null lines merge, a null and a number do not"
input='[
 {"file":"a.go","line":null,"evidence":"e","severity":"LOW","agent":"x","description":"d1","recommendation":"r1"},
 {"file":"a.go","line":null,"evidence":"e","severity":"LOW","agent":"y","description":"d2","recommendation":"r2"}
]'
out=$(run_jq dedup-findings.jq "$input")
assert_jq_str "$out" 'length' "1" "both null merges"
input='[
 {"file":"a.go","line":null,"evidence":"e","severity":"LOW","agent":"x","description":"d1","recommendation":"r1"},
 {"file":"a.go","line":3,"evidence":"e","severity":"LOW","agent":"y","description":"d2","recommendation":"r2"}
]'
out=$(run_jq dedup-findings.jq "$input")
assert_jq_str "$out" 'length' "2" "null vs number stays separate"

echo "Test 5: the merged survivor keeps the highest severity, whatever the order"
# Order independence matters because agent dispatch order is not fixed: the
# same review must not produce a HIGH on one run and a LOW on the next.
low_first='[
 {"file":"a.go","line":1,"evidence":"e","severity":"LOW","agent":"x","description":"d1","recommendation":"r1"},
 {"file":"a.go","line":1,"evidence":"e","severity":"CRITICAL","agent":"y","description":"d2","recommendation":"r2"}
]'
high_first='[
 {"file":"a.go","line":1,"evidence":"e","severity":"CRITICAL","agent":"y","description":"d2","recommendation":"r2"},
 {"file":"a.go","line":1,"evidence":"e","severity":"LOW","agent":"x","description":"d1","recommendation":"r1"}
]'
out=$(run_jq dedup-findings.jq "$low_first")
assert_jq_str "$out" '.[0].severity' "CRITICAL" "low first — max severity kept"
out=$(run_jq dedup-findings.jq "$high_first")
assert_jq_str "$out" '.[0].severity' "CRITICAL" "high first — max severity kept"

echo "Test 6: an unknown severity ranks below every known one"
# sevrank returns 0 for anything unlisted. A typo'd severity must never
# outrank a real CRITICAL and silently downgrade it.
input='[
 {"file":"a.go","line":1,"evidence":"e","severity":"CRITICAL","agent":"x","description":"d1","recommendation":"r1"},
 {"file":"a.go","line":1,"evidence":"e","severity":"SEVERE","agent":"y","description":"d2","recommendation":"r2"}
]'
out=$(run_jq dedup-findings.jq "$input")
assert_jq_str "$out" '.[0].severity' "CRITICAL" "unknown severity does not displace CRITICAL"

echo "Test 7: a cross-agent duplicate is credited, a self-duplicate is not"
cross='[
 {"file":"a.go","line":1,"evidence":"e","severity":"LOW","agent":"x","description":"boundary","recommendation":"use <="},
 {"file":"a.go","line":1,"evidence":"e","severity":"HIGH","agent":"y","description":"untested","recommendation":"add a case"}
]'
out=$(run_jq dedup-findings.jq "$cross")
assert_jq_str "$out" '.[0].provenance.consolidated_from | length' "1" "cross-agent duplicate credited"
assert_jq_str "$out" '.[0].provenance.consolidated_from[0].agent' "x" "credit names the other agent"
assert_jq_str "$out" '.[0].provenance.consolidated_from[0].angle' "boundary" "credit carries the angle"
self='[
 {"file":"a.go","line":1,"evidence":"e","severity":"LOW","agent":"x","description":"first","recommendation":"r"},
 {"file":"a.go","line":1,"evidence":"e","severity":"HIGH","agent":"x","description":"second","recommendation":"r"}
]'
out=$(run_jq dedup-findings.jq "$self")
assert_jq_str "$out" '(.[0].provenance.consolidated_from // []) | length' "0" "self-duplicate not credited"
assert_jq_str "$out" '.[0].severity' "HIGH" "self-duplicate still escalates severity"

echo "Test 7b: the survivor's text is the text of the severity it carries (RC-068)"
# Merging kept the first finding's title and description and raised only its
# severity, so a LOW "boundary" note shipped as a HIGH carrying an unrelated
# defect's severity. The more severe finding now survives whole; the other is
# credited with its own severity and angle.
out=$(run_jq dedup-findings.jq "$cross")
assert_jq_str "$out" '[.[0].agent, .[0].severity, .[0].description] | join("|")' "y|HIGH|untested" "low first — the HIGH finding survives whole"
assert_jq_str "$out" '.[0].provenance.consolidated_from[0].severity' "LOW" "the credit keeps its own severity"
reversed=$(jq -c 'reverse' <<<"$cross")
out=$(run_jq dedup-findings.jq "$reversed")
assert_jq_str "$out" '[.[0].agent, .[0].severity, .[0].description] | join("|")' "y|HIGH|untested" "high first — the same survivor"
# Credits gathered before the survivor changes move with it, minus any naming
# the new survivor's own author.
chain='[
 {"file":"a.go","line":1,"evidence":"e","severity":"LOW","agent":"x","description":"dx","recommendation":"r"},
 {"file":"a.go","line":1,"evidence":"e","severity":"LOW","agent":"y","description":"dy","recommendation":"r"},
 {"file":"a.go","line":1,"evidence":"e","severity":"LOW","agent":"w","description":"dw","recommendation":"r"},
 {"file":"a.go","line":1,"evidence":"e","severity":"HIGH","agent":"y","description":"dy2","recommendation":"r"}
]'
out=$(run_jq dedup-findings.jq "$chain")
assert_jq_str "$out" '[.[0].agent, .[0].description] | join("|")' "y|dy2" "the latest, most severe finding survives"
assert_jq_str "$out" '[.[0].provenance.consolidated_from[].agent] | sort | join(",")' "w,x" "earlier credits carried, the survivor's own dropped"

echo "Test 8: an empty input yields an empty array, not null"
out=$(run_jq dedup-findings.jq '[]')
assert_equals "$out" "[]" "empty in, empty out"

echo "Test 8b: a script finding is never merged, either way round (RC-076)"
# The correction round re-runs this program over every verified finding, so a
# reviewer CRITICAL at the symlink check's line absorbed its HIGH ("most severe
# survives whole") and validation then retracted the CRITICAL. The mark is what
# keeps it out, in both directions: it is neither folded nor a survivor.
script='{"file":"leak","line":1,"evidence":"/etc/passwd","severity":"HIGH","agent":"rc-check-symlinks","description":"ds","recommendation":"rs","provenance":{"validator":{"result":"SCRIPT"}}}'
input="[{\"file\":\"leak\",\"line\":1,\"evidence\":\"/etc/passwd\",\"severity\":\"CRITICAL\",\"agent\":\"x\",\"description\":\"dc\",\"recommendation\":\"r\"},
 $script,
 {\"file\":\"leak\",\"line\":2,\"evidence\":\"/etc/passwd\",\"severity\":\"LOW\",\"agent\":\"y\",\"description\":\"dl\",\"recommendation\":\"r\"}]"
out=$(run_jq dedup-findings.jq "$input")
assert_jq_str "$out" '[.[] | .agent] | join(",")' "x,rc-check-symlinks" "the script finding stands where it was; the reviewer LOW merges"
script_compact=$(jq -c . <<<"$script")
assert_jq_str "$out" '.[1] | tojson' "$script_compact" "the script finding passes through untouched"
assert_jq_str "$out" '[.[0].provenance.consolidated_from[].agent] | join(",")' "y" "the CRITICAL absorbs only the reviewer duplicate"
out=$(run_jq dedup-findings.jq "[$script, {\"file\":\"leak\",\"line\":1,\"evidence\":\"/etc/passwd\",\"severity\":\"LOW\",\"agent\":\"x\",\"description\":\"dl\",\"recommendation\":\"r\"}]")
assert_jq_str "$out" 'length' "2" "a less severe reviewer duplicate is not folded into it either"
assert_jq_str "$out" '.[0].provenance.consolidated_from' "null" "the script finding gains no credit"

# ---------------------------------------------------------------------------
echo "Test 9: consolidation merges a cluster and conserves every bystander"
# RC-1 in one assertion: the input carries findings outside the cluster, and a
# reducer scoped wrongly deletes them while still reporting success.
findings='{"verified":[
 {"file":"a.go","line":1,"agent":"x","severity":"MEDIUM","evidence":"e1","description":"d1","recommendation":"r1","verdict":"APPROVE"},
 {"file":"a.go","line":1,"agent":"y","severity":"LOW","evidence":"e2","description":"d2","recommendation":"r2","verdict":"APPROVE"},
 {"file":"b.go","line":9,"agent":"z","severity":"HIGH","evidence":"e3","description":"d3","recommendation":"r3","verdict":"APPROVE"},
 {"file":"c.go","line":4,"agent":"w","severity":"LOW","evidence":"e4","description":"d4","recommendation":"r4","verdict":"APPROVE"}
],"correctable":[],"stripped":[],"total_findings":4,"duplicates_consolidated":0,
 "verdicts":{"x":"APPROVE","y":"APPROVE","z":"APPROVE","w":"APPROVE"}}'
clusters='[{"members":[{"file":"a.go","line":1,"agent":"x"},{"file":"a.go","line":1,"agent":"y"}]}]'
out=$(run_jq consolidate-clusters.jq "$findings" --argjson clusters "$clusters")
assert_jq_str "$out" '.verified | length' "3" "one cluster of two collapses to one, bystanders kept"
assert_jq_str "$out" '[.verified[].file] | join(",")' "a.go,b.go,c.go" "the surviving files are the right ones"
assert_jq_str "$out" '.duplicates_consolidated' "1" "one semantic duplicate counted"
assert_jq_str "$out" '.consolidation_records | length' "1" "one consolidation record written"

echo "Test 10: the cluster primary is the most severe member"
assert_jq_str "$out" '.verified[0].severity' "MEDIUM" "MEDIUM outranks LOW as primary"
assert_jq_str "$out" '.verified[0].provenance.consolidated_from[0].agent' "y" "the folded member is credited"

echo "Test 11: REQUEST CHANGES anywhere in a cluster wins the merged verdict"
# An APPROVE primary must not launder a REQUEST CHANGES filed by a member it
# absorbed.
findings='{"verified":[
 {"file":"a.go","line":1,"agent":"x","severity":"HIGH","evidence":"e1","description":"d1","recommendation":"r1","verdict":"APPROVE"},
 {"file":"a.go","line":1,"agent":"y","severity":"LOW","evidence":"e2","description":"d2","recommendation":"r2","verdict":"REQUEST CHANGES"}
],"correctable":[],"stripped":[],"total_findings":2,"duplicates_consolidated":0,"verdicts":{}}'
out=$(run_jq consolidate-clusters.jq "$findings" --argjson clusters "$clusters")
assert_jq_str "$out" '.verified[0].verdict' "REQUEST CHANGES" "REQUEST CHANGES wins over the primary's APPROVE"

echo "Test 12: a cluster naming fewer than two present members is a no-op"
# A manifest can name a member that verification stripped. Merging a
# single-member 'cluster' would rewrite a finding for no reason.
clusters_one='[{"members":[{"file":"a.go","line":1,"agent":"x"},{"file":"gone.go","line":7,"agent":"absent"}]}]'
out=$(run_jq consolidate-clusters.jq "$findings" --argjson clusters "$clusters_one")
assert_jq_str "$out" '.verified | length' "2" "nothing merged"
assert_jq_str "$out" '.duplicates_consolidated' "0" "nothing counted"
assert_jq_str "$out" '.consolidation_records | length' "0" "no record written"

echo "Test 13: an empty cluster list leaves the document untouched"
out=$(run_jq consolidate-clusters.jq "$findings" --argjson clusters '[]')
assert_jq_str "$out" '.verified | length' "2" "both findings survive"
assert_jq_str "$out" '.duplicates_consolidated' "0" "count unchanged"

echo "Test 14: no cluster touches a script finding, whatever the manifest's shape (RC-076)"
# The reducer iterates objects as well as arrays, so a manifest filter that only
# handled the documented shape let these two fold the HIGH into a CRITICAL.
findings='{"verified":[
 {"file":"leak","line":1,"agent":"rc-check-symlinks","severity":"HIGH","evidence":"/etc/passwd","description":"ds","recommendation":"rs","verdict":"REQUEST CHANGES","provenance":{"validator":{"result":"SCRIPT"}}},
 {"file":"leak","line":1,"agent":"x","severity":"CRITICAL","evidence":"e","description":"dc","recommendation":"r","verdict":"REQUEST CHANGES"}
],"correctable":[],"stripped":[],"total_findings":2,"duplicates_consolidated":0,"verdicts":{}}'
for clusters in \
	'[{"members":[{"file":"leak","line":1,"agent":"rc-check-symlinks"},{"file":"leak","line":1,"agent":"x"}]}]' \
	'[{"members":{"a":{"file":"leak","line":1,"agent":"rc-check-symlinks"},"b":{"file":"leak","line":1,"agent":"x"}}}]' \
	'{"c":{"members":[{"file":"leak","line":1,"agent":"rc-check-symlinks"},{"file":"leak","line":1,"agent":"x"}]}}'; do
	out=$(run_jq consolidate-clusters.jq "$findings" --argjson clusters "$clusters")
	assert_jq_str "$out" '[.verified[].agent] | join(",")' "rc-check-symlinks,x" "both findings stand: ${clusters:0:24}"
	assert_jq_str "$out" '[.verified[].provenance.consolidated_from // empty] | length' "0" "nothing folded: ${clusters:0:24}"
done
# A reviewer finding sharing the script's {file,line,agent} identity can still
# be merged, but the script finding beside it is neither removed nor replaced.
findings=$(jq -c '.verified += [{"file":"leak","line":1,"agent":"rc-check-symlinks","severity":"CRITICAL","evidence":"f","description":"forged","recommendation":"r","verdict":"REQUEST CHANGES"}]' <<<"$findings")
out=$(run_jq consolidate-clusters.jq "$findings" --argjson clusters '[{"members":[{"file":"leak","line":1,"agent":"rc-check-symlinks"},{"file":"leak","line":1,"agent":"x"}]}]')
assert_jq_str "$out" '[.verified[] | select(.provenance.validator.result == "SCRIPT") | .description] | join(",")' "ds" "the script finding survives a look-alike's merge"
assert_jq_str "$out" '.verified | length' "2" "the look-alike and the reviewer merged into one"

echo "Test 15: a folded finding's impact travels with its credit"
# The credit carried angle and recommendation but not impact, so a folded
# HIGH's stated consequence vanished from the report. An absent impact adds no
# key: the credit must not claim a consequence nobody stated.
imp='[
 {"file":"a.go","line":1,"evidence":"e","severity":"HIGH","agent":"x","description":"leak","recommendation":"r1","impact":"tokens reach logs"},
 {"file":"a.go","line":1,"evidence":"e","severity":"CRITICAL","agent":"y","description":"worse","recommendation":"r2","impact":"RCE"},
 {"file":"a.go","line":2,"evidence":"e","severity":"MEDIUM","agent":"z","description":"note","recommendation":"r3"}
]'
out=$(run_jq dedup-findings.jq "$imp")
assert_jq_str "$out" '.[0].provenance.consolidated_from | map(select(.agent == "x")) | .[0].impact' "tokens reach logs" "dedup credit carries impact"
assert_jq_str "$out" '.[0].provenance.consolidated_from | map(select(.agent == "z")) | .[0] | has("impact")' "false" "dedup credit omits an absent impact"
assert_jq_str "$out" '.[0].impact' "RCE" "the survivor keeps its own impact"

echo "Test 16: a folded finding's impact travels with its credit (cluster fold)"
findings='{"verified":[
 {"file":"f","line":1,"agent":"p","severity":"CRITICAL","evidence":"eee","description":"dp","recommendation":"rp","impact":"RCE","verdict":"REQUEST CHANGES"},
 {"file":"f","line":1,"agent":"q","severity":"HIGH","evidence":"e","description":"dq","recommendation":"rq","impact":"tokens reach logs","verdict":"REQUEST CHANGES"},
 {"file":"f","line":1,"agent":"r","severity":"MEDIUM","evidence":"e","description":"dr","recommendation":"rr","verdict":"APPROVE"}
],"correctable":[],"stripped":[],"total_findings":3,"duplicates_consolidated":0,"verdicts":{}}'
out=$(run_jq consolidate-clusters.jq "$findings" --argjson clusters '[{"members":[{"file":"f","line":1,"agent":"p"},{"file":"f","line":1,"agent":"q"},{"file":"f","line":1,"agent":"r"}]}]')
assert_jq_str "$out" '.verified[0].provenance.consolidated_from | map(select(.agent == "q")) | .[0].impact' "tokens reach logs" "cluster credit carries impact"
assert_jq_str "$out" '.verified[0].provenance.consolidated_from | map(select(.agent == "r")) | .[0] | has("impact")' "false" "cluster credit omits an absent impact"

# ---------------------------------------------------------------------------
# rc_md_neutralise / rc_md_title (jq/md-neutralise.jq): reviewer prose is
# authored under the influence of a diff the PR author controls, and both
# renderers print it into markdown a forge will render. Every expected value
# below was checked against GitHub's and GitLab's markdown endpoints
# (docs/dev/pipeline.md, "Rendering reviewer prose", says how to re-probe).

# Assert that one neutraliser def maps <input> to exactly <expected>. -j, not
# -r: the output is compared byte for byte and -r would append a newline the def
# never wrote. A plain assignment, as in assert_jq, so a jq error aborts the
# suite instead of asserting against the empty string.
# Usage: assert_md <def> <input> <expected> <label>
assert_md() {
	local actual
	actual=$(jq -nj -L "$JQ_DIR" --arg s "$2" "include \"md-neutralise\"; \$s | $1")
	assert_equals "$actual" "$3" "$4"
}

echo "Test 17: raw HTML is shown, not rendered; a code span becomes an escaped <code> (RC-136)"
assert_md rc_md_neutralise 'a<b, <details> </details> <!-- hide' \
	'a&lt;b, &lt;details> &lt;/details> &lt;!-- hide' \
	"every < outside a span becomes &lt;"
# shellcheck disable=SC2016 # literal markdown code spans, not expansions.
assert_md rc_md_neutralise 'Use `<=` so a token expiring exactly now is still valid.' \
	'Use <code>&lt;\=</code> so a token expiring exactly now is still valid.' \
	"a span's HTML becomes entities and its punctuation is escaped, so it reads the same"
# shellcheck disable=SC2016
assert_md rc_md_neutralise '``a ` <b>`` then <i>' \
	'<code>a \` &lt;b&gt;</code> then &lt;i>' \
	"a double-backtick span holding a single backtick is one span"
# shellcheck disable=SC2016
assert_md rc_md_neutralise '`` `x` `` and `**b** [l](u) \`' \
	'<code>\`x\`</code> and <code>\*\*b\*\* \[l\]\(u\) \\</code>' \
	"one padding space is stripped and markdown inside a span cannot render"

echo "Test 18: a backtick outside a detected span can never pair in the renderer (RC-136)"
# shellcheck disable=SC2016
assert_md rc_md_neutralise 'a ` b <i>' 'a &#96; b &lt;i>' \
	"an unmatched backtick becomes an entity"
# shellcheck disable=SC2016
assert_md rc_md_neutralise $'`a\nb` <b>x</b> `c`' '<code>a b</code> &lt;b>x&lt;/b> <code>c</code>' \
	"a span crossing a line is one span, its newline a space as CommonMark renders it"
# shellcheck disable=SC2016
assert_md rc_md_neutralise '\`<b>x</b>`' '\`&lt;b>x&lt;/b>&#96;' \
	"a backslash-escaped backtick opens nothing and stays escaped"
# shellcheck disable=SC2016
assert_md rc_md_neutralise '\``x` <b>' '\`<code>x</code> &lt;b>' \
	"an escaped backtick before a span stays escaped and the span still pairs"

echo "Test 19: mentions are wrapped in <code> and cannot notify (RC-137)"
assert_md rc_md_neutralise '@bob (@bob) \@bob' \
	'<code>\@bob</code> (<code>\@bob</code>) \ <code>\@bob</code>' \
	"bare, punctuated and backslash-escaped mentions are wrapped; a backslash cannot escape the tag"
assert_md rc_md_neutralise 'email@example.com x@bob' 'email@example.com x@bob' \
	"an @ after a word character is not a mention on either forge"
assert_md rc_md_neutralise '@org/team and @first.last.' \
	'<code>\@org\/team</code> and <code>\@first\.last</code>.' \
	"team and dotted mentions are wrapped whole, trailing period outside"
assert_md rc_md_neutralise '@a@b' '<code>\@a\@b</code>' \
	"a chained mention cannot leave its second half live"
# shellcheck disable=SC2016
assert_md rc_md_neutralise '`x`@bob' '<code>x</code><code>\@bob</code>' \
	"a mention right after a span is wrapped"
# shellcheck disable=SC2016
assert_md rc_md_neutralise 'see `@bob`' 'see <code>\@bob</code>' \
	"a mention inside a span is inside <code> already"

echo "Test 20: image embeds are shown as text"
assert_md rc_md_neutralise '![x](https://example.com/a.png)' '!\[x](https://example.com/a.png)' \
	"![ is escaped"
# shellcheck disable=SC2016
assert_md rc_md_neutralise '`![x](u)`' '<code>\!\[x\]\(u\)</code>' \
	"an image inside a span is escaped text"

echo "Test 21: line-start block constructs are escaped; lists and inline formatting survive"
block_in=$'## H\n> q\n---\n  ```\n~~~\n| a |\n|---|---|\na | b\n:--|--\n- item\n1. step\n* * *\nFoo\n='
block_out=$'\\## H\n\\> q\n\\---\n  &#96;&#96;&#96;\n\\~~~\n| a |\n\\|---|---|\na | b\n\\:--|--\n- item\n1. step\n\\* * *\nFoo\n\\='
assert_md rc_md_neutralise "$block_in" "$block_out" \
	"headings, quotes, breaks, fences, table delimiter rows and setext underlines are escaped"
# shellcheck disable=SC2016
assert_md rc_md_neutralise '```x``` <b>' '<code>x</code> &lt;b>' \
	"a line opening with a closed span is a span, not a fence"
assert_md rc_md_neutralise '**b** _i_ [l](https://example.com)' '**b** _i_ [l](https://example.com)' \
	"bold, italics and plain links are untouched"
assert_md rc_md_neutralise '' '' "the empty string stays empty"

echo "Test 22: a title is one line (RC-138)"
assert_md rc_md_title $'T\r\n## APPROVE\u2028<!-- review-council:marker -->' \
	'T ## APPROVE &lt;!-- review-council:marker -->' \
	"CR, LF and Unicode line separators become one space before neutralising"
assert_md rc_md_neutralise $'a\nb' $'a\nb' \
	"rc_md_neutralise keeps newlines; only rc_md_title joins lines"

echo "Test 23: HTML and mentions stay dead where detection and renderer disagree on a span (RC-136)"
# The renderer parses the link before the code span, so the backtick in its
# destination opens nothing there; a neutraliser that skipped escaping inside
# what it took for a span left </details> live.
# shellcheck disable=SC2016
assert_md rc_md_neutralise '[a](http://x/`)</details> `' \
	'[a](http://x/<code>\)&lt;\/details&gt; </code>' \
	"a backtick in a link destination cannot make </details> live"
# shellcheck disable=SC2016
assert_md rc_md_neutralise '[a](http://x/`) @user `' '[a](http://x/<code>\) \@user </code>' \
	"nor leave a mention live"
# shellcheck disable=SC2016
assert_md rc_md_neutralise '[a](http://x "`") </details> @bob `' \
	'[a](http://x "<code>\"\) &lt;\/details&gt; \@bob </code>' \
	"nor can a backtick in a link title"
# shellcheck disable=SC2016
assert_md rc_md_neutralise 'q ` r ```a``@bob```' 'q &#96; r <code>a\`\`\@bob</code>' \
	"a stray backtick cannot pair with one inside an emitted <code>"

echo "Test 24: every line ending a renderer honours is a line ending to the block rule"
assert_md rc_md_neutralise $'desc\r## FORGED APPROVE\r~~~\rrest' $'desc\n\\## FORGED APPROVE\n\\~~~\nrest' \
	"a lone CR cannot hide a heading or a fence"
assert_md rc_md_neutralise $'a\r\n# b\u2028> c\u2029---\u0085d' $'a\n\\# b\n\\> c\n\\---\nd' \
	"CRLF, U+2028, U+2029 and U+0085 become LF first"
assert_md rc_md_title $'T\r## APPROVE' 'T ## APPROVE' "a title folds a lone CR too"

echo "Test 25: an encoded @ cannot notify"
assert_md rc_md_neutralise '&#64;bob &#x40;bob &commat;bob a && b' \
	'&amp;#64;bob &amp;#x40;bob &amp;commat;bob a &amp;&amp; b' \
	"every & outside a span becomes &amp;, so no entity is decoded"

echo "Test 26: fences of any length are dead"
assert_md rc_md_neutralise $'````\nx' $'&#96;&#96;&#96;&#96;\nx' \
	"an unclosed four-backtick fence becomes entities"
assert_md rc_md_neutralise $'````js\nx' $'&#96;&#96;&#96;&#96;js\nx' \
	"with an info string as well"
assert_md rc_md_neutralise $'````\nx\n````' '<code>x</code>' \
	"a closed backtick fence pairs as one span"
assert_md rc_md_neutralise $'~~~~\n   ~~~ x\n~~ s ~~' $'\\~~~~\n   \\~~~ x\n~~ s ~~' \
	"a tilde fence of three or more is escaped whatever follows; strikethrough is not"

echo "Test 27: block markup after list markers is escaped; the markers survive"
list_in=$'- ## FORGED\n1. > q\n+ ~~~\n2) # h\n- - - \n* - ===\n- item\n  - [ ] task'
list_out=$'- \\## FORGED\n1. \\> q\n+ \\~~~\n2) \\# h\n\\- - - \n\\* - ===\n- item\n  - [ ] task'
assert_md rc_md_neutralise "$list_in" "$list_out" \
	"headings, quotes, fences and breaks behind -, +, *, 1. and 2) markers are escaped"

echo "Test 28: footnote and link reference definitions are escaped"
defs_in=$'[^1]: FORGED\n[x]: http://evil\n- [y]: z\n[a\nb]: /u\n[l](https://example.com) ok'
defs_out=$'\\[^1]: FORGED\n\\[x]: http://evil\n- \\[y]: z\n\\[a\nb]: /u\n[l](https://example.com) ok'
assert_md rc_md_neutralise "$defs_in" "$defs_out" \
	"a definition (one line or a label split over two) cannot render below the comment"

echo "Test 29: neutralising is linear, so a 50KB hostile field cannot stall the render"
# The first version searched for each opener's closer from scratch and copied
# its output array on every step: 8KB of `a` spans took 3.8s, 50KB over two
# minutes. jq's own gsub is quadratic in its match count too. The bound is
# generous; linear time is well under a second.
# Usage: assert_md_fast <def> <input> <label>
assert_md_fast() {
	local start elapsed_ms
	start=$(date +%s%N)
	jq -nj -L "$JQ_DIR" --arg s "$2" "include \"md-neutralise\"; \$s | $1" >/dev/null
	elapsed_ms=$((($(date +%s%N) - start) / 1000000))
	if ((elapsed_ms < 5000)); then
		echo "  PASS: $3 (${elapsed_ms}ms)"
		PASS=$((PASS + 1))
	else
		echo "  FAIL: $3 took ${elapsed_ms}ms (bound 5000ms)"
		FAIL=$((FAIL + 1))
	fi
}
# shellcheck disable=SC2016
spans=$(jq -nj '"`a` " * 12800')
# shellcheck disable=SC2016
mixed=$(jq -nj '"`a` @b <c &d ![e](f)\r- # g\r~~~\r" * 1600')
# shellcheck disable=SC2016
runs=$(jq -nj '[range(1; 316) | "`" * . + "x"] | add')
# shellcheck disable=SC2016
slashes=$(jq -nj '"\\" * 50000 + "`<x>`"')
chain=$(jq -nj '"@a" * 25000')
assert_md_fast rc_md_neutralise "$spans" "12800 code spans"
assert_md_fast rc_md_neutralise "$mixed" "every rule firing 1600 times"
assert_md_fast rc_md_neutralise "$runs" "315 unmatched runs of distinct lengths"
assert_md_fast rc_md_neutralise "$slashes" "50000 backslashes before a backtick"
assert_md_fast rc_md_neutralise "$chain" "a 50KB chained mention"
assert_md_fast rc_md_title "$mixed" "a 50KB title"

echo "Test 30: a definition label holding an escaped ] is still escaped"
assert_md rc_md_neutralise $'[a\\]\n]: https://evil.example/x "t"\nhidden? [z][a\\]]' \
	$'\\[a\\]\n]: https://evil.example/x "t"\nhidden? [z][a\\]]' \
	"a label continued on the next line after an escaped ] cannot define a link"
assert_md rc_md_neutralise $'[x\\]y\n]: <https://e/>' $'\\[x\\]y\n]: &lt;https://e/>' \
	"nor can one whose destination is an autolink"
assert_md rc_md_neutralise $'- [a\\]\n]: x' $'- \\[a\\]\n]: x' \
	"nor one behind a list marker"

echo "Test 31: a line cannot start a GitLab quick action"
# GitLab runs /approve, /close, /label ... with the posting token's rights when
# a top-level paragraph line starts with "/"; "\/" does not match and renders "/".
assert_md rc_md_neutralise '/approve' '\/approve' "a quick action at column 0 is escaped"
assert_md rc_md_neutralise '   /close' '   \/close' "and after up to three spaces"
assert_md rc_md_neutralise $'x\n/label ~bug' $'x\n\\/label ~bug' "and on a later line"
assert_md rc_md_neutralise '- /x' '- \/x' "and behind a list marker, for uniformity"
assert_md rc_md_neutralise 'a/b and https://x.example/y' 'a/b and https://x.example/y' \
	"a slash mid-line is untouched"
assert_md rc_md_title '/approve' '\/approve' "and in a title"

echo "Test 32: a title ending in a backslash cannot escape the template's closing **"
assert_md rc_md_title $'T \\' $'T \\\\' "a trailing lone backslash is doubled"
assert_md rc_md_title $'T \\\\' $'T \\\\' "an already-escaped one is left alone"

echo "Test 33: a mention starting with a dot is wrapped too"
assert_md rc_md_neutralise 'hi @.bob' 'hi <code>\@\.bob</code>' "@.bob is wrapped"
assert_md rc_md_neutralise 'x @. y @.' 'x @. y @.' "a bare @. is not a mention"

echo "Test 34: em and en dashes become '-' before neutralising, in prose and titles"
assert_md rc_md_neutralise $'T\n\u2014\u2014\u2014' $'T\n\\---' "an em-dash line is escaped as a dash line, not left to become an underline"
assert_md rc_md_neutralise $'a \u2013 b \u2014 ## x' 'a - b - ## x' "en and em dashes map to a hyphen"
assert_md rc_md_title $'\u2014\u2014\u2014' '\---' "and in a title"

echo "Test 35: a change-author-named path prints as an inert <code> element"
# A finding's file path is chosen by the change author (evidence verification
# only checks that the file exists), and the renderers print it as code.
# shellcheck disable=SC2016 # literal markdown, not an expansion.
assert_md rc_md_code 'a`</details><img src=x>@octocat`.md:1' \
	'<code>a\`&lt;\/details&gt;&lt;img src\=x&gt;\@octocat\`\.md\:1</code>' \
	"no backtick, tag or mention in a path survives"
assert_md rc_md_code 'src/a b.go:3' '<code>src\/a b\.go\:3</code>' "a normal path reads the same"
assert_md rc_md_code $'a\r# b\u2028c' '<code>a \# b c</code>' "every line ending becomes a space"
assert_md rc_md_code $'a\u2014b' $'<code>a\u2014b</code>' "a path keeps its dashes"

# ---------------------------------------------------------------------------
# recompute-verdicts.jq: each agent's verdict in findings.json, derived from the
# findings and the verdict it filed. Before it, three rules lived in prose and
# were applied by hand-editing .verdicts, and both renderers print that map as
# is (#52). Each case builds one document and asks for one agent's verdict.

# shellcheck disable=SC2016 # jq programs; every $ is jq's.
finding() { # agent severity [extra-json]
	local extra="${3:-}"
	[[ -n "$extra" ]] || extra='{}'
	jq -nc --arg a "$1" --arg s "$2" --argjson x "$extra" \
		'{agent: $a, severity: $s, file: "a.go", line: 1} + $x'
}
# recompute <declared-map> <verified> <stripped> [verdicts-map] [correctable]
# -> the program's output over a document holding those arrays.
# shellcheck disable=SC2016 # jq programs; every $ is jq's.
recompute() {
	local map="${4:-}" corr="${5:-}" d
	[[ -n "$map" ]] || map='{}'
	[[ -n "$corr" ]] || corr='[]'
	d=$(jq -nc --argjson v "$2" --argjson s "$3" --argjson m "$map" --argjson c "$corr" \
		'{verified: $v, correctable: $c, stripped: $s, verdicts: $m}')
	run_jq recompute-verdicts.jq "$d" --argjson declared "$1"
}
A=divisor-guard-code
B=divisor-testing-code
V=".doc.verdicts[\"$A\"]"

echo "Test 36: the rule table, first match wins (RC-160)"
high=$(finding "$A" HIGH)
crit=$(finding "$A" CRITICAL)
med=$(finding "$A" MEDIUM)
other_high=$(finding "$B" HIGH)
out=$(recompute "{\"$A\":\"APPROVE\"}" "[$high]" '[]')
assert_jq_str "$out" "$V" "REQUEST CHANGES" "a verified HIGH forces REQUEST CHANGES over a filed APPROVE"
out=$(recompute "{\"$A\":\"APPROVE\"}" "[$crit]" '[]')
assert_jq_str "$out" "$V" "REQUEST CHANGES" "so does a verified CRITICAL"
out=$(recompute "{\"$A\":\"REQUEST CHANGES\"}" '[]' '[]')
assert_jq_str "$out" "$V" "APPROVE" "no findings left upgrades REQUEST CHANGES to APPROVE"
out=$(recompute "{\"$A\":\"REQUEST CHANGES\"}" "[$med]" '[]')
assert_jq_str "$out" "$V" "REQUEST CHANGES" "a MEDIUM left keeps the filed REQUEST CHANGES"
out=$(recompute "{\"$A\":\"APPROVE\"}" "[$med]" '[]')
assert_jq_str "$out" "$V" "APPROVE" "a MEDIUM left keeps the filed APPROVE"
out=$(recompute "{\"$A\":\"APPROVE\"}" "[$other_high]" '[]')
assert_jq_str "$out" "$V" "APPROVE" "another agent's HIGH does not force this one"

echo "Test 37: what counts as a finding left (RC-161)"
# A suppressed-low strip is a commenter's scoping hint and never changes a
# verdict (disposition.md rule 3), so it still counts. Every other strip, a
# correctable finding, and another agent's finding do not.
sup=$(finding "$A" LOW '{"status":"stripped","reason":"DISPOSITION_SUPPRESSED_LOW"}')
res=$(finding "$A" MEDIUM '{"status":"stripped","reason":"DISPOSITION_RESOLVED"}')
gone=$(finding "$A" HIGH '{"status":"stripped","reason":"FILE_NOT_FOUND"}')
out=$(recompute "{\"$A\":\"REQUEST CHANGES\"}" '[]' "[$sup]")
assert_jq_str "$out" "$V" "REQUEST CHANGES" "a suppressed-low strip still counts as left"
out=$(recompute "{\"$A\":\"REQUEST CHANGES\"}" '[]' "[$res, $gone]")
assert_jq_str "$out" "$V" "APPROVE" "resolved and evidence-failed strips do not"
out=$(recompute "{\"$A\":\"REQUEST CHANGES\"}" '[]' '[]' '{}' "[$high]")
assert_jq_str "$out" "$V" "APPROVE" "a correctable finding does not"

echo "Test 38: an agent credited on a consolidated finding still holds it"
# Step 3c folds a secondary into another agent's primary and removes it from
# verified. Its reviewer's concern survives in the primary, so it is not
# upgraded to APPROVE; the HIGH is the primary's, so it is not forced either.
primary=$(finding "$B" HIGH "{\"provenance\":{\"consolidated_from\":[{\"agent\":\"$A\",\"severity\":\"MEDIUM\"}]}}")
out=$(recompute "{\"$A\":\"REQUEST CHANGES\",\"$B\":\"REQUEST CHANGES\"}" "[$primary]" '[]')
assert_jq_str "$out" "$V" "REQUEST CHANGES" "a credited agent keeps its filed REQUEST CHANGES"
out=$(recompute "{\"$A\":\"APPROVE\",\"$B\":\"REQUEST CHANGES\"}" "[$primary]" '[]')
assert_jq_str "$out" "$V" "APPROVE" "and its filed APPROVE: the primary's HIGH forces only the primary's agent"

echo "Test 39: the map's agents are the declared ones; every change is reported"
out=$(recompute "{\"$A\":\"REQUEST CHANGES\",\"$B\":\"APPROVE\"}" "[$med]" '[]' \
	"{\"$A\":\"APPROVE\",\"divisor-x\":\"APPROVE\"}")
assert_jq_str "$out" '.doc.verdicts | tojson' "{\"$A\":\"REQUEST CHANGES\",\"$B\":\"APPROVE\"}" \
	"a hand edit is corrected, a missing agent restored, an added one dropped"
assert_jq_str "$out" '[.changes[] | "\(.agent)=\(.from)>\(.to):\(.rule)"] | join(" ")' \
	"$A=APPROVE>REQUEST CHANGES:DECLARED $B=null>APPROVE:NO_FINDINGS divisor-x=APPROVE>null:NOT_DECLARED" \
	"each change names the agent, both values and the rule"
out=$(recompute "{\"$A\":\"REQUEST CHANGES\"}" "[$med]" '[]' "{\"$A\":\"REQUEST CHANGES\"}")
assert_jq_str "$out" '.changes | length' "0" "a map that already follows from the findings reports no change"
assert_jq_str "$out" '.doc.verified | length' "1" "and the findings pass through untouched"

echo "Test 40: inputs the rules cannot read are refused, not guessed at"
for bad in '[]' '{"x":"MAYBE"}' '{"x":null}' 'null'; do
	out=$(recompute "$bad" '[]' '[]')
	assert_jq_str "$out" '.problem | type' "string" "declared map $bad is refused"
	assert_jq_str "$out" 'has("doc")' "false" "and no document is produced for it"
done
for bad in '[]' '{"verified":{},"stripped":[]}' '{"verified":[1],"stripped":[]}' '{"verified":[]}'; do
	out=$(run_jq recompute-verdicts.jq "$bad" --argjson declared "{\"$A\":\"APPROVE\"}")
	assert_jq_str "$out" '.problem | type' "string" "findings document $bad is refused"
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
