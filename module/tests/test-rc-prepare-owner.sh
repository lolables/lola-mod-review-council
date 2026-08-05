#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$SCRIPT_DIR/../skills/review-council/scripts/rc-prepare.sh"
# shellcheck source=module/tests/helpers.sh
source "$SCRIPT_DIR/helpers.sh"

# Run prepare in a throwaway checkout whose origin is <origin>, then assert the
# forge/owner/repo triple it recorded in session.txt. A remote the parser cannot
# reduce to a safe owner/repo reports `none` for both, via the
# `${forge_owner:-none}` fallback in the session.txt writer.
# Usage: assert_forge_fields <origin> <forge> <owner> <repo> <label>
assert_forge_fields() {
	local origin="$1" want_forge="$2" want_owner="$3" want_repo="$4" label="$5"
	local work result sess got_forge got_owner got_repo
	work=$(mktemp -d)
	setup_repo "$work" feature "$origin"
	result=$(cd "$work" && AGENTS_DIR="$SCRIPT_DIR/../agents" bash "$SCRIPT" --mode code 2>/dev/null)
	sess=$(echo "$result" | jq -r '.session_dir')
	got_forge=$(sed -n -E 's/^Forge: +//p' "$sess/session.txt")
	got_owner=$(sed -n -E 's/^Owner: +//p' "$sess/session.txt")
	got_repo=$(sed -n -E 's/^Repo: +//p' "$sess/session.txt")
	assert_equals "$got_forge" "$want_forge" "$label — forge"
	assert_equals "$got_owner" "$want_owner" "$label — owner"
	assert_equals "$got_repo" "$want_repo" "$label — repo"
	rm -rf "$work"
}

# The URL-input branch resolves the same triple from a PR URL instead of from
# the origin, and needs the identical host rule. It is the reachable half of it:
# `--scope url` is a user-facing entry point, and the origin is not consulted.
#
# Run it against a recording gh and publish what the run did as
# rc_url_{gh_calls,forge,owner,repo}. The gh log is the primary evidence rather
# than session.txt alone, because a host the rule correctly refuses never
# reaches the forge and so produces no PR metadata and no changeset to inspect —
# leaving "did this review aim a forge call at that repository" as the question
# the host rule actually decides.
#
# The fake gh also keeps the run off the network: rc-clone-target.sh prefers gh
# over `git clone`, and a catch-all `exit 0` satisfies `gh repo clone` without
# producing a checkout, so the follow-up fetch fails fast and the review falls
# back to diff-only. The checkout carries no origin, so nothing but the URL can
# decide the forge.
#
# A fake `glab` joins it for the GitLab cases. glab is absent on most hosts, so
# without it forge_tool is `none`, no MR metadata is fetched, the changeset
# comes back empty and prepare exits before writing session.txt — leaving the
# owner/repo assertions with nothing to read. The fake also records its own
# argv, which is what makes the "no --repo ever reaches glab" invariant
# checkable rather than assumed.
rc_url_gh_calls="" rc_url_glab_calls=""
rc_url_forge="" rc_url_owner="" rc_url_repo=""
rc_url_status="" rc_url_message=""
run_url_scope() { # pr-url -> sets rc_url_{gh_calls,glab_calls,forge,owner,repo,status,message}
	local url="$1" work bin cache result sess
	work=$(mktemp -d)
	bin=$(mktemp -d)
	cache=$(mktemp -d)
	cat >"$bin/glab" <<GLAB
#!/usr/bin/env bash
echo "glab \$*" >>"$bin/glab.log"
case "\$1 \$2" in
"mr view")
	echo '{"title":"Add feature","description":"Body","target_branch":"main","source_branch":"feature","web_url":"$url","state":"opened"}'
	;;
"mr diff")
	printf 'diff --git a/foo.go b/foo.go\nindex 0000000..1111111 100644\n--- a/foo.go\n+++ b/foo.go\n@@ -0,0 +1,2 @@\n+package main\n+func main() {}\n'
	;;
esac
exit 0
GLAB
	chmod +x "$bin/glab"
	cat >"$bin/gh" <<GH
#!/usr/bin/env bash
echo "gh \$*" >>"$bin/gh.log"
case "\$1 \$2" in
"pr view")
	echo '{"number":42,"title":"Add feature","body":"Body","baseRefName":"main","headRefName":"feature","url":"$url","state":"OPEN","statusCheckRollup":[]}'
	;;
"pr diff")
	printf 'diff --git a/foo.go b/foo.go\nindex 0000000..1111111 100644\n--- a/foo.go\n+++ b/foo.go\n@@ -0,0 +1,2 @@\n+package main\n+func main() {}\n'
	;;
"api "*) echo "[]" ;;
esac
exit 0
GH
	chmod +x "$bin/gh"
	setup_repo "$work" feature ""
	result=$(cd "$work" && PATH="$bin:$PATH" XDG_CACHE_HOME="$cache" \
		AGENTS_DIR="$SCRIPT_DIR/../agents" \
		bash "$SCRIPT" --mode code --scope url --scope-value "$url" 2>/dev/null)
	rc_url_gh_calls=$(cat "$bin/gh.log" 2>/dev/null || true)
	rc_url_glab_calls=$(cat "$bin/glab.log" 2>/dev/null || true)
	rc_url_status=$(echo "$result" | jq -r '.status // empty')
	rc_url_message=$(echo "$result" | jq -r '.message // empty')
	rc_url_forge="" rc_url_owner="" rc_url_repo=""
	sess=$(echo "$result" | jq -r '.session_dir // empty')
	if [[ -n "$sess" ]] && [[ -f "$sess/session.txt" ]]; then
		rc_url_forge=$(sed -n -E 's/^Forge: +//p' "$sess/session.txt")
		rc_url_owner=$(sed -n -E 's/^Owner: +//p' "$sess/session.txt")
		rc_url_repo=$(sed -n -E 's/^Repo: +//p' "$sess/session.txt")
	fi
	rm -rf "$work" "$bin" "$cache"
}

# Did the run aim any gh call at acme/widgets? That is the harm a misread host
# causes: `gh api repos/acme/widgets/...` answered by whoever owns that name on
# the host gh resolves against.
# Usage: assert_forge_reached <yes|no> <label>
assert_forge_reached() {
	local want="$1" label="$2" got=no
	if grep -qF 'acme/widgets' <<<"$rc_url_gh_calls"; then got=yes; fi
	assert_equals "$got" "$want" "$label"
}

# Assert the run refused the URL as a precondition failure and said why.
#
# `empty` is the wrong token for this: SKILL.md's recovery table routes a
# non-terminal `--scope url` outcome into "re-run with --scope all", which turns
# "review PR 42" into a full council review of the local checkout reported as
# the answer. `skip` is terminal — report and stop.
# Usage: assert_unsupported_host <host> <label>
assert_unsupported_host() {
	local host="$1" label="$2"
	assert_equals "$rc_url_status" "skip" "$label — status"
	if grep -qF "$host" <<<"$rc_url_message"; then
		echo "  PASS: $label — message names the host"
		PASS=$((PASS + 1))
	else
		echo "  FAIL: $label — message does not name '$host' (got '$rc_url_message')"
		FAIL=$((FAIL + 1))
	fi
}

echo "Test 1: https origin records owner/repo without the .git suffix"
assert_forge_fields "https://github.com/acme/widgets.git" github acme widgets "https origin"

echo "Test 2: scp-like ssh origin records owner/repo without the .git suffix"
assert_forge_fields "git@github.com:acme/widgets.git" github acme widgets "ssh origin"

echo "Test 3: gitlab origin records owner/repo without the .git suffix"
assert_forge_fields "https://gitlab.com/acme/widgets.git" gitlab acme widgets "gitlab origin"

# A nested subgroup is an everyday legitimate GitLab remote that this parser
# cannot reduce to a two-segment owner/repo. Blanking the values is correct;
# demoting the forge is not. Nothing on the gitlab path consumes owner/repo
# (glab infers the project from the local remote), whereas `local` would
# silently review the branch diff instead of the requested merge request.
echo "Test 4: gitlab subgroup origin blanks owner/repo but keeps the forge"
assert_forge_fields "https://gitlab.com/group/subgroup/project.git" gitlab none none "gitlab subgroup origin"

echo "Test 5: unsafe github origin degrades to local"
assert_forge_fields "https://github.com/acme/widgets;id" local none none "unsafe github origin"

# Tests 6-9 pin the host match to the whole host. A substring test reads any
# host that merely contains `github.com` as GitHub — and with the dot left
# unescaped, `github.company.com` matches as well (`github` + any char + `com`).
# Either one sends `gh api` calls and a constructed github.com clone URL at an
# unrelated service.
echo "Test 6: a host that merely ends in github.com is not GitHub"
assert_forge_fields "https://mygithub.com/acme/widgets.git" local none none "mygithub.com origin"

echo "Test 7: a host that merely contains github.com is not GitHub"
assert_forge_fields "https://github.company.com/acme/widgets.git" local none none "github.company.com origin"

# The canonical GitHub Enterprise form. Degrading to `local` is the supported
# outcome — `gh` resolves OWNER/REPO against its own default host, so reaching
# an enterprise install needs GH_HOST handling rather than a looser match.
echo "Test 8: a GitHub Enterprise host degrades to local"
assert_forge_fields "https://github.example.com/acme/widgets.git" local none none "GHES origin"

echo "Test 9: a host that merely ends in gitlab.com is not GitLab"
assert_forge_fields "https://mygitlab.com/acme/widgets.git" local none none "mygitlab.com origin"

# Tests 10-12 are the same rule on the URL-input branch, which resolves the
# triple from the PR URL rather than from the origin. Read as GitHub, a
# mygithub.com PR URL aims `gh api repos/acme/widgets/pulls/42` and a
# constructed https://github.com/acme/widgets.git clone at an unrelated service.
#
# Refusing the host is only half the job. The URL named a pull request, so
# reporting "no changes to review" is misleading in the one direction that
# matters: SKILL.md's recovery table then broadens the run to --scope all and
# returns a council review of the local checkout as the answer about a PR that
# was never fetched. Each of these must terminate with `skip` and name the host.
echo "Test 10: a PR URL on a host that merely ends in github.com is not GitHub"
run_url_scope "https://mygithub.com/acme/widgets/pull/42"
assert_forge_reached no "mygithub.com PR URL — no forge call for acme/widgets"
assert_unsupported_host "mygithub.com" "mygithub.com PR URL"

echo "Test 11: a PR URL on a host that merely contains github.com is not GitHub"
run_url_scope "https://github.company.com/acme/widgets/pull/42"
assert_forge_reached no "github.company.com PR URL — no forge call for acme/widgets"
assert_unsupported_host "github.company.com" "github.company.com PR URL"

echo "Test 12: a PR URL on a GitHub Enterprise host is not GitHub"
run_url_scope "https://github.example.com/acme/widgets/pull/42"
assert_forge_reached no "GHES PR URL — no forge call for acme/widgets"
assert_unsupported_host "github.example.com" "GHES PR URL"

# The positive case: without it the three above could pass because the fixture
# never reaches gh at all, rather than because the host rule refused them.
echo "Test 13: a github.com PR URL still reaches the forge with its owner/repo"
run_url_scope "https://github.com/acme/widgets/pull/42"
assert_forge_reached yes "github.com PR URL — forge call carries acme/widgets"
assert_equals "$rc_url_status" "ok" "github.com PR URL — status"
assert_equals "$rc_url_forge" "github" "github.com PR URL — forge"
assert_equals "$rc_url_owner" "acme" "github.com PR URL — owner"
assert_equals "$rc_url_repo" "widgets" "github.com PR URL — repo"

echo "Test 14: a forge that is neither GitHub nor GitLab is refused by name"
run_url_scope "https://bitbucket.org/acme/widgets/pull-requests/3"
assert_unsupported_host "bitbucket.org" "bitbucket.org PR URL"

# Tests 15-18 are the GitLab project path. GitLab nests projects under
# arbitrarily deep subgroups, so the first two path segments are not owner/repo
# — and taking them anyway PASSED the character-class guard, silently naming a
# different project. project_id is a hash of "${owner}/${repo}" and keys the
# learnings/prior-reviews cache, so every project under gitlab.com/group/
# subgroup/ collided into one cache and a review of one could surface findings
# recorded against a sibling. GitLab emits `/-/` precisely to separate the
# project path from the route; split there.
echo "Test 15: a subgroup MR URL resolves the full namespace, not the first two segments"
run_url_scope "https://gitlab.com/group/subgroup/project/-/merge_requests/5"
assert_equals "$rc_url_forge" "gitlab" "gitlab subgroup MR URL — forge"
assert_equals "$rc_url_owner" "group/subgroup" "gitlab subgroup MR URL — owner"
assert_equals "$rc_url_repo" "project" "gitlab subgroup MR URL — repo"

# The safety invariant behind the character-class guard: build_repo_flag's
# result is expanded UNQUOTED at four gh call sites (deliberate word-splitting),
# so a slash-bearing owner reaching one would split into extra argv words. It
# cannot today because the GitLab path calls `glab mr view` / `glab mr diff`
# with no --repo at all — pinned here rather than assumed, since a subgroup
# owner is the first owner value that legitimately contains a slash.
if [[ -n "$rc_url_glab_calls" ]] && ! grep -qF -e '--repo' <<<"$rc_url_glab_calls"; then
	echo "  PASS: gitlab subgroup MR URL — glab was called, and never with --repo"
	PASS=$((PASS + 1))
else
	echo "  FAIL: gitlab subgroup MR URL — expected glab calls with no --repo, got '$rc_url_glab_calls'"
	FAIL=$((FAIL + 1))
fi
assert_forge_reached no "gitlab subgroup MR URL — no gh call for the project"

echo "Test 16: a deeply nested MR URL keeps every group in the owner"
run_url_scope "https://gitlab.com/a/b/c/d/-/merge_requests/9"
assert_equals "$rc_url_owner" "a/b/c" "deep subgroup MR URL — owner"
assert_equals "$rc_url_repo" "d" "deep subgroup MR URL — repo"

echo "Test 17: an unnested MR URL is unchanged"
run_url_scope "https://gitlab.com/group/project/-/merge_requests/5"
assert_equals "$rc_url_forge" "gitlab" "plain gitlab MR URL — forge"
assert_equals "$rc_url_owner" "group" "plain gitlab MR URL — owner"
assert_equals "$rc_url_repo" "project" "plain gitlab MR URL — repo"

# `..` satisfies ^[a-zA-Z0-9._-]+$, so the character class alone admits a
# traversal segment. Each segment is checked on its own and the pair is blanked
# rather than accepted — blank owner/repo is safe here (nothing on the GitLab
# path consumes them, and project_id falls back to hashing $PWD).
echo "Test 18: a traversal segment blanks owner/repo instead of being admitted"
run_url_scope "https://gitlab.com/group/../etc/-/merge_requests/1"
assert_equals "$rc_url_owner" "none" "traversal MR URL — owner"
assert_equals "$rc_url_repo" "none" "traversal MR URL — repo"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
