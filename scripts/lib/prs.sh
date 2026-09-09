#!/usr/bin/env bash
# Pull-request lookups against the forge, and the classification that turns
# them into buckets. Source this file; do not execute it.
#
# Requires common.sh and comments.sh to be sourced first: the classifier reads
# IGNORE_EMAIL_LIST and the effort thresholds from one, and every marker reader
# from the other.
#
# Input globals the caller owns:
#
#   REPO        "owner/name". resolve_target sets it and every other function
#               here reads it, so resolve_target must run first.
#   TARGET_PR   set by resolve_target: the single PR named on the command line,
#               or empty for "every open PR". A NON-EMPTY value also disables
#               the author deny-list in classify_prs — naming a PR says which
#               PR you want, so an explicit target is never filtered out from
#               under you.
#   WINDOW_START  the trailing-hour boundary classify_prs measures against.
#   VERDICT_SCOPE whose verdicts classify_prs counts: "self" (only the account
#               gh is authenticated as), "all" (any account), or a single
#               login. UNSET MEANS "self", which is the safe reading and the
#               one the driver relies on — see classify_prs.
#   IGNORE_APPROVED  1 to drop PRs the forge reports as approved before they
#               are classified at all. UNSET MEANS 0: this library is shared
#               with a read-only status script that reports on every open PR,
#               and a filter it never asked for would lose PRs from its report
#               rather than save it money.
#
# PER-PR LOOKUPS FAIL OPEN — an unanswered gh call resolves to "this PR needs
# review", because the cost of a wrong answer is one duplicate review. Two
# functions are deliberately not per-PR lookups and do not follow that rule:
# requester_authorised fails closed, and collect_prs fails loud. Both say why
# in their own comments.
#
# shellcheck shell=bash
# shellcheck disable=SC2250 # Bare $var, as every other shell source here writes
# it. Enabling the braces-always style in these files would make them the only
# ones of their kind in the tree; consistency is worth more than the check.
#
# shellcheck disable=SC2154 # DEEP_FILES, QUICK_FILES, SECURITY_PATHS and
# IGNORE_EMAIL_LIST are set by common.sh, and WINDOW_START by the entry script,
# which sources this file after both (see above). `shellcheck -x` resolves all
# five through that entry script, but `task lint` also checks this file
# standalone, where they look unassigned; this code is the price of that second
# pass.

[[ -n "${_RC_PRS_LOADED:-}" ]] && return 0
_RC_PRS_LOADED=1

# resolve_target <target> -> sets REPO and TARGET_PR.
#
# <target> may be empty (every open PR), a bare PR number, or a GitHub PR URL.
# A URL also fixes the repository, and disagreeing with an explicit --repo is
# an error rather than a silent winner: the two spellings name different
# repositories and there is no reading of the command that wants one of them
# discarded.
#
# The host is anchored at the start of the string, and the owner and repo are
# then checked against GitHub's own naming rules. Both matter, because whatever
# comes out of here is the repository this tool reviews and comments on
# publicly. Unanchored, `github.com/o/r/pull/1` matched anywhere in the string,
# so a mirror (mygithub.com/...), a redirector (evil.com/github.com/...), a
# non-web scheme (ftp://github.com/...) and a sentence with a link in it all
# resolved to a github.com repository the operator never named. Unvalidated,
# `github.com/../../pull/4` captured `..`/`..`, which requester_authorised
# would then interpolate into the API path `repos/../../collaborators/...`.
resolve_target() {
	local target="$1" url_owner url_repo
	TARGET_PR=""
	if [[ -n "$target" ]]; then
		if [[ "$target" =~ ^[0-9]+$ ]]; then
			TARGET_PR="$target"
		elif [[ "$target" =~ ^(https?://)?(www\.)?github\.com/([^/?#]+)/([^/?#]+)/pull/([0-9]+) ]]; then
			url_owner="${BASH_REMATCH[3]}"
			url_repo="${BASH_REMATCH[4]%.git}"
			TARGET_PR="${BASH_REMATCH[5]}"
			# GitHub logins are alphanumeric with hyphens; repository names add
			# `.` and `_`. A name of nothing but dots is a path traversal
			# wearing a repository's clothes, and GitHub reserves it anyway.
			if [[ ! "$url_owner" =~ ^[A-Za-z0-9-]+$ ]] ||
				[[ ! "$url_repo" =~ ^[A-Za-z0-9._-]+$ ]] || [[ "$url_repo" =~ ^\.+$ ]]; then
				echo "Not a usable owner/name in that PR URL: '${url_owner}/${url_repo}'." >&2
				exit 2
			fi
			if [[ -n "${REPO:-}" ]] && [[ "$REPO" != "${url_owner}/${url_repo}" ]]; then
				echo "Conflicting repository: --repo '${REPO}' vs URL '${url_owner}/${url_repo}'." >&2
				exit 2
			fi
			REPO="${url_owner}/${url_repo}"
		else
			echo "Target must be a PR number or a GitHub PR URL, got: ${target}" >&2
			exit 2
		fi
	fi

	# No explicit repo? Fall back to the GitHub repo of the current directory.
	if [[ -z "${REPO:-}" ]]; then
		REPO="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)"
	fi
	if [[ -z "$REPO" ]]; then
		echo "Could not determine the target repository." >&2
		echo "Pass --repo owner/name, give a PR URL, or run inside a checkout of the repo." >&2
		exit 1
	fi
}

# collect_prs -> "<number>\t<headRefOid>" lines on stdout, and one of:
#
#   0  the lookup answered. Output may still be empty, which means the
#      repository genuinely has no open PRs.
#   1  a PR was named and could not be read.
#   2  the listing itself failed.
#
# THIS IS THE ONE LOOKUP HERE THAT FAILS LOUD. Everywhere else an unanswered gh
# call means "review it". Here an empty answer is indistinguishable from "there
# is nothing to review", so failing open would turn a typo'd --repo, a 502 or a
# secondary rate limit into "everything is reviewed, nothing to do" — a silent
# success at zero work, which for a tool that spends money and comments in
# public is the worst outcome available.
#
# The status is a RETURN VALUE and not an exit or an errexit abort, because
# neither of those crosses the boundary a caller puts around this. Bash unsets
# errexit inside a command-substitution subshell unless `shopt -s inherit_errexit`
# is set, and nothing in this tree sets it; since every caller reads stdout with
# `raw="$(collect_prs)"`, a failing gh in here aborts nothing and an `exit`
# would only end the substitution. A return value survives both.
#
# The wording of each failure is left to the caller, as the empty case is: "no
# open PRs" and "the lookup broke" read differently to the driver (nothing to
# review) and to the status script (nothing to report), and a library that
# phrases or exits on them is one neither caller can compose.
collect_prs() {
	local raw
	if [[ -n "${TARGET_PR:-}" ]]; then
		raw="$(gh pr view "$TARGET_PR" --repo "$REPO" \
			--json number,headRefOid --jq '[.number, .headRefOid] | @tsv' 2>/dev/null)" || return 1
		[[ -n "$raw" ]] || return 1
	else
		# gh's own stderr is left alone here: when this fails the operator is
		# about to be told the listing broke, and gh's message is the only
		# thing that says why.
		raw="$(gh pr list --repo "$REPO" --state open --limit 500 \
			--json number,headRefOid --jq 'sort_by(.number) | reverse | .[] | [.number, .headRefOid] | @tsv')" || return 2
	fi
	printf '%s' "$raw"
}

# comments_for <pr> -> the PR's comment timeline as gh returns it, or empty on
# failure. Fetched once per PR and handed to each reader below, so one request
# answers the verdict, the re-review requests and the rate-limit ledger.
comments_for() {
	gh pr view "$1" --repo "$REPO" --json comments 2>/dev/null || true
}

# requester_authorised <login> <association> -> success when this account may
# spend a review. Two gates, cheap one first: authorAssociation arrives with the
# comment payload and rules out everyone with no standing in the repo, so the
# API call happens only for a plausible requester.
#
# THIS IS THE ONE LOOKUP HERE THAT FAILS CLOSED. Everywhere else an unanswered
# gh call means "review it", because a duplicate review costs one review. Here
# it would mean "let a stranger start reviews", and that cost has no ceiling. An
# unreadable answer is not permission.
#
# `.permission` is the legacy four-value field (admin|write|read|none) and it
# folds the finer roles the way this wants them folded: maintain reports as
# write, triage reports as read. Triage can label and close but cannot push,
# and should not be able to spend the API budget either.
requester_authorised() {
	local login="$1" assoc="$2" perm
	case "$assoc" in
	OWNER | MEMBER | COLLABORATOR) ;;
	*) return 1 ;;
	esac
	# The login is interpolated into an API path. GitHub logins are alphanumeric
	# with hyphens; anything else is refused rather than sent.
	[[ "$login" =~ ^[A-Za-z0-9-]+$ ]] || return 1
	perm="$(gh api "repos/${REPO}/collaborators/${login}/permission" \
		--jq '.permission' 2>/dev/null || true)"
	[[ "$perm" = "admin" || "$perm" = "write" ]]
}

# requested_rereview <pr> <comments-json> <since> -> success when an authorised
# request is outstanding on this PR. Records the requester, which the rate
# limiter and the decline reply both read.
requested_rereview() {
	local pr="$1" json="$2" since="$3" login at assoc requests
	requests="$(rereview_requests_for "$json" "$since")"
	while IFS=$'\t' read -r login at assoc; do
		[[ -n "$login" ]] || continue
		# shellcheck disable=SC2310 # A non-zero return is "not authorised" —
		# the expected answer, not an error — and the one call inside that can
		# genuinely fail absorbs its own failure to reach it.
		if requester_authorised "$login" "$assoc"; then
			REQ_PR+=("$pr")
			REQ_LOGIN+=("$login")
			REQ_AT+=("$at")
			return 0
		fi
	done <<<"$requests"
	return 1
}

# ignored_author <pr> -> success when the PR was written entirely by addresses
# on IGNORE_EMAIL_LIST, and so should not be reviewed at all.
#
# "Entirely", not "at all": one human commit on a Renovate branch is human work
# and has to come back for review, and a rebase or merge commit a bot authored
# must not disqualify a human's PR. The `seen` guard makes the empty case false
# rather than vacuously true, so a gh failure (which yields no addresses) fails
# open to reviewing — the same stance council_verdict_for takes.
ignored_author() {
	local pr="$1" emails email pattern hit seen=0
	[[ "${#IGNORE_EMAIL_LIST[@]}" -gt 0 ]] || return 1
	emails="$(gh pr view "$pr" --repo "$REPO" --json commits \
		--jq '.commits[].authors[].email' 2>/dev/null || true)"
	[[ -n "$emails" ]] || return 1
	while IFS= read -r email; do
		[[ -n "$email" ]] || continue
		hit=0
		for pattern in "${IGNORE_EMAIL_LIST[@]}"; do
			# Whole-address compare, lowercased on both sides. Not a glob:
			# "[bot]" in these addresses is a literal, and `==` would read it
			# as a one-character bracket expression.
			if [[ "${email,,}" = "${pattern,,}" ]]; then
				hit=1
				break
			fi
		done
		[[ "$hit" -eq 1 ]] || return 1
		seen=1
	done <<<"$emails"
	[[ "$seen" -eq 1 ]]
}

# approved_pr <pr> -> success when the forge reports the PR as approved, and so
# it should not be reviewed under --ignore-approved.
#
# `reviewDecision` is GitHub's own summary of the human reviews on a PR, and it
# reports exactly one of APPROVED, CHANGES_REQUESTED, REVIEW_REQUIRED or
# nothing at all. Only the first is an approval: the other two both mean the PR
# is still waiting on somebody, and "no decision" is what an unreviewed PR in a
# repository with no review requirement looks like.
#
# Compared as an exact value rather than a substring, and a lookup that answers
# nothing is not an approval, so a gh failure fails open to reviewing — the
# same stance ignored_author and council_verdict_for take.
#
# Note what this reads and what it does not: reviewDecision is a statement
# about the PR's current review state, not about the commit that state was
# reached on. GitHub keeps an approval across later pushes unless the branch is
# protected with "dismiss stale approvals", so a PR approved and then pushed to
# still reports APPROVED here and is still skipped. That is the flag doing what
# it says; a run that wants those commits looked at leaves it off.
approved_pr() {
	local decision
	decision="$(gh pr view "$1" --repo "$REPO" --json reviewDecision \
		--jq '.reviewDecision // ""' 2>/dev/null || true)"
	[[ "$decision" = "APPROVED" ]]
}

# effort_for <pr> -> quick | standard | deep
# Classify a PR's review depth from its GitHub metadata so a trivial change is
# not sent through an expensive deep review. --effort overrides the result. A
# gh/jq failure fails open to standard (full verification, no subsystem
# fan-out) rather than deep, so a transient lookup error cannot silently
# escalate cost.
effort_for() {
	local pr="$1" json files is_bot
	if [[ -n "$FORCE_EFFORT" ]]; then
		printf '%s' "$FORCE_EFFORT"
		return
	fi
	json="$(gh pr view "$pr" --repo "$REPO" \
		--json changedFiles,author,files 2>/dev/null || true)"
	[[ -n "$json" ]] || {
		printf 'standard'
		return
	}
	# `|| true` keeps a jq failure from tripping errexit/the ERR trap; the
	# numeric guard and the "0"/"1" defaults below make the fallback explicit.
	files="$(printf '%s' "$json" | jq -r '.changedFiles // 0' 2>/dev/null || true)"
	[[ "$files" =~ ^[0-9]+$ ]] || files=0
	is_bot="$(printf '%s' "$json" | jq -r 'if (.author.is_bot // false) then 1 else 0 end' 2>/dev/null || true)"
	# shellcheck disable=SC2312 # The entry scripts that source this file both
	# set `-o pipefail` before doing so, so jq's exit status is not actually
	# masked here at runtime — only a standalone lint pass of this file, which
	# sees no `set` line at all, cannot tell that.
	if [[ "$files" -ge "$DEEP_FILES" ]] ||
		printf '%s' "$json" | jq -r '.files[].path' 2>/dev/null | grep -qiE "$SECURITY_PATHS"; then
		printf 'deep'
	elif [[ "$is_bot" = 1 ]] && [[ "$files" -le "$QUICK_FILES" ]]; then
		printf 'quick'
	else
		printf 'standard'
	fi
}

# Each PR's comment timeline and the verdict it was classified against, kept
# past classify_prs so later readers need no second fetch. The driver's decline
# reply already asks COMMENTS_JSON whether it has replied before; the recorded
# sha and timestamp are here so that a second caller can report what a PR was
# reviewed at without running the classification a second way.
#
# File scope, not function scope: `declare -A` inside a function makes the array
# local to that function, which would leave every caller reading an empty map.
declare -A COMMENTS_JSON
declare -A REVIEWED_SHA
declare -A REVIEWED_AT
declare -A REVIEWED_BY
declare -A REVIEWED_IS_OURS

# classify_prs <prs-tsv> -> populates the globals below from a
# "<number>\t<headRefOid>" list. Globals rather than return values because bash
# has no record type, and because rc-prepare.sh already establishes stages
# communicating through documented globals.
#
#   UNREVIEWED[]  no usable prior verdict
#   STALE[]       a verdict exists, but at an older commit
#   SKIPPED[]     reviewed at head, nobody asked for another look
#   REQUESTED[]   reviewed at head, an authorised request is outstanding
#   IGNORED[]     every commit author is on IGNORE_EMAIL_LIST
#   IGNORED_APPROVED[]  the forge reports the PR as approved, and the caller
#                 set IGNORE_APPROVED. Always empty when it did not.
#   FOREIGN[]     "<pr>:<login>" — a marker this account did not post
#   REQ_PR[] REQ_LOGIN[] REQ_AT[]   the outstanding authorised requests
#   SPENT                 verdicts this account posted in the trailing hour
#   OLDEST_IN_WINDOW      earliest verdict still inside that hour
#   COMMENTS_JSON[pr]     the fetched timeline, kept for later readers
#   REVIEWED_SHA[pr] REVIEWED_AT[pr]   the verdict this PR was classified on
#   REVIEWED_BY[pr]       the login that posted it, empty under VERDICT_SCOPE
#                         "self" — council_verdict_for reports no login, and
#                         the answer there is "this account" by construction
#   REVIEWED_IS_OURS[pr]  1 when that comment was ours, else 0
#
# The three request arrays are parallel — which PR, who asked, and when — and
# are read by the driver's hourly cap and by the reply it posts when it defers
# a request.
#
# The last row is what lets a second caller report on a PR without a second
# copy of this loop. The driver discards both values after bucketing; recording
# them costs nothing and keeps one implementation of the rules.
#
# Every array is reset on entry, so a second call in one process reports on the
# list it was given rather than on that list plus the previous one.
#
# WINDOW_START must be set by the caller before this runs.
classify_prs() {
	local prs_raw="$1"
	local pr head comments_json verdict_tsv reviewed reviewed_at foreign spent_here
	local reviewed_by reviewed_ours

	UNREVIEWED=()
	STALE=()
	SKIPPED=()
	IGNORED=()
	IGNORED_APPROVED=()
	REQUESTED=()
	FOREIGN=()
	REQ_PR=()
	REQ_LOGIN=()
	REQ_AT=()
	COMMENTS_JSON=()
	REVIEWED_SHA=()
	REVIEWED_AT=()
	REVIEWED_BY=()
	REVIEWED_IS_OURS=()
	SPENT=0
	OLDEST_IN_WINDOW=""

	while IFS=$'\t' read -r pr head; do
		[[ -n "$pr" ]] || continue
		# The deny-list is batch triage. Naming one PR by number or URL says which
		# PR you want, so an explicit target is never filtered out from under you.
		#
		# shellcheck disable=SC2310 # Suspending errexit inside ignored_author is
		# what this call wants: a non-zero return is its "not ignored" answer, not
		# an error, and the one command in it that can genuinely fail (gh) already
		# absorbs its own failure with `|| true` to fail open. There is nothing
		# here for set -e to catch.
		if [[ -z "${TARGET_PR:-}" ]] && ignored_author "$pr"; then
			IGNORED+=("$pr")
			continue
		fi
		# Batch triage too, and for the same reason, so it is gated on
		# TARGET_PR the same way. Second because this check costs a request:
		# a PR the deny-list has already dropped never pays for one.
		#
		# shellcheck disable=SC2310 # as ignored_author above: a non-zero return
		# is this predicate's "not approved" answer, not a failure.
		if [[ -z "${TARGET_PR:-}" ]] && [[ "${IGNORE_APPROVED:-0}" -eq 1 ]] && approved_pr "$pr"; then
			IGNORED_APPROVED+=("$pr")
			continue
		fi
		comments_json="$(comments_for "$pr")"
		# shellcheck disable=SC2034 # written here, read by the scripts that source this file
		COMMENTS_JSON["$pr"]="$comments_json"
		spent_here="$(verdicts_since "$comments_json" "$WINDOW_START")"
		[[ "$spent_here" =~ ^[0-9]+$ ]] || spent_here=0
		SPENT=$((SPENT + spent_here))
		# The default is "self", and it is a default with money behind it: the
		# marker is public, so counting a verdict this account did not post
		# lets anyone who can comment pin a PR at its current head and suppress
		# every later review. A caller that sets nothing therefore gets the
		# gated reader, and the driver sets nothing.
		if [[ "${VERDICT_SCOPE:-self}" = "self" ]]; then
			verdict_tsv="$(council_verdict_for "$comments_json")"
			IFS=$'\t' read -r reviewed reviewed_at <<<"$verdict_tsv"
			# viewerDidAuthor IS that reader's gate, so anything it returns is
			# ours. It reports no login and nothing here goes looking for one:
			# the account is the one gh is authenticated as, and asking the API
			# for its name would be a request spent on a value already known.
			reviewed_by=""
			reviewed_ours=1
		else
			verdict_tsv="$(council_verdict_any_for "$comments_json" "$VERDICT_SCOPE")"
			IFS=$'\t' read -r reviewed reviewed_at reviewed_by reviewed_ours <<<"$verdict_tsv"
			[[ "$reviewed_ours" = "1" ]] || reviewed_ours=0
		fi
		if [[ -n "$reviewed_at" ]] && [[ "$reviewed_at" > "$WINDOW_START" ]]; then
			if [[ -z "$OLDEST_IN_WINDOW" ]] || [[ "$reviewed_at" < "$OLDEST_IN_WINDOW" ]]; then
				OLDEST_IN_WINDOW="$reviewed_at"
			fi
		fi
		# A sha that is not a sha is not a verdict. Fails open, as everywhere here.
		[[ "$reviewed" =~ ^[0-9a-fA-F]{7,40}$ ]] || reviewed=""
		# The pair is recorded here rather than at the parse above, so a reader
		# gets what this PR was actually classified on: an unparseable marker
		# stores empty, not the garbage it was written as. The timestamp is
		# blanked with the sha for the same reason — the two are one answer, and
		# a PR reported as never reviewed must not carry a review time beside
		# it. This is after the OLDEST_IN_WINDOW test on purpose: the rate-limit
		# ledger counts what this account posted, which a malformed marker of
		# ours still is.
		# The author travels with the pair for the same reason: a PR reported
		# as never reviewed must not carry a reviewer's name beside it.
		[[ -n "$reviewed" ]] || {
			reviewed_at=""
			reviewed_by=""
			reviewed_ours=0
		}
		# shellcheck disable=SC2034 # written here, read by the scripts that source this file
		REVIEWED_SHA["$pr"]="$reviewed"
		# shellcheck disable=SC2034 # written here, read by the scripts that source this file
		REVIEWED_AT["$pr"]="$reviewed_at"
		# shellcheck disable=SC2034 # written here, read by the scripts that source this file
		REVIEWED_BY["$pr"]="$reviewed_by"
		# shellcheck disable=SC2034 # written here, read by the scripts that source this file
		REVIEWED_IS_OURS["$pr"]="$reviewed_ours"
		if [[ -z "$reviewed" ]]; then
			foreign="$(foreign_verdict_login "$comments_json")"
			[[ -z "$foreign" ]] || FOREIGN+=("${pr}:${foreign}")
		fi
		if [[ -z "$reviewed" ]]; then
			UNREVIEWED+=("$pr")
		elif [[ "$reviewed" = "$head" ]]; then
			# Nothing new to review — unless someone with write access asked.
			#
			# shellcheck disable=SC2310 # as ignored_author above: a non-zero return
			# is this predicate's "no request" answer, not a failure.
			if requested_rereview "$pr" "$comments_json" "$reviewed_at"; then
				REQUESTED+=("$pr")
			else
				SKIPPED+=("$pr")
			fi
		else
			STALE+=("$pr")
		fi
	done <<<"$prs_raw"
}
