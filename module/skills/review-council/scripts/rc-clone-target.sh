#!/usr/bin/env bash
set -uo pipefail

# shellcheck source=module/skills/review-council/scripts/rc-lib.sh
source "$(dirname "$0")/rc-lib.sh"
rc_trap_errors     # report script:line on any unhandled failure (never silent)
rc_require_timeout # this script makes forge calls; fail before any side effect
# shellcheck source=module/skills/review-council/scripts/lib/forge/gitlab.sh
source "$(dirname "$0")/lib/forge/gitlab.sh"
# shellcheck source=module/skills/review-council/scripts/lib/symlinks.sh
source "$(dirname "$0")/lib/symlinks.sh"

# rc-clone-target.sh — materialize a target repo for PR/MR review when we are
# not already in it. Emits JSON with review_root for downstream reads.
#
# Usage:
#   rc-clone-target.sh --forge github|gitlab --owner O --repo R --pr N --head REF [--url URL]
#                      [--head-sha SHA]
#
#   --owner is a GitLab namespace for --forge gitlab and may name subgroups
#   (`group/subgroup`); --pr is then the merge request number.
#
#   --url names the target repository outright, host included, and is the only
#   way to reach a host other than the forge's canonical one (github.com,
#   gitlab.com): a GitHub Enterprise install or a self-hosted GitLab. The local
#   origin is never a source for the host — see "Which host did the caller ask
#   for?" below.
#
#   --head-sha is the merge request's head commit as preparation already read
#   it. GitLab materializes the archive at that sha instead of looking the
#   merge request up again; anything but a 40-hex commit id is refused.
#
# Output JSON:
#   {"status":"in_place|ok|skip","review_root":"<path|.>","message":"..."}
#     in_place  -> current working tree is the target at PR head; review_root "."
#     ok        -> materialized into cache; review_root is the checkout path
#                  (GitHub) or the extracted archive tree (GitLab), and GitLab
#                  adds "special_files_removed":<n>
#     skip      -> not materialized (unsupported forge / clone failure); review_root "."

forge="" owner="" repo="" pr="" head="" url="" head_sha=""
while [[ $# -gt 0 ]]; do
	case "$1" in
	--forge)
		forge="$2"
		shift 2
		;;
	--owner)
		owner="$2"
		shift 2
		;;
	--repo)
		repo="$2"
		shift 2
		;;
	--pr)
		pr="$2"
		shift 2
		;;
	--head)
		head="$2"
		shift 2
		;;
	--url)
		url="$2"
		shift 2
		;;
	--head-sha)
		head_sha="$2"
		shift 2
		;;
	*)
		json_output "skip" "Unknown flag: $1" '{"review_root":"."}'
		exit 0
		;;
	esac
done

emit() { # status message
	local payload
	payload=$(jq -n --arg r "${review_root:-.}" --arg s "${special_files_removed:-}" \
		'{review_root:$r} + (if $s == "" then {} else {special_files_removed:($s | tonumber)} end)')
	json_output "$1" "$2" "$payload"
}

# <name> <default> — the integer in environment variable <name>, else <default>.
# Base 10 is forced: a leading zero would otherwise read as octal.
cap_from_env() {
	local value="${!1:-}"
	if [[ "$value" =~ ^[0-9]{1,18}$ ]]; then
		echo "$((10#$value))"
	else
		echo "$2"
	fi
}

# <dir> — remove a tree an archive may have left with read-only directories,
# which `rm -rf` alone cannot empty. find does not follow symlinks, so only the
# tree's own directories are made writable.
rm_tree() {
	[[ -e "$1" || -L "$1" ]] || return 0
	find "$1" -type d -exec chmod u+rwx {} + 2>/dev/null
	rm -rf "$1"
}

# <dir> — how many entries below <dir> are neither a regular file nor a
# directory, or are a regular file with a second hard link. remove_special
# deletes exactly those. One `x` per entry counts a name holding a newline once.
count_special() {
	local n
	n=$(find "$1" -mindepth 1 \( ! -type f ! -type d -o -type f -links +1 \) -exec printf x \; | wc -c) || return 1
	echo "${n//[^0-9]/}"
}
remove_special() {
	find "$1" -mindepth 1 \( ! -type f ! -type d -o -type f -links +1 \) -exec rm -f {} +
}

# Does the checkout we are standing in track a symlink leading out of the
# repository? In-place review reads the operator's own tree, live links and
# all, so such a checkout is not reused: the cache paths materialize the same
# head with every link inert, and the operator's tree is never modified.
# Every tracked link goes into the map, so a chain through another link is
# judged as the kernel would follow it. Links that stay inside can only reach
# the review's own content and are left alone. A git failure counts as
# escaping: the cache path is the safe one.
inplace_link_escapes() {
	local listing rec meta mode obj path target i
	local -a link_paths=() link_targets=()
	listing=$(mktemp) || return 0
	if ! git ls-files -s -z >"$listing" 2>/dev/null; then
		rm -f "$listing"
		return 0
	fi
	rc_symlink_map_reset
	# shellcheck disable=SC2094 # the rm inside runs only on the path that
	# returns at once, so nothing reads the listing after it is removed.
	while IFS= read -r -d '' rec; do
		meta="${rec%%$'\t'*}"
		path="${rec#*$'\t'}"
		read -r mode obj _ <<<"$meta"
		[[ "$mode" == 120000 ]] || continue
		# The sentinel keeps a trailing newline that $( ) would strip.
		if ! target=$(git cat-file blob "$obj" && printf x); then
			rm -f "$listing"
			return 0
		fi
		target="${target%x}"
		rc_symlink_map_add "$path" "$target"
		link_paths+=("$path")
		link_targets+=("$target")
	done <"$listing"
	rm -f "$listing"
	for i in "${!link_paths[@]}"; do
		rc_symlink_escapes "${link_paths[i]}" "${link_targets[i]}" && return 0
	done
	return 1
}

# Validate identifiers (defense in depth; prepare.sh already validates).
# A GitLab owner is a namespace path that may nest subgroups, so for GitLab
# every segment of owner/repo is gated on its own by project_path_ok — the
# same gate prepare applies (see rc-lib.sh). A GitHub owner never holds a `/`.
ids_ok=true
if [[ "$forge" == "gitlab" ]]; then
	project_path_ok "$owner" "$repo" || ids_ok=false
elif [[ ! "$owner" =~ ^[a-zA-Z0-9._-]+$ ]] || [[ ! "$repo" =~ ^[a-zA-Z0-9._-]+$ ]]; then
	ids_ok=false
fi
if [[ "$ids_ok" != true ]] || [[ ! "$pr" =~ ^[0-9]+$ ]]; then
	review_root="."
	emit "skip" "Invalid or missing owner/repo/pr; reviewing from diff only."
	exit 0
fi
if [[ -n "$head_sha" ]] && [[ ! "$head_sha" =~ ^[0-9a-f]{40}$ ]]; then
	review_root="."
	emit "skip" "--head-sha is not a 40-hex commit id; reviewing from diff only."
	exit 0
fi

# A GitHub pull request's head is fetched from pull/N/head on the base
# repository, so pull requests from forks resolve too. A GitLab merge request
# is materialized from the repository archive at its head sha instead (see
# "GitLab: the archive at the head sha" below). Other forges fall back to
# diff-only review.
case "$forge" in
github)
	default_host="github.com"
	head_ref="pull/${pr}/head"
	head_label="$head_ref"
	;;
gitlab)
	default_host="gitlab.com"
	head_label="merge request ${pr}"
	;;
*)
	review_root="."
	emit "skip" "Cloning not implemented for forge '${forge}'; reviewing from diff only."
	exit 0
	;;
esac

# --- Which host did the caller ask for? ---
# In precedence order: an explicit --url, else the canonical host of --forge
# (github.com or gitlab.com).
#
# The origin's host is deliberately not a source here. Under URL scope the
# checkout we happen to be standing in has nothing to do with the PR being
# reviewed, and owner/repo is a name collision away from any mirror — or any
# host an attacker controls — that serves the same two path segments. Letting
# the origin choose the host would point review_root at foreign content, which
# is then evidence-verified as though it were the PR. When the caller names no
# host, the forge's canonical host is used.
#
# A --url must also name the repository --owner/--repo name. The URL decides
# what is cloned; owner/repo decide which cache entry it is filed under and
# what the messages say was reviewed. Disagreeing, they file and report one
# project's checkout as another's. The path is read straight off the URL
# rather than from parse_remote, which names no path at all for a URL with a
# port; parse_remote still covers the scp-like `host:path` form. Compared
# case-insensitively with any `.git` dropped, the way forges route.
target_host="$default_host"
if [[ -n "$url" ]]; then
	parse_remote "$url"
	target_host="$rc_remote_host"
	url_path="$rc_remote_path"
	if [[ "$url" == *://* ]]; then
		url_rest="${url#*://}"
		url_path=""
		[[ "$url_rest" == */* ]] && url_path="${url_rest#*/}"
		url_path="${url_path%.git}"
	fi
	if [[ "${url_path,,}" != "${owner,,}/${repo,,}" ]]; then
		review_root="."
		emit "skip" "--url does not name ${owner}/${repo}; reviewing from diff only."
		exit 0
	fi
fi

# --- Already in it? Same host AND project path AND current branch == PR head ---
origin_url=$(git remote get-url origin 2>/dev/null || echo "")
parse_remote "$origin_url"
cur_host="$rc_remote_host" cur_path="$rc_remote_path"
cur_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
# Does the checkout we are standing in hold the repository we were asked for?
# The host is part of the question, not an incidental detail: standing in a
# same-named repository on a different host is exactly when the working tree
# must not be reused. Only when host and the whole project path agree does
# "acme/widgets" mean the same repository the caller named. The whole path,
# not parse_remote's owner/repo pair: that pair is blank for a GitLab subgroup
# project, which would never match. For GitHub the gated owner holds no `/`,
# so the path comparison is exactly the owner-and-repo one.
origin_names_target=false
if [[ -n "$cur_host" ]] && [[ "${cur_host,,}" == "${target_host,,}" ]] &&
	[[ "${cur_path,,}" == "${owner,,}/${repo,,}" ]]; then
	origin_names_target=true
fi
inplace_note=""
if [[ "$origin_names_target" == true ]] && [[ -n "$head" ]] && [[ "$cur_branch" == "$head" ]]; then
	if inplace_link_escapes; then
		inplace_note=" Not reviewed in place: this checkout tracks a symlink leading out of the repository."
	else
		review_root="."
		emit "in_place" "Already in ${owner}/${repo} at ${head}; using working tree."
		exit 0
	fi
fi

# --- Materialize into per-endpoint cache ---
# Every git network call runs with each credential prompt disabled. A private host
# with no credential helper otherwise makes git ask for a username on the
# terminal or through an askpass program, and the run waits out the 120s
# timeout before falling back. A configured credential helper still answers;
# an empty GIT_ASKPASS/SSH_ASKPASS is read as unset. GCM_INTERACTIVE is Git
# Credential Manager's own switch for its prompts.
no_prompt=(env GIT_TERMINAL_PROMPT=0 GCM_INTERACTIVE=never GIT_ASKPASS= SSH_ASKPASS=)
# github.com credentials come from gh for every git call, not only the clone.
# `gh repo clone` hands its credential helper to that one clone and stores
# nothing, so on a private repository the fetch of pull/N/head — and the
# checkout, which in a blobless clone downloads the blobs it needs — had no
# credentials unless the operator had run `gh auth setup-git`. The helper is
# passed the way gh passes it, as process-scoped configuration: scoped to
# https://github.com so no other host ever asks gh for a token, appended after
# any GIT_CONFIG_* entries the caller set, and written to no config file. A
# non-numeric GIT_CONFIG_COUNT is left alone; git refuses it either way.
gh_auth=()
if [[ "$forge" == "github" ]] && [[ "$target_host" == "github.com" ]] && command -v gh >/dev/null 2>&1 &&
	[[ "${GIT_CONFIG_COUNT:-0}" =~ ^[0-9]+$ ]]; then
	config_index=$((10#${GIT_CONFIG_COUNT:-0}))
	gh_auth=("GIT_CONFIG_COUNT=$((config_index + 1))"
		"GIT_CONFIG_KEY_${config_index}=credential.https://github.com.helper"
		"GIT_CONFIG_VALUE_${config_index}=!gh auth git-credential")
fi
cache_root="${XDG_CACHE_HOME:-$HOME/.cache}/review-council/clones"
# Built from the host the caller named, never from the origin's.
clone_url="${url:-https://${target_host}/${owner}/${repo}.git}"
# The entry is named for the endpoint, not for the repository alone. Two hosts
# serve an "acme/widgets" just as happily, and a key of owner/repo alone hands
# one host's checkout back for the other's: the `git fetch origin pull/N/head`
# below then runs against the wrong origin and the review grounds every finding
# in a foreign repository while still reporting `ok`. That is the in_place host
# test's failure mode one layer down.
#
# The host is not character-gated the way owner and repo are, so it is reduced
# to their alphabet before it becomes a path component. parse_remote already
# refuses a host holding `/` or `:`; folding everything else down to `_` leaves
# nothing that could escape the cache root, and nothing that could carry a
# newline past the `ls -dt` listing the LRU prune splits on. The entry always
# ends in `-${owner}-${repo}` (GitHub) or `+${repo}` (GitLab, below) with every
# part non-empty, so it can never be `.` or `..` either.
host_slug="${target_host,,}"
host_slug="${host_slug//[^a-z0-9._-]/_}"
# A refused parse — a ported URL, or anything else parse_remote will not name —
# leaves the host empty, which would file every unnamable endpoint under one
# key and reintroduce the collision for exactly the callers most likely to hit
# it. Those are keyed by the URL itself instead, via a checksum so the name
# stays a single readable path component.
if [[ -z "$host_slug" ]]; then
	host_slug="url-$(printf '%s' "$clone_url" | cksum | awk '{print $1}')"
fi
# A GitLab owner may nest subgroups, and its `/` must not become a nested
# directory under the cache root. Folding it into the `-` the GitHub key joins
# with would file group `g/sub` project `p` and group `g-sub` project `p` under
# one entry — the cross-repository reuse described above, between two projects
# on one host. GitLab keys are therefore joined with `+`, which neither a gated
# segment nor a host slug can contain: splitting the name on `+` recovers the
# host and every path segment exactly, so distinct projects never share an
# entry. GitHub keeps its `-` key so existing cache entries stay valid.
if [[ "$forge" == "gitlab" ]]; then
	dest="${cache_root}/${host_slug}+${owner//\//+}+${repo}"
else
	dest="${cache_root}/${host_slug}-${owner}-${repo}"
fi

mkdir -p "$cache_root" 2>/dev/null || {
	review_root="."
	emit "skip" "Cannot create clone cache; reviewing from diff only."
	exit 0
}

if [[ "$forge" == "gitlab" ]]; then
	# --- GitLab: the archive at the head sha ---
	# A private project cannot be cloned without a credential, and the only
	# credential here that is bound to the host is glab's. git cannot borrow it
	# safely: `glab auth git-credential get` answers with a token for any host
	# asked about, and `glab repo clone` defaults to SSH. So the tree is fetched
	# through glab's API instead — the repository archive at the merge request's
	# head sha — and every call goes through lib/forge/gitlab.sh's gate and
	# rc_forge_glab, which keep glab's token on hosts the user logged glab in to
	# and environment tokens on the host they are bound to.
	#
	# glab addresses a host by bare name and takes a port from its own config,
	# so a host that is empty (parse_remote refuses a ported URL) or does not
	# read as a hostname cannot be addressed at all.
	gl_host="${target_host,,}"
	if [[ ! "$gl_host" =~ ^[a-z0-9][a-z0-9.-]*$ ]]; then
		review_root="."
		emit "skip" "'${url}' names no GitLab host glab can address (a port is not supported); reviewing from diff only."
		exit 0
	fi
	if ! rc_forge_glab_admits "$gl_host" "$owner" "$repo"; then
		review_root="."
		emit "skip" "${RC_FORGE_GL_GATE[$gl_host]} Reviewing from diff only."
		exit 0
	fi
	# owner/repo are gated segments, so `/` is the only character to encode.
	project_api="projects/${owner//\//%2F}%2F${repo}"
	# The head sha comes from --head-sha (validated above) when preparation
	# passed it, else from the merge request itself. It names a cache
	# directory and goes into the archive request, so it must be exactly a
	# commit id: anything else is refused, not cleaned up.
	if [[ -z "$head_sha" ]]; then
		if ! mr_json=$(rc_forge_glab 30 "$gl_host" api --hostname "$gl_host" \
			"${project_api}/merge_requests/${pr}" 2>/dev/null); then
			review_root="."
			emit "skip" "Lookup of ${head_label} on ${gl_host} failed; reviewing from diff only."
			exit 0
		fi
		head_sha=$(jq -r '.sha // empty' <<<"$mr_json" 2>/dev/null || echo "")
	fi
	if [[ ! "$head_sha" =~ ^[0-9a-f]{40}$ ]]; then
		review_root="."
		emit "skip" "Merge request ${pr} on ${gl_host} reported no 40-hex head sha; reviewing from diff only."
		exit 0
	fi

	# --- What is cached, and what each run gets ---
	# The cache entry holds the archive file itself, `<sha>.tar.gz`, and
	# nothing else. An archive at a sha never changes, so a cached one cannot
	# go stale; a new sha replaces the entry's archive. Each run then unpacks
	# it into a tree of its own under the hidden `.runs/` directory and fetches
	# THIS run's changed files into it (below). Nothing a run returns as
	# review_root is ever written by another run, so two runs over one
	# project — two merge requests from one source branch, say — neither see
	# each other's changed files nor pull a tree out from under each other.
	# The archive is re-validated on every run, cached or not: the checks are
	# what make it safe to unpack, not a property of how it was fetched.
	#
	# The archive is the MR author's to shape, so it is bounded before
	# anything is unpacked, each by an environment cap: its own size, its
	# entry count, and the bytes it unpacks to (which the changed files fetched
	# below count against too). Every download and every tar run is bounded as
	# well: a download through `head -c` one byte past its cap, each tar under
	# rc_timeout, the unpacked size measured by streaming every member through
	# `head -c … | wc -c` (-O, common to GNU tar and bsdtar) rather than by
	# summing the sizes `tar -tv` prints: the two tars lay that listing out
	# differently, and an owner name holding spaces shifts the column in either.
	max_bytes=$(cap_from_env REVIEW_COUNCIL_ARCHIVE_MAX_BYTES 209715200)
	max_unpacked=$(cap_from_env REVIEW_COUNCIL_ARCHIVE_MAX_UNPACKED_BYTES 2147483648)
	max_entries=$(cap_from_env REVIEW_COUNCIL_ARCHIVE_MAX_ENTRIES 200000)
	max_changed=$(cap_from_env REVIEW_COUNCIL_MAX_CHANGED_FILES 300)
	archive="$dest/${head_sha}.tar.gz"
	# Removed on every exit until it is handed over: first the download
	# directory, then this run's tree.
	work=""
	trap '[[ -z "$work" ]] || rm_tree "$work"' EXIT
	cached=false downloaded=false
	[[ -f "$archive" && ! -L "$archive" ]] && cached=true
	if [[ "$cached" != true ]]; then
		# A hidden directory under the cache root, so the archive is renamed
		# into the entry on one filesystem and the LRU's `*/` never lists it.
		if ! work=$(mktemp -d "${cache_root}/.archive.XXXXXX" 2>/dev/null); then
			work=""
			review_root="."
			emit "skip" "Cannot create a download directory in the clone cache; reviewing from diff only."
			exit 0
		fi
		archive="$work/archive.tar.gz"
		if rc_forge_glab 120 "$gl_host" api --hostname "$gl_host" \
			"${project_api}/repository/archive.tar.gz?sha=${head_sha}" 2>/dev/null |
			head -c "$((max_bytes + 1))" >"$archive"; then
			downloaded=true
		else
			downloaded=false
		fi
	fi
	archive_bytes=$(wc -c <"$archive")
	if ((${archive_bytes//[^0-9]/} > max_bytes)); then
		review_root="."
		emit "skip" "The archive of ${head_label} is larger than REVIEW_COUNCIL_ARCHIVE_MAX_BYTES (${max_bytes} bytes); reviewing from diff only."
		exit 0
	fi
	if [[ "$cached" != true && "$downloaded" != true ]]; then
		review_root="."
		emit "skip" "Download of the archive of ${head_label} failed; reviewing from diff only."
		exit 0
	fi
	# The member list is streamed, never held: a listing of long paths runs to
	# gigabytes. awk stops at the first member that is absolute or has a `..`
	# component, or at the entry past the cap. Both GNU tar and bsdtar already
	# refuse to extract outside the target directory by default; this refuses
	# the archive outright before either is asked, so a tar that does not
	# cannot be handed one. A name holding a newline only splits into more
	# lines: more to check, and an over-count. An early stop ends tar with
	# SIGPIPE, so the verdict decides; only an "ok" verdict also needs tar to
	# have succeeded.
	if listing=$(rc_timeout 120 tar -tzf "$archive" 2>/dev/null | awk -v max="$max_entries" '
		$0 ~ /^\// || $0 == ".." || $0 ~ /^\.\.\// || $0 ~ /\/\.\.$/ || $0 ~ /\/\.\.\// { verdict = "unsafe"; exit }
		++n > max { verdict = "entries"; exit }
		END { print (verdict == "" ? "ok" : verdict) }'); then
		listed=true
	else
		listed=false
	fi
	case "$listing" in
	unsafe)
		review_root="."
		emit "skip" "The archive of ${head_label} names a path outside its tree; refusing it and reviewing from diff only."
		exit 0
		;;
	entries)
		review_root="."
		emit "skip" "The archive of ${head_label} holds more than REVIEW_COUNCIL_ARCHIVE_MAX_ENTRIES (${max_entries}) entries; reviewing from diff only."
		exit 0
		;;
	ok) [[ "$listed" == true ]] ;;
	*) false ;;
	esac || {
		review_root="."
		emit "skip" "The archive of ${head_label} could not be read; reviewing from diff only."
		exit 0
	}
	if unpacked=$(rc_timeout 120 tar -xzOf "$archive" 2>/dev/null | head -c "$((max_unpacked + 1))" | wc -c); then
		measured=true
	else
		measured=false
	fi
	unpacked="${unpacked//[^0-9]/}"
	if ((${unpacked:-0} > max_unpacked)); then
		review_root="."
		emit "skip" "The archive of ${head_label} unpacks to more than REVIEW_COUNCIL_ARCHIVE_MAX_UNPACKED_BYTES (${max_unpacked} bytes); reviewing from diff only."
		exit 0
	fi
	if [[ "$measured" != true ]]; then
		review_root="."
		emit "skip" "The archive of ${head_label} could not be read; reviewing from diff only."
		exit 0
	fi
	# A validated download replaces the whole entry: an archive at an older
	# sha, or a tree or clone left by an earlier layout of this cache.
	if [[ "$cached" != true ]]; then
		rm_tree "$dest"
		if [[ -e "$dest" ]] || ! mkdir "$dest" 2>/dev/null ||
			! mv "$archive" "$dest/${head_sha}.tar.gz" 2>/dev/null; then
			review_root="."
			emit "skip" "Cannot store the archive of ${owner}/${repo} in the clone cache; reviewing from diff only."
			exit 0
		fi
		archive="$dest/${head_sha}.tar.gz"
		rm_tree "$work"
		work=""
	fi

	# --- This run's tree ---
	if ! mkdir -p "${cache_root}/.runs" 2>/dev/null ||
		! work=$(mktemp -d "${cache_root}/.runs/${dest##*/}.XXXXXX" 2>/dev/null); then
		work=""
		review_root="."
		emit "skip" "Cannot create a review tree in the clone cache; reviewing from diff only."
		exit 0
	fi
	run_tree="$work"
	# GitLab wraps the tree in one `<repo>-<sha>-<sha>/` directory, which
	# --strip-components=1 removes. Owners are never taken from the archive
	# and modes are filtered through the umask (flags common to GNU tar and
	# bsdtar). Neither tar extracts through a symlink the archive itself
	# created (GNU tar defers symlinks to the end, bsdtar refuses the path),
	# and both refuse a hard link whose target leaves the directory.
	if ! rc_timeout 120 tar -xzf "$archive" -C "$run_tree" --strip-components=1 \
		--no-same-owner --no-same-permissions >/dev/null 2>&1; then
		review_root="."
		emit "skip" "The archive of ${head_label} could not be read; reviewing from diff only."
		exit 0
	fi

	# Anything that is not a regular file or a directory goes: a committed
	# symlink is the author's to aim, at /etc/passwd or at a credentials
	# file, and every reviewer reads this tree through it as though it were
	# repository content; a FIFO blocks the first reader. A regular file with
	# a second link goes too: git cannot commit a hard link, so one in the
	# tree came from the archive, not the repository.
	if ! special_files_removed=$(count_special "$run_tree") ||
		! remove_special "$run_tree" ||
		! remaining=$(count_special "$run_tree") || [[ "$remaining" != "0" ]]; then
		special_files_removed=""
		review_root="."
		emit "skip" "Could not remove the links and special files from the archive of ${head_label}; reviewing from diff only."
		exit 0
	fi

	# `git archive`, which GitLab builds the archive with, honours the
	# commit's own .gitattributes: `export-ignore` leaves a file out and
	# `export-subst` rewrites it with commit metadata. Both are the MR
	# author's to set, so the files THIS merge request changes — the ones
	# findings are anchored to — are fetched one by one as the exact blobs at
	# the head sha and written over the extracted tree, on every run: two
	# merge requests at one sha change different files. Without this a
	# hidden file strips every finding in it as FILE_NOT_FOUND: a false clean
	# review of the author's choosing.
	#
	# A deleted file is absent at the head and a submodule bump (mode 160000)
	# is not a file, so neither is fetched. Every listed path is validated as
	# the archive members are, and the list is capped.
	if ! diff_pages=$(rc_forge_glab 60 "$gl_host" api --hostname "$gl_host" --paginate \
		"${project_api}/merge_requests/${pr}/diffs?per_page=100" 2>/dev/null) ||
		! changed_json=$(jq -sc '
			if length > 0 and all(.[]; type == "array") then
				[(add // [])[] | select(.deleted_file != true and .b_mode != "160000") | .new_path]
			else error("not a listing") end' <<<"$diff_pages" 2>/dev/null); then
		review_root="."
		emit "skip" "Listing the changed files of ${head_label} failed; reviewing from diff only."
		exit 0
	fi
	if ! jq -e 'all(.[]; type == "string" and (test("[[:cntrl:]]") | not)
		and (startswith("/") | not)
		and all(split("/")[]; . != "" and . != "." and . != ".."))' <<<"$changed_json" >/dev/null 2>&1; then
		review_root="."
		emit "skip" "${head_label^} lists an unsafe changed path; refusing it and reviewing from diff only."
		exit 0
	fi
	changed_count=$(jq length <<<"$changed_json")
	if ((changed_count > max_changed)); then
		review_root="."
		emit "skip" "${head_label^} changes more than REVIEW_COUNCIL_MAX_CHANGED_FILES (${max_changed}) files; reviewing from diff only."
		exit 0
	fi
	# The changed files share the unpacked cap with the archive.
	budget=$((max_unpacked - ${unpacked:-0}))
	changed_paths=$(jq -r '.[]' <<<"$changed_json")
	while IFS= read -r path; do
		[[ -n "$path" ]] || continue
		# Every directory on the way must be a real directory and the file
		# itself must not be one, so no write lands through a link (they are
		# all gone already) or replaces a directory the archive made.
		IFS='/' read -r -a parts <<<"$path"
		target="$run_tree"
		for ((k = 0; k < ${#parts[@]}; k++)); do
			target="$target/${parts[$k]}"
			if [[ -L "$target" ]] || { [[ $k -lt $((${#parts[@]} - 1)) ]] && [[ -e "$target" && ! -d "$target" ]]; } ||
				{ [[ $k -eq $((${#parts[@]} - 1)) ]] && [[ -d "$target" ]]; }; then
				review_root="."
				emit "skip" "Changed file ${path} of ${head_label} collides with the archive's tree; reviewing from diff only."
				exit 0
			fi
		done
		path_enc=$(jq -rn --arg p "$path" '$p | @uri')
		# The blob is staged beside the tree, never inside it, and bounded
		# like the archive: one byte past what is left of the budget.
		if rc_forge_glab 30 "$gl_host" api --hostname "$gl_host" \
			"${project_api}/repository/files/${path_enc}/raw?ref=${head_sha}" 2>/dev/null |
			head -c "$((budget + 1))" >"${run_tree}.blob"; then
			fetched=true
		else
			fetched=false
		fi
		blob_bytes=$(wc -c <"${run_tree}.blob")
		blob_bytes="${blob_bytes//[^0-9]/}"
		if ((blob_bytes > budget)); then
			rm -f "${run_tree}.blob"
			review_root="."
			emit "skip" "The archive and changed files of ${head_label} unpack to more than REVIEW_COUNCIL_ARCHIVE_MAX_UNPACKED_BYTES (${max_unpacked} bytes); reviewing from diff only."
			exit 0
		fi
		budget=$((budget - blob_bytes))
		if [[ "$fetched" != true ]] || ! mkdir -p "${target%/*}" || ! mv -f "${run_tree}.blob" "$target"; then
			rm -f "${run_tree}.blob"
			review_root="."
			emit "skip" "Fetching changed file ${path} of ${head_label} failed; reviewing from diff only."
			exit 0
		fi
	done <<<"$changed_paths"

	if ! extracted=$(ls -A "$run_tree") || [[ -z "$extracted" ]]; then
		review_root="."
		emit "skip" "The archive of ${head_label} holds no files; reviewing from diff only."
		exit 0
	fi
	work=""
	review_root="$run_tree"
	ok_message="Materialized ${owner}/${repo} at ${head_label} (${head_sha}) from its archive into a tree for this run, changed files fetched exactly; removed ${special_files_removed} link(s) or special file(s)."
else
	clone_ok=false
	if [[ -d "$dest/.git" ]]; then
		# Reuse existing clone.
		clone_ok=true
	else
		# Prefer gh (auth); flags after -- are passed to git clone.
		# `gh repo clone OWNER/REPO` resolves against gh's own default host, so on
		# any other host it would clone a same-named repository from github.com
		# rather than the one asked for. Every other host goes straight to git,
		# which honours the URL and the operator's credential helper. So does every
		# other forge: gh can only ever name a GitHub repository.
		if [[ "$forge" == "github" ]] && [[ "$target_host" == "github.com" ]] && command -v gh >/dev/null 2>&1; then
			if rc_timeout 120 "${no_prompt[@]}" gh repo clone "${owner}/${repo}" "$dest" -- --filter=blob:none --no-checkout >/dev/null 2>&1; then
				clone_ok=true
			fi
		fi
		# Plain blobless partial clone. Clear any partial dest a failed gh clone
		# may have left behind, or this clone aborts with "destination exists".
		if [[ "$clone_ok" != true ]]; then
			rm -rf "$dest" 2>/dev/null
			if rc_timeout 120 "${no_prompt[@]}" ${gh_auth[@]+"${gh_auth[@]}"} git clone --filter=blob:none --no-checkout -- "$clone_url" "$dest" >/dev/null 2>&1; then
				clone_ok=true
			fi
		fi
		# Shallow fallback.
		if [[ "$clone_ok" != true ]]; then
			rm -rf "$dest" 2>/dev/null
			if rc_timeout 120 "${no_prompt[@]}" ${gh_auth[@]+"${gh_auth[@]}"} git clone --depth 50 -- "$clone_url" "$dest" >/dev/null 2>&1; then
				clone_ok=true
			fi
		fi
	fi

	if [[ "$clone_ok" != true ]]; then
		review_root="."
		emit "skip" "Clone of ${owner}/${repo} failed; reviewing from diff only."
		exit 0
	fi

	# Fetch the PR/MR head ref (works for forks on the base repo) and check it out.
	if ! rc_timeout 120 "${no_prompt[@]}" ${gh_auth[@]+"${gh_auth[@]}"} git -C "$dest" fetch origin "$head_ref" >/dev/null 2>&1; then
		review_root="."
		emit "skip" "Fetch of ${head_label} failed; reviewing from diff only."
		exit 0
	fi
	# A committed symlink is the author's to aim, at /etc/passwd or a
	# credentials file, and every reviewer reads this tree as repository
	# content. With core.symlinks=false git writes each link as a regular file
	# holding its target text: the path still exists for reviewers, and nothing
	# behind it is reachable. The setting goes in the cache clone's own config,
	# never the operator's. A link an earlier checkout (or the shallow
	# fallback's clone) already wrote is deleted first and the checkout is
	# forced, because git leaves a path it believes unchanged exactly as it is
	# on disk.
	if ! git -C "$dest" config core.symlinks false >/dev/null 2>&1 ||
		! find "$dest" -path "$dest/.git" -prune -o -type l -exec rm -f {} + 2>/dev/null; then
		review_root="."
		emit "skip" "Could not make the symlinks in the ${owner}/${repo} cache inert; reviewing from diff only."
		exit 0
	fi
	# Checkout populates the working tree; a blobless --no-checkout clone has no
	# files until this runs. If it fails, the tree is empty and every finding
	# would be stripped FILE_NOT_FOUND (a false-clean review), so fall back to
	# diff-only review instead of emitting a misleading "ok".
	if ! "${no_prompt[@]}" ${gh_auth[@]+"${gh_auth[@]}"} git -C "$dest" checkout -q -f FETCH_HEAD >/dev/null 2>&1; then
		review_root="."
		emit "skip" "Checkout of ${head_label} failed; reviewing from diff only."
		exit 0
	fi
	review_root="$dest"
	ok_message="Materialized ${owner}/${repo} at ${head_label} into cache."
fi

# Fail closed. Whichever path built the tree, no reviewer may meet a live
# symlink in it: GitHub writes links as plain files and GitLab deletes them,
# and either going wrong lands here instead of in front of a reviewer. A
# GitLab run tree is this run's alone, so it goes with the refusal.
if ! live_links=$(find "$review_root" -path "$review_root/.git" -prune -o -type l -print 2>/dev/null) ||
	[[ -n "$live_links" ]]; then
	if [[ -n "${run_tree:-}" ]]; then
		rm_tree "$run_tree" 2>/dev/null || true
	fi
	review_root="."
	emit "skip" "A symlink survived materializing ${head_label}; reviewing from diff only."
	exit 0
fi

# Mark as most-recently-used for LRU.
touch "$dest" 2>/dev/null || true

# --- LRU prune: keep newest N clone dirs (by mtime), remove the rest ---
# Use `ls -dt` (POSIX) rather than `find -printf` (GNU-only) so the cap is
# enforced on macOS too — rc-lib.sh explicitly accommodates non-GNU hosts.
cap=$(cap_from_env REVIEW_COUNCIL_CLONE_CACHE_MAX 10)
# shellcheck disable=SC2012,SC2312 # `find -printf`/`-newermt` sorting is GNU-only
# and this cap must hold on macOS too. Entry names are
# "${host_slug}-${owner}-${repo}" or "${host_slug}+<segments joined by +>",
# every part reduced to ^[a-zA-Z0-9._-]+$ before it gets here, and mapfile
# splits on newlines, so the non-alphanumeric-filename hazard SC2012 warns
# about cannot arise. Entries left behind by an older key
# shape are listed too: nothing touches them any more, so they sort oldest and
# are the first evicted. An empty or missing cache_root legitimately yields no
# entries. A GitLab entry is one directory holding its archive, listed and
# evicted whole; a GitLab download in progress (`.archive.*`) and the per-run
# trees (`.runs/`) are hidden, so `*/` never lists them and evicting an entry
# never pulls a tree out from under a running review. Everything is removed
# with rm_tree: an extracted archive may hold read-only directories.
mapfile -t by_age < <(ls -dt "$cache_root"/*/ 2>/dev/null | sed 's:/*$::')
if [[ ${#by_age[@]} -gt $cap ]]; then
	for ((k = cap; k < ${#by_age[@]}; k++)); do
		# Never prune the just-created destination.
		[[ "${by_age[$k]}" == "$dest" ]] && continue
		rm_tree "${by_age[$k]}" 2>/dev/null || true
	done
fi
# A download directory outlives its run only when the run was killed before
# its EXIT trap. An hour is far past any run's timeouts, so one that old is
# abandoned, not another run's work in progress. -mmin is not POSIX but GNU
# and BSD find both have it.
abandoned=$(find "$cache_root" -mindepth 1 -maxdepth 1 -type d -name '.archive.*' -mmin +60 2>/dev/null || true)
# A GitLab run's tree is review_root for as long as its review runs, and
# nothing tells this script when that is over. Reviews take minutes, so a tree
# is kept for six hours and then removed, as is a blob a killed run left staged
# beside its tree. The trade-off: a session resumed after that has lost its
# review_root, and evidence checks strip its findings until preparation is run
# again — accepted, against trees of up to the unpacked cap each sitting on
# disk for a day.
abandoned+=$'\n'$(find "$cache_root/.runs" -mindepth 1 -maxdepth 1 -mmin +360 2>/dev/null || true)
# Age alone does not bound the disk: a batch over many merge requests leaves a
# tree per review inside six hours. So only the newest
# REVIEW_COUNCIL_MAX_RUN_TREES trees are kept, by mtime with `ls -dt` as in the
# LRU above.
max_run_trees=$(cap_from_env REVIEW_COUNCIL_MAX_RUN_TREES 8)
# Only GitLab makes run trees, so on GitHub .runs is routinely missing or
# empty. An unmatched glob stays literal and names no directory; listing it
# would fail, and the error trap would report that as a broken command.
runs_by_age=()
run_trees=("$cache_root"/.runs/*/)
# shellcheck disable=SC2012,SC2312 # as in the LRU above: run tree names are
# an entry name plus mktemp's alphanumeric suffix, nothing ls could mangle.
if [[ -d "${run_trees[0]}" ]]; then
	mapfile -t runs_by_age < <(ls -dt "${run_trees[@]}" 2>/dev/null | sed 's:/*$::')
fi
for ((k = max_run_trees; k < ${#runs_by_age[@]}; k++)); do
	abandoned+=$'\n'"${runs_by_age[$k]}"
done
# The tree this run has just returned as review_root is never removed, however
# old its mtime reads or however many trees are newer.
while IFS= read -r stale; do
	[[ -z "$stale" || "$stale" == "${run_tree:-}" ]] || rm_tree "$stale" 2>/dev/null || true
done <<<"$abandoned"

emit "ok" "${ok_message}${inplace_note}"
exit 0
