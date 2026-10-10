#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$SCRIPT_DIR/../skills/review-council/scripts/rc-post-comment-gitlab.sh"
# shellcheck source=module/tests/helpers.sh
source "$SCRIPT_DIR/helpers.sh"

# rc-post-comment-gitlab.sh posts the council verdict to a GitLab merge request
# with the same upsert, supersede and identity policy rc-post-comment-github.sh
# applies to a pull request. This suite mirrors test-rc-post-comment-github.sh
# case for case, then adds the GitLab-only surface: pagination, the credential
# gate, the host and project addressing, and the environment glab must never see.
#
# The caller's own glab environment must not leak into the stub: a developer
# with GITLAB_TOKEN exported would otherwise change what the token assertions
# below observe.
unset GITLAB_TOKEN GITLAB_ACCESS_TOKEN OAUTH_TOKEN GITLAB_API_HOST GITLAB_HOST \
	GITLAB_URI GL_HOST GLAB_ENABLE_CI_AUTOLOGIN

# A stateful fake GitLab behind a `glab` stub. Notes live in $GLAB_STATE/notes.json
# and the stub reads and writes them the way the API does, so every jq selector
# in the script runs for real against the fixture, and every write is observable
# afterwards as the state it left behind.
#
# Files in $GLAB_STATE:
#   log            one `glab <argv>` line per call
#   env            per call, the three variables the script must control
#   notes.json     the merge request's notes (seed it; the stub mutates it)
#   input.<n>.<M>.json  a copy of the n-th write's --input file (M = POST|PUT)
# Env:
#   MOCK_AUTH_HOSTS   hosts `glab auth status --hostname H` admits
#                     (default gitlab.example.com)
#   MOCK_USER         raw `api user` stdout (default {"id":4242,"username":...})
#   MOCK_USER_RC      `api user` exit status (non-zero prints a 401 to stderr)
#   MOCK_LIST_RC      notes listing exit status
#   MOCK_PAGE_SIZE    notes per printed page (default 100)
#   MOCK_BAD_PAGE     a raw page appended after the notes (an error body)
#   MOCK_LIST_RAW     raw listing stdout, printed INSTEAD of the notes pages
#   MOCK_GET_RC       single-note GET exit status
#   MOCK_CREATE_FAIL_AT  the n-th create fails
#   MOCK_UPDATE_RC    every PUT exits with this status
#   MOCK_VIEWER_ID    author id stamped on created notes (default 4242)
make_glab() {
	local st="$1"
	mkdir -p "$st"
	echo '[]' >"$st/notes.json"
	cat >"$st/glab" <<'GLAB'
#!/usr/bin/env bash
st="$GLAB_STATE"
echo "glab $*" >>"$st/log"
echo "GITLAB_TOKEN=${GITLAB_TOKEN-unset} GITLAB_API_HOST=${GITLAB_API_HOST-unset} GLAB_ENABLE_CI_AUTOLOGIN=${GLAB_ENABLE_CI_AUTOLOGIN-unset}" >>"$st/env"
if [[ "$1 $2" == "auth status" ]]; then
	host="" prev=""
	for a in "$@"; do
		[[ "$prev" == "--hostname" ]] && host="$a"
		prev="$a"
	done
	case " ${MOCK_AUTH_HOSTS-gitlab.example.com} " in
	*" $host "*) exit 0 ;;
	esac
	echo "x $host has not been authenticated with glab" >&2
	exit 1
fi
[[ "$1" == "api" ]] || { echo "stub: unexpected glab $1" >&2; exit 2; }
shift
method=GET input="" endpoint=""
while [[ $# -gt 0 ]]; do
	case "$1" in
	-X | --method) method="$2"; shift ;;
	--input) input="$2"; shift ;;
	-H | --header | --hostname) shift ;;
	--paginate) : ;;
	-*) echo "stub: unexpected flag $1" >&2; exit 2 ;;
	*) [[ -z "$endpoint" ]] && endpoint="$1" ;;
	esac
	shift
done
notes="$st/notes.json"
viewer="${MOCK_VIEWER_ID:-4242}"
if [[ -n "$input" ]]; then
	w=$(($(cat "$st/writes" 2>/dev/null || echo 0) + 1))
	echo "$w" >"$st/writes"
	cp "$input" "$st/input.$w.$method.json"
fi
case "$method $endpoint" in
"GET user")
	if [[ "${MOCK_USER_RC:-0}" -ne 0 ]]; then
		echo "glab: 401 Unauthorized" >&2
		exit "$MOCK_USER_RC"
	fi
	if [[ -n "${MOCK_USER+set}" ]]; then
		printf '%s' "$MOCK_USER"
	else
		printf '{"id":%s,"username":"council-bot"}' "$viewer"
	fi
	;;
"GET "*"/notes?"*)
	[[ "${MOCK_LIST_RC:-0}" -eq 0 ]] || { echo "glab: 500" >&2; exit "$MOCK_LIST_RC"; }
	if [[ -n "${MOCK_LIST_RAW+set}" ]]; then
		printf '%s\n' "$MOCK_LIST_RAW"
		exit 0
	fi
	jq -c --argjson n "${MOCK_PAGE_SIZE:-100}" \
		'. as $a | if length == 0 then [[]] else [range(0; length; $n) as $i | $a[$i:$i + $n]] end | .[]' "$notes"
	[[ -z "${MOCK_BAD_PAGE:-}" ]] || printf '%s\n' "$MOCK_BAD_PAGE"
	;;
"POST "*/notes)
	seq=$(($(cat "$st/seq" 2>/dev/null || echo 0) + 1))
	echo "$seq" >"$st/seq"
	if [[ "${MOCK_CREATE_FAIL_AT:-0}" -eq "$seq" ]]; then
		echo "glab: 422 Unprocessable" >&2
		exit 1
	fi
	id=$((900 + seq))
	jq --argjson id "$id" --argjson v "$viewer" --slurpfile in "$input" \
		'. + [{id:$id, body:$in[0].body, system:false, author:{id:$v, username:"council-bot"}}]' \
		"$notes" >"$notes.new" && mv "$notes.new" "$notes"
	printf '{"id":%s,"body":"..."}' "$id"
	;;
"PUT "*/notes/*)
	[[ "${MOCK_UPDATE_RC:-0}" -eq 0 ]] || { echo "glab: 500" >&2; exit "$MOCK_UPDATE_RC"; }
	id="${endpoint##*/}"
	jq --argjson id "$id" --slurpfile in "$input" \
		'map(if .id == $id then .body = $in[0].body else . end)' \
		"$notes" >"$notes.new" && mv "$notes.new" "$notes"
	jq -c --argjson id "$id" '.[] | select(.id == $id)' "$notes"
	;;
"GET "*/notes/*)
	[[ "${MOCK_GET_RC:-0}" -eq 0 ]] || { echo "glab: 500" >&2; exit "$MOCK_GET_RC"; }
	id="${endpoint##*/}"
	out=$(jq -c --argjson id "$id" '.[] | select(.id == $id)' "$notes")
	[[ -n "$out" ]] || { echo "glab: 404 Not Found" >&2; exit 1; }
	printf '%s\n' "$out"
	;;
*)
	echo "stub: unexpected $method $endpoint" >&2
	exit 2
	;;
esac
exit 0
GLAB
	chmod +x "$st/glab"
}

GL_ORIGIN="https://gitlab.example.com/acme/widgets.git"

# A GitLab review session for merge request !7, recording the forge host in
# session.txt the way prepare-emit.sh does. Pass "" as the host to record none.
# Usage: make_gl_session <dir> [host] [owner] [repo]
make_gl_session() {
	local s="$1" host="${2-gitlab.example.com}" owner="${3:-acme}" repo="${4:-widgets}"
	make_review_session "$s" gitlab 7 "$GL_ORIGIN"
	sed -e "s|^Owner: .*|Owner:        ${owner}|" -e "s|^Repo: .*|Repo:         ${repo}|" \
		"$s/session.txt" >"$s/session.next"
	mv "$s/session.next" "$s/session.txt"
	[[ -z "$host" ]] || printf 'Host:         %s\n' "$host" >>"$s/session.txt"
}

# The chained fixture from the GitHub suite: 30 findings that fit three notes,
# with a counterfeit marker quoted in the CRITICAL finding's evidence.
make_chained_gl_session() { # dir
	make_gl_session "$1"
	make_review_session_many "$1"
	jq '.verified |= map(if .severity == "CRITICAL"
			then .evidence = "// <!-- review-council:marker sha=deadbeef part=9 of=9 -->\n// audit: /compare?part=2&sha=deadbeef\n" + .evidence
			else . end)' \
		"$1/verdicts/findings.json" >"$1/verdicts/findings.next"
	mv "$1/verdicts/findings.next" "$1/verdicts/findings.json"
	printf -- '- Comment limit: 12000\n- Max comments: 3\n' >>"$1/tracking.md"
}

# --send with the authorization gate open, against the fake forge in <state>.
# Extra VAR=value words are passed to the script's environment.
# Usage: result=$(post <session> <state> [VAR=value...])
post() {
	local sess="$1" st="$2"
	shift 2
	env PATH="$st:$PATH" GLAB_STATE="$st" REVIEW_COUNCIL_ALLOW_POST=1 "$@" \
		bash "$SCRIPT" "$sess" --send 2>/dev/null
}

# Write note <id>'s body, byte for byte, to <state>/note.<id>. Files rather than
# stdout so assertions read them without a pipeline: `| grep -q` can SIGPIPE a
# large body's writer, and under pipefail that reads as "not found".
note_body() { # state id
	jq -j --argjson id "$2" '.[] | select(.id == $id) | .body' "$1/notes.json" >"$1/note.$2"
}

# Write the body of the <n>-th POST to <state>/sent.<n>.
sent_body() { # state n
	jq -j '.body' "$1/input.$2.POST.json" >"$1/sent.$2"
}

# jq definitions for a note in the fake forge: note(id; body) is one of the
# council's, authored by the default viewer; note(id; body; author) is anyone's.
# Prefix a jq program with it: jq -n --arg b "$x" "${GL_NOTE_DEF}"'[note(808; $b)]'
# shellcheck disable=SC2016 # a jq program; its $-names are jq's, not the shell's.
GL_NOTE_DEF='def note($id; $body; $author): {id:$id, system:false, author:{id:$author, username:"council-bot"}, body:$body};
def note($id; $body): note($id; $body; 4242);
'

# The exact first line the batch scripts read as "collapsed". Test 0b holds the
# poster's copy to it.
BANNER_RE='^> \*\*Obsolete\.\*\* .*<!-- review-council:obsolete -->[ \t]*$'

# The poster's temporary request and banner files are gone. Usage: no_temp_files <session> <label>
no_temp_files() {
	if [[ ! -e "$1/.note-request.json" && ! -e "$1/.supersede-body.md" ]]; then
		echo "  PASS: $2"
		PASS=$((PASS + 1))
	else
		echo "  FAIL: $2"
		FAIL=$((FAIL + 1))
	fi
}

# Assert note <id> was retired: the obsolete banner as its first line, linking
# the new verdict, then a blank line, then the original body intact.
assert_retired() { # state id original label
	local body first
	note_body "$1" "$2"
	body=$(cat "$1/note.$2")
	first=$(head -n 1 "$1/note.$2")
	if jq -en --arg b "$first" --arg re "$BANNER_RE" '$b | test($re)' >/dev/null &&
		[[ "$first" == *"/-/merge_requests/7#note_"* ]] &&
		[[ "$body" == "$first"$'\n\n'"$3" ]]; then
		echo "  PASS: $4"
		PASS=$((PASS + 1))
	else
		echo "  FAIL: $4 (body: ${body:0:300})"
		FAIL=$((FAIL + 1))
	fi
}

assert_untouched() { # state id original label
	local body want
	note_body "$1" "$2"
	body=$(cat "$1/note.$2")
	want=$(printf '%s' "$3")
	if [[ "$body" == "$want" ]]; then
		echo "  PASS: $4"
		PASS=$((PASS + 1))
	else
		echo "  FAIL: $4"
		FAIL=$((FAIL + 1))
	fi
}

assert_log_has() { # state fixed-string label
	if grep -qF -- "$2" "$1/log" 2>/dev/null; then
		echo "  PASS: $3"
		PASS=$((PASS + 1))
	else
		echo "  FAIL: $3 (no '$2' in glab log)"
		FAIL=$((FAIL + 1))
	fi
}

assert_log_lacks() { # state fixed-string label
	if ! grep -qF -- "$2" "$1/log" 2>/dev/null; then
		echo "  PASS: $3"
		PASS=$((PASS + 1))
	else
		echo "  FAIL: $3 (found '$2' in glab log)"
		FAIL=$((FAIL + 1))
	fi
}

no_writes() { # state label
	if ! grep -qE -- '-X (POST|PUT|PATCH|DELETE)' "$1/log" 2>/dev/null; then
		echo "  PASS: $2"
		PASS=$((PASS + 1))
	else
		echo "  FAIL: $2"
		FAIL=$((FAIL + 1))
	fi
}

# This run's head sha, as the rendered marker carries it. Guarded by the caller:
# an empty extraction would make a forgery quote nothing.
head_sha_of() { # session
	sed -n 's/.*review-council:marker sha=\([^ ]*\).*/\1/p' "$1/comment-body.md"
}

echo "Test 0: the declared limit is GitLab's actual note cap"
# Fifteen times GitHub's, so the same review that has to be pared there posts
# whole here. Collapsing it toward GitHub's value would trim needlessly.
gl_limit=$(sed -n '/^rc_comment_limit()/,/^}/p' "$SCRIPT" | sed -nE "s/.*printf '([0-9]+)'.*/\1/p")
assert_equals "$gl_limit" "1000000" "GitLab's note limit is declared as 1000000"

echo "Test 0b: the poster's banner pattern is this suite's"
# The poster decides "already retired" from the first line the batch scripts
# read as "collapsed". test-scripts-forge-gitlab.sh holds the batch side to the
# poster's constant; this holds the poster to the pattern asserted below. It
# stays inside module/: the mutation harness runs this suite on a copy of
# module/ alone.
poster_re=$(sed -nE "s/^RC_GL_OBSOLETE_RE='(.*)'\$/\1/p" "$SCRIPT")
assert_equals "$poster_re" "$BANNER_RE" "the poster's banner pattern matches this suite's"

echo "Test 1: dry-run renders the body and calls no glab"
sess=$(mktemp -d)
st=$(mktemp -d)
make_gl_session "$sess"
make_glab "$st"
result=$(PATH="$st:$PATH" GLAB_STATE="$st" REVIEW_COUNCIL_ALLOW_POST=1 bash "$SCRIPT" "$sess" 2>/dev/null)
assert_json_field "$result" "status" "rendered" "status is rendered (dry-run)"
assert_json_field "$result" "parts" "1" "one part"
assert_json_field "$result" "pare_level" "0" "nothing pared"
if grep -qF "<!-- review-council:marker sha=" "$sess/comment-body.md"; then
	echo "  PASS: body rendered"
	PASS=$((PASS + 1))
else
	echo "  FAIL: no body"
	FAIL=$((FAIL + 1))
fi
if echo "$result" | jq -r '.message' | grep -qF "merge request !7"; then
	echo "  PASS: the merge request is named with GitLab's own sigil"
	PASS=$((PASS + 1))
else
	echo "  FAIL: the merge request number is missing or wrongly sigiled"
	FAIL=$((FAIL + 1))
fi
if [[ ! -s "$st/log" ]]; then
	echo "  PASS: no glab call on a dry-run"
	PASS=$((PASS + 1))
else
	echo "  FAIL: a dry-run reached glab"
	FAIL=$((FAIL + 1))
fi
rm -rf "$sess" "$st"

echo "Test 2: send creates a note, its body sent intact as JSON"
sess=$(mktemp -d)
st=$(mktemp -d)
make_gl_session "$sess"
make_glab "$st"
result=$(post "$sess" "$st")
assert_json_field "$result" "status" "posted" "status is posted"
assert_json_field "$result" "action" "created" "action is created"
assert_json_field "$result" "superseded" "0" "nothing superseded"
assert_log_has "$st" "api --hostname gitlab.example.com -X POST projects/acme%2Fwidgets/merge_requests/7/notes --input" \
	"create POSTs to the merge request's notes"
assert_log_has "$st" "-H Content-Type: application/json" "the body is declared JSON"
assert_log_lacks "$st" "body=" "no body travels in argv"
sent_body "$st" 1
if cmp -s "$st/sent.1" "$sess/comment-body.md"; then
	echo "  PASS: the POSTed JSON body is the rendered body, byte for byte"
	PASS=$((PASS + 1))
else
	echo "  FAIL: the POSTed body differs from the rendered one"
	FAIL=$((FAIL + 1))
fi
n_notes=$(jq 'length' "$st/notes.json")
assert_equals "$n_notes" "1" "exactly one note exists"
no_temp_files "$sess" "the request file is removed after posting"
rm -rf "$sess" "$st"

echo "Test 3: send is a no-op when this commit's note is identical"
sess=$(mktemp -d)
st=$(mktemp -d)
make_gl_session "$sess"
make_glab "$st"
bash "$SCRIPT" "$sess" >/dev/null 2>&1
jq -n --rawfile b "$sess/comment-body.md" "${GL_NOTE_DEF}"'[note(900; $b)]' >"$st/notes.json"
result=$(post "$sess" "$st")
assert_json_field "$result" "action" "unchanged" "action is unchanged"
no_writes "$st" "no write for an identical body"
rm -rf "$sess" "$st"

echo "Test 4: send updates in place when the body differs"
sess=$(mktemp -d)
st=$(mktemp -d)
make_gl_session "$sess"
make_glab "$st"
bash "$SCRIPT" "$sess" >/dev/null 2>&1
sha=$(head_sha_of "$sess")
jq -n --arg b "stale prior body"$'\n\n'"<!-- review-council:marker sha=${sha} part=1 of=1 -->" \
	"${GL_NOTE_DEF}"'[note(901; $b)]' >"$st/notes.json"
result=$(post "$sess" "$st")
assert_json_field "$result" "action" "updated" "action is updated"
assert_log_has "$st" "-X PUT projects/acme%2Fwidgets/merge_requests/7/notes/901 --input" "PUT note 901"
note_body "$st" 901
if cmp -s "$st/note.901" "$sess/comment-body.md"; then
	echo "  PASS: note 901 now carries the rendered body"
	PASS=$((PASS + 1))
else
	echo "  FAIL: note 901 was not updated to the rendered body"
	FAIL=$((FAIL + 1))
fi
rm -rf "$sess" "$st"

# Test 3's prior note, but rendered by an earlier session: same head, same
# findings, a different session directory. Each run stamps its session into the
# marker, so the bodies differ and the verdict is edited. Without that the edit
# is skipped and a batch run cannot tell this completed re-review from one that
# posted nothing.
echo "Test 4a: a re-review from a new session at the same head edits the verdict"
sess=$(mktemp -d)
st=$(mktemp -d)
make_gl_session "$sess"
sess_new=$(mktemp -d)
cp -R "$sess/." "$sess_new" # same checkout (Review root), findings and verdict
make_glab "$st"
bash "$SCRIPT" "$sess" >/dev/null 2>&1
jq -n --rawfile b "$sess/comment-body.md" "${GL_NOTE_DEF}"'[note(902; $b)]' >"$st/notes.json"
result=$(post "$sess_new" "$st")
assert_json_field "$result" "action" "updated" "the earlier session's verdict is edited in place"
assert_json_field "$result" "superseded" "0" "an edit at the same head retires nothing"
assert_log_has "$st" "-X PUT projects/acme%2Fwidgets/merge_requests/7/notes/902 --input" "PUT note 902"
note_body "$st" 902
if cmp -s "$st/note.902" "$sess_new/comment-body.md"; then
	echo "  PASS: note 902 now carries the new session's body"
	PASS=$((PASS + 1))
else
	echo "  FAIL: note 902 was not updated to the new session's body"
	FAIL=$((FAIL + 1))
fi
rm -rf "$sess" "$sess_new" "$st"

echo "Test 5: a new commit supersedes the prior commit's note with the banner"
sess=$(mktemp -d)
st=$(mktemp -d)
make_gl_session "$sess"
make_glab "$st"
old=$'an older council note\n\n<!-- review-council:marker sha=deadbeefdeadbeef part=1 of=1 -->'
jq -n --arg b "$old" "${GL_NOTE_DEF}"'[note(808; $b)]' >"$st/notes.json"
result=$(post "$sess" "$st")
assert_json_field "$result" "action" "created" "action is created"
assert_json_field "$result" "superseded" "1" "one prior note superseded"
assert_retired "$st" 808 "$old" "the prior note carries the batch scripts' obsolete banner above its body"
note_body "$st" 808
first=$(head -n 1 "$st/note.808")
if [[ "$first" == *"#note_901)"* ]]; then
	echo "  PASS: the banner links the note just posted"
	PASS=$((PASS + 1))
else
	echo "  FAIL: the banner does not link the new verdict"
	FAIL=$((FAIL + 1))
fi
assert_log_lacks "$st" "DELETE" "nothing is ever deleted"
assert_json_field "$result" "retire_failed" "0" "no retire failed"
no_temp_files "$sess" "the request and banner files are removed after retiring"
rm -rf "$sess" "$st"

echo "Test 5b: a verdict quoting the obsolete tag is still retired (RC-071)"
# Only the FIRST line says whether a note is retired; it is what the batch
# scripts read. A prior verdict quoting the tag in its evidence is live, and on
# GitLab, which cannot hide a note, skipping it would leave it live for good.
sess=$(mktemp -d)
st=$(mktemp -d)
make_gl_session "$sess"
make_glab "$st"
old=$'## Review Council: APPROVE\n\n```\necho "<!-- review-council:obsolete -->"\n```\n\n<!-- review-council:marker sha=deadbeefdeadbeef part=1 of=1 -->'
jq -n --arg b "$old" "${GL_NOTE_DEF}"'[note(808; $b)]' >"$st/notes.json"
result=$(post "$sess" "$st")
assert_json_field "$result" "superseded" "1" "the quoting verdict is superseded"
assert_retired "$st" 808 "$old" "the quoting verdict carries the banner"
rm -rf "$sess" "$st"

echo "Test 6: a failed notes lookup is an error, never 'none'"
sess=$(mktemp -d)
st=$(mktemp -d)
make_gl_session "$sess"
make_glab "$st"
result=$(post "$sess" "$st" MOCK_LIST_RC=1)
assert_json_field "$result" "status" "error" "status is error on lookup failure"
no_writes "$st" "nothing posted after a failed lookup"
rm -rf "$sess" "$st"

echo "Test 6b: a page that is not an array is an error, never 'none'"
# An error body mid-listing would otherwise read as a short list, and a short
# list is how a duplicate verdict gets posted.
sess=$(mktemp -d)
st=$(mktemp -d)
make_gl_session "$sess"
make_glab "$st"
result=$(post "$sess" "$st" MOCK_BAD_PAGE='{"message":"500 Internal Server Error"}')
assert_json_field "$result" "status" "error" "status is error on a non-array page"
no_writes "$st" "nothing posted after a malformed page"
rm -rf "$sess" "$st"
# The sharper shape: an object as the ONLY page. Joined without the array check
# it becomes an empty list — "nothing posted yet" — and a duplicate follows.
sess=$(mktemp -d)
st=$(mktemp -d)
make_gl_session "$sess"
make_glab "$st"
result=$(post "$sess" "$st" MOCK_LIST_RAW='{}')
assert_json_field "$result" "status" "error" "status is error when the only page is an object (RC-072)"
no_writes "$st" "nothing posted after an object page"
rm -rf "$sess" "$st"

echo "Test 7: glab absent degrades to render-only"
sess=$(mktemp -d)
make_gl_session "$sess"
gbin=$(mktemp -d)
noglab=$(path_without_command glab "$gbin")
rc=0
PATH="$noglab" bash -c 'command -v glab' >/dev/null 2>&1 || rc=$?
if [[ $rc -eq 1 ]]; then
	echo "  PASS: glab masked from PATH, interpreter intact"
	PASS=$((PASS + 1))
else
	echo "  FAIL: masked PATH unusable (rc=$rc; 0=glab still found, 127=no bash)"
	FAIL=$((FAIL + 1))
fi
result=$(PATH="$noglab" REVIEW_COUNCIL_ALLOW_POST=1 bash "$SCRIPT" "$sess" --send 2>/dev/null)
assert_json_field "$result" "status" "rendered" "degrades to rendered when glab is missing"
if echo "$result" | jq -r '.message' | grep -qF "post"; then
	echo "  PASS: the message tells the caller to post manually"
	PASS=$((PASS + 1))
else
	echo "  FAIL: the degrade message gives no instruction"
	FAIL=$((FAIL + 1))
fi
rm -rf "$sess" "$gbin"

echo "Test 8: refuses to post without REVIEW_COUNCIL_ALLOW_POST"
sess=$(mktemp -d)
st=$(mktemp -d)
make_gl_session "$sess"
make_glab "$st"
result=$(PATH="$st:$PATH" GLAB_STATE="$st" bash "$SCRIPT" "$sess" --send 2>/dev/null)
assert_json_field "$result" "status" "confirm_required" "status is confirm_required without allow-post"
if [[ ! -s "$st/log" ]]; then
	echo "  PASS: glab never invoked"
	PASS=$((PASS + 1))
else
	echo "  FAIL: glab invoked despite the gate"
	FAIL=$((FAIL + 1))
fi
rm -rf "$sess" "$st"

echo "Test 9: a host glab is not logged in to is refused before any other call"
sess=$(mktemp -d)
st=$(mktemp -d)
make_gl_session "$sess"
make_glab "$st"
result=$(post "$sess" "$st" MOCK_AUTH_HOSTS="")
assert_json_field "$result" "status" "error" "status is error for an unconfigured host"
if echo "$result" | jq -r '.message' | grep -qF "glab auth login --hostname gitlab.example.com"; then
	echo "  PASS: the adapter's refusal is relayed"
	PASS=$((PASS + 1))
else
	echo "  FAIL: the refusal does not tell the user how to log in"
	FAIL=$((FAIL + 1))
fi
calls=$(cat "$st/log")
assert_equals "$calls" "glab auth status --hostname gitlab.example.com" \
	"the login check is the only glab call made"
rm -rf "$sess" "$st"

echo "Test 10: an unresolvable or malformed viewer fails closed"
# Council identity is marker AND author id. Without an id there is nothing to
# compare authors against, and the marker alone is public.
for case_ in "rc" '{"username":"council-bot"}' '{"id":"4242","username":"council-bot"}' \
	'{"id":0,"username":"council-bot"}' '{"id":42.5,"username":"council-bot"}' '{"id":4242}' 'not json'; do
	sess=$(mktemp -d)
	st=$(mktemp -d)
	make_gl_session "$sess"
	make_glab "$st"
	if [[ "$case_" == "rc" ]]; then
		result=$(post "$sess" "$st" MOCK_USER_RC=1)
	else
		result=$(post "$sess" "$st" MOCK_USER="$case_")
	fi
	assert_json_field "$result" "status" "error" "viewer '${case_}' is an error"
	no_writes "$st" "nothing written for viewer '${case_}'"
	assert_log_lacks "$st" "/notes" "no note was listed for viewer '${case_}'"
	rm -rf "$sess" "$st"
done
sess=$(mktemp -d)
st=$(mktemp -d)
make_gl_session "$sess"
make_glab "$st"
result=$(post "$sess" "$st" MOCK_USER_RC=1)
if echo "$result" | jq -r '.message' | grep -qF "glab auth status"; then
	echo "  PASS: the message points at glab auth status"
	PASS=$((PASS + 1))
else
	echo "  FAIL: the message gives the user nothing to act on"
	FAIL=$((FAIL + 1))
fi
rm -rf "$sess" "$st"

echo "Test 11: a verdict answering a conversation supersedes rather than edits"
# GitLab, like GitHub, does not notify on an edit: the reply has to be a note.
sess=$(mktemp -d)
st=$(mktemp -d)
make_gl_session "$sess"
make_glab "$st"
bash "$SCRIPT" "$sess" >/dev/null 2>&1
prior=$(cat "$sess/comment-body.md")
jq -n --arg b "$prior" "${GL_NOTE_DEF}"'[note(900; $b)]' >"$st/notes.json"
printf 'reply from @bootc: finding 3 is wrong, the guard is two lines up.\n' >"$sess/pr-conversation.txt"
printf 'Result: ran\n' >"$sess/verdicts/_meta/disposition.txt" # Disposition ran (RC-075 gate)
result=$(post "$sess" "$st")
assert_json_field "$result" "action" "created" "answering a conversation posts a new note"
assert_json_field "$result" "superseded" "1" "the prior verdict is retired, the new one is not"
assert_retired "$st" 900 "$prior" "the prior same-sha verdict was retired with the exact banner"
note_body "$st" 901
if ! grep -qF "review-council:obsolete" "$st/note.901"; then
	echo "  PASS: the fresh note is live"
	PASS=$((PASS + 1))
else
	echo "  FAIL: the run retired its own fresh verdict"
	FAIL=$((FAIL + 1))
fi
# Retire AFTER posting: the PUT on 900 comes after the POST.
ln_post=$(grep -n -- '-X POST' "$st/log" | head -1 | cut -d: -f1 || true)
ln_put=$(grep -n -- '-X PUT .*/notes/900' "$st/log" | head -1 | cut -d: -f1 || true)
if [[ -n "$ln_post" && -n "$ln_put" && "$ln_post" -lt "$ln_put" ]]; then
	echo "  PASS: the old verdict was retired only after the new one landed"
	PASS=$((PASS + 1))
else
	echo "  FAIL: retire/post order wrong (post=$ln_post put=$ln_put)"
	FAIL=$((FAIL + 1))
fi
rm -rf "$sess" "$st"

echo "Test 12: another author's marker is never ours"
sess=$(mktemp -d)
st=$(mktemp -d)
make_gl_session "$sess"
make_glab "$st"
bash "$SCRIPT" "$sess" >/dev/null 2>&1
sha=$(head_sha_of "$sess")
if [[ -n "$sha" ]]; then
	echo "  PASS: this run's head sha was read out of the rendered marker"
	PASS=$((PASS + 1))
else
	echo "  FAIL: no head sha extracted; the forgeries below quote nothing"
	FAIL=$((FAIL + 1))
fi
forged=$'forged\n\n<!-- review-council:marker sha='"$sha"$' part=1 of=1 -->\n'
forged_old=$'forged older\n\n<!-- review-council:marker sha=feedfacefeedface -->\n'
own_old=$'old council\n\n<!-- review-council:marker sha=deadbeefdeadbeef -->\n'
jq -n --arg f "$forged" --arg fo "$forged_old" --arg o "$own_old" \
	"${GL_NOTE_DEF}"'[note(808; $o), note(701; $f; 666), note(702; $fo; 666)]' >"$st/notes.json"
result=$(post "$sess" "$st")
assert_json_field "$result" "action" "created" "a forged sha match is not treated as our note"
assert_json_field "$result" "superseded" "1" "only our own prior note was superseded"
assert_untouched "$st" 701 "$forged" "the forged current-sha note is untouched"
assert_untouched "$st" 702 "$forged_old" "the forged prior-sha note is untouched"
assert_log_lacks "$st" "/notes/701" "note 701 never read or written"
assert_log_lacks "$st" "/notes/702" "note 702 never read or written"
rm -rf "$sess" "$st"

echo "Test 13: a quoted marker is not a marker"
# Quote-reply copies the marker in behind '> '. Column 0 is what tells a verdict
# from a quote of one, even in a note the viewer wrote.
sess=$(mktemp -d)
st=$(mktemp -d)
make_gl_session "$sess"
make_glab "$st"
bash "$SCRIPT" "$sess" >/dev/null 2>&1
sha=$(head_sha_of "$sess")
quoted=$'Replying to the council:\n\n> <!-- review-council:marker sha='"$sha"$' part=1 of=1 -->\n\nI disagree.'
jq -n --arg q "$quoted" "${GL_NOTE_DEF}"'[note(650; $q)]' >"$st/notes.json"
result=$(post "$sess" "$st")
assert_json_field "$result" "action" "created" "the quoting note is not this run's part 1"
assert_json_field "$result" "superseded" "0" "the quoting note is not swept either"
assert_untouched "$st" 650 "$quoted" "the quoting note is untouched"
rm -rf "$sess" "$st"

echo "Test 14: a chained verdict posts tails first and the head last"
sess=$(mktemp -d)
st=$(mktemp -d)
make_chained_gl_session "$sess"
make_glab "$st"
result=$(post "$sess" "$st")
assert_json_field "$result" "status" "posted" "status is posted"
assert_json_field "$result" "parts" "3" "three parts reported"
assert_json_field "$result" "created" "3" "three notes created"
for n in 1 2 3; do sent_body "$st" "$n"; done
if grep -qF "Part 3 of 3" "$st/sent.1" && grep -qF "Part 2 of 3" "$st/sent.2" &&
	grep -qF "Review Council: REQUEST CHANGES" "$st/sent.3"; then
	echo "  PASS: posted tail-first, head last"
	PASS=$((PASS + 1))
else
	echo "  FAIL: posting order wrong"
	FAIL=$((FAIL + 1))
fi
head_body=$(cat "$st/sent.3")
if grep -qF '[part 2](https://gitlab.example.com/acme/widgets/-/merge_requests/7#note_902)' <<<"$head_body" &&
	grep -qF '[part 3](https://gitlab.example.com/acme/widgets/-/merge_requests/7#note_901)' <<<"$head_body"; then
	echo "  PASS: the head links to the notes that were just posted"
	PASS=$((PASS + 1))
else
	echo "  FAIL: part links not substituted into the head"
	FAIL=$((FAIL + 1))
fi
if ! grep -qF 'review-council:part-links' <<<"$head_body"; then
	echo "  PASS: the placeholder is gone from the posted head"
	PASS=$((PASS + 1))
else
	echo "  FAIL: the unsubstituted placeholder was posted"
	FAIL=$((FAIL + 1))
fi
rm -rf "$sess" "$st"

# Seed <state> with a previous run's three parts as notes 901..903, the head
# optionally altered by <suffix> (an edit, or a stale body).
seed_chain() { # session state [head-suffix]
	bash "$SCRIPT" "$1" >/dev/null 2>&1
	jq -n --rawfile p1 "$1/comment-body.md" --rawfile p2 "$1/comment-body.part2.md" \
		--rawfile p3 "$1/comment-body.part3.md" --arg sfx "${3:-}" \
		"${GL_NOTE_DEF}"'[note(901; ($p1 + $sfx)), note(902; $p2), note(903; $p3)]' >"$2/notes.json"
}

echo "Test 15: a re-review of the same commit updates each part in place"
sess=$(mktemp -d)
st=$(mktemp -d)
make_chained_gl_session "$sess"
make_glab "$st"
seed_chain "$sess" "$st"
# Make every part stale without touching its marker line.
jq 'map(.body = ("stale preface\n" + .body))' "$st/notes.json" >"$st/n" && mv "$st/n" "$st/notes.json"
result=$(post "$sess" "$st")
assert_json_field "$result" "action" "updated" "action is updated"
assert_json_field "$result" "updated" "3" "all three parts updated"
assert_json_field "$result" "created" "0" "nothing created"
for n in 2 3; do
	note_body "$st" $((900 + n))
	if cmp -s "$st/note.$((900 + n))" "$sess/comment-body.part${n}.md"; then
		echo "  PASS: part ${n} written to its own note"
		PASS=$((PASS + 1))
	else
		echo "  FAIL: part ${n} landed elsewhere"
		FAIL=$((FAIL + 1))
	fi
done
rm -rf "$sess" "$st"

echo "Test 16: a verdict that now needs fewer notes retires the surplus"
sess=$(mktemp -d)
st=$(mktemp -d)
make_chained_gl_session "$sess"
make_glab "$st"
seed_chain "$sess" "$st"
note_body "$st" 902
note_body "$st" 903
p2=$(cat "$st/note.902")
p3=$(cat "$st/note.903")
# Same commit, no chaining any more: the verdict fits one note.
sed '/^- Comment limit:/d; /^- Max comments:/d' "$sess/tracking.md" >"$sess/t" && mv "$sess/t" "$sess/tracking.md"
result=$(post "$sess" "$st")
assert_json_field "$result" "parts" "1" "the verdict now fits one note"
assert_json_field "$result" "superseded" "2" "the two surplus parts were retired"
assert_retired "$st" 902 "$p2" "surplus part 2 bannered"
assert_retired "$st" 903 "$p3" "surplus part 3 bannered"
note_body "$st" 901
if cmp -s "$st/note.901" "$sess/comment-body.md"; then
	echo "  PASS: part 1 kept and updated"
	PASS=$((PASS + 1))
else
	echo "  FAIL: part 1 was not updated to the single-note verdict"
	FAIL=$((FAIL + 1))
fi
rm -rf "$sess" "$st"

echo "Test 17: superseding a prior commit sweeps every part, never the new chain"
sess=$(mktemp -d)
st=$(mktemp -d)
make_chained_gl_session "$sess"
make_glab "$st"
o1=$'prior part 1\n\n<!-- review-council:marker sha=deadbeefdeadbeef part=1 of=2 -->'
o2=$'prior part 2\n\n<!-- review-council:marker sha=deadbeefdeadbeef part=2 of=2 -->'
jq -n --arg a "$o1" --arg b "$o2" "${GL_NOTE_DEF}"'[note(801; $a), note(802; $b)]' >"$st/notes.json"
result=$(post "$sess" "$st")
assert_json_field "$result" "parts" "3" "three parts posted"
assert_json_field "$result" "superseded" "2" "both parts of the prior commit superseded"
assert_retired "$st" 801 "$o1" "prior part 1 bannered"
assert_retired "$st" 802 "$o2" "prior part 2 bannered"
own_bannered=0
for id in 901 902 903; do
	note_body "$st" "$id"
	grep -qF "review-council:obsolete" "$st/note.$id" && own_bannered=$((own_bannered + 1))
done
assert_equals "$own_bannered" "0" "no part of the new chain was retired"
rm -rf "$sess" "$st"

echo "Test 18: a retired note is never bannered twice"
sess=$(mktemp -d)
st=$(mktemp -d)
make_gl_session "$sess"
make_glab "$st"
already=$'> **Obsolete.** Superseded by the [current Review Council verdict](https://gitlab.example.com/acme/widgets/-/merge_requests/7#note_5) for commit `abc1234`. <!-- review-council:obsolete -->\n\nolder\n\n<!-- review-council:marker sha=deadbeefdeadbeef part=1 of=1 -->'
jq -n --arg b "$already" "${GL_NOTE_DEF}"'[note(808; $b)]' >"$st/notes.json"
result=$(post "$sess" "$st")
assert_json_field "$result" "status" "posted" "status is posted"
assert_untouched "$st" 808 "$already" "the banner was not stacked"
assert_log_lacks "$st" "-X PUT projects/acme%2Fwidgets/merge_requests/7/notes/808" "no write to the retired note"
rm -rf "$sess" "$st"
# The same banner on a note edited from a CRLF client.
sess=$(mktemp -d)
st=$(mktemp -d)
make_gl_session "$sess"
make_glab "$st"
already_crlf="${already//$'\n'/$'\r\n'}"
jq -n --arg b "$already_crlf" "${GL_NOTE_DEF}"'[note(808; $b)]' >"$st/notes.json"
result=$(post "$sess" "$st")
assert_untouched "$st" 808 "$already_crlf" "a CRLF banner is recognised and not stacked"
rm -rf "$sess" "$st"

echo "Test 18b: a retire that fails is reported, not counted (RC-071)"
# The new verdict did post, so the status stays `posted`; but a prior verdict
# left live must not be reported as superseded.
for fail in MOCK_UPDATE_RC=1 MOCK_GET_RC=1; do
	sess=$(mktemp -d)
	st=$(mktemp -d)
	make_gl_session "$sess"
	make_glab "$st"
	old=$'older\n\n<!-- review-council:marker sha=deadbeefdeadbeef part=1 of=1 -->'
	jq -n --arg b "$old" "${GL_NOTE_DEF}"'[note(808; $b)]' >"$st/notes.json"
	result=$(post "$sess" "$st" "$fail")
	assert_json_field "$result" "status" "posted" "${fail}: the new verdict still reports posted"
	assert_json_field "$result" "superseded" "0" "${fail}: the failed retire is not counted"
	assert_json_field "$result" "retire_failed" "1" "${fail}: the failed retire is reported"
	if echo "$result" | jq -r '.message' | grep -qF "could not be retired"; then
		echo "  PASS: ${fail}: the message says a prior note is still live"
		PASS=$((PASS + 1))
	else
		echo "  FAIL: ${fail}: the message hides the failed retire"
		FAIL=$((FAIL + 1))
	fi
	no_temp_files "$sess" "${fail}: temp files removed on the failure path"
	rm -rf "$sess" "$st"
done

echo "Test 19: a write that fails partway through a chain is reported"
sess=$(mktemp -d)
st=$(mktemp -d)
make_chained_gl_session "$sess"
make_glab "$st"
result=$(post "$sess" "$st" MOCK_CREATE_FAIL_AT=2)
assert_json_field "$result" "status" "error" "a failed create is an error, not a post"
if echo "$result" | jq -r '.message' | grep -qF "part 2 of 3"; then
	echo "  PASS: the message names the part that failed"
	PASS=$((PASS + 1))
else
	echo "  FAIL: the failure does not say where it stopped"
	FAIL=$((FAIL + 1))
fi
jq -r '.[].body' "$st/notes.json" >"$st/all-bodies"
if ! grep -qF "Review Council: REQUEST CHANGES" "$st/all-bodies"; then
	echo "  PASS: the head was never posted over an incomplete chain"
	PASS=$((PASS + 1))
else
	echo "  FAIL: a verdict was posted summarising findings that never landed"
	FAIL=$((FAIL + 1))
fi
rm -rf "$sess" "$st"

echo "Test 20: a failed update of an existing part is reported"
sess=$(mktemp -d)
st=$(mktemp -d)
make_chained_gl_session "$sess"
make_glab "$st"
seed_chain "$sess" "$st"
jq 'map(.body = ("stale preface\n" + .body))' "$st/notes.json" >"$st/n" && mv "$st/n" "$st/notes.json"
result=$(post "$sess" "$st" MOCK_UPDATE_RC=1)
assert_json_field "$result" "status" "error" "a failed update is an error"
if echo "$result" | jq -r '.message' | grep -qF "part 3 of 3"; then
	echo "  PASS: the first part attempted is the one named"
	PASS=$((PASS + 1))
else
	echo "  FAIL: the failing part is not identified"
	FAIL=$((FAIL + 1))
fi
rm -rf "$sess" "$st"

echo "Test 21: a single-note create failure reports an error"
sess=$(mktemp -d)
st=$(mktemp -d)
make_gl_session "$sess"
make_glab "$st"
result=$(post "$sess" "$st" MOCK_CREATE_FAIL_AT=1)
assert_json_field "$result" "status" "error" "status is error"
if echo "$result" | jq -r '.message' | grep -qiF "failed to create"; then
	echo "  PASS: the message says the create failed"
	PASS=$((PASS + 1))
else
	echo "  FAIL: the create failure is not described"
	FAIL=$((FAIL + 1))
fi
no_temp_files "$sess" "the request file is removed on the error path too"
rm -rf "$sess" "$st"

echo "Test 22: substituting the part links never pushes the head over the limit"
sess=$(mktemp -d)
st=$(mktemp -d)
make_chained_gl_session "$sess"
make_glab "$st"
# The limit sits 64 bytes above the head as rendered: the packer fills part 1
# with the same findings (it over-reserves only a few bytes for group counts),
# and the links line, over 100 bytes, has no room. See the GitHub suite's twin.
bash "$SCRIPT" "$sess" >/dev/null 2>&1
head_bytes=$(wc -c <"$sess/comment-body.md" | tr -d ' ')
limit=$((head_bytes + 64))
sed "s/^- Comment limit: .*/- Comment limit: ${limit}/" "$sess/tracking.md" >"$sess/t" && mv "$sess/t" "$sess/tracking.md"
bash "$SCRIPT" "$sess" >/dev/null 2>&1
packed_bytes=$(wc -c <"$sess/comment-body.md" | tr -d ' ')
assert_equals "$packed_bytes" "$head_bytes" \
	"precondition: the head packs the same findings 64 bytes short of the limit"
result=$(post "$sess" "$st")
assert_json_field "$result" "parts" "3" "still a chain, so the links are still attempted"
sent_body "$st" 3
tight=$(wc -c <"$st/sent.3" | tr -d ' ')
if [[ "$tight" -le "$limit" ]]; then
	echo "  PASS: the head near the limit was not grown past it ($tight <= $limit)"
	PASS=$((PASS + 1))
else
	echo "  FAIL: substitution pushed the head over the limit ($tight > $limit)"
	FAIL=$((FAIL + 1))
fi
if grep -qF "review-council:part-links" "$st/sent.3" && ! grep -qF "[part 2](" "$st/sent.3"; then
	echo "  PASS: the links were dropped and the placeholder left in their place"
	PASS=$((PASS + 1))
else
	echo "  FAIL: the links were substituted into a head with no room for them"
	FAIL=$((FAIL + 1))
fi
rm -rf "$sess" "$st"

echo "Test 23: a finding's evidence cannot impersonate the part or sha marker"
sess=$(mktemp -d)
st=$(mktemp -d)
make_chained_gl_session "$sess"
make_glab "$st"
seed_chain "$sess" "$st"
note_body "$st" 901
if grep -qF '<!-- review-council:marker sha=deadbeef part=9 of=9 -->' "$st/note.901"; then
	echo "  PASS: the head quotes a counterfeit marker above its own"
	PASS=$((PASS + 1))
else
	echo "  FAIL: the fixture no longer carries the impersonating evidence in part 1"
	FAIL=$((FAIL + 1))
fi
result=$(post "$sess" "$st")
assert_json_field "$result" "created" "0" "part 1 matched its own note, not a second one"
assert_json_field "$result" "updated" "1" "the head is updated in place (links substituted)"
assert_json_field "$result" "unchanged" "2" "the unchanged tail parts are left alone"
assert_json_field "$result" "superseded" "0" "no part of the current verdict was superseded"
rm -rf "$sess" "$st"

echo "Test 24: a quoted head sha cannot pull a prior verdict into this chain"
sess=$(mktemp -d)
st=$(mktemp -d)
make_gl_session "$sess"
make_glab "$st"
bash "$SCRIPT" "$sess" >/dev/null 2>&1
sha=$(head_sha_of "$sess")
prior=$'Prior verdict.\n\n```\n<!-- review-council:marker sha='"$sha"$' part=1 of=1 -->\n```\n\n<!-- review-council:marker sha=deadbeefdeadbeef part=1 of=1 -->'
jq -n --arg b "$prior" "${GL_NOTE_DEF}"'[note(808; $b)]' >"$st/notes.json"
result=$(post "$sess" "$st")
assert_json_field "$result" "created" "1" "this run's verdict is posted as a new note"
assert_json_field "$result" "updated" "0" "the prior verdict is not overwritten in place"
assert_json_field "$result" "superseded" "1" "the prior verdict is superseded instead"
assert_retired "$st" 808 "$prior" "the prior verdict was bannered"
rm -rf "$sess" "$st"

echo "Test 25: a chain whose head sha is unresolvable still matches part by part"
sess=$(mktemp -d)
st=$(mktemp -d)
make_chained_gl_session "$sess"
rm -rf "$sess/checkout/.git"
make_glab "$st"
seed_chain "$sess" "$st"
note_body "$st" 901
if grep -qF '<!-- review-council:marker sha=unknown part=1 of=3 ' "$st/note.901"; then
	echo "  PASS: the marker carries a non-hex sha"
	PASS=$((PASS + 1))
else
	echo "  FAIL: the fixture did not produce an unresolvable head sha"
	FAIL=$((FAIL + 1))
fi
result=$(post "$sess" "$st")
assert_json_field "$result" "created" "0" "no part is posted a second time"
assert_json_field "$result" "updated" "1" "the head is updated in place"
assert_json_field "$result" "unchanged" "2" "parts 2 and 3 are matched to their own notes"
assert_json_field "$result" "superseded" "0" "no part of the current verdict was superseded"
rm -rf "$sess" "$st"

echo "Test 26: an edit below the marker does not orphan a council note"
sess=$(mktemp -d)
st=$(mktemp -d)
make_chained_gl_session "$sess"
make_glab "$st"
edit=$'\n\nEdited by a maintainer: tracking the retry loop in #412.\n'
seed_chain "$sess" "$st" "$edit"
old=$'a prior commit\n\n<!-- review-council:marker sha=deadbeefdeadbeef part=1 of=1 -->\n'"$edit"
jq --arg b "$old" "${GL_NOTE_DEF}"'. + [note(808; $b)]' "$st/notes.json" >"$st/n" && mv "$st/n" "$st/notes.json"
result=$(post "$sess" "$st")
assert_json_field "$result" "created" "0" "the edited head is still this run's part 1"
assert_json_field "$result" "updated" "1" "the edited head is updated in place"
assert_json_field "$result" "unchanged" "2" "the untouched tail parts are still matched"
assert_json_field "$result" "superseded" "1" "the edited prior verdict is still swept"
assert_retired "$st" 808 "$(printf '%s' "$old")" "the edited prior verdict was bannered"
rm -rf "$sess" "$st"

echo "Test 27: a 200 KB note travels in a file, not in argv"
# Linux caps one argv string at 128 KiB; a body passed as a field would fail
# with E2BIG on exactly the reviews that matter most.
sess=$(mktemp -d)
st=$(mktemp -d)
make_gl_session "$sess"
make_review_session_many "$sess" 10 80 120 40
make_glab "$st"
result=$(post "$sess" "$st")
assert_json_field "$result" "status" "posted" "a large verdict posts"
assert_json_field "$result" "parts" "1" "in one note, under GitLab's limit"
sent_body "$st" 1
big=$(wc -c <"$st/sent.1" | tr -d ' ')
if [[ "$big" -ge 200000 ]] && cmp -s "$st/sent.1" "$sess/comment-body.md"; then
	echo "  PASS: the ${big}-byte body arrived intact via --input"
	PASS=$((PASS + 1))
else
	echo "  FAIL: the large body was not sent intact (${big} bytes)"
	FAIL=$((FAIL + 1))
fi
assert_log_lacks "$st" "body=" "no body field in argv"
rm -rf "$sess" "$st"

echo "Test 28: notes on every page are read"
# The council's note sits on page 3, behind a participant's note and a system note. A
# listing that read one page would miss it and post a duplicate.
sess=$(mktemp -d)
st=$(mktemp -d)
make_gl_session "$sess"
make_glab "$st"
bash "$SCRIPT" "$sess" >/dev/null 2>&1
jq -n --rawfile b "$sess/comment-body.md" \
	"${GL_NOTE_DEF}"'[note(600; "looks good"; 77), {id:601, system:true, author:{id:4242}, body:"added 1 commit"}, note(900; $b)]' \
	>"$st/notes.json"
result=$(post "$sess" "$st" MOCK_PAGE_SIZE=1)
assert_json_field "$result" "action" "unchanged" "the note on page 3 was found"
assert_log_has "$st" "--paginate" "the listing paginates"
assert_log_has "$st" "notes?per_page=100&sort=asc&order_by=created_at" "the listing is oldest first, 100 per page"
no_writes "$st" "no duplicate posted"
rm -rf "$sess" "$st"

echo "Test 29: a self-hosted nested project is addressed on every call"
sess=$(mktemp -d)
st=$(mktemp -d)
make_gl_session "$sess" git.example.org "g/sub" p
make_glab "$st"
old=$'older\n\n<!-- review-council:marker sha=deadbeefdeadbeef part=1 of=1 -->'
jq -n --arg b "$old" "${GL_NOTE_DEF}"'[note(808; $b)]' >"$st/notes.json"
result=$(post "$sess" "$st" MOCK_AUTH_HOSTS=git.example.org)
assert_json_field "$result" "status" "posted" "status is posted"
unaddressed=$(grep -vcE -- '--hostname git\.example\.org( |$)' "$st/log" || true)
assert_equals "$unaddressed" "0" "every glab call names --hostname git.example.org"
assert_log_has "$st" "projects/g%2Fsub%2Fp/merge_requests/7/notes" "the nested project is URL-encoded"
note_body "$st" 808
first=$(head -n 1 "$st/note.808")
if [[ "$first" == *"(https://git.example.org/g/sub/p/-/merge_requests/7#note_901)"* ]]; then
	echo "  PASS: the banner links the self-hosted note"
	PASS=$((PASS + 1))
else
	echo "  FAIL: the banner link is not on the recorded host"
	FAIL=$((FAIL + 1))
fi
rm -rf "$sess" "$st"

echo "Test 30: an unsafe project path or host is refused before any call"
for spec in "git.example.org|g/..|p" "git.example.org|-g|p" "git.example.org|none|p" \
	"git.example.org:8443|g|p" "evil.example/x|g|p" "-oProxy|g|p"; do
	IFS='|' read -r h o r <<<"$spec"
	sess=$(mktemp -d)
	st=$(mktemp -d)
	make_gl_session "$sess" "$h" "$o" "$r"
	make_glab "$st"
	result=$(post "$sess" "$st" MOCK_AUTH_HOSTS="$h")
	assert_json_field "$result" "status" "error" "'${spec}' is an error"
	if [[ ! -s "$st/log" ]]; then
		echo "  PASS: no glab call for '${spec}'"
		PASS=$((PASS + 1))
	else
		echo "  FAIL: glab was called for '${spec}'"
		FAIL=$((FAIL + 1))
	fi
	rm -rf "$sess" "$st"
done

echo "Test 31: an absent or 'none' host defaults to gitlab.com, without the login check"
for h in "" none; do
	sess=$(mktemp -d)
	st=$(mktemp -d)
	make_gl_session "$sess" "$h"
	make_glab "$st"
	result=$(post "$sess" "$st")
	assert_json_field "$result" "status" "posted" "host '${h}' posts"
	assert_log_has "$st" "api --hostname gitlab.com user" "host '${h}' addresses gitlab.com"
	assert_log_lacks "$st" "auth status" "gitlab.com needs no login check"
	rm -rf "$sess" "$st"
done

echo "Test 32: GITLAB_API_HOST and CI autologin never reach glab"
sess=$(mktemp -d)
st=$(mktemp -d)
make_gl_session "$sess"
make_glab "$st"
result=$(post "$sess" "$st" GITLAB_API_HOST=evil.example GLAB_ENABLE_CI_AUTOLOGIN=true)
assert_json_field "$result" "status" "posted" "status is posted"
leaked=$(grep -cvE 'GITLAB_API_HOST=unset GLAB_ENABLE_CI_AUTOLOGIN=unset$' "$st/env" || true)
assert_equals "$leaked" "0" "neither variable is visible to any glab call"
rm -rf "$sess" "$st"

echo "Test 33: an environment token reaches only the host it is bound to"
sess=$(mktemp -d)
st=$(mktemp -d)
make_gl_session "$sess" git.example.org
make_glab "$st"
result=$(post "$sess" "$st" MOCK_AUTH_HOSTS=git.example.org GITLAB_TOKEN=glpat-secret)
assert_json_field "$result" "status" "posted" "status is posted"
leaked=$(grep -c 'GITLAB_TOKEN=glpat-secret' "$st/env" || true)
assert_equals "$leaked" "0" "a gitlab.com-bound token is stripped for git.example.org"
rm -rf "$sess" "$st"
sess=$(mktemp -d)
st=$(mktemp -d)
make_gl_session "$sess" git.example.org
make_glab "$st"
result=$(post "$sess" "$st" MOCK_AUTH_HOSTS=git.example.org GITLAB_TOKEN=glpat-secret GITLAB_HOST=https://git.example.org)
calls=$(wc -l <"$st/env" | tr -d ' ')
kept=$(grep -c 'GITLAB_TOKEN=glpat-secret' "$st/env" || true)
assert_equals "$kept" "$calls" "a token bound to git.example.org is kept for it"
rm -rf "$sess" "$st"

# --- Rendering (unchanged from the render-only script) -------------------------

echo "Test 34: permalinks use GitLab's /-/ separator, not GitHub's route"
sess=$(mktemp -d)
make_review_session "$sess" gitlab 7 "$GL_ORIGIN"
bash "$SCRIPT" "$sess" >/dev/null 2>&1
body="$sess/comment-body.md"
if grep -qF "https://gitlab.example.com/acme/widgets/-/blob/" "$body" &&
	grep -qF "https://gitlab.example.com/acme/widgets/-/commit/" "$body"; then
	echo "  PASS: file and commit links built with /-/"
	PASS=$((PASS + 1))
else
	echo "  FAIL: no GitLab-shaped links"
	FAIL=$((FAIL + 1))
fi
if grep -qE 'gitlab\.example\.com/acme/widgets/(blob|commit)/' "$body"; then
	echo "  FAIL: a GitHub-shaped route leaked into a GitLab body"
	FAIL=$((FAIL + 1))
else
	echo "  PASS: no GitHub-shaped routes"
	PASS=$((PASS + 1))
fi
rm -rf "$sess"

echo "Test 35: an unparseable origin and no recorded host degrade to plain spans"
sess=$(mktemp -d)
make_review_session "$sess" gitlab 7 ""
bash "$SCRIPT" "$sess" >/dev/null 2>&1
if grep -qF "gitlab.com" "$sess/comment-body.md"; then
	echo "  FAIL: defaulted to gitlab.com with no usable origin"
	FAIL=$((FAIL + 1))
else
	echo "  PASS: no guessed host"
	PASS=$((PASS + 1))
fi
# shellcheck disable=SC2016 # a literal markdown code span in the expected output
if grep -qF '`auth/token.go:1`' "$sess/comment-body.md"; then
	echo "  PASS: the finding degraded to a plain code span"
	PASS=$((PASS + 1))
else
	echo "  FAIL: the finding location is neither linked nor a plain span"
	FAIL=$((FAIL + 1))
fi
rm -rf "$sess"

echo "Test 36: GitLab's own limit is what applies, not GitHub's"
sess=$(mktemp -d)
make_gl_session "$sess"
make_review_session_many "$sess"
result=$(bash "$SCRIPT" "$sess" 2>/dev/null)
assert_json_field "$result" "pare_level" "0" "a 30-finding body is unpared on GitLab"
assert_equals "$(grep -cF "💬 Full reviewer analysis" "$sess/comment-body.md" || true)" "30" \
	"every finding keeps its analysis"
rm -rf "$sess"

echo "Test 37: a recorded Comment limit overrides the forge, and is disclosed"
sess=$(mktemp -d)
make_gl_session "$sess"
make_review_session_many "$sess"
printf -- '- Comment limit: 20000\n- Max comments: 1\n' >>"$sess/tracking.md"
result=$(bash "$SCRIPT" "$sess" 2>/dev/null)
gl_bytes=$(wc -c <"$sess/comment-body.md" | tr -d ' ')
if [[ "$gl_bytes" -le 20000 ]]; then
	echo "  PASS: the override was honoured ($gl_bytes <= 20000)"
	PASS=$((PASS + 1))
else
	echo "  FAIL: the forge limit won over the recorded one ($gl_bytes)"
	FAIL=$((FAIL + 1))
fi
if grep -qF "Trimmed to fit the gitlab comment limit" "$sess/comment-body.md"; then
	echo "  PASS: the disclosure names the forge"
	PASS=$((PASS + 1))
else
	echo "  FAIL: a pared GitLab body did not disclose"
	FAIL=$((FAIL + 1))
fi
gl_msg=$(echo "$result" | jq -r '.message')
if [[ "$gl_msg" == *"Trimmed to fit the note limit"* && "$gl_msg" == *"$sess/report.md"* ]]; then
	echo "  PASS: the status envelope reports the trim and names the full report"
	PASS=$((PASS + 1))
else
	echo "  FAIL: the status envelope does not report the trim: ${gl_msg}"
	FAIL=$((FAIL + 1))
fi
rm -rf "$sess"

echo "Test 38: refuses cleanly on every malformed invocation"
sess=$(mktemp -d)
make_gl_session "$sess"
result=$(bash "$SCRIPT" "$sess" --bogus 2>/dev/null)
assert_json_field "$result" "status" "skip" "an unknown flag is a skip"
if echo "$result" | jq -r '.message' | grep -qF -- "--bogus"; then
	echo "  PASS: the offending flag is named"
	PASS=$((PASS + 1))
else
	echo "  FAIL: the message does not say which flag"
	FAIL=$((FAIL + 1))
fi
rm -rf "$sess"
result=$(bash "$SCRIPT" "/nonexistent/session/$$" 2>/dev/null)
assert_json_field "$result" "status" "skip" "a missing session directory is a skip"
result=$(bash "$SCRIPT" 2>/dev/null)
assert_json_field "$result" "status" "skip" "no arguments at all is a skip"
sess=$(mktemp -d)
make_gl_session "$sess"
rm -f "$sess/tracking.md"
result=$(bash "$SCRIPT" "$sess" 2>/dev/null)
assert_json_field "$result" "status" "skip" "a session with no tracking.md is a skip"
rm -rf "$sess"
sess=$(mktemp -d)
make_gl_session "$sess"
printf '# Review Council Session Tracking\n\n- Forge: gitlab\n- PR: none\n' >"$sess/tracking.md"
result=$(bash "$SCRIPT" "$sess" 2>/dev/null)
assert_json_field "$result" "status" "skip" "no merge request is a skip"
if [[ ! -f "$sess/comment-body.md" ]]; then
	echo "  PASS: nothing rendered when there is nowhere to post it"
	PASS=$((PASS + 1))
else
	echo "  FAIL: rendered a body for a session with no merge request"
	FAIL=$((FAIL + 1))
fi
rm -rf "$sess"

echo "Test 39: an oversized verdict chains, and a dry-run says how many notes"
sess=$(mktemp -d)
make_chained_gl_session "$sess"
result=$(bash "$SCRIPT" "$sess" 2>/dev/null)
assert_json_field "$result" "parts" "3" "split across three notes"
assert_json_field "$result" "pare_level" "0" "chained rather than pared"
n_files=$(echo "$result" | jq -r '.part_files | length')
assert_equals "$n_files" "3" "every part file is reported"
if echo "$result" | jq -r '.message' | grep -qF "in 3 parts"; then
	echo "  PASS: the message says there is more than one note"
	PASS=$((PASS + 1))
else
	echo "  FAIL: a chained render read as a single body"
	FAIL=$((FAIL + 1))
fi
rm -rf "$sess"

echo "Test D1: the poster refuses a re-review that skipped Disposition (RC-075)"
sess=$(mktemp -d)
st=$(mktemp -d)
make_gl_session "$sess"
make_glab "$st"
printf 'reply\n' >"$sess/pr-conversation.txt"
result=$(post "$sess" "$st")
assert_json_field "$result" "status" "error" "status is error"
no_writes "$st" "nothing written to the merge request"
rm -rf "$sess" "$st"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
