#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$SCRIPT_DIR/../skills/review-council/scripts/rc-clone-target.sh"
# shellcheck source=module/tests/helpers.sh
source "$SCRIPT_DIR/helpers.sh"

# Build a temp bin dir with mock git/gh, prepended to PATH per-test.
make_mockbin() {
	local dir="$1" mode="$2" branch="$3" remote="${4:-https://github.com/acme/widgets.git}"
	mkdir -p "$dir"
	cat >"$dir/git" <<MOCKGIT
#!/usr/bin/env bash
# mode=$mode drives behavior; log invocations for assertions.
echo "git \$*" >>"$dir/git.log"
# The network calls also record the prompt-control environment they ran with.
case " \$* " in
*" clone "* | *" fetch "*)
	echo "GIT_TERMINAL_PROMPT=\${GIT_TERMINAL_PROMPT-unset} GCM_INTERACTIVE=\${GCM_INTERACTIVE-unset} GIT_ASKPASS=\${GIT_ASKPASS-unset} SSH_ASKPASS=\${SSH_ASKPASS-unset}" >>"$dir/env.log"
	;;
esac
# Detect the subcommand among args, not in "\$1": the real calls are
# \`git -C DEST fetch\` / \`git -C DEST checkout\`, so "\$1" is -C.
if [[ "$mode" == "checkoutfail" ]] && printf '%s\n' "\$@" | grep -qx 'checkout'; then exit 1; fi
if [[ "$mode" == "fetchfail" ]] && printf '%s\n' "\$@" | grep -qx 'fetch'; then exit 1; fi
case "\$1" in
	remote) echo "$remote" ;;
	rev-parse)
		if [[ "\$2" == "--abbrev-ref" ]]; then echo "$branch"; else echo "deadbeef"; fi ;;
	clone)
		if [[ "$mode" == "partialfail" ]] && printf '%s\n' "\$@" | grep -q 'blob:none'; then
			exit 1
		fi
		# Create the destination dir (last non-flag arg).
		for a in "\$@"; do dest="\$a"; done
		mkdir -p "\$dest/.git" ;;
	fetch) : ;;
	checkout) : ;;
	*) : ;;
esac
exit 0
MOCKGIT
	chmod +x "$dir/git"
	# A gh that always fails. Without one the script finds the machine's real
	# gh on PATH and runs `gh repo clone` against the network; failing keeps
	# these cases on the git-clone fallback they assert. Cases that exercise gh
	# write their own over it.
	printf '#!/usr/bin/env bash\necho "gh \$*" >>"%s/gh.log"\nexit 1\n' "$dir" >"$dir/gh"
	chmod +x "$dir/gh"
}

# Test 1: already in the target repo on the PR branch -> in_place
echo "Test 1: in-place detection"
bin=$(mktemp -d)
make_mockbin "$bin" ok "feature-x"
result=$(PATH="$bin:$PATH" bash "$SCRIPT" --forge github --owner acme --repo widgets --pr 7 --head feature-x 2>/dev/null)
assert_json_field "$result" "status" "in_place" "status is in_place"
assert_json_field "$result" "review_root" "." "review_root is ."
rm -rf "$bin"

# Test 2: different branch -> materialize into cache, review_root = dest
echo "Test 2: materialize into cache"
bin=$(mktemp -d)
make_mockbin "$bin" ok "main"
cache=$(mktemp -d)
result=$(PATH="$bin:$PATH" XDG_CACHE_HOME="$cache" bash "$SCRIPT" \
	--forge github --owner acme --repo widgets --pr 7 --head feature-x 2>/dev/null)
assert_json_field "$result" "status" "ok" "status is ok"
root=$(echo "$result" | jq -r '.review_root')
if [[ "$root" == "$cache/review-council/clones/github.com-acme-widgets" ]]; then
	echo "  PASS: review_root points at cache clone"
	PASS=$((PASS + 1))
else
	echo "  FAIL: got '$root'"
	FAIL=$((FAIL + 1))
fi
if grep -q 'blob:none' "$bin/git.log"; then
	echo "  PASS: attempted blobless partial clone"
	PASS=$((PASS + 1))
else
	echo "  FAIL: no partial clone attempted"
	FAIL=$((FAIL + 1))
fi
if grep -q 'pull/7/head' "$bin/git.log"; then
	echo "  PASS: fetched PR head ref"
	PASS=$((PASS + 1))
else
	echo "  FAIL: PR head not fetched"
	FAIL=$((FAIL + 1))
fi
rm -rf "$bin" "$cache"

# Test 3: partial clone fails -> shallow fallback
echo "Test 3: shallow fallback"
bin=$(mktemp -d)
make_mockbin "$bin" partialfail "main"
cache=$(mktemp -d)
result=$(PATH="$bin:$PATH" XDG_CACHE_HOME="$cache" bash "$SCRIPT" \
	--forge github --owner acme --repo widgets --pr 7 --head feature-x 2>/dev/null)
assert_json_field "$result" "status" "ok" "status is ok after fallback"
if grep -q 'depth 50' "$bin/git.log"; then
	echo "  PASS: shallow fallback used"
	PASS=$((PASS + 1))
else
	echo "  FAIL: no shallow fallback"
	FAIL=$((FAIL + 1))
fi
rm -rf "$bin" "$cache"

# Test 4: a forge with no clone support -> skip (generic fallback), review_root = .
echo "Test 4: unsupported forge skip"
bin=$(mktemp -d)
make_mockbin "$bin" ok "main"
result=$(PATH="$bin:$PATH" bash "$SCRIPT" --forge bitbucket --owner acme --repo widgets --pr 7 --head feature-x 2>/dev/null)
assert_json_field "$result" "status" "skip" "status is skip"
assert_json_field "$result" "review_root" "." "review_root stays ."
rm -rf "$bin"

# Test 5: LRU prune keeps newest N, removes older clones
echo "Test 5: LRU prune"
bin=$(mktemp -d)
make_mockbin "$bin" ok "main"
cache=$(mktemp -d)
clones="$cache/review-council/clones"
mkdir -p "$clones"
# Seed 3 stale clones older than the new one; cap = 2.
# POSIX `-t CCYYMMDDhhmm` rather than `-d`: BSD touch rejects free-form dates.
for n in old1 old2 old3; do
	mkdir -p "$clones/$n"
	touch -t 202001010000 "$clones/$n"
done
PATH="$bin:$PATH" XDG_CACHE_HOME="$cache" REVIEW_COUNCIL_CLONE_CACHE_MAX=2 \
	bash "$SCRIPT" --forge github --owner acme --repo widgets --pr 7 --head feature-x >/dev/null 2>&1
remaining=$(find "$clones" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
if [[ "$remaining" -eq 2 ]]; then
	echo "  PASS: cache pruned to cap (2)"
	PASS=$((PASS + 1))
else
	echo "  FAIL: expected 2 clones, got $remaining"
	FAIL=$((FAIL + 1))
fi
if [[ -d "$clones/github.com-acme-widgets" ]]; then
	echo "  PASS: fresh clone retained"
	PASS=$((PASS + 1))
else
	echo "  FAIL: fresh clone was pruned"
	FAIL=$((FAIL + 1))
fi
rm -rf "$bin" "$cache"

# Test 5b: the cache cap is read as base 10, and junk falls back to the default
echo "Test 5b: REVIEW_COUNCIL_CLONE_CACHE_MAX parsing"
for case in "08:8" "abc:10"; do
	cap_value="${case%%:*}" want="${case##*:}"
	bin=$(mktemp -d)
	make_mockbin "$bin" ok "main"
	cache=$(mktemp -d)
	clones="$cache/review-council/clones"
	mkdir -p "$clones"
	for n in $(seq 1 12); do
		mkdir -p "$clones/old$n"
		touch -t 202001010000 "$clones/old$n"
	done
	PATH="$bin:$PATH" XDG_CACHE_HOME="$cache" REVIEW_COUNCIL_CLONE_CACHE_MAX="$cap_value" \
		bash "$SCRIPT" --forge github --owner acme --repo widgets --pr 7 --head feature-x >/dev/null 2>&1
	remaining=$(find "$clones" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
	assert_equals "$remaining" "$want" "cap '$cap_value' keeps $want entries"
	rm -rf "$bin" "$cache"
done

# Test 6: checkout of the PR head fails -> skip (no false-clean empty tree)
echo "Test 6: checkout failure falls back to skip"
bin=$(mktemp -d)
make_mockbin "$bin" checkoutfail "main"
cache=$(mktemp -d)
result=$(PATH="$bin:$PATH" XDG_CACHE_HOME="$cache" bash "$SCRIPT" \
	--forge github --owner acme --repo widgets --pr 7 --head feature-x 2>/dev/null)
assert_json_field "$result" "status" "skip" "status is skip on checkout failure"
assert_json_field "$result" "review_root" "." "review_root falls back to ."
rm -rf "$bin" "$cache"

# Test 6b: fetch of the PR head fails -> skip (no false-clean empty tree)
# The clone succeeds here, so status/review_root alone cannot tell this branch
# apart from the clone- and checkout-failure fallbacks — assert the message.
echo "Test 6b: fetch failure falls back to skip"
bin=$(mktemp -d)
make_mockbin "$bin" fetchfail "main"
cache=$(mktemp -d)
result=$(PATH="$bin:$PATH" XDG_CACHE_HOME="$cache" bash "$SCRIPT" \
	--forge github --owner acme --repo widgets --pr 7 --head feature-x 2>/dev/null)
assert_json_field "$result" "status" "skip" "status is skip on fetch failure"
assert_json_field "$result" "review_root" "." "review_root falls back to ."
assert_json_field "$result" "message" \
	"Fetch of pull/7/head failed; reviewing from diff only." \
	"message names the failed fetch"
rm -rf "$bin" "$cache"

# Test 7: malformed identifiers are rejected before any git runs
# owner/repo are forge-derived and interpolate into both the constructed clone
# URL and the cache directory path
# (`${cache_root}/${host_slug}-${owner}-${repo}`), so the character gate has to
# reject them up front — a clone that merely happens to fail afterwards is not
# the same guarantee.
echo "Test 7: owner/repo/pr character gate"
while IFS='|' read -r label bad_owner bad_repo bad_pr; do
	bin=$(mktemp -d)
	make_mockbin "$bin" ok "main"
	cache=$(mktemp -d)
	result=$(PATH="$bin:$PATH" XDG_CACHE_HOME="$cache" bash "$SCRIPT" \
		--forge github --owner "$bad_owner" --repo "$bad_repo" --pr "$bad_pr" --head feature-x 2>/dev/null)
	assert_json_field "$result" "status" "skip" "$label: status is skip"
	assert_json_field "$result" "review_root" "." "$label: review_root stays ."
	if [[ -s "$bin/git.log" ]]; then
		invocations=$(tr '\n' ' ' <"$bin/git.log")
		echo "  FAIL: $label: git was invoked ($invocations)"
		FAIL=$((FAIL + 1))
	else
		echo "  PASS: $label: git was never invoked"
		PASS=$((PASS + 1))
	fi
	rm -rf "$bin" "$cache"
done <<'GATECASES'
owner traversal|../evil|widgets|7
owner with space|acme widgets|widgets|7
owner metacharacter|acme; rm -rf /|widgets|7
repo traversal|acme|../evil|7
repo metacharacter|acme|widgets$(id)|7
non-numeric pr|acme|widgets|abc
pr metacharacter|acme|widgets|7; rm -rf /
GATECASES

# Emit a gh mock into <dir> that records its invocation and fails, so the git
# clone path stays exercised while a test can still assert whether gh was
# reached at all. `gh repo clone OWNER/REPO` resolves against gh's own default
# host, so reaching it is itself a wrong-host outcome off github.com.
make_gh_mock() {
	local dir="$1"
	cat >"$dir/gh" <<GHMOCK
#!/usr/bin/env bash
echo "gh \$*" >>"$dir/gh.log"
exit 1
GHMOCK
	chmod +x "$dir/gh"
}

# Test 8: an origin on a foreign host never diverts the review
# owner/repo alone is a name collision — a mirror, or a host an attacker
# controls, serves acme/widgets just as happily. Under URL scope the checkout
# we happen to be standing in has nothing to do with the PR being reviewed, so
# neither the in-place fast path nor the clone URL may follow it: findings are
# evidence-verified against whatever review_root names, so following a foreign
# origin verifies foreign file content as if it were the PR.
echo "Test 8: foreign origin host"
for tc_branch in feature-x main; do
	bin=$(mktemp -d)
	make_mockbin "$bin" ok "$tc_branch" "https://evil.attacker.test/acme/widgets.git"
	make_gh_mock "$bin"
	cache=$(mktemp -d)
	result=$(PATH="$bin:$PATH" XDG_CACHE_HOME="$cache" bash "$SCRIPT" \
		--forge github --owner acme --repo widgets --pr 7 --head feature-x 2>/dev/null)
	status=$(echo "$result" | jq -r '.status // empty')
	root=$(echo "$result" | jq -r '.review_root // empty')
	if [[ "$status" == "in_place" || "$root" == "." ]]; then
		echo "  FAIL: branch=$tc_branch: reused a foreign-host working tree (status '$status', review_root '$root')"
		FAIL=$((FAIL + 1))
	else
		echo "  PASS: branch=$tc_branch: did not review the foreign-host working tree"
		PASS=$((PASS + 1))
	fi
	# gh is only ever handed OWNER/REPO, so it cannot reach the foreign host;
	# git is the only way there.
	if grep -qF 'evil.attacker.test' "$bin/git.log"; then
		echo "  FAIL: branch=$tc_branch: cloned from the foreign host"
		FAIL=$((FAIL + 1))
	else
		echo "  PASS: branch=$tc_branch: never contacted the foreign host"
		PASS=$((PASS + 1))
	fi
	if grep -qF 'https://github.com/acme/widgets.git' "$bin/git.log" || grep -qF 'repo clone' "$bin/gh.log" 2>/dev/null; then
		echo "  PASS: branch=$tc_branch: fell back to the host --forge github implies"
		PASS=$((PASS + 1))
	else
		echo "  FAIL: branch=$tc_branch: no clone attempted against github.com"
		FAIL=$((FAIL + 1))
	fi
	rm -rf "$bin" "$cache"
done

# Test 9: --url names the target host, and the origin is trusted against it
# An enterprise target is reachable by naming it, not by guessing it from the
# origin. With the two in agreement the working tree is the target, so the
# in-place path must fire on a host that is not github.com.
echo "Test 9: enterprise target named by --url"
for tc_branch in main feature-x; do
	bin=$(mktemp -d)
	make_mockbin "$bin" ok "$tc_branch" "https://github.example.com/acme/widgets.git"
	make_gh_mock "$bin"
	cache=$(mktemp -d)
	result=$(PATH="$bin:$PATH" XDG_CACHE_HOME="$cache" bash "$SCRIPT" \
		--forge github --owner acme --repo widgets --pr 7 --head feature-x \
		--url https://github.example.com/acme/widgets.git 2>/dev/null)
	if [[ "$tc_branch" == "feature-x" ]]; then
		assert_json_field "$result" "status" "in_place" "at the PR head: status is in_place"
		assert_json_field "$result" "review_root" "." "at the PR head: review_root is ."
	else
		assert_json_field "$result" "status" "ok" "off the PR head: status is ok"
		if grep -qF 'https://github.example.com/acme/widgets.git' "$bin/git.log"; then
			echo "  PASS: off the PR head: cloned the enterprise host"
			PASS=$((PASS + 1))
		else
			echo "  FAIL: off the PR head: enterprise host not cloned"
			FAIL=$((FAIL + 1))
		fi
	fi
	# A gh clone counts as a github.com resolution whatever the caller asked
	# for: gh resolves OWNER/REPO against its own default host.
	if grep -qF 'https://github.com/' "$bin/git.log" || grep -qF 'repo clone' "$bin/gh.log" 2>/dev/null; then
		echo "  FAIL: branch=$tc_branch: resolved against github.com"
		FAIL=$((FAIL + 1))
	else
		echo "  PASS: branch=$tc_branch: never resolved against github.com"
		PASS=$((PASS + 1))
	fi
	rm -rf "$bin" "$cache"
done

# Test 10: an explicit --url outranks the host derived from the origin
echo "Test 10: --url override"
bin=$(mktemp -d)
make_mockbin "$bin" ok "main"
cat >"$bin/gh" <<GHMOCK
#!/usr/bin/env bash
echo "gh \$*" >>"$bin/gh.log"
exit 1
GHMOCK
chmod +x "$bin/gh"
cache=$(mktemp -d)
result=$(PATH="$bin:$PATH" XDG_CACHE_HOME="$cache" bash "$SCRIPT" \
	--forge github --owner acme --repo widgets --pr 7 --head feature-x \
	--url https://git.corp.example/acme/widgets.git 2>/dev/null)
assert_json_field "$result" "status" "ok" "status is ok"
if grep -qF 'https://git.corp.example/acme/widgets.git' "$bin/git.log"; then
	echo "  PASS: cloned the supplied URL"
	PASS=$((PASS + 1))
else
	echo "  FAIL: supplied URL not used"
	FAIL=$((FAIL + 1))
fi
if [[ -f "$bin/gh.log" ]] && grep -qF 'repo clone' "$bin/gh.log"; then
	echo "  FAIL: gh clone reached for a non-github.com URL"
	FAIL=$((FAIL + 1))
else
	echo "  PASS: gh clone not reached for a non-github.com URL"
	PASS=$((PASS + 1))
fi
rm -rf "$bin" "$cache"

# Test 11: a port makes the endpoint a different endpoint
# `--url https://host:8443/acme/widgets.git` and an origin on the same hostname
# without the port are two different services, and the one we are standing in
# is not the one the caller named. A parse that drops the port makes them
# compare equal and the in-place path then hands back the local working tree as
# though it were the PR — the same-name/different-endpoint confusion the host
# check exists to prevent, arriving through the port instead of the hostname.
echo "Test 11: a ported --url never matches a portless origin"
for tc_url in https://github.com:8443/acme/widgets.git https://ghe.corp.net:8443/acme/widgets.git; do
	bin=$(mktemp -d)
	make_mockbin "$bin" ok "feature-x" "${tc_url/:8443/}"
	make_gh_mock "$bin"
	cache=$(mktemp -d)
	result=$(PATH="$bin:$PATH" XDG_CACHE_HOME="$cache" bash "$SCRIPT" \
		--forge github --owner acme --repo widgets --pr 7 --head feature-x \
		--url "$tc_url" 2>/dev/null)
	status=$(echo "$result" | jq -r '.status // empty')
	if [[ "$status" == "in_place" ]]; then
		echo "  FAIL: $tc_url: reused the working tree of a different endpoint"
		FAIL=$((FAIL + 1))
	else
		echo "  PASS: $tc_url: did not reuse the working tree of a different endpoint"
		PASS=$((PASS + 1))
	fi
	if grep -qF "$tc_url" "$bin/git.log"; then
		echo "  PASS: $tc_url: cloned the endpoint the caller named"
		PASS=$((PASS + 1))
	else
		echo "  FAIL: $tc_url: did not clone the endpoint the caller named"
		FAIL=$((FAIL + 1))
	fi
	# gh resolves OWNER/REPO against its own default host on port 443, so
	# reaching it is a wrong-endpoint resolution however the hostname reads.
	if [[ -f "$bin/gh.log" ]] && grep -qF 'repo clone' "$bin/gh.log"; then
		echo "  FAIL: $tc_url: resolved a ported URL through gh"
		FAIL=$((FAIL + 1))
	else
		echo "  PASS: $tc_url: never resolved a ported URL through gh"
		PASS=$((PASS + 1))
	fi
	rm -rf "$bin" "$cache"
done

# Test 12: a cache entry belongs to one endpoint, not to an owner/repo pair
# `git fetch origin pull/N/head` runs against whatever origin the reused
# checkout carries, so serving one host's acme/widgets back for another host's
# acme/widgets grounds every finding in a foreign repository while the run
# still reports `ok` — the in_place host test's failure mode, one layer down in
# the clone cache. The ported pair is the same claim for the endpoints
# parse_remote refuses to name: they arrive with no host at all, and filing
# them under one key would restore the collision for exactly those callers.
echo "Test 12: cache entries are per target endpoint"
while IFS='|' read -r label url_a url_b; do
	bin=$(mktemp -d)
	make_mockbin "$bin" ok "main"
	make_gh_mock "$bin"
	cache=$(mktemp -d)
	first=$(PATH="$bin:$PATH" XDG_CACHE_HOME="$cache" bash "$SCRIPT" \
		--forge github --owner acme --repo widgets --pr 7 --head feature-x \
		--url "$url_a" 2>/dev/null)
	assert_json_field "$first" "status" "ok" "$label: first endpoint materialized"
	root_a=$(echo "$first" | jq -r '.review_root')
	# Only ever write inside the cache: a skip would hand back "." and the
	# marker would land in the working directory.
	if [[ "$root_a" == "$cache"/* && -d "$root_a" ]]; then
		echo first >"$root_a/FROM_FIRST_ENDPOINT"
	else
		echo "  FAIL: $label: first review_root is not a cache entry ('$root_a')"
		FAIL=$((FAIL + 1))
	fi
	second=$(PATH="$bin:$PATH" XDG_CACHE_HOME="$cache" bash "$SCRIPT" \
		--forge github --owner acme --repo widgets --pr 7 --head feature-x \
		--url "$url_b" 2>/dev/null)
	root_b=$(echo "$second" | jq -r '.review_root')
	if [[ "$root_b" != "$root_a" ]]; then
		echo "  PASS: $label: the two endpoints got separate cache entries"
		PASS=$((PASS + 1))
	else
		echo "  FAIL: $label: both endpoints shared '$root_b'"
		FAIL=$((FAIL + 1))
	fi
	if [[ -e "$root_b/FROM_FIRST_ENDPOINT" ]]; then
		echo "  FAIL: $label: reviewed the first endpoint's checkout"
		FAIL=$((FAIL + 1))
	else
		echo "  PASS: $label: did not reuse the first endpoint's checkout"
		PASS=$((PASS + 1))
	fi
	rm -rf "$bin" "$cache"
done <<'ENDPOINTPAIRS'
named hosts|https://github.example.com/acme/widgets.git|https://ghe.corp.example/acme/widgets.git
ported hosts|https://github.example.com:8443/acme/widgets.git|https://ghe.corp.example:8443/acme/widgets.git
ENDPOINTPAIRS
# A GitLab merge request is materialized from the repository archive glab
# fetches at the MR's head sha, not by git: an unauthenticated clone of a
# private project fails, and glab is the one client holding a credential bound
# to the host. The mock serves what <dir> holds — `hosts` (the hosts glab is
# logged in to, one per line), `mr.json` (the merge request), `archive.tgz`,
# `diffs.json` (the merge request's changed files; `[]` unless a test says
# otherwise) and `raw/<url-encoded path>` (one changed file's blob) — and
# records each call in glab.log and the credential environment it ran with in
# glab-env.log. A missing file makes that call fail.
make_glab_mock() { # dir
	local dir="$1"
	mkdir -p "$dir/raw"
	echo '[]' >"$dir/diffs.json"
	cat >"$dir/glab" <<GLABMOCK
#!/usr/bin/env bash
echo "glab \$*" >>"$dir/glab.log"
echo "GITLAB_TOKEN=\${GITLAB_TOKEN-unset} GITLAB_ACCESS_TOKEN=\${GITLAB_ACCESS_TOKEN-unset} OAUTH_TOKEN=\${OAUTH_TOKEN-unset} GITLAB_API_HOST=\${GITLAB_API_HOST-unset} GLAB_ENABLE_CI_AUTOLOGIN=\${GLAB_ENABLE_CI_AUTOLOGIN-unset}" >>"$dir/glab-env.log"
case "\$1 \$2" in
"auth status")
	[[ "\$3" == "--hostname" ]] && grep -qxF -- "\$4" "$dir/hosts" 2>/dev/null && exit 0
	# glab's own wording for a host missing from its config.
	echo "x \$4 has not been authenticated with glab" >&2
	exit 1
	;;
"api --hostname")
	path="\${*: -1}"
	case "\$path" in
	*/repository/archive.tar.gz\?sha=*) cat "$dir/archive.tgz" 2>/dev/null ;;
	*/merge_requests/*/diffs\?*) cat "$dir/diffs.json" 2>/dev/null ;;
	*/merge_requests/*) cat "$dir/mr.json" 2>/dev/null ;;
	*/repository/files/*/raw\?ref=*)
		enc="\${path#*/repository/files/}"
		cat "$dir/raw/\${enc%/raw\?ref=*}" 2>/dev/null
		;;
	*) exit 1 ;;
	esac
	;;
*) exit 1 ;;
esac
GLABMOCK
	chmod +x "$dir/glab"
}

# Build <out>, a gzipped tarball shaped like GitLab's repository archive: one
# top-level `<repo>-<sha>-<sha>/` directory holding sub/nested.txt (content
# <marker>) and `leak`, a symlink to /etc/passwd that a reviewer reading the
# tree would otherwise follow out of it.
make_archive() { # out sha marker
	local out="$1" sha="$2" marker="$3" src top
	src=$(mktemp -d)
	top="p-${sha}-${sha}"
	mkdir -p "$src/$top/sub"
	echo "$marker" >"$src/$top/sub/nested.txt"
	ln -s /etc/passwd "$src/$top/leak"
	tar -czf "$out" -C "$src" "$top"
	rm -rf "$src"
}

sha_a=1111111111111111111111111111111111111111
sha_b=2222222222222222222222222222222222222222

# The GitLab tests share one fixture: a merge request at sha_a whose archive is
# make_archive's. gl_fixture builds it into $bin/$cache/$clones; gl_run runs
# the script against it, with any VAR=value arguments in its environment;
# gl_cleanup removes it, read-only directories included. The cache entry for
# g/sub/p is $entry; each run's own tree is review_root, under $clones/.runs.
gl_fixture() {
	bin=$(mktemp -d)
	make_mockbin "$bin" ok "main" "https://gitlab.com/other/repo.git"
	make_glab_mock "$bin"
	make_archive "$bin/archive.tgz" "$sha_a" "head-a"
	echo "{\"sha\":\"$sha_a\"}" >"$bin/mr.json"
	cache=$(mktemp -d)
	clones="$cache/review-council/clones"
	entry="$clones/gitlab.com+g+sub+p"
}
gl_run() { # [VAR=value...]
	env PATH="$bin:$PATH" XDG_CACHE_HOME="$cache" "$@" bash "$SCRIPT" \
		--forge gitlab --owner g/sub --repo p --pr 7 --head feature-x 2>/dev/null
}
gl_cleanup() {
	chmod -R u+w "$bin" "$cache" 2>/dev/null || true
	rm -rf "$bin" "$cache"
}
# Assert <root> is a run tree of the g/sub/p entry: a directory directly under
# $clones/.runs, named for the entry.
assert_run_tree() { # root label
	if [[ -d "$1" && "$(dirname "$1")" == "$clones/.runs" && "$(basename "$1")" == "gitlab.com+g+sub+p."* ]]; then
		echo "  PASS: $2"
		PASS=$((PASS + 1))
	else
		echo "  FAIL: $2 ('$1' is not a run tree under '$clones/.runs')"
		FAIL=$((FAIL + 1))
	fi
}
# Assert the entry's contents, sorted and joined by spaces, equal <want>.
assert_entry_listing() { # want label
	local listing
	listing=$(find "$entry" -mindepth 1 -maxdepth 1 2>/dev/null | sed "s:^$entry/::" | LC_ALL=C sort | tr '\n' ' ' || true)
	assert_equals "$listing" "$1" "$2"
}

# Test 13: a GitLab merge request head is materialized from its archive
echo "Test 13: GitLab merge request materialized from an archive"
gl_fixture
result=$(gl_run)
assert_json_field "$result" "status" "ok" "status is ok"
root=$(echo "$result" | jq -r '.review_root')
assert_run_tree "$root" "review_root is this run's own tree"
assert_entry_listing "${sha_a}.tar.gz " "the cache entry holds the archive at the head sha, and only it"
assert_json_field "$result" "special_files_removed" "1" "the removed symlink is counted"
assert_json_field "$result" "message" \
	"Materialized g/sub/p at merge request 7 (${sha_a}) from its archive into a tree for this run, changed files fetched exactly; removed 1 link(s) or special file(s)." \
	"message names the merge request, its sha and the removed links"
nested=$(cat "$root/sub/nested.txt" 2>/dev/null || echo missing)
assert_equals "$nested" "head-a" "the nested file is read from the archive's top-level directory"
if [[ -e "$root/leak" || -L "$root/leak" ]]; then
	echo "  FAIL: the committed symlink survived extraction"
	FAIL=$((FAIL + 1))
else
	echo "  PASS: the committed symlink was removed"
	PASS=$((PASS + 1))
fi
lookups=$(grep -cF 'api --hostname gitlab.com projects/g%2Fsub%2Fp/merge_requests/7' "$bin/glab.log" || true)
assert_equals "$lookups" "1" \
	"the head sha was looked up on the merge request, project path encoded"
downloads=$(grep -cF "api --hostname gitlab.com projects/g%2Fsub%2Fp/repository/archive.tar.gz?sha=${sha_a}" "$bin/glab.log" || true)
assert_equals "$downloads" "1" \
	"the archive was fetched at that sha"
# gitlab.com is exempt from the configured-host gate: it is where an unbound
# token is issued.
assert_equals "$(grep -c 'auth status' "$bin/glab.log" || true)" "0" "gitlab.com is not asked about"
if [[ -s "$bin/git.log" ]] && grep -qE '(^| )(clone|fetch)( |$)' "$bin/git.log"; then
	echo "  FAIL: git cloned or fetched a GitLab target"
	FAIL=$((FAIL + 1))
else
	echo "  PASS: git never cloned or fetched a GitLab target"
	PASS=$((PASS + 1))
fi
leftovers=$(find "$clones" -mindepth 1 -maxdepth 1 -name '.archive.*' | wc -l | tr -d ' ')
assert_equals "$leftovers" "0" "no temporary download is left in the cache root"

# Test 13b: the cached archive is reused at its sha and replaced at a newer one
# Every run unpacks a tree of its own, so a second run never hands back (or
# writes into) the first run's.
echo "Test 13b: cached GitLab archive follows the head sha"
: >"$bin/glab.log"
first_root="$root"
result=$(gl_run)
root=$(echo "$result" | jq -r '.review_root')
assert_run_tree "$root" "same sha: a run tree"
if [[ "$root" != "$first_root" && -d "$first_root" ]]; then
	echo "  PASS: same sha: a fresh tree, the first run's left alone"
	PASS=$((PASS + 1))
else
	echo "  FAIL: same sha: '$root' reuses or removed the first run's '$first_root'"
	FAIL=$((FAIL + 1))
fi
assert_json_field "$result" "special_files_removed" "1" "same sha: this run's removals are counted"
assert_equals "$(grep -c 'archive.tar.gz' "$bin/glab.log" || true)" "0" "same sha: the archive is not fetched again"
make_archive "$bin/archive.tgz" "$sha_b" "head-b"
echo "{\"sha\":\"$sha_b\"}" >"$bin/mr.json"
result=$(gl_run)
root=$(echo "$result" | jq -r '.review_root')
nested=$(cat "$root/sub/nested.txt" 2>/dev/null || echo missing)
assert_equals "$nested" "head-b" "new sha: the tree holds the new head's content"
assert_entry_listing "${sha_b}.tar.gz " "new sha: the archive at the older sha is replaced"
gl_cleanup

# Test 13a: a head sha handed over by prepare is used without a lookup
# Prepare has already read the merge request; asking again costs a call and
# could see a different head. A malformed --head-sha is refused, not looked
# past.
echo "Test 13a: --head-sha skips the merge request lookup"
for tc_sha in "$sha_a" "1111" "--x" "${sha_a//1/A}"; do
	gl_fixture
	result=$(env PATH="$bin:$PATH" XDG_CACHE_HOME="$cache" bash "$SCRIPT" \
		--forge gitlab --owner g/sub --repo p --pr 7 --head feature-x --head-sha "$tc_sha" 2>/dev/null)
	if [[ "$tc_sha" == "$sha_a" ]]; then
		assert_entry_listing "${sha_a}.tar.gz " "valid --head-sha: the archive at that sha"
		lookups=$(grep -c 'merge_requests/7$' "$bin/glab.log" || true)
		assert_equals "$lookups" "0" "valid --head-sha: no merge request lookup"
	else
		assert_json_field "$result" "status" "skip" "--head-sha '$tc_sha': status is skip"
		assert_json_field "$result" "message" "--head-sha is not a 40-hex commit id; reviewing from diff only." \
			"--head-sha '$tc_sha': message names the bad sha"
		if [[ -e "$bin/glab.log" ]]; then
			echo "  FAIL: --head-sha '$tc_sha': glab was invoked"
			FAIL=$((FAIL + 1))
		else
			echo "  PASS: --head-sha '$tc_sha': glab was never invoked"
			PASS=$((PASS + 1))
		fi
	fi
	gl_cleanup
done

# Test 13c: an entry left by an earlier cache layout is replaced, not reused
echo "Test 13c: legacy GitLab cache entry replaced"
gl_fixture
mkdir -p "$entry/.git" "$entry/$sha_a/ro"
echo stale >"$entry/STALE"
chmod 555 "$entry/$sha_a/ro"
result=$(gl_run)
assert_json_field "$result" "status" "ok" "status is ok"
assert_entry_listing "${sha_a}.tar.gz " "only the archive is left in the entry"
gl_cleanup

# Test 13d: the LRU prune evicts whole entries, never a run's tree
# A concurrent run's hidden download directory is left alone until it is an
# hour old, and a run's tree until it is six hours old, when their runs are
# long over. Every removal copes with the read-only directories an archive can
# leave behind.
echo "Test 13d: LRU prune with a GitLab entry"
gl_fixture
for tc_dir in old1 .archive.abandoned .archive.inflight .runs/old-run .runs/recent-run \
	.runs/five-hour-run .runs/seven-hour-run; do
	mkdir -p "$clones/$tc_dir/ro"
	echo x >"$clones/$tc_dir/ro/file"
	chmod 555 "$clones/$tc_dir/ro"
done
touch -t 202001010000 "$clones/old1" "$clones/.archive.abandoned"
# Ages either side of the run trees' six-hour limit. GNU date reads
# `-d @<epoch>`, BSD date `-r <epoch>`.
stamp_ago() { # seconds
	local when=$(($(date +%s) - $1))
	date -d "@$when" +%Y%m%d%H%M 2>/dev/null || date -r "$when" +%Y%m%d%H%M
}
two_days_ago=$(stamp_ago $((2 * 86400)))
two_hours_ago=$(stamp_ago $((2 * 3600)))
touch -t "$two_days_ago" "$clones/.runs/old-run"
touch -t "$two_hours_ago" "$clones/.runs/recent-run"
five_hours_ago=$(stamp_ago $((5 * 3600)))
seven_hours_ago=$(stamp_ago $((7 * 3600)))
touch -t "$five_hours_ago" "$clones/.runs/five-hour-run"
touch -t "$seven_hours_ago" "$clones/.runs/seven-hour-run"
result=$(gl_run REVIEW_COUNCIL_CLONE_CACHE_MAX=1)
assert_json_field "$result" "status" "ok" "status is ok"
listing=$(find "$clones" -mindepth 1 -maxdepth 1 | sed "s:^$clones/::" | LC_ALL=C sort | tr '\n' ' ')
assert_equals "$listing" ".archive.inflight .runs gitlab.com+g+sub+p " \
	"the older entry and the abandoned download are evicted, the fresh entry and the in-flight download kept"
runs=$(find "$clones/.runs" -mindepth 1 -maxdepth 1 -name '*-run' | sed "s:^$clones/.runs/::" | LC_ALL=C sort | tr '\n' ' ')
assert_equals "$runs" "five-hour-run recent-run " "run trees past six hours are removed, younger ones kept"
root=$(echo "$result" | jq -r '.review_root')
if [[ -f "$root/sub/nested.txt" ]]; then
	echo "  PASS: this run's tree is intact"
	PASS=$((PASS + 1))
else
	echo "  FAIL: this run's tree was pruned"
	FAIL=$((FAIL + 1))
fi
gl_cleanup

# Test 13m: only the newest REVIEW_COUNCIL_MAX_RUN_TREES run trees are kept
# Age alone does not bound the disk: a batch leaves a tree per review inside
# six hours. The tree this run returns is never removed, even when its mtime
# reads as the oldest of all (a wrapper around the glab mock backdates it
# mid-run, when the last changed file is fetched into a subdirectory).
echo "Test 13m: run tree count bound"
for tc_case in current-newest current-oldest; do
	gl_fixture
	mkdir -p "$clones/.runs"
	for ((n = 1; n <= 5; n++)); do
		mkdir "$clones/.runs/t$n"
		tree_age=$(stamp_ago $((n * 600)))
		touch -t "$tree_age" "$clones/.runs/t$n"
	done
	want="t1 "
	if [[ "$tc_case" == "current-oldest" ]]; then
		echo '[{"new_path":"sub/hook.txt"}]' >"$bin/diffs.json"
		echo hook >"$bin/raw/sub%2Fhook.txt"
		mv "$bin/glab" "$bin/glab.mock"
		cat >"$bin/glab" <<GLABHOOK
#!/usr/bin/env bash
if [[ "\${*: -1}" == *"/raw?ref="* ]]; then
	for tree in "$clones"/.runs/gitlab.com+g+sub+p.*; do touch -t 202001010000 "\$tree"; done
fi
exec "$bin/glab.mock" "\$@"
GLABHOOK
		chmod +x "$bin/glab"
		want="t1 t2 "
	fi
	result=$(gl_run REVIEW_COUNCIL_MAX_RUN_TREES=2)
	assert_json_field "$result" "status" "ok" "$tc_case: status is ok"
	root=$(echo "$result" | jq -r '.review_root')
	if [[ -f "$root/sub/nested.txt" ]]; then
		echo "  PASS: $tc_case: this run's tree is kept"
		PASS=$((PASS + 1))
	else
		echo "  FAIL: $tc_case: this run's tree was removed"
		FAIL=$((FAIL + 1))
	fi
	others=$(find "$clones/.runs" -mindepth 1 -maxdepth 1 -name 't*' | sed "s:^$clones/.runs/::" | LC_ALL=C sort | tr '\n' ' ')
	assert_equals "$others" "$want" "$tc_case: only the newest trees within the cap of 2 are kept"
	gl_cleanup
done
# A cap that is not a plain integer falls back to the default of 8.
gl_fixture
mkdir -p "$clones/.runs"
for ((n = 1; n <= 9; n++)); do
	mkdir "$clones/.runs/t$n"
	tree_age=$(stamp_ago $((n * 600)))
	touch -t "$tree_age" "$clones/.runs/t$n"
done
gl_run REVIEW_COUNCIL_MAX_RUN_TREES=lots >/dev/null
kept=$(find "$clones/.runs" -mindepth 1 -maxdepth 1 -name 't*' | wc -l | tr -d ' ')
assert_equals "$kept" "7" "a non-integer cap keeps the default 8 trees, this run's among them"
gl_cleanup

# Test 13e: the files the merge request changes are fetched exactly
# GitLab builds the archive with `git archive`, which honours the commit's own
# .gitattributes: `export-ignore` drops a file and `export-subst` rewrites one.
# Both are the MR author's to set, so every changed file is fetched as its
# blob at the head sha and written over the archive's copy. Deleted files and
# submodule bumps are not files at the head and are not fetched. glab 1.102
# prints each page of a paginated listing as its own array.
echo "Test 13e: changed files fetched exactly"
gl_fixture
cat >"$bin/diffs.json" <<'DIFFS'
[{"new_path":"hidden.txt","new_file":true},{"new_path":"sub/nested.txt"},
 {"new_path":"gone.txt","deleted_file":true},{"new_path":"vendor/lib","b_mode":"160000"}]
[{"new_path":"page2/new file.txt","new_file":true}]
DIFFS
echo "hidden-exact" >"$bin/raw/hidden.txt"
echo "subst-exact" >"$bin/raw/sub%2Fnested.txt"
echo "second page" >"$bin/raw/page2%2Fnew%20file.txt"
result=$(gl_run)
assert_json_field "$result" "status" "ok" "status is ok"
root=$(echo "$result" | jq -r '.review_root')
for tc_pair in "hidden.txt|hidden-exact" "sub/nested.txt|subst-exact" "page2/new file.txt|second page"; do
	got=$(cat "$root/${tc_pair%%|*}" 2>/dev/null || echo missing)
	assert_equals "$got" "${tc_pair#*|}" "${tc_pair%%|*} holds its exact blob"
done
assert_equals "$(grep -c "raw?ref=${sha_a}\$" "$bin/glab.log" || true)" "3" "each changed file was fetched at the head sha"
if grep -qE 'files/(gone|vendor)' "$bin/glab.log"; then
	echo "  FAIL: a deleted file or a submodule was fetched"
	FAIL=$((FAIL + 1))
else
	echo "  PASS: deleted files and submodules are not fetched"
	PASS=$((PASS + 1))
fi
assert_equals "$(grep -c 'merge_requests/7/diffs?per_page=100$' "$bin/glab.log" || true)" "1" \
	"the changed files were listed once"
if grep -qF -- '--paginate' "$bin/glab.log"; then
	echo "  PASS: the listing is paginated"
	PASS=$((PASS + 1))
else
	echo "  FAIL: the listing is not paginated"
	FAIL=$((FAIL + 1))
fi
staged=$(find "$clones/.runs" -name '*.blob' | wc -l | tr -d ' ')
assert_equals "$staged" "0" "no staged blob is left beside the tree"
gl_cleanup

# Test 13l: every run fetches its own merge request's changed files
# Two merge requests can share a head sha — a second MR from the same source
# branch, or one retargeted. The second must not be handed the first's tree:
# a file only it changes, and which the archive leaves out, would be missing
# and its findings stripped.
echo "Test 13l: changed files are fetched on every run"
gl_fixture
echo '[{"new_path":"harmless.txt","new_file":true}]' >"$bin/diffs.json"
echo "harmless" >"$bin/raw/harmless.txt"
first=$(gl_run)
first_root=$(echo "$first" | jq -r '.review_root')
echo '[{"new_path":"evil.sh","new_file":true}]' >"$bin/diffs.json"
echo "rm -rf /" >"$bin/raw/evil.sh"
second=$(gl_run)
assert_json_field "$second" "status" "ok" "second run: status is ok"
second_root=$(echo "$second" | jq -r '.review_root')
evil=$(cat "$second_root/evil.sh" 2>/dev/null || echo missing)
assert_equals "$evil" "rm -rf /" "second run: its own changed file is in its tree"
for tc_pair in "$first_root/evil.sh|the first run's tree never gains the second's file" \
	"$second_root/harmless.txt|the second run's tree never holds the first's file"; do
	if [[ -e "${tc_pair%%|*}" ]]; then
		echo "  FAIL: ${tc_pair#*|}"
		FAIL=$((FAIL + 1))
	else
		echo "  PASS: ${tc_pair#*|}"
		PASS=$((PASS + 1))
	fi
done
assert_equals "$(grep -c 'archive.tar.gz' "$bin/glab.log" || true)" "1" "the archive itself is fetched once"
gl_cleanup

# Test 13f: a changed-file listing that cannot be trusted falls back to skip
# Never a partial tree: one bad path or one failed fetch refuses the lot, and
# the run's tree is removed. The validated archive stays cached.
echo "Test 13f: changed-file failures fall back to skip"
while IFS='|' read -r label tc_case want_msg; do
	gl_fixture
	tc_env=()
	case "$tc_case" in
	no-listing) rm "$bin/diffs.json" ;;
	not-array) echo '{"message":"404 Not found"}' >"$bin/diffs.json" ;;
	empty-listing) : >"$bin/diffs.json" ;;
	dotdot) echo '[{"new_path":"../evil"}]' >"$bin/diffs.json" ;;
	absolute) echo '[{"new_path":"/etc/passwd"}]' >"$bin/diffs.json" ;;
	newline) printf '%s\n' '[{"new_path":"a\nb"}]' >"$bin/diffs.json" ;;
	empty-segment) echo '[{"new_path":"a//b"}]' >"$bin/diffs.json" ;;
	not-string) echo '[{"new_path":null}]' >"$bin/diffs.json" ;;
	fetch-fails) echo '[{"new_path":"hidden.txt"}]' >"$bin/diffs.json" ;;
	under-a-file) echo '[{"new_path":"sub/nested.txt/x"}]' >"$bin/diffs.json" ;;
	over-a-dir) echo '[{"new_path":"sub"}]' >"$bin/diffs.json" ;;
	over-cap)
		echo '[{"new_path":"a.txt"},{"new_path":"b.txt"}]' >"$bin/diffs.json"
		echo a >"$bin/raw/a.txt"
		echo b >"$bin/raw/b.txt"
		tc_env=(REVIEW_COUNCIL_MAX_CHANGED_FILES=1)
		;;
	over-budget)
		# 7 bytes of archive content plus a 4-byte blob, against a cap of 10.
		echo '[{"new_path":"big.txt"}]' >"$bin/diffs.json"
		printf 'abcd' >"$bin/raw/big.txt"
		tc_env=(REVIEW_COUNCIL_ARCHIVE_MAX_UNPACKED_BYTES=10)
		;;
	over-budget-sum)
		# 7 bytes of archive content plus two 2-byte blobs, against 10.
		echo '[{"new_path":"one.txt"},{"new_path":"two.txt"}]' >"$bin/diffs.json"
		printf 'ab' >"$bin/raw/one.txt"
		printf 'cd' >"$bin/raw/two.txt"
		tc_env=(REVIEW_COUNCIL_ARCHIVE_MAX_UNPACKED_BYTES=10)
		;;
	*)
		echo "  FAIL: unknown changed-file case '$tc_case'"
		FAIL=$((FAIL + 1))
		;;
	esac
	echo x >"$bin/raw/sub%2Fnested.txt%2Fx"
	echo x >"$bin/raw/sub"
	result=$(gl_run "${tc_env[@]+"${tc_env[@]}"}")
	assert_json_field "$result" "status" "skip" "$label: status is skip"
	assert_json_field "$result" "review_root" "." "$label: review_root stays ."
	assert_json_field "$result" "message" "$want_msg" "$label: message names the failure"
	trees=$(find "$clones/.runs" -mindepth 1 2>/dev/null | wc -l | tr -d ' ')
	assert_equals "$trees" "0" "$label: no run tree or staged blob is left"
	gl_cleanup
done <<'CHANGEDCASES'
listing fails|no-listing|Listing the changed files of merge request 7 failed; reviewing from diff only.
listing is not an array|not-array|Listing the changed files of merge request 7 failed; reviewing from diff only.
listing is empty output|empty-listing|Listing the changed files of merge request 7 failed; reviewing from diff only.
path with a .. component|dotdot|Merge request 7 lists an unsafe changed path; refusing it and reviewing from diff only.
absolute path|absolute|Merge request 7 lists an unsafe changed path; refusing it and reviewing from diff only.
path holding a newline|newline|Merge request 7 lists an unsafe changed path; refusing it and reviewing from diff only.
path with an empty segment|empty-segment|Merge request 7 lists an unsafe changed path; refusing it and reviewing from diff only.
path that is not a string|not-string|Merge request 7 lists an unsafe changed path; refusing it and reviewing from diff only.
blob fetch fails|fetch-fails|Fetching changed file hidden.txt of merge request 7 failed; reviewing from diff only.
path under a regular file|under-a-file|Changed file sub/nested.txt/x of merge request 7 collides with the archive's tree; reviewing from diff only.
path that is a directory|over-a-dir|Changed file sub of merge request 7 collides with the archive's tree; reviewing from diff only.
more changed files than the cap|over-cap|Merge request 7 changes more than REVIEW_COUNCIL_MAX_CHANGED_FILES (1) files; reviewing from diff only.
two changed files past the unpacked cap together|over-budget-sum|The archive and changed files of merge request 7 unpack to more than REVIEW_COUNCIL_ARCHIVE_MAX_UNPACKED_BYTES (10 bytes); reviewing from diff only.
changed files past the unpacked cap|over-budget|The archive and changed files of merge request 7 unpack to more than REVIEW_COUNCIL_ARCHIVE_MAX_UNPACKED_BYTES (10 bytes); reviewing from diff only.
CHANGEDCASES

# A changed file that fits what is left of the unpacked cap is fetched.
gl_fixture
echo '[{"new_path":"fits.txt"}]' >"$bin/diffs.json"
printf 'abc' >"$bin/raw/fits.txt"
result=$(gl_run REVIEW_COUNCIL_ARCHIVE_MAX_UNPACKED_BYTES=10)
assert_json_field "$result" "status" "ok" "a changed file exactly at the unpacked cap is fetched"
gl_cleanup

# Test 13g: the archive is bounded before it is unpacked
# The fixture archive is a few hundred bytes, unpacks to 7 bytes of file
# content ("head-a\n") and lists 4 entries. A cap that is not a plain integer
# falls back to its default; a leading zero is decimal, not octal. A refused
# archive is never cached.
echo "Test 13g: archive size caps"
while IFS='|' read -r label tc_var tc_value want want_msg; do
	gl_fixture
	result=$(gl_run "${tc_var}=${tc_value}")
	assert_json_field "$result" "status" "$want" "$label: status is $want"
	if [[ "$want" == "skip" ]]; then
		assert_json_field "$result" "message" "$want_msg" "$label: message names the cap"
		written=$(find "$clones" -mindepth 1 2>/dev/null | wc -l | tr -d ' ')
		assert_equals "$written" "0" "$label: nothing is left in the cache"
	fi
	gl_cleanup
done <<'CAPCASES'
compressed size over the cap|REVIEW_COUNCIL_ARCHIVE_MAX_BYTES|10|skip|The archive of merge request 7 is larger than REVIEW_COUNCIL_ARCHIVE_MAX_BYTES (10 bytes); reviewing from diff only.
unpacked size over the cap|REVIEW_COUNCIL_ARCHIVE_MAX_UNPACKED_BYTES|6|skip|The archive of merge request 7 unpacks to more than REVIEW_COUNCIL_ARCHIVE_MAX_UNPACKED_BYTES (6 bytes); reviewing from diff only.
unpacked size at the cap|REVIEW_COUNCIL_ARCHIVE_MAX_UNPACKED_BYTES|7|ok|
leading zero is decimal|REVIEW_COUNCIL_ARCHIVE_MAX_UNPACKED_BYTES|08|ok|
entry count over the cap|REVIEW_COUNCIL_ARCHIVE_MAX_ENTRIES|3|skip|The archive of merge request 7 holds more than REVIEW_COUNCIL_ARCHIVE_MAX_ENTRIES (3) entries; reviewing from diff only.
entry count at the cap|REVIEW_COUNCIL_ARCHIVE_MAX_ENTRIES|4|ok|
non-integer cap|REVIEW_COUNCIL_ARCHIVE_MAX_BYTES|abc|ok|
negative cap|REVIEW_COUNCIL_ARCHIVE_MAX_UNPACKED_BYTES|-1|ok|
exponent cap|REVIEW_COUNCIL_ARCHIVE_MAX_ENTRIES|1e9|ok|
non-integer changed-file cap|REVIEW_COUNCIL_MAX_CHANGED_FILES|x|ok|
CAPCASES

# The member listing is streamed and stops at the cap: a moderate archive of
# 600 files against a cap of 100 is refused, and so is a `..` member that sits
# after many ordinary ones.
gl_fixture
src=$(mktemp -d)
top="p-${sha_a}-${sha_a}"
mkdir -p "$src/$top/many"
for ((n = 0; n < 600; n++)); do
	: >"$src/$top/many/f$n"
done
tar -czf "$bin/archive.tgz" -C "$src" "$top"
result=$(gl_run REVIEW_COUNCIL_ARCHIVE_MAX_ENTRIES=100)
assert_json_field "$result" "message" \
	"The archive of merge request 7 holds more than REVIEW_COUNCIL_ARCHIVE_MAX_ENTRIES (100) entries; reviewing from diff only." \
	"600 entries against a cap of 100 are refused"
mkdir -p "$src/w"
mv "$src/$top" "$src/w/$top"
echo evil >"$src/evil"
(cd "$src/w" && tar -czPf "$bin/archive.tgz" "$top" "$top/../../evil")
result=$(gl_run)
assert_json_field "$result" "message" \
	"The archive of merge request 7 names a path outside its tree; refusing it and reviewing from diff only." \
	"a .. member among ordinary ones is refused"
rm -rf "$src"
gl_cleanup

# A listing that fails partway is a failed read even when every member it got
# to was fine: tar stands in here for one that hits a corrupt tail after
# listing the members before it.
gl_fixture
real_tar=$(command -v tar)
cat >"$bin/tar" <<TARMOCK
#!/usr/bin/env bash
if [[ "\$1" == "-tzf" ]]; then "$real_tar" "\$@"; exit 2; fi
exec "$real_tar" "\$@"
TARMOCK
chmod +x "$bin/tar"
result=$(gl_run)
assert_json_field "$result" "message" \
	"The archive of merge request 7 could not be read; reviewing from diff only." \
	"a listing that fails after its members is refused"
gl_cleanup

# Test 13h: everything but regular files and directories is removed
# Links of every shape — to a directory, nested, dangling, named with a
# newline — and a FIFO, which would block the first reviewer to open it. Hard
# links go too: git cannot commit one, so a file with a second link came from
# the archive, and a tar that let one through could have aimed it anywhere.
echo "Test 13h: links and special files removed"
gl_fixture
src=$(mktemp -d)
top="p-${sha_a}-${sha_a}"
mkdir -p "$src/$top/sub/deep"
echo "head-a" >"$src/$top/sub/nested.txt"
ln -s /etc/passwd "$src/$top/leak"
ln -s /etc "$src/$top/dirlink"
ln -s ../nested.txt "$src/$top/sub/deep/link"
ln -s /nonexistent/target "$src/$top/dangle"
ln -s /etc/passwd "$src/$top/nl"$'\n'"link"
mkfifo "$src/$top/fifo"
echo pair >"$src/$top/pair-a"
ln "$src/$top/pair-a" "$src/$top/pair-b"
tar -czf "$bin/archive.tgz" -C "$src" "$top"
rm -rf "$src"
result=$(gl_run)
assert_json_field "$result" "status" "ok" "status is ok"
assert_json_field "$result" "special_files_removed" "8" "every link, the FIFO and both hard-linked names are counted"
root=$(echo "$result" | jq -r '.review_root')
left=$(find "$root" ! -type f ! -type d | wc -l | tr -d ' ')
assert_equals "$left" "0" "nothing but regular files and directories is left"
linked=$(find "$root" -type f -links +1 | wc -l | tr -d ' ')
assert_equals "$linked" "0" "no hard-linked file is left"
nested=$(cat "$root/sub/nested.txt" 2>/dev/null || echo missing)
assert_equals "$nested" "head-a" "regular files are kept"
gl_cleanup

# Test 13i: a hard link aimed out of the tree is never followed
# git cannot commit a hard link, so one in the archive is crafted. Each tar
# names its own way to rewrite a link target when creating the fixture.
echo "Test 13i: hard-link escape"
gl_fixture
outside=$(mktemp -d)
echo "SECRET" >"$outside/secret"
src=$(mktemp -d)
mkdir -p "$src/top"
echo inside >"$src/top/a"
ln "$src/top/a" "$src/top/hl"
escape="../../..${outside}/secret"
# The members are named, not found by walking top/: tar stores the body under
# whichever name it reads first and links the other to it, so a readdir that
# returns hl first stores no link at all.
if tar --version 2>/dev/null | grep -q 'GNU tar'; then
	tar -czPf "$bin/archive.tgz" -C "$src" --transform "s,^top/a\$,${escape},RSh" top/a top/hl
else
	tar -czPf "$src/mid.tgz" -C "$src" -s ",^top/a\$,${escape}," top/a top/hl
	tar -czPf "$bin/archive.tgz" --exclude "$escape" "@$src/mid.tgz"
fi
rm -rf "$src"
result=$(gl_run)
assert_json_field "$result" "status" "skip" "status is skip"
secret=$(cat "$outside/secret")
assert_equals "$secret" "SECRET" "the outside file is untouched"
leaked=$(grep -rlF SECRET "$cache" 2>/dev/null || true)
assert_equals "$leaked" "" "no cached file reads the outside file"
rm -rf "$outside"
gl_cleanup

# Test 13j: a cached archive is checked again on every run
# The checks are what make an archive safe to unpack, so one already in the
# cache gets them too; and a cache file that is not a plain file is fetched
# afresh rather than read through.
echo "Test 13j: cached archive re-validated"
gl_fixture
gl_run >/dev/null
src=$(mktemp -d)
mkdir -p "$src/w/top"
echo evil >"$src/evil"
(cd "$src/w" && tar -czPf "$entry/${sha_a}.tar.gz" top/../../evil)
rm -rf "$src"
result=$(gl_run)
assert_json_field "$result" "message" \
	"The archive of merge request 7 names a path outside its tree; refusing it and reviewing from diff only." \
	"a tampered cached archive is refused"
gl_cleanup
gl_fixture
gl_run >/dev/null
mv "$entry/${sha_a}.tar.gz" "$cache/elsewhere.tar.gz"
ln -s "$cache/elsewhere.tar.gz" "$entry/${sha_a}.tar.gz"
: >"$bin/glab.log"
result=$(gl_run)
assert_json_field "$result" "status" "ok" "a symlinked cache file: status is ok"
assert_equals "$(grep -c 'archive.tar.gz' "$bin/glab.log" || true)" "1" "a symlinked cache file is fetched afresh"
if [[ -L "$entry/${sha_a}.tar.gz" ]]; then
	echo "  FAIL: the symlinked cache file survived"
	FAIL=$((FAIL + 1))
else
	echo "  PASS: the symlinked cache file was replaced"
	PASS=$((PASS + 1))
fi
gl_cleanup

# Test 13k: a failed run's tree is removed even when read-only
# --no-same-permissions filters modes through the umask, which never adds
# write permission, so a directory archived 0555 extracts read-only and a
# plain `rm -rf` of the tree fails inside it.
echo "Test 13k: read-only directories do not pin a failed run's tree"
gl_fixture
src=$(mktemp -d)
top="p-${sha_a}-${sha_a}"
mkdir -p "$src/$top/ro"
echo locked >"$src/$top/ro/file"
chmod 555 "$src/$top/ro"
tar -czf "$bin/archive.tgz" -C "$src" "$top"
chmod -R u+w "$src"
rm -rf "$src"
echo '[{"new_path":"missing.txt"}]' >"$bin/diffs.json"
result=$(gl_run)
assert_json_field "$result" "status" "skip" "status is skip"
trees=$(find "$clones/.runs" -mindepth 1 2>/dev/null | wc -l | tr -d ' ')
assert_equals "$trees" "0" "the read-only run tree was removed"
gl_cleanup

# Test 14: every way the archive path can fail falls back to diff-only review
# Each leaves review_root "." and writes nothing into the cache entry: a
# half-built tree would be evidence-verified as though it were the merge
# request. The archive members are controlled by the merge request's author,
# so one naming an absolute path or a `..` component is refused before
# anything is extracted.
echo "Test 14: GitLab archive failures fall back to skip"
while IFS='|' read -r label tc_case want_msg; do
	bin=$(mktemp -d)
	make_mockbin "$bin" ok "main" "https://gitlab.com/other/repo.git"
	make_glab_mock "$bin"
	make_archive "$bin/archive.tgz" "$sha_a" "head-a"
	echo "{\"sha\":\"$sha_a\"}" >"$bin/mr.json"
	cache=$(mktemp -d)
	clones="$cache/review-council/clones"
	outside=$(mktemp -d)
	case "$tc_case" in
	mr-fails) rm "$bin/mr.json" ;;
	archive-fails) rm "$bin/archive.tgz" ;;
	short-sha) echo '{"sha":"1111111"}' >"$bin/mr.json" ;;
	upper-sha) echo "{\"sha\":\"${sha_a//1/A}\"}" >"$bin/mr.json" ;;
	option-sha) echo '{"sha":"--output=/tmp/x"}' >"$bin/mr.json" ;;
	no-sha) echo '{"title":"t"}' >"$bin/mr.json" ;;
	not-json) echo 'not json' >"$bin/mr.json" ;;
	not-archive) echo 'not an archive' >"$bin/archive.tgz" ;;
	empty-archive)
		mkdir -p "$outside/src/p-top"
		tar -czf "$bin/archive.tgz" -C "$outside/src" p-top
		;;
	dotdot-member)
		# `top/../../evil` survives --strip-components=1 as `../evil`: one
		# level above the tree, into the cache entry or beyond.
		mkdir -p "$outside/w/top"
		echo evil >"$outside/evil"
		(cd "$outside/w" && tar -czPf "$bin/archive.tgz" top/../../evil)
		rm "$outside/evil"
		;;
	absolute-member)
		echo evil >"$outside/abs-evil"
		tar -czPf "$bin/archive.tgz" "$outside/abs-evil"
		rm "$outside/abs-evil"
		;;
	*)
		echo "  FAIL: unknown archive case '$tc_case'"
		FAIL=$((FAIL + 1))
		;;
	esac
	result=$(PATH="$bin:$PATH" XDG_CACHE_HOME="$cache" bash "$SCRIPT" \
		--forge gitlab --owner g/sub --repo p --pr 7 --head feature-x 2>/dev/null)
	assert_json_field "$result" "status" "skip" "$label: status is skip"
	assert_json_field "$result" "review_root" "." "$label: review_root stays ."
	assert_json_field "$result" "message" "$want_msg" "$label: message names the failure"
	# No run tree or download survives a failure. Only an archive that passed
	# every check (the one with no files) may stay cached.
	written=$(find "$clones/.runs" "$clones" -mindepth 1 -maxdepth 1 \( -path "$clones/.runs/*" -o -name '.archive.*' \) 2>/dev/null || true)
	assert_equals "$written" "" "$label: no run tree or download is left"
	if [[ "$tc_case" != "empty-archive" && -e "$clones/gitlab.com+g+sub+p" ]]; then
		echo "  FAIL: $label: a refused archive was cached"
		FAIL=$((FAIL + 1))
	fi
	if [[ -e "$outside/evil" || -e "$outside/abs-evil" || -e "$cache/review-council/evil" || -e "$clones/evil" ]]; then
		echo "  FAIL: $label: an archive member was written outside the tree"
		FAIL=$((FAIL + 1))
	else
		echo "  PASS: $label: nothing was written outside the tree"
		PASS=$((PASS + 1))
	fi
	rm -rf "$bin" "$cache" "$outside"
done <<'ARCHIVECASES'
merge request lookup fails|mr-fails|Lookup of merge request 7 on gitlab.com failed; reviewing from diff only.
archive download fails|archive-fails|Download of the archive of merge request 7 failed; reviewing from diff only.
short sha|short-sha|Merge request 7 on gitlab.com reported no 40-hex head sha; reviewing from diff only.
uppercase sha|upper-sha|Merge request 7 on gitlab.com reported no 40-hex head sha; reviewing from diff only.
option-shaped sha|option-sha|Merge request 7 on gitlab.com reported no 40-hex head sha; reviewing from diff only.
no sha|no-sha|Merge request 7 on gitlab.com reported no 40-hex head sha; reviewing from diff only.
lookup is not JSON|not-json|Merge request 7 on gitlab.com reported no 40-hex head sha; reviewing from diff only.
not an archive|not-archive|The archive of merge request 7 could not be read; reviewing from diff only.
archive with no files|empty-archive|The archive of merge request 7 holds no files; reviewing from diff only.
member with a .. component|dotdot-member|The archive of merge request 7 names a path outside its tree; refusing it and reviewing from diff only.
absolute member|absolute-member|The archive of merge request 7 names a path outside its tree; refusing it and reviewing from diff only.
ARCHIVECASES

# Test 14b: a host glab is not logged in to is never sent a request
# The gate is lib/forge/gitlab.sh's: `glab auth status --hostname H` answers
# locally for an unconfigured H, so the only call made is that question.
echo "Test 14b: GitLab host gate"
bin=$(mktemp -d)
make_mockbin "$bin" ok "main" "https://gitlab.com/other/repo.git"
make_glab_mock "$bin"
make_archive "$bin/archive.tgz" "$sha_a" "head-a"
echo "{\"sha\":\"$sha_a\"}" >"$bin/mr.json"
echo "git.example.org" >"$bin/hosts"
cache=$(mktemp -d)
result=$(PATH="$bin:$PATH" XDG_CACHE_HOME="$cache" bash "$SCRIPT" \
	--forge gitlab --owner g/sub --repo p --pr 7 --head feature-x \
	--url https://evil.example.net/g/sub/p 2>/dev/null)
assert_json_field "$result" "status" "skip" "unconfigured host: status is skip"
assert_json_field "$result" "review_root" "." "unconfigured host: review_root stays ."
assert_json_field "$result" "message" \
	"glab is not logged in to evil.example.net; run 'glab auth login --hostname evil.example.net' first. Refusing to send GitLab credentials to a host glab is not configured for. Reviewing from diff only." \
	"unconfigured host: message carries the gate's refusal"
calls=$(tr '\n' ';' <"$bin/glab.log")
assert_equals "$calls" "glab auth status --hostname evil.example.net;" \
	"unconfigured host: only the gate's question was asked"
rm -rf "$bin" "$cache"

# A ported host cannot be addressed: glab takes a bare host name.
bin=$(mktemp -d)
make_mockbin "$bin" ok "main" "https://gitlab.com/other/repo.git"
make_glab_mock "$bin"
cache=$(mktemp -d)
result=$(PATH="$bin:$PATH" XDG_CACHE_HOME="$cache" bash "$SCRIPT" \
	--forge gitlab --owner g/sub --repo p --pr 7 --head feature-x \
	--url https://git.example.org:8443/g/sub/p 2>/dev/null)
assert_json_field "$result" "status" "skip" "ported host: status is skip"
assert_json_field "$result" "message" \
	"'https://git.example.org:8443/g/sub/p' names no GitLab host glab can address (a port is not supported); reviewing from diff only." \
	"ported host: message says why"
if [[ -e "$bin/glab.log" ]]; then
	echo "  FAIL: ported host: glab was invoked"
	FAIL=$((FAIL + 1))
else
	echo "  PASS: ported host: glab was never invoked"
	PASS=$((PASS + 1))
fi
rm -rf "$bin" "$cache"

# Test 14c: a credential bound to another host never reaches glab
# Every call goes through rc_forge_glab: GITLAB_API_HOST and CI autologin are
# always removed, and the environment tokens only travel to the host they are
# bound to (here GITLAB_API_HOST's, which is not the one addressed).
echo "Test 14c: GitLab calls carry only the addressed host's credentials"
bin=$(mktemp -d)
make_mockbin "$bin" ok "main" "https://gitlab.com/other/repo.git"
make_glab_mock "$bin"
make_archive "$bin/archive.tgz" "$sha_a" "head-a"
echo "{\"sha\":\"$sha_a\"}" >"$bin/mr.json"
echo "git.example.org" >"$bin/hosts"
cache=$(mktemp -d)
result=$(PATH="$bin:$PATH" XDG_CACHE_HOME="$cache" GITLAB_TOKEN=tok-a GITLAB_ACCESS_TOKEN=tok-b \
	OAUTH_TOKEN=tok-c GITLAB_API_HOST=other.example.com GLAB_ENABLE_CI_AUTOLOGIN=true bash "$SCRIPT" \
	--forge gitlab --owner g/sub --repo p --pr 7 --head feature-x \
	--url https://git.example.org/g/sub/p 2>/dev/null)
assert_json_field "$result" "status" "ok" "configured host: status is ok"
calls=$(wc -l <"$bin/glab-env.log")
assert_equals "${calls// /}" "4" "configured host: gate, lookup, download and changed-file listing each ran glab"
want_env="GITLAB_TOKEN=unset GITLAB_ACCESS_TOKEN=unset OAUTH_TOKEN=unset GITLAB_API_HOST=unset GLAB_ENABLE_CI_AUTOLOGIN=unset"
stray=$(grep -cvxF "$want_env" "$bin/glab-env.log" || true)
assert_equals "$stray" "0" "configured host: no foreign token, API host or CI autologin reached glab"
rm -rf "$bin" "$cache"

# Test 15: nested GitLab owners get one flat, unambiguous cache entry each
# `g/sub` must not become a nested directory under the cache root, and folding
# its `/` into the `-` that already joins the key would file group `g/sub`
# project `p` and group `g-sub` project `p` under one entry — the cross-project
# reuse Test 12 rules out between hosts.
echo "Test 15: nested GitLab owner cache key"
bin=$(mktemp -d)
make_mockbin "$bin" ok "main" "https://gitlab.com/other/repo.git"
make_gh_mock "$bin"
make_glab_mock "$bin"
make_archive "$bin/archive.tgz" "$sha_a" "head-a"
echo "{\"sha\":\"$sha_a\"}" >"$bin/mr.json"
cache=$(mktemp -d)
clones="$cache/review-council/clones"
roots=()
for tc_owner in g/sub g-sub; do
	result=$(PATH="$bin:$PATH" XDG_CACHE_HOME="$cache" bash "$SCRIPT" \
		--forge gitlab --owner "$tc_owner" --repo p --pr 7 --head feature-x 2>/dev/null)
	assert_json_field "$result" "status" "ok" "owner $tc_owner: status is ok"
	root=$(echo "$result" | jq -r '.review_root')
	roots+=("$root")
done
# Each project's archive is filed in an entry of its own, directly under the
# cache root; each run's tree is named for its entry.
for tc_entry in gitlab.com+g+sub+p gitlab.com+g-sub+p; do
	if [[ -f "$clones/$tc_entry/${sha_a}.tar.gz" ]]; then
		echo "  PASS: entry $tc_entry sits directly under the cache root"
		PASS=$((PASS + 1))
	else
		echo "  FAIL: no entry $tc_entry directly under '$clones'"
		FAIL=$((FAIL + 1))
	fi
done
nested_run="${roots[0]##*/}"
hyphen_run="${roots[1]##*/}"
assert_equals "${nested_run%.*}" "gitlab.com+g+sub+p" "nested owner's run tree is named for its entry"
assert_equals "${hyphen_run%.*}" "gitlab.com+g-sub+p" "hyphenated owner's run tree is named for its entry"
if grep -qF 'api --hostname gitlab.com projects/g%2Fsub%2Fp/repository/archive.tar.gz' "$bin/glab.log" &&
	grep -qF 'api --hostname gitlab.com projects/g-sub%2Fp/repository/archive.tar.gz' "$bin/glab.log"; then
	echo "  PASS: fetched each project's own archive from gitlab.com"
	PASS=$((PASS + 1))
else
	echo "  FAIL: a project's archive was not fetched by its own path"
	FAIL=$((FAIL + 1))
fi
if [[ -f "$bin/gh.log" ]] && grep -qF 'repo clone' "$bin/gh.log"; then
	echo "  FAIL: gh clone reached for a GitLab target"
	FAIL=$((FAIL + 1))
else
	echo "  PASS: gh clone never reached for a GitLab target"
	PASS=$((PASS + 1))
fi
rm -rf "$bin" "$cache"

# Test 16: every segment of a GitLab project path is gated before any call
# A nested owner passes the joined path into the API path; a `..` segment
# would resolve to a different project on the server, an empty one is no
# project at all, and a leading `-` is read as an option by anything that takes
# the path as an argument.
echo "Test 16: GitLab project path segment gate"
while IFS='|' read -r label bad_owner bad_repo; do
	bin=$(mktemp -d)
	make_mockbin "$bin" ok "main"
	make_glab_mock "$bin"
	cache=$(mktemp -d)
	result=$(PATH="$bin:$PATH" XDG_CACHE_HOME="$cache" bash "$SCRIPT" \
		--forge gitlab --owner "$bad_owner" --repo "$bad_repo" --pr 7 --head feature-x 2>/dev/null)
	assert_json_field "$result" "status" "skip" "$label: status is skip"
	assert_json_field "$result" "review_root" "." "$label: review_root stays ."
	if [[ -s "$bin/git.log" || -e "$bin/glab.log" ]]; then
		invocations=$(cat "$bin/git.log" "$bin/glab.log" 2>/dev/null | tr '\n' ' ')
		echo "  FAIL: $label: git or glab was invoked ($invocations)"
		FAIL=$((FAIL + 1))
	else
		echo "  PASS: $label: neither git nor glab was invoked"
		PASS=$((PASS + 1))
	fi
	rm -rf "$bin" "$cache"
done <<'GITLABGATECASES'
dot-dot segment|g/..|p
dot segment|g/.|p
empty segment|g//x|p
leading slash|/g|p
trailing slash|g/|p
hyphen-led owner|-g|p
hyphen-led subgroup|g/-s|p
empty owner||p
slash in repo|g|sub/p
dot-dot repo|g|..
hyphen-led repo|g|-p
metacharacter segment|g/s;id|p
GITLABGATECASES

# Test 17: in place on a nested GitLab project
# The origin's whole project path is the identity: parse_remote names no
# owner/repo pair for a three-segment path, so comparing those alone would
# never match a subgroup project — or, worse, match on two segments of it.
echo "Test 17: GitLab in-place detection"
while IFS='|' read -r label origin want; do
	bin=$(mktemp -d)
	make_mockbin "$bin" ok "feature-x" "$origin"
	make_glab_mock "$bin"
	make_archive "$bin/archive.tgz" "$sha_a" "head-a"
	echo "{\"sha\":\"$sha_a\"}" >"$bin/mr.json"
	echo "git.example.org" >"$bin/hosts"
	cache=$(mktemp -d)
	result=$(PATH="$bin:$PATH" XDG_CACHE_HOME="$cache" bash "$SCRIPT" \
		--forge gitlab --owner g/sub --repo p --pr 7 --head feature-x \
		--url https://git.example.org/g/sub/p 2>/dev/null)
	assert_json_field "$result" "status" "$want" "$label: status is $want"
	rm -rf "$bin" "$cache"
done <<'INPLACECASES'
https origin, same path|https://git.example.org/g/sub/p.git|in_place
ssh origin, same path|git@git.example.org:g/sub/p.git|in_place
case-folded origin|https://Git.Example.org/G/Sub/P.git|in_place
other host|https://gitlab.com/g/sub/p.git|ok
parent group project|https://git.example.org/g/sub.git|ok
deeper project|https://git.example.org/g/sub/p/q.git|ok
INPLACECASES

# Test 18: GitHub clone and fetch never wait on an interactive credential prompt
# A private host with no credential helper makes git ask for a username on the
# terminal, or through an askpass program, and the run then sits there until
# the 120s timeout. Each network call clears every prompting channel; a
# configured credential helper is untouched and still answers. GitLab runs no
# git at all (Test 13).
echo "Test 18: network calls run without credential prompts"
want_env="GIT_TERMINAL_PROMPT=0 GCM_INTERACTIVE=never GIT_ASKPASS= SSH_ASKPASS="
bin=$(mktemp -d)
make_mockbin "$bin" partialfail "main" "https://example.invalid/other/repo.git"
cat >"$bin/gh" <<GHMOCK
#!/usr/bin/env bash
echo "GIT_TERMINAL_PROMPT=\${GIT_TERMINAL_PROMPT-unset} GCM_INTERACTIVE=\${GCM_INTERACTIVE-unset} GIT_ASKPASS=\${GIT_ASKPASS-unset} SSH_ASKPASS=\${SSH_ASKPASS-unset}" >>"$bin/env.log"
exit 1
GHMOCK
chmod +x "$bin/gh"
cache=$(mktemp -d)
result=$(PATH="$bin:$PATH" XDG_CACHE_HOME="$cache" GIT_TERMINAL_PROMPT=1 GCM_INTERACTIVE=always \
	GIT_ASKPASS=/bin/false SSH_ASKPASS=/bin/false bash "$SCRIPT" \
	--forge github --owner acme --repo widgets --pr 7 --head feature-x 2>/dev/null)
assert_json_field "$result" "status" "ok" "status is ok"
# gh, the blobless clone, the shallow clone and the fetch.
want_calls=4
calls=$(wc -l <"$bin/env.log" | tr -d ' ')
assert_equals "$calls" "$want_calls" "every network call was recorded"
stray=$(grep -cvxF "$want_env" "$bin/env.log" || true)
assert_equals "$stray" "0" "every network call ran with prompts disabled"
rm -rf "$bin" "$cache"

# Test 19: --url must name the repository --owner/--repo name
# The URL decides where the clone comes from and the owner/repo decide which
# cache entry it lands in and what the messages claim was reviewed. If the two
# disagree, one project's checkout is filed and reported as another's. The
# path is compared case-insensitively with any `.git` dropped, as forges route.
echo "Test 19: --url must name --owner/--repo"
while IFS='|' read -r label tc_forge tc_owner tc_url want; do
	bin=$(mktemp -d)
	make_mockbin "$bin" ok "main" "https://example.invalid/other/repo.git"
	make_gh_mock "$bin"
	make_glab_mock "$bin"
	make_archive "$bin/archive.tgz" "$sha_a" "head-a"
	echo "{\"sha\":\"$sha_a\"}" >"$bin/mr.json"
	echo "git.example.org" >"$bin/hosts"
	cache=$(mktemp -d)
	result=$(PATH="$bin:$PATH" XDG_CACHE_HOME="$cache" bash "$SCRIPT" \
		--forge "$tc_forge" --owner "$tc_owner" --repo widgets --pr 7 --head feature-x \
		--url "$tc_url" 2>/dev/null)
	assert_json_field "$result" "status" "$want" "$label: status is $want"
	if [[ "$want" == "skip" ]]; then
		assert_json_field "$result" "review_root" "." "$label: review_root stays ."
		if [[ -s "$bin/git.log" || -e "$bin/glab.log" ]]; then
			invocations=$(cat "$bin/git.log" "$bin/glab.log" 2>/dev/null | tr '\n' ' ')
			echo "  FAIL: $label: git or glab was invoked ($invocations)"
			FAIL=$((FAIL + 1))
		else
			echo "  PASS: $label: neither git nor glab was invoked"
			PASS=$((PASS + 1))
		fi
	fi
	rm -rf "$bin" "$cache"
done <<'URLCASES'
other owner|github|acme|https://github.com/evil/widgets.git|skip
other repo|github|acme|https://github.com/acme/gadgets.git|skip
extra segment|github|acme|https://github.com/acme/widgets/extra.git|skip
host only|github|acme|https://github.com|skip
other subgroup|gitlab|g/sub|https://git.example.org/g/other/widgets|skip
parent namespace|gitlab|g/sub|https://git.example.org/g/widgets.git|skip
case and .git differ|github|acme|https://GitHub.com/ACME/Widgets.git|ok
no .git suffix|gitlab|g/sub|https://git.example.org/g/sub/widgets|ok
ported host|github|acme|https://ghe.example.com:8443/acme/widgets.git|ok
URLCASES

# Test 20: the clone URL can never be read as an option
# `--` ends git clone's options, so a URL starting with `-` is a URL.
echo "Test 20: clone URL follows --"
bin=$(mktemp -d)
make_mockbin "$bin" partialfail "main"
make_gh_mock "$bin"
cache=$(mktemp -d)
PATH="$bin:$PATH" XDG_CACHE_HOME="$cache" bash "$SCRIPT" \
	--forge github --owner acme --repo widgets --pr 7 --head feature-x >/dev/null 2>&1
for tc_flags in "--filter=blob:none --no-checkout" "--depth 50"; do
	if grep -qF "git clone ${tc_flags} -- https://github.com/acme/widgets.git" "$bin/git.log"; then
		echo "  PASS: clone ${tc_flags}: URL follows --"
		PASS=$((PASS + 1))
	else
		echo "  FAIL: clone ${tc_flags}: URL not preceded by --"
		FAIL=$((FAIL + 1))
	fi
done
rm -rf "$bin" "$cache"

# Test 21: git authenticates to github.com through gh, without user config
# `gh repo clone` hands gh's credential helper to the clone alone, so on a
# private repository the later fetch of pull/N/head — and the checkout, which
# in a blobless clone downloads the blobs it needs — had no credentials unless
# the operator had run `gh auth setup-git`. Every git call of the github.com
# path is given gh as a credential helper through GIT_CONFIG_COUNT, scoped to
# https://github.com and appended after any entries the caller set. The mock
# asks the real git which helper it resolves, so the assertion is git's own
# reading of that environment.
echo "Test 21: github.com git calls use gh as credential helper"
real_git=$(command -v git)
make_cred_mockbin() { # dir
	local dir="$1"
	cat >"$dir/git" <<MOCKGIT
#!/usr/bin/env bash
sub=""
for a in "\$@"; do
	case "\$a" in clone | fetch | checkout) sub="\$a"; break ;; esac
done
case "\$1" in
remote) echo "https://example.invalid/other/repo.git"; exit 0 ;;
rev-parse) echo "main"; exit 0 ;;
esac
[[ -n "\$sub" ]] || exit 0
helper=\$(GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null "$real_git" config --get-urlmatch credential.helper "https://github.com/acme/widgets.git" 2>/dev/null || echo none)
echo "\$sub helper=\$helper key0=\${GIT_CONFIG_KEY_0-unset} prompt=\${GIT_TERMINAL_PROMPT-unset}" >>"$dir/cred.log"
if [[ "\$sub" == clone ]]; then
	for a in "\$@"; do dest="\$a"; done
	mkdir -p "\$dest/.git"
fi
MOCKGIT
	chmod +x "$dir/git"
	printf '#!/usr/bin/env bash\nexit 1\n' >"$dir/gh"
	chmod +x "$dir/gh"
}
while IFS='|' read -r label tc_url tc_env want_helper want_key0; do
	bin=$(mktemp -d)
	make_cred_mockbin "$bin"
	cache=$(mktemp -d)
	url_args=()
	[[ -n "$tc_url" ]] && url_args=(--url "$tc_url")
	# shellcheck disable=SC2086 # tc_env is a list of VAR=value words
	result=$(env $tc_env PATH="$bin:$PATH" XDG_CACHE_HOME="$cache" bash "$SCRIPT" \
		--forge github --owner acme --repo widgets --pr 7 --head feature-x \
		"${url_args[@]}" 2>/dev/null)
	assert_json_field "$result" "status" "ok" "$label: status is ok"
	for sub in clone fetch checkout; do
		line=$(grep -m1 "^$sub " "$bin/cred.log" || echo "$sub missing")
		assert_equals "$line" "$sub helper=$want_helper key0=$want_key0 prompt=0" \
			"$label: $sub credential helper and prompt"
	done
	rm -rf "$bin" "$cache"
done <<'CREDCASES'
github.com||GIT_CONFIG_COUNT=0|!gh auth git-credential|credential.https://github.com.helper
caller entries kept|https://github.com/acme/widgets.git|GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.askPass GIT_CONFIG_VALUE_0=|!gh auth git-credential|core.askPass
other host|https://ghe.example.com/acme/widgets.git|GIT_CONFIG_COUNT=0|none|unset
CREDCASES

# Test 22: a cache with no per-run trees is not a failure
# Only GitLab makes trees under .runs, so a GitHub checkout routinely finds the
# directory missing, or emptied by an earlier prune. Listing it then matched
# nothing, and the error trap reported a failed command on stderr — which the
# agent reading this script's output takes for a real one.
echo "Test 22: no run trees means a clean stderr"
for tc_runs in missing empty; do
	bin=$(mktemp -d)
	make_mockbin "$bin" ok "main" "https://example.invalid/other/repo.git"
	make_gh_mock "$bin"
	cache=$(mktemp -d)
	[[ "$tc_runs" == empty ]] && mkdir -p "$cache/review-council/clones/.runs"
	errfile="$bin/stderr"
	result=$(PATH="$bin:$PATH" XDG_CACHE_HOME="$cache" bash "$SCRIPT" \
		--forge github --owner acme --repo widgets --pr 7 --head feature-x 2>"$errfile")
	assert_json_field "$result" "status" "ok" ".runs $tc_runs: status is ok"
	assert_equals "$(<"$errfile")" "" ".runs $tc_runs: nothing on stderr"
	rm -rf "$bin" "$cache"
done

# --- Symlinks in the GitHub checkout (RC-076) ---------------------------------
#
# These run real git against a local fixture: the wrapper only redirects the
# clone URL, so the fetch of pull/7/head, the config and the checkout are
# exactly what a review does.

# A real git whose clones come from <fixture> instead of the network.
# LATE_LINK, when set, is a path the wrapper makes a live link after each
# checkout, standing in for a materialization that left one behind.
make_fixture_git() { # bindir fixture
	local dir="$1" fixture="$2" real_git
	real_git=$(command -v git)
	mkdir -p "$dir"
	cat >"$dir/git" <<WRAP
#!/usr/bin/env bash
args=("\$@")
if printf '%s\n' "\$@" | grep -qx clone; then
	for i in "\${!args[@]}"; do
		if [[ "\${args[\$i]}" == "--" ]]; then
			args[\$((i + 1))]="file://$fixture"
			break
		fi
	done
fi
"$real_git" "\${args[@]}"
rc=\$?
if [[ -n "\${LATE_LINK:-}" ]] && printf '%s\n' "\$@" | grep -qx checkout; then
	ln -s /etc/passwd "\$LATE_LINK"
fi
exit \$rc
WRAP
	chmod +x "$dir/git"
	printf '#!/usr/bin/env bash\nexit 1\n' >"$dir/gh"
	chmod +x "$dir/gh"
}

# A repository whose refs/pull/7/head adds an escaping link and an inside one.
make_link_fixture() { # dir canary
	mkdir -p "$1"
	(
		cd "$1"
		git_init_sandbox
		mkdir -p docs
		echo base >README
		git add README
		git commit -qm base
		ln -s "$2" leak
		ln -s ../README docs/readme-link
		git add leak docs/readme-link
		git commit -qm links
		git update-ref refs/pull/7/head HEAD
		git checkout -q --detach HEAD~1
	)
}

live_links() { # root -> count of symlinks outside .git
	find "$1" -path "$1/.git" -prune -o -type l -print | wc -l | tr -d ' '
}

canary=$(mktemp)
echo "RC-CANARY-TEST" >"$canary"
fixture=$(mktemp -d)
make_link_fixture "$fixture/origin" "$canary"
gbin=$(mktemp -d)
make_fixture_git "$gbin" "$fixture/origin"

echo "Test 23: GitHub checkout writes committed symlinks as inert files (RC-076)"
cache=$(mktemp -d)
result=$(cd "$fixture" && PATH="$gbin:$PATH" XDG_CACHE_HOME="$cache" bash "$SCRIPT" \
	--forge github --owner acme --repo widgets --pr 7 --head feature-x 2>/dev/null)
assert_json_field "$result" "status" "ok" "status is ok"
root="$cache/review-council/clones/github.com-acme-widgets"
assert_json_field "$result" "review_root" "$root" "review_root is the cache clone"
assert_equals "$(live_links "$root")" "0" "no live link in the review tree"
assert_equals "$(cat "$root/leak" 2>/dev/null)" "$canary" "the link is a file holding its target text"
assert_equals "$(grep -rl RC-CANARY-TEST --exclude-dir=.git "$root" | wc -l | tr -d ' ')" "0" \
	"the target's content is nowhere in the tree"
assert_equals "$(git -C "$root" config core.symlinks)" "false" "the cache clone's own config holds the setting"

echo "Test 24: links an earlier checkout left live are made inert (RC-076)"
git -C "$root" config core.symlinks true
git -C "$root" checkout -q -f FETCH_HEAD
ln -s "$canary" "$root/planted"
assert_equals "$(live_links "$root")" "2" "precondition: the cache holds live links"
result=$(cd "$fixture" && PATH="$gbin:$PATH" XDG_CACHE_HOME="$cache" bash "$SCRIPT" \
	--forge github --owner acme --repo widgets --pr 7 --head feature-x 2>/dev/null)
assert_json_field "$result" "status" "ok" "status is ok"
assert_equals "$(live_links "$root")" "0" "every live link is gone"
assert_equals "$(cat "$root/leak" 2>/dev/null)" "$canary" "the tracked link is an inert file again"
rm -rf "$cache"

echo "Test 25: a link that survives materializing fails closed (RC-076)"
cache=$(mktemp -d)
root="$cache/review-council/clones/github.com-acme-widgets"
result=$(cd "$fixture" && PATH="$gbin:$PATH" XDG_CACHE_HOME="$cache" LATE_LINK="$root/late" bash "$SCRIPT" \
	--forge github --owner acme --repo widgets --pr 7 --head feature-x 2>/dev/null)
assert_json_field "$result" "status" "skip" "status is skip"
assert_json_field "$result" "review_root" "." "review falls back to the diff"
rm -rf "$cache"

echo "Test 26: a checkout tracking an escaping link is not reviewed in place (RC-076)"
op=$(mktemp -d)
git clone -q "$fixture/origin" "$op/w"
git -C "$op/w" fetch -q origin pull/7/head
git -C "$op/w" checkout -q -b feature-x FETCH_HEAD
git -C "$op/w" remote set-url origin https://github.com/acme/widgets.git
cache=$(mktemp -d)
result=$(cd "$op/w" && PATH="$gbin:$PATH" XDG_CACHE_HOME="$cache" bash "$SCRIPT" \
	--forge github --owner acme --repo widgets --pr 7 --head feature-x 2>/dev/null)
assert_json_field "$result" "status" "ok" "reviewed from the cache, not in place"
if [[ -L "$op/w/leak" ]]; then
	echo "  PASS: the operator's checkout is untouched"
	PASS=$((PASS + 1))
else
	echo "  FAIL: the operator's checkout was modified"
	FAIL=$((FAIL + 1))
fi
rm -rf "$cache"

echo "Test 26b: a checkout whose links stay inside is still reviewed in place"
git -C "$op/w" rm -q leak
git -C "$op/w" commit -qm "drop leak"
result=$(cd "$op/w" && PATH="$gbin:$PATH" bash "$SCRIPT" \
	--forge github --owner acme --repo widgets --pr 7 --head feature-x 2>/dev/null)
assert_json_field "$result" "status" "in_place" "status is in_place"
rm -rf "$op" "$fixture" "$gbin" "$canary"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
