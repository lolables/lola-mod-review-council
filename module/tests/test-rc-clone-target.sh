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
if [[ "$root" == "$cache/review-council/clones/acme-widgets" ]]; then
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

# Test 4: non-github forge -> skip (generic fallback), review_root = .
echo "Test 4: non-github skip"
bin=$(mktemp -d)
make_mockbin "$bin" ok "main"
result=$(PATH="$bin:$PATH" bash "$SCRIPT" --forge gitlab --owner acme --repo widgets --pr 7 --head feature-x 2>/dev/null)
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
if [[ -d "$clones/acme-widgets" ]]; then
	echo "  PASS: fresh clone retained"
	PASS=$((PASS + 1))
else
	echo "  FAIL: fresh clone was pruned"
	FAIL=$((FAIL + 1))
fi
rm -rf "$bin" "$cache"

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
# URL and the cache directory path (`${cache_root}/${owner}-${repo}`), so the
# character gate has to reject them up front — a clone that merely happens to
# fail afterwards is not the same guarantee.
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

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
