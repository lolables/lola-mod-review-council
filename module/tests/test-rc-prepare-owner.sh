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
# The Host: line is published as rc_local_host rather than asserted here, so the
# callers that do not care about it keep their four-argument form.
# Usage: assert_forge_fields <origin> <forge> <owner> <repo> <label>
rc_local_host=""
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
	rc_local_host=$(sed -n -E 's/^Host: +//p' "$sess/session.txt")
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
#
# The fake glab is logged in to the hosts in the optional second argument
# (default: gitlab.com and git.example.org): `glab auth status --hostname H`
# exits 0 for those and 1 for any other, which is what the real one does
# locally for a host absent from its config. The value `none` installs no glab
# at all — PATH is then a sandbox of links to every other tool, because a real
# glab on the host would otherwise be found.
rc_url_gh_calls="" rc_url_glab_calls=""
rc_url_forge="" rc_url_owner="" rc_url_repo="" rc_url_host=""
rc_url_status="" rc_url_message=""
run_url_scope() { # pr-url [glab-hosts|none] -> sets rc_url_{gh_calls,glab_calls,forge,owner,repo,host,status,message}
	local url="$1" glab_hosts="${2:-gitlab.com git.example.org}" work bin cache result sess run_path
	work=$(mktemp -d)
	bin=$(mktemp -d)
	cache=$(mktemp -d)
	cat >"$bin/glab" <<GLAB
#!/usr/bin/env bash
echo "glab \$*" >>"$bin/glab.log"
case "\$1 \$2" in
"auth status")
	case " $glab_hosts " in
	*" \$4 "*) exit 0 ;;
	*)
		# glab's own wording for a host missing from its config.
		echo "x \$4 has not been authenticated with glab" >&2
		exit 1
		;;
	esac
	;;
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
	run_path="$bin:$PATH"
	if [[ "$glab_hosts" == "none" ]]; then
		rm -f "$bin/glab"
		mkdir "$bin/sys"
		local dir tool
		IFS=':' read -r -a path_dirs <<<"$PATH"
		for dir in "${path_dirs[@]}"; do
			for tool in "$dir"/*; do
				[[ -x "$tool" ]] && [[ ! -e "$bin/sys/${tool##*/}" ]] && [[ "${tool##*/}" != "glab" ]] &&
					ln -s "$tool" "$bin/sys/${tool##*/}"
			done
		done
		run_path="$bin:$bin/sys"
	fi
	setup_repo "$work" feature ""
	result=$(cd "$work" && PATH="$run_path" XDG_CACHE_HOME="$cache" \
		AGENTS_DIR="$SCRIPT_DIR/../agents" \
		bash "$SCRIPT" --mode code --scope url --scope-value "$url" 2>/dev/null)
	rc_url_gh_calls=$(cat "$bin/gh.log" 2>/dev/null || true)
	rc_url_glab_calls=$(cat "$bin/glab.log" 2>/dev/null || true)
	rc_url_status=$(echo "$result" | jq -r '.status // empty')
	rc_url_message=$(echo "$result" | jq -r '.message // empty')
	rc_url_forge="" rc_url_owner="" rc_url_repo="" rc_url_host=""
	sess=$(echo "$result" | jq -r '.session_dir // empty')
	if [[ -n "$sess" ]] && [[ -f "$sess/session.txt" ]]; then
		rc_url_forge=$(sed -n -E 's/^Forge: +//p' "$sess/session.txt")
		rc_url_owner=$(sed -n -E 's/^Owner: +//p' "$sess/session.txt")
		rc_url_repo=$(sed -n -E 's/^Repo: +//p' "$sess/session.txt")
		rc_url_host=$(sed -n -E 's/^Host: +//p' "$sess/session.txt")
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
	if grep -qF -e "$host" <<<"$rc_url_message"; then
		echo "  PASS: $label — message names the host"
		PASS=$((PASS + 1))
	else
		echo "  FAIL: $label — message does not name '$host' (got '$rc_url_message')"
		FAIL=$((FAIL + 1))
	fi
}

# Usage: assert_message_has <fixed-string> <label>
assert_message_has() {
	if grep -qF -e "$1" <<<"$rc_url_message"; then
		echo "  PASS: $2 — message says '$1'"
		PASS=$((PASS + 1))
	else
		echo "  FAIL: $2 — message lacks '$1' (got '$rc_url_message')"
		FAIL=$((FAIL + 1))
	fi
}

# Usage: assert_glab_called <fixed-string> <label> / assert_glab_not_called ...
assert_glab_called() {
	if grep -qF -e "$1" <<<"$rc_url_glab_calls"; then
		echo "  PASS: $2"
		PASS=$((PASS + 1))
	else
		echo "  FAIL: $2 (no '$1' in glab calls: '$rc_url_glab_calls')"
		FAIL=$((FAIL + 1))
	fi
}
assert_glab_not_called() {
	if grep -qF -e "$1" <<<"$rc_url_glab_calls"; then
		echo "  FAIL: $2 ('$1' in glab calls: '$rc_url_glab_calls')"
		FAIL=$((FAIL + 1))
	else
		echo "  PASS: $2"
		PASS=$((PASS + 1))
	fi
}

echo "Test 1: https origin records owner/repo without the .git suffix"
assert_forge_fields "https://github.com/acme/widgets.git" github acme widgets "https origin"

echo "Test 2: scp-like ssh origin records owner/repo without the .git suffix"
assert_forge_fields "git@github.com:acme/widgets.git" github acme widgets "ssh origin"

echo "Test 3: gitlab origin records owner/repo without the .git suffix"
assert_forge_fields "https://gitlab.com/acme/widgets.git" gitlab acme widgets "gitlab origin"

# A nested subgroup is an everyday legitimate GitLab remote. It used to come
# through blank, leaving glab to infer the project from the checkout — and glab
# prefers an `upstream` remote over origin, so a fork reviewed upstream's MR of
# the same number, possibly on another host. The full path is read instead:
# the last segment is the repo, everything before it the owner.
echo "Test 4: gitlab subgroup origin records the full namespace"
assert_forge_fields "https://gitlab.com/group/subgroup/project.git" gitlab group/subgroup project "gitlab subgroup origin"
assert_forge_fields "git@gitlab.com:g/s/p.git" gitlab g/s p "gitlab subgroup ssh origin"

# The URL branch's per-segment gate applies to a remote too: `..` and a
# hyphen-led segment satisfy the character class but must not reach glab.
echo "Test 4a: an unsafe gitlab subgroup origin records no project"
assert_forge_fields "https://gitlab.com/g/../p.git" gitlab none none "traversal gitlab origin"
assert_forge_fields "https://gitlab.com/g/-s/p.git" gitlab none none "hyphen-led gitlab origin"

# End to end: the MR of a local subgroup checkout is fetched by its full path,
# never left for glab to resolve from the checkout's remotes.
echo "Test 4b: a local subgroup checkout addresses glab to its own project"
local_bin=$(mktemp -d)
local_work=$(mktemp -d)
local_cache=$(mktemp -d)
cat >"$local_bin/glab" <<GLAB
#!/usr/bin/env bash
echo "glab \$*" >>"$local_bin/glab.log"
case "\$1 \$2" in
"mr view") echo '{"title":"T","description":"B","target_branch":"main","source_branch":"feature","web_url":"u","state":"opened"}' ;;
esac
exit 0
GLAB
chmod +x "$local_bin/glab"
setup_repo "$local_work" feature "git@gitlab.com:g/s/p.git"
(cd "$local_work" && PATH="$local_bin:$PATH" XDG_CACHE_HOME="$local_cache" \
	AGENTS_DIR="$SCRIPT_DIR/../agents" \
	bash "$SCRIPT" --mode code --scope pr --scope-value 5 >/dev/null 2>&1) || true
rc_url_glab_calls=$(cat "$local_bin/glab.log" 2>/dev/null || true)
assert_glab_called "mr view 5 -R gitlab.com/g/s/p --output json" "local subgroup checkout — mr view addressed"
assert_glab_called "mr diff 5 -R gitlab.com/g/s/p --raw" "local subgroup checkout — mr diff addressed"
rm -rf "$local_bin" "$local_work" "$local_cache"

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
# so a slash-bearing owner reaching one would split into extra argv words. The
# GitLab adapter never uses build_repo_flag: it passes the whole project path
# as one quoted `-R host/group/subgroup/project` — pinned here rather than
# assumed, since a subgroup owner is the first owner value that legitimately
# contains a slash.
assert_glab_called "mr view 5 -R gitlab.com/group/subgroup/project --output json" \
	"gitlab subgroup MR URL — glab addressed the full project path"
assert_glab_not_called "--repo" "gitlab subgroup MR URL — glab never given build_repo_flag's --repo"
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
# traversal segment. Each segment is checked on its own, and a URL that fails
# is refused outright: with no project to name, glab would fall back to the
# launch directory's remote and review a different merge request.
echo "Test 18: a traversal segment is refused instead of being admitted"
run_url_scope "https://gitlab.com/group/../etc/-/merge_requests/1"
assert_equals "$rc_url_status" "skip" "traversal MR URL — status"
assert_equals "$rc_url_glab_calls" "" "traversal MR URL — glab never called"

# Tests 19-27 cover self-hosted GitLab. The `/-/merge_requests/N` route is
# GitLab's own, so it identifies the forge on any host; the host itself is
# recorded in session.txt because every later forge call (the adapter, the
# clone, permalinks, the poster) has to be aimed at it, and none of them can
# recover it from a checkout that may not exist.
echo "Test 19: a self-hosted nested-group MR URL resolves as GitLab on that host"
run_url_scope "https://git.example.org/g/sub/p/-/merge_requests/4"
assert_equals "$rc_url_status" "ok" "self-hosted MR URL — status"
assert_equals "$rc_url_forge" "gitlab" "self-hosted MR URL — forge"
assert_equals "$rc_url_owner" "g/sub" "self-hosted MR URL — owner"
assert_equals "$rc_url_repo" "p" "self-hosted MR URL — repo"
assert_equals "$rc_url_host" "git.example.org" "self-hosted MR URL — host"
first_glab_call=$(head -n1 <<<"$rc_url_glab_calls")
assert_equals "$first_glab_call" "glab auth status --hostname git.example.org" \
	"self-hosted MR URL — the login check is glab's first call"
assert_glab_called "mr view 4" "self-hosted MR URL — glab asked for MR 4"

# glab addresses a host by name only (`--hostname host:port` is rejected), and
# a non-default port is configured through its per-host api_host instead. So a
# ported URL cannot be honoured as given; refusing it names the fix.
echo "Test 20: a self-hosted MR URL with a port is refused, naming the fix"
run_url_scope "https://git.example.org:8443/g/p/-/merge_requests/4"
assert_equals "$rc_url_status" "skip" "ported MR URL — status"
assert_message_has "GitLab hosts with a port are not supported" "ported MR URL"
assert_message_has "api_host for git.example.org" "ported MR URL — names the host"
assert_equals "$rc_url_glab_calls" "" "ported MR URL — glab never called"

echo "Test 21: the recorded host is lowercased, scheme matched in any case"
run_url_scope "HTTPS://GitLab.com/g/p/-/merge_requests/4"
assert_equals "$rc_url_forge" "gitlab" "mixed-case gitlab.com MR URL — forge"
assert_equals "$rc_url_host" "gitlab.com" "mixed-case gitlab.com MR URL — host"

echo "Test 22: a github.com PR URL records github.com as the host"
run_url_scope "https://github.com/acme/widgets/pull/42"
assert_equals "$rc_url_host" "github.com" "github.com PR URL — host"

# Accepting GitLab on any host must not leak into GitHub: the GitHub route
# (`/pull/N`) identifies nothing about the host, so GHE stays refused.
echo "Test 23: a GHE PR URL is still refused"
run_url_scope "https://ghe.example.com/o/r/pull/1"
assert_unsupported_host "ghe.example.com" "GHE PR URL"

# Without the `/-/` separator there is no way to tell the project path from the
# route, and it is not a GitLab MR URL as GitLab emits one.
echo "Test 24: an MR-shaped URL without the /-/ separator is refused"
run_url_scope "https://git.example.org/g/p/merge_requests/4"
assert_unsupported_host "git.example.org" "MR URL without /-/"

# Userinfo in the authority is never part of a forge URL a user copies; letting
# it through would put credentials-shaped text into the recorded host.
echo "Test 25: an MR URL with userinfo in the authority is refused"
run_url_scope "https://u@git.example.org/g/p/-/merge_requests/4"
assert_unsupported_host "git.example.org" "MR URL with userinfo"
assert_equals "$rc_url_glab_calls" "" "MR URL with userinfo — glab never called"

# The host is handed to glab and to constructed URLs later; a label that starts
# with a hyphen can read as an option and is not a valid hostname anyway.
echo "Test 26: an MR URL whose host label starts with a hyphen is refused"
run_url_scope "https://-bad.example/g/p/-/merge_requests/1"
assert_unsupported_host "-bad.example" "MR URL with a hyphen-led host"
assert_equals "$rc_url_glab_calls" "" "MR URL with a hyphen-led host — glab never called"

# A GitLab project always sits in a namespace, so a single-segment project path
# is malformed. It is refused rather than reviewed: with no project to name,
# glab falls back to the launch directory's remote and fetches whatever MR
# carries that number there.
echo "Test 27: a single-segment MR URL is refused"
run_url_scope "https://git.example.org/p/-/merge_requests/1"
assert_equals "$rc_url_status" "skip" "single-segment MR URL — status"
assert_message_has "https://git.example.org/p/-/merge_requests/1" "single-segment MR URL"
assert_equals "$rc_url_glab_calls" "" "single-segment MR URL — glab never called"

echo "Test 28: a local-remote session records the origin's host"
assert_forge_fields "https://github.com/acme/widgets.git" github acme widgets "github origin (host)"
assert_equals "$rc_local_host" "github.com" "github origin — host"
assert_forge_fields "git@gitlab.com:acme/widgets.git" gitlab acme widgets "gitlab ssh origin (host)"
assert_equals "$rc_local_host" "gitlab.com" "gitlab ssh origin — host"

# `local` addresses no forge, so naming a host would invite a later stage to
# aim a call at it.
echo "Test 29: a local-forge session records no host"
assert_forge_fields "https://github.example.com/acme/widgets.git" local none none "GHES origin (host)"
assert_equals "$rc_local_host" "none" "GHES origin — host"
assert_forge_fields "https://github.com/acme/widgets;id" local none none "unsafe github origin (host)"
assert_equals "$rc_local_host" "none" "unsafe github origin — host"

echo "Test 30: a review outside any git repository records no host"
nogit_work=$(mktemp -d)
nogit_cache=$(mktemp -d)
echo "package main" >"$nogit_work/a.go"
nogit_result=$(cd "$nogit_work" && XDG_CACHE_HOME="$nogit_cache" GIT_CEILING_DIRECTORIES="$nogit_work" \
	AGENTS_DIR="$SCRIPT_DIR/../agents" bash "$SCRIPT" --mode code --scope all 2>/dev/null)
nogit_sess=$(echo "$nogit_result" | jq -r '.session_dir // empty')
nogit_host=""
if [[ -n "$nogit_sess" ]] && [[ -f "$nogit_sess/session.txt" ]]; then
	nogit_host=$(sed -n -E 's/^Host: +//p' "$nogit_sess/session.txt")
fi
assert_equals "$nogit_host" "none" "no-git session — host"
rm -rf "$nogit_work" "$nogit_cache"

# Tests 31-33 are the credential gate. glab sends the stored token (as
# PRIVATE-TOKEN) to whatever host it is pointed at, configured or not, so a
# pasted MR URL on a hostile host would collect it. `glab auth status
# --hostname H` answers locally whether H is configured; nothing else may run
# until it says yes.
echo "Test 31: a host glab is not logged in to is refused before any other glab call"
run_url_scope "https://git.evil.example/g/p/-/merge_requests/4"
assert_equals "$rc_url_status" "skip" "unconfigured host — status"
assert_message_has "glab is not logged in to git.evil.example" "unconfigured host"
assert_message_has "glab auth login --hostname git.evil.example" "unconfigured host — names the fix"
assert_equals "$rc_url_glab_calls" "glab auth status --hostname git.evil.example" \
	"unconfigured host — the login check is the only glab call"

echo "Test 32: gitlab.com is gated the same way"
run_url_scope "https://gitlab.com/g/p/-/merge_requests/4" "git.example.org"
assert_equals "$rc_url_status" "skip" "gitlab.com, not logged in — status"
assert_equals "$rc_url_glab_calls" "glab auth status --hostname gitlab.com" \
	"gitlab.com, not logged in — the login check is the only glab call"

echo "Test 33: no glab on PATH is refused the same way"
run_url_scope "https://git.example.org/g/p/-/merge_requests/4" none
assert_equals "$rc_url_status" "skip" "no glab — status"
assert_message_has "glab is not installed" "no glab"

# Tests 34-38: the MR number and the project path come from ONE capture. A
# second, looser pass over the URL (a greedy `.*/merge_requests/N`) read the
# LAST occurrence, so a query string could swap in a different MR of the same
# project.
echo "Test 34: an MR number in the query string does not replace the path's"
run_url_scope "https://git.example.org/g/p/-/merge_requests/4?x=/merge_requests/999"
assert_equals "$rc_url_status" "ok" "MR URL with query — status"
assert_glab_called "mr view 4" "MR URL with query — glab asked for MR 4"
assert_glab_not_called "999" "MR URL with query — MR 999 never requested"

echo "Test 35: a repeated route is refused, not read as a project named '-'"
run_url_scope "https://git.example.org/g/p/-/merge_requests/4/-/merge_requests/7"
assert_equals "$rc_url_status" "skip" "repeated route — status"
assert_equals "$rc_url_glab_calls" "" "repeated route — glab never called"

echo "Test 36: a non-numeric MR number is refused"
run_url_scope "https://git.example.org/g/p/-/merge_requests/4abc"
assert_equals "$rc_url_status" "skip" "non-numeric MR — status"
assert_message_has "Cannot read a project" "non-numeric MR"
assert_equals "$rc_url_glab_calls" "" "non-numeric MR — glab never called"

echo "Test 37: a newline after the MR number is refused"
run_url_scope $'https://git.example.org/g/p/-/merge_requests/4\nmalicious'
assert_equals "$rc_url_status" "skip" "newline payload — status"
assert_message_has "Cannot read a project" "newline payload"
assert_equals "$rc_url_glab_calls" "" "newline payload — glab never called"

echo "Test 38: a PR number in the query string does not replace the path's"
run_url_scope "https://github.com/acme/widgets/pull/4?x=/pull/999"
assert_equals "$rc_url_status" "ok" "PR URL with query — status"
if grep -qF 'pr view 4 ' <<<"$rc_url_gh_calls" && ! grep -qF '999' <<<"$rc_url_gh_calls"; then
	echo "  PASS: PR URL with query — gh asked for PR 4 and never 999"
	PASS=$((PASS + 1))
else
	echo "  FAIL: PR URL with query — expected 'pr view 4' and no 999, got '$rc_url_gh_calls'"
	FAIL=$((FAIL + 1))
fi

# The GitHub host is never a GitLab instance, whatever route its URL carries —
# with a port parse_remote reports no host at all, so it would otherwise fall
# through to the any-host GitLab rule.
echo "Test 39: github.com is never read as GitLab"
run_url_scope "https://github.com:8443/g/p/-/merge_requests/1" "github.com gitlab.com"
assert_equals "$rc_url_status" "skip" "ported github.com MR URL — status"
assert_equals "$rc_url_glab_calls" "" "ported github.com MR URL — glab never called"
run_url_scope "https://GitHub.com/g/p/-/merge_requests/1" "github.com gitlab.com"
assert_equals "$rc_url_status" "skip" "github.com MR URL — status"
assert_equals "$rc_url_glab_calls" "" "github.com MR URL — glab never called"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
