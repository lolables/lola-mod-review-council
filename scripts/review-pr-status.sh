#!/usr/bin/env bash
#
# review-pr-status.sh
#
# Report where every open pull request of a GitHub repository stands with
# respect to Review Council — or just the one PR you name. The target
# repository and PR are resolved from the arguments and the current directory,
# so the script is not tied to any one project.
#
# THIS SCRIPT NEVER WRITES. It posts no comment, invokes no agent CLI and
# spends nothing. Every call it makes is a read, and the report is the whole of
# its output — which is what makes it safe to run on a timer, against someone
# else's repository, or while a batch review is already going.
#
# It is the companion to review-open-prs.sh and shares that script's
# classification code (scripts/lib/), so what it reports is what the driver
# would act on rather than a second opinion about it. A PR shown here as
# "unreviewed" is a PR review-open-prs.sh would queue.
#
# The state vocabulary, one word per PR:
#
#   unreviewed   no usable prior verdict
#   stale        a verdict exists, but for an older commit
#   requested    reviewed at head, and someone with write access has asked
#                for another look in a comment
#   up-to-date   reviewed at head, and nobody has asked for more
#   ignored      every commit author is on the ignore list (see below), so the
#                driver would drop this PR before it reached the queue
#
# A trailing * on the state means the verdict it rests on came from an account
# other than the one you are authenticated as — see --account below.
#
# The table beneath the summary carries one row per PR:
#
#   PR         the pull request number
#   STATE      one of the words above
#   VERDICT    the verdict word of the review the STATE was derived from
#              ("APPROVE", "REQUEST CHANGES", ...), read from that same comment
#              under the same --account scope and shown verbatim rather than
#              mapped onto a known vocabulary. Long verdicts are clipped so one
#              of them cannot break the alignment of every other row. A review
#              whose comment carries no heading shows an em dash.
#   BY         the account whose verdict the STATE was derived from. An em
#              dash under --account self, where the answer is the account you
#              are authenticated as and no lookup is spent to spell it out.
#              This column alone widens to fit the longest name in it, because
#              a clipped login is not merely ugly — you cannot paste it back
#              into --account.
#   REVIEWED   how long ago that review was posted
#   WOULD RUN  the depth this PR would be reviewed at if it were queued now
#              (quick, standard or deep — see the Environment section). A
#              forecast from the PR's current size and paths, not a record of
#              anything: an unreviewed PR has one too. An ignored PR shows
#              none, because it would not be reviewed at all.
#
# A value that does not exist — no verdict, no review time — is shown as an em
# dash rather than as a blank or a zero.
#
# --json replaces the table with one machine-readable envelope on stdout, and
# suppresses every human decoration that goes with the table: no summary line,
# no ledger line, no asterisk, no footnote — the envelope is the entire output,
# which is what makes it safe to pipe into `jq`. An absent value is JSON
# `null` there, never `""` and never the table's em dash; `reviewed_is_ours` is
# a real boolean, the machine-readable form of the table's `*` suffix, so a
# reader does not have to scrape a presentation character back out of a
# string. The `effort` key keeps that name even though the table column above
# it is headed WOULD RUN — the rename was a presentation fix, and renaming the
# JSON key alongside it would have been a gratuitous API break for no reader.
#
#   {
#     "repo": "owner/name",
#     "generated_at": "2026-08-23T14:00:00Z",
#     "account_scope": "all",
#     "window": {
#       "start": "2026-08-23T13:00:00Z",
#       "spent": 2,
#       "limit": 3,
#       "next_slot": "2026-08-23T15:04:05Z"
#     },
#     "pull_requests": [
#       {
#         "number": 123,
#         "state": "up-to-date",
#         "head": "c3d4e5f...",
#         "reviewed_sha": "a1b2c3d...",
#         "reviewed_at": "2026-08-23T12:00:00Z",
#         "reviewed_by": "council-bot",
#         "reviewed_is_ours": true,
#         "verdict": "REQUEST CHANGES",
#         "effort": "deep",
#         "foreign_marker": null
#       }
#     ]
#   }
#
# `window.limit` is `null` when REREVIEW_PER_HOUR is unset (uncapped). The
# envelope is assembled with `jq -n`/`jq -nc` from shell variables passed as
# `--arg`/`--argjson`, never by string concatenation, so a login, verdict or
# repo name containing a quote, backslash or newline cannot break the document.
#
# --tsv replaces the table with one tab-separated line per pull request and no
# header line, for the shell pipeline that wants a column rather than a
# document. It suppresses the same human decoration --json does: no summary
# line, no ledger line, no asterisk, no footnote, no em dashes. Nine fields, in
# this order:
#
#   1  number        7  effort
#   2  state         8  head
#   3  verdict       9  reviewed_sha
#   4  by
#   5  is_ours       1 or 0, the machine form of the table's *
#   6  reviewed_at   the ISO-8601 timestamp, not the table's relative age: an
#                    age can be computed from a timestamp, and a timestamp
#                    cannot be recovered from "2h ago"
#
# An absent value is an EMPTY field — never an em dash, never "null", never a
# dash. `verdict` is verbatim and is NOT clipped: the table's width limit is a
# layout concern and has no business in a machine format. `effort` is empty for
# an ignored PR, as it is null in --json, because that PR would not be reviewed
# at all.
#
# Every emitted value has tabs, carriage returns and newlines replaced with a
# single space first. A tab inside a verdict would otherwise shift every field
# after it and a consumer's `cut -f5` would read the wrong column with no error
# anywhere — and a verdict is free text out of a markdown heading somebody
# typed. This is the same rule --json follows by passing every value through
# `jq --arg`: never let a value carry the delimiter of the format transporting
# it.
#
# --tsv and --json together is a usage error rather than one of them silently
# winning, because passing both is a mistake in whatever wrapper did it.
#
# Prior reviews are detected from the hidden marker the council embeds in every
# comment it posts:
#
#   <!-- review-council:marker sha=<full-head-sha> -->
#
# Three things have to hold before a comment counts as a review, because that
# marker is public and anyone can type one: it must start a LINE at column 0,
# it must not be collapsed, and it must come from an account the --account
# scope admits. If a lookup fails outright the PR is reported as needing
# review, so an outage never reads as "everything is fine".
#
# Whose reviews count:
#
#   --account all      any account's verdict counts. The default, because the
#                      council often posts from a bot account or from a second
#                      machine, and a report counting only your own reads every
#                      one of those PRs as unreviewed.
#   --account self     only verdicts posted by the account gh is authenticated
#                      as. The one scope under which STATE predicts the driver
#                      exactly — review-open-prs.sh refuses a marker it did not
#                      post — so it is the setting to use when you are
#                      debugging that script's queue.
#   --account <login>  only that account's verdicts.
#
# Under any scope but self, STATE stops being a strict prediction of what your
# own driver would do: a PR shown as up-to-date* is one the driver WOULD review
# again, because it does not trust a marker from elsewhere. The star and the
# footnote under the table are what keep the report honest about that gap.
#
# A marker the scope did NOT count is named beneath the table and its PR is
# still reported as unreviewed: a token that rotated between runs and a forged
# marker look identical from the timeline, and neither is something to trust.
# One that WAS counted appears in the BY column instead, and is not listed
# there as well — the same comment described twice, in two contradictory ways,
# would be worse than either description alone.
#
# Ignoring dependency bots:
#
# The driver drops PRs written entirely by a known bot address before they
# reach its queue, and this script reports those PRs as "ignored" rather than
# hiding them, so the list is visible instead of merely in effect. The default
# covers Dependabot and Renovate in both their GitHub App and self-hosted
# forms. Addresses are matched case-insensitively against the whole commit
# author address, and a PR counts as ignored only when it has at least one
# commit author and EVERY one of them is listed.
#
# As in the driver, the list is batch triage and does not apply to a PR you
# name explicitly: asking for #123 by number or URL says which PR you want.
#
#   --ignore-email <addr>   Add an address to the list. Repeatable.
#   --no-ignore-emails      Clear the list; report every PR on its own terms.
#   IGNORE_EMAILS           Replace the built-in list (see Environment).
#
# Usage:
#   ./review-pr-status.sh                       # every open PR of the current repo
#   ./review-pr-status.sh 123                   # just PR #123 (current repo)
#   ./review-pr-status.sh https://github.com/owner/name/pull/123   # by URL
#   ./review-pr-status.sh --repo owner/name     # a different repository
#   ./review-pr-status.sh --account self        # only your own account's reviews
#   ./review-pr-status.sh --account council-bot # only that account's reviews
#   ./review-pr-status.sh --ignore-email ci@corp.example   # also ignore CI's PRs
#   ./review-pr-status.sh --no-ignore-emails    # report bot PRs on their own terms
#   ./review-pr-status.sh --json                # the same report as one JSON envelope
#   ./review-pr-status.sh --tsv                 # one tab-separated line per PR, no header
#   ./review-pr-status.sh --exit-code           # exit 10 instead of 0 if anything is pending
#
# Target selection:
#   * A positional argument may be a PR number (123) or a GitHub PR URL. Either
#     restricts the report to that single PR; a URL also sets the repository.
#   * The repository is taken from, in order: a PR URL argument, --repo, then the
#     GitHub remote of the current directory. Run inside a checkout, or pass one
#     of the first two, to report on any repository from anywhere.
#
# Environment:
#   DEEP_FILES          changedFiles at or above this are reported as deep
#                       effort (default 10).
#   QUICK_FILES         bot PRs at or below this many files are reported as
#                       quick effort (default 2).
#   SECURITY_PATHS      Extended-regex; any changed path matching it (case-
#                       insensitive) is reported as deep effort. Default covers
#                       ca/crl/cert/key/auth/crypto/tls/token/rbac/sign/... .
#   REREVIEW_PER_HOUR   The driver's hourly cap on requested re-reviews. Read
#                       here only to print how much of it is spent. Unset or
#                       empty means no cap; a non-numeric value is an error.
#   IGNORE_EMAILS       Comma- or whitespace-separated commit-author addresses
#                       whose PRs are reported as ignored. REPLACES the
#                       built-in Dependabot and Renovate list rather than
#                       extending it; set it to the empty string to report
#                       every PR on its own terms. --ignore-email appends to
#                       whichever list is in effect.
#
# Exit codes:
#   Without --exit-code the script exits 0 whenever it produced a report — a
#   backlog is not a failure, and the report is the answer whether or not it
#   is comfortable.
#
#   --exit-code           0   reported, and nothing is unreviewed, stale or
#                             requested, under the --account scope in force
#                         10  reported, and at least one PR is unreviewed,
#                             stale or requested
#
#   1   a hard failure — gh unauthenticated, the repository unresolvable, a
#       named PR that does not exist, or a listing that would not answer.
#       --exit-code does not change this: an outage must never come back as
#       10 or as 0, both of which say the check itself succeeded.
#   2   a usage or configuration error — an unknown flag, a --repo that
#       disagrees with the PR URL beside it, a non-numeric DEEP_FILES.
#
#   10 rather than reusing 1 is the whole point of the flag: a wrapper doing
#   `review-pr-status.sh --exit-code || alert` would otherwise fire identically
#   for "three PRs are waiting" and "GitHub is down" — opposite operational
#   situations, one the system working and telling you so, the other the check
#   having failed and telling you nothing. 1 and 2 keep the meanings they
#   already have throughout both scripts, so the flag adds a code rather than
#   redefining one.
#
#   up-to-date and ignored PRs are never pending, so a repository whose every
#   open PR is current or bot-authored exits 0 under --exit-code too.
#
# Requirements: gh (authenticated) and jq.

# Below the blank line above, and so out of `usage`, which prints the header
# verbatim up to that point — a lint directive is not help text.
#
# shellcheck disable=SC2250 # Bare $var, as every other shell source here writes
# it. Enabling the braces-always style in this one file would make it the only
# one of its kind in the tree; consistency is worth more than the check.

set -euo pipefail

# Resolve this script through any symlinks to find lib/. Not `dirname "$0"`:
# invoked through a symlink that is the LINK's directory, not the script's, so
# the lib lookup would land in the wrong place. Not `readlink -f` or `realpath`
# either — both are GNU/newer-BSD only, and the macOS leg of the portability
# suite is the reason this is spelled out by hand. Each hop re-bases with
# `cd -P` because a relative link target is relative to the directory of the
# LINK, not of the original invocation.
_src="${BASH_SOURCE[0]}"
_hops=0
while [[ -L "$_src" ]]; do
	# A symlink cycle is a broken installation, not something to hang on.
	_hops=$((_hops + 1))
	if [[ "$_hops" -gt 40 ]]; then
		echo "Too many symlink hops resolving ${BASH_SOURCE[0]}" >&2
		exit 1
	fi
	_dir="$(cd -P "$(dirname "$_src")" && pwd)"
	_src="$(readlink "$_src")"
	[[ "$_src" = /* ]] || _src="${_dir}/${_src}"
done
SCRIPT_DIR="$(cd -P "$(dirname "$_src")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/lib"
SCRIPT_REAL="$_src"
unset _src _dir _hops

# shellcheck source=scripts/lib/common.sh
source "$LIB_DIR/common.sh"

# Armed right after common.sh defines ERR_TRAP, and before comments.sh is
# sourced, so a source-time failure in comments.sh (a typo, an unbound
# variable, a bad regex) is reported rather than exiting silently. The one gap
# this cannot close is a failure while common.sh itself is sourcing: nothing
# can catch it with a trap that file has not defined yet. common.sh's own
# validation paths print their own message and exit 2, so that gap is covered
# a different way rather than left open.
# shellcheck disable=SC2064  # install ERR_TRAP's literal body; its $?/$LINENO stay deferred
trap "$ERR_TRAP" ERR

# shellcheck source=scripts/lib/comments.sh
source "$LIB_DIR/comments.sh"

# shellcheck source=scripts/lib/prs.sh
source "$LIB_DIR/prs.sh"

REPO=""   # owner/name; resolved below from URL arg, --repo, or the CWD repo
TARGET="" # positional PR number or URL; empty => report on all open PRs
# effort_for reads this as its override, and there is no --effort flag here to
# set it: this report says what tier a PR would be given, and a flag that
# changed that answer would only describe a run nobody is going to make.
# Declared rather than left unset because the shared helper reads it under
# `set -u`.
FORCE_EFFORT=""
# Whose verdicts classify_prs counts: "all", "self", or a single login.
# "all" here and "self" in the library's default is not an inconsistency: this
# script reports, and a report that hides the fleet's reviews answers nobody's
# question; the driver spends money, and money follows the gated reader.
VERDICT_SCOPE="all"
# Set by --json: emit the machine-readable envelope instead of the table, and
# suppress every human decoration that goes with it.
JSON=0
# Set by --tsv: emit one tab-separated line per PR instead of the table, with
# the same decoration suppressed. Mutually exclusive with --json, checked once
# after parsing rather than in each branch so the order the two flags were
# given in cannot change the answer.
TSV=0
# Set by --exit-code: turn a backlog into exit 10 instead of 0. See the "Exit
# codes" comment above and the check at the end of the script for why 10 is a
# distinct code from 1 rather than a reuse of it.
EXIT_CODE=0

usage() {
	sed -n '2,/^$/p' "$SCRIPT_REAL" | sed 's/^#\{0,1\} \{0,1\}//'
}

# ---- Parse arguments -------------------------------------------------------
while [[ "$#" -gt 0 ]]; do
	case "$1" in
	--repo)
		[[ "$#" -ge 2 ]] || {
			echo "--repo requires an argument (owner/name)" >&2
			exit 2
		}
		REPO="$2"
		shift
		;;
	--ignore-email)
		[[ "$#" -ge 2 ]] || {
			echo "--ignore-email requires an argument (an email address)" >&2
			exit 2
		}
		IGNORE_EMAIL_LIST+=("$2")
		shift
		;;
	--no-ignore-emails)
		IGNORE_EMAIL_LIST=()
		;;
	--json)
		JSON=1
		;;
	--tsv)
		TSV=1
		;;
	--exit-code)
		EXIT_CODE=1
		;;
	--account)
		[[ "$#" -ge 2 ]] || {
			echo "--account requires an argument (a login, or 'all' or 'self')" >&2
			exit 2
		}
		# Refused empty, accepted in any other shape. An empty scope would match
		# no author at all and report a fully reviewed repository as untouched,
		# which is the one answer here that is wrong rather than narrow. No
		# character check beyond that: an app posts as "dependabot[bot]", and a
		# login pattern that rejected the bracket would reject exactly the fleet
		# account this flag exists to name. The value is compared inside jq as an
		# --arg, never interpolated into a query or a path.
		[[ -n "$2" ]] || {
			echo "--account requires a non-empty login, or 'all' or 'self'" >&2
			exit 2
		}
		VERDICT_SCOPE="$2"
		shift
		;;
	-h | --help)
		usage
		exit 0
		;;
	-*)
		echo "Unknown option: $1" >&2
		usage >&2
		exit 2
		;;
	*)
		if [[ -n "$TARGET" ]]; then
			echo "Only one PR target may be given (got '$TARGET' and '$1')." >&2
			exit 2
		fi
		TARGET="$1"
		;;
	esac
	shift
done

# ---- Preconditions ---------------------------------------------------------
# Two renderings of one classification, so asking for both is a mistake in the
# wrapper that did it rather than a preference between them. Silently letting
# one win would leave that wrapper parsing the wrong format with no clue why.
if [[ "$JSON" -eq 1 ]] && [[ "$TSV" -eq 1 ]]; then
	echo "--tsv and --json are alternative renderings; pass one, not both." >&2
	exit 2
fi

require_commands gh jq

gh auth status >/dev/null 2>&1 || {
	echo "gh is not authenticated. Run 'gh auth login' (or set GITHUB_TOKEN)." >&2
	exit 1
}

# ---- Resolve target repository and (optional) single PR, then collect PRs --
resolve_target "$TARGET"

# collect_prs reports through its exit status, and the `|| collect_rc=$?` is
# what makes that status readable: errexit does not reach into the command
# substitution around it (bash unsets errexit there without `inherit_errexit`,
# which this tree does not set), so without an explicit check a failed lookup
# would arrive here as an empty string and be announced as "no open pull
# requests" — a clean exit 0 having reported on nothing.
collect_rc=0
# shellcheck disable=SC2310 # Suspending errexit is the whole point: collect_prs
# reports failure through its status, and the case below handles every value it
# documents. Letting set -e abort instead would lose the distinction between a
# missing PR and a broken listing, which is what this call exists to make.
prs_raw="$(collect_prs)" || collect_rc=$?
case "$collect_rc" in
0) ;;
1)
	echo "PR #${TARGET_PR} not found in ${REPO}." >&2
	exit 1
	;;
*)
	echo "Could not list the open pull requests in ${REPO}." >&2
	echo "The lookup failed, which is not the same as there being nothing to report; no status was produced." >&2
	exit 1
	;;
esac
if [[ -z "$prs_raw" ]]; then
	echo "No open pull requests found in ${REPO}."
	exit 0
fi

# ---- Classify each PR against its prior Review Council comment --------------
# All date arithmetic goes through jq. `date -u -d` is a GNU extension and
# test-rc-portability.sh fails the macOS leg for it; jq is already required.
WINDOW_START="$(jq -rn '(now - 3600) | todate')"
classify_prs "$prs_raw"

# The window slides far enough to free a slot one hour after its oldest verdict.
NEXT_SLOT="(now)"
if [[ -n "$OLDEST_IN_WINDOW" ]]; then
	NEXT_SLOT="$(jq -rn --arg t "$OLDEST_IN_WINDOW" '($t | fromdateiso8601 + 3600) | todate')"
fi

# The same buckets both renderers read below, not a re-derivation of them —
# so --exit-code can never disagree with what the table or the JSON reported.
# up-to-date and ignored PRs are not pending, which is why a repository that
# is entirely current or bot-authored exits 0.
pending=$((${#UNREVIEWED[@]} + ${#STALE[@]} + ${#REQUESTED[@]}))

# state_of <pr> -> the single word this PR is reported under. Derived from the
# buckets rather than recomputed, so the report and the driver's queue can
# never disagree about a PR. The order of the tests is the order of the
# buckets' precedence: an ignored PR is never classified further, and a PR that
# is in none of the four is one the driver would skip.
state_of() {
	local pr="$1" p
	for p in "${IGNORED[@]}"; do [[ "$p" = "$pr" ]] && {
		printf 'ignored'
		return
	}; done
	for p in "${UNREVIEWED[@]}"; do [[ "$p" = "$pr" ]] && {
		printf 'unreviewed'
		return
	}; done
	for p in "${STALE[@]}"; do [[ "$p" = "$pr" ]] && {
		printf 'stale'
		return
	}; done
	for p in "${REQUESTED[@]}"; do [[ "$p" = "$pr" ]] && {
		printf 'requested'
		return
	}; done
	printf 'up-to-date'
}

# age_human <iso> -> "2h ago", or an em dash for a time that does not exist.
# Through jq, never `date -d`: that is a GNU extension and
# test-rc-portability.sh fails the macOS leg for it.
age_human() {
	[[ -n "$1" ]] || {
		printf '—'
		return
	}
	jq -rn --arg t "$1" '
		(now - ($t | fromdateiso8601)) as $d
		| if $d < 60 then "just now"
		  elif $d < 3600 then "\(($d / 60) | floor)m ago"
		  elif $d < 86400 then "\(($d / 3600) | floor)h ago"
		  else "\(($d / 86400) | floor)d ago" end
	' 2>/dev/null || printf '—'
}

# cell <text> <width> -> <text> clipped to <width> characters, with a trailing
# ellipsis when it had to be cut, padded out to exactly <width>, and followed
# by the single space that separates it from the next column.
#
# Clipped because one long verdict must not push every column after it out of
# line on that row alone. Padded here rather than with `printf '%-<width>s'`
# because bash pads that to a BYTE count: the em dash this table prints for an
# absent value is three bytes and one column wide, so every row carrying one
# would pull the columns after it two places left. `${#text}` counts characters,
# which is what a terminal lays out.
cell() {
	local text="$1" width="$2"
	if [[ "${#text}" -gt "$width" ]]; then
		text="${text:0:$((width - 1))}…"
	fi
	printf '%s%*s ' "$text" "$((width - ${#text}))" ""
}

# The BY column's heading, named because it is also that column's minimum
# width. Spelling it twice would let the two drift, and a heading wider than
# the column it heads is the exact defect this column is being resized to fix.
BY_HEADING="BY"

# row <by-width> <pr> <state> <verdict> <by> <reviewed> <effort> -> one line of
# the table.
#
# The column widths live here alone because the header and the rows have to
# agree on them: a table whose heading is a column out from its body is worse
# than one with no heading at all. BY is the one width the caller supplies,
# because it is measured from the rows rather than fixed — see the collection
# pass below. Each cell is written straight to stdout rather than collected
# through `$(cell ...)`, so no column's exit status is swallowed by a
# substitution. The last column is not padded, which is what keeps every line
# free of trailing whitespace.
row() {
	cell "$2" 6
	cell "$3" 12
	cell "$4" 18
	cell "$5" "$1"
	cell "$6" 10
	printf '%s\n' "$7"
}

# tsv_row <field>... -> the fields on one line, tab-separated.
#
# The sanitising loop is the whole reason this exists as a function rather than
# as a `printf` at the call site. A tab or a newline inside any value would
# shift every field after it, and a consumer's `cut -f5` would then read the
# wrong column with no error anywhere — so each value gets its tabs, carriage
# returns and newlines replaced with a single space, in ONE place that every
# field passes through. A tenth field added here later is covered by that
# without anyone having to remember it, which nine per-field substitutions at
# the call site would not be.
#
# The separator is prepended rather than appended so an empty trailing field
# still holds its place: a line ending in a tab is nine fields to `cut` and to
# `awk -F'\t'`, and one ending without it is eight.
tsv_row() {
	local field line="" sep=""
	for field in "$@"; do
		line+="${sep}${field//[$'\t\r\n']/ }"
		sep=$'\t'
	done
	printf '%s\n' "$line"
}

# ---- Report ----------------------------------------------------------------
# --json and the table are two renderings of the one classification classify_prs
# already produced above: neither branch re-runs it or re-derives state on its
# own, so the two can never disagree about a PR.
if [[ "$JSON" -eq 1 ]]; then
	# One compact object per PR, built entirely with `jq -nc` from --arg/
	# --argjson values and folded below with `jq -s`. Never string-concatenated:
	# a login, verdict or repo name carrying a quote, backslash or newline must
	# not be able to break the document, and jq's own argument encoding is what
	# guarantees that rather than a hand-rolled escape.
	pr_objects=""
	while IFS=$'\t' read -r pr head; do
		[[ -n "$pr" ]] || continue
		state="$(state_of "$pr")"
		# Same scope the state was decided under, so the word describes the very
		# comment the row rests on rather than a different account's review.
		verdict="$(council_verdict_word "${COMMENTS_JSON[$pr]:-}" "$VERDICT_SCOPE")"
		if [[ "$state" = "ignored" ]]; then
			effort=""
		else
			effort="$(effort_for "$pr")"
		fi
		foreign=""
		for f in "${FOREIGN[@]}"; do
			[[ "$f" = "${pr}:"* ]] && foreign="${f#*:}"
		done
		# The machine-readable form of the table's `*` suffix: a real JSON
		# boolean, not a string a reader would have to parse back out.
		is_ours="false"
		[[ "${REVIEWED_IS_OURS[$pr]:-0}" = "1" ]] && is_ours="true"
		pr_objects+="$(jq -nc \
			--argjson number "$pr" \
			--arg state "$state" \
			--arg head "$head" \
			--arg reviewed_sha "${REVIEWED_SHA[$pr]:-}" \
			--arg reviewed_at "${REVIEWED_AT[$pr]:-}" \
			--arg reviewed_by "${REVIEWED_BY[$pr]:-}" \
			--argjson reviewed_is_ours "$is_ours" \
			--arg verdict "$verdict" \
			--arg effort "$effort" \
			--arg foreign "$foreign" \
			'def n: if . == "" then null else . end;
			 {number: $number, state: $state, head: ($head | n),
			  reviewed_sha: ($reviewed_sha | n), reviewed_at: ($reviewed_at | n),
			  reviewed_by: ($reviewed_by | n), reviewed_is_ours: $reviewed_is_ours,
			  verdict: ($verdict | n), effort: ($effort | n),
			  foreign_marker: ($foreign | n)}')"$'\n'
	done <<<"$prs_raw"

	printf '%s' "$pr_objects" | jq -s \
		--arg repo "$REPO" \
		--arg scope "$VERDICT_SCOPE" \
		--arg window_start "$WINDOW_START" \
		--argjson spent "$SPENT" \
		--arg limit "${REQUESTS_PER_HOUR:-}" \
		--arg next_slot "$NEXT_SLOT" \
		'{repo: $repo,
		  generated_at: (now | todate),
		  account_scope: $scope,
		  window: {start: $window_start, spent: $spent,
		           limit: (if $limit == "" then null else ($limit | tonumber) end),
		           next_slot: $next_slot},
		  pull_requests: .}'
elif [[ "$TSV" -eq 1 ]]; then
	# The head sha is a field here, so unlike the table this loop keeps it.
	while IFS=$'\t' read -r pr head; do
		[[ -n "$pr" ]] || continue
		state="$(state_of "$pr")"
		# Same scope the state was decided under, so the word describes the very
		# comment the row rests on rather than a different account's review. Not
		# clipped: the table cuts a long verdict to keep its columns in line, and
		# that is a layout concern with no business in a machine format.
		verdict="$(council_verdict_word "${COMMENTS_JSON[$pr]:-}" "$VERDICT_SCOPE")"
		if [[ "$state" = "ignored" ]]; then
			effort=""
		else
			effort="$(effort_for "$pr")"
		fi
		# The machine form of the table's `*` suffix, as a digit rather than a
		# presentation character a reader would have to scrape back out.
		is_ours=0
		[[ "${REVIEWED_IS_OURS[$pr]:-0}" = "1" ]] && is_ours=1
		# An absent value is an empty field. Not an em dash, which is the table's
		# way of saying the same thing to a person, and not the string "null",
		# which a consumer would have to know to special-case.
		tsv_row "$pr" "$state" "$verdict" "${REVIEWED_BY[$pr]:-}" "$is_ours" \
			"${REVIEWED_AT[$pr]:-}" "$effort" "$head" "${REVIEWED_SHA[$pr]:-}"
	done <<<"$prs_raw"
else
	# Every PR classify_prs saw landed in exactly one bucket, so the buckets are
	# the population: counting them rather than the input lines keeps the summary
	# and the table below it describing the same set of pull requests.
	total=$((${#UNREVIEWED[@]} + ${#STALE[@]} + ${#REQUESTED[@]} + ${#SKIPPED[@]} + ${#IGNORED[@]}))

	echo "review-council status — ${REPO}  (accounts: ${VERDICT_SCOPE})"
	printf '%s open · %s need review · %s requested · %s current · %s ignored\n' \
		"$total" "$((${#UNREVIEWED[@]} + ${#STALE[@]}))" "${#REQUESTED[@]}" \
		"${#SKIPPED[@]}" "${#IGNORED[@]}"
	printf 'Requested re-reviews: %s/%s used this hour, next slot %s\n\n' \
		"$SPENT" "${REQUESTS_PER_HOUR:-unlimited}" "$NEXT_SLOT"

	# Collected first and printed second, because the BY column is sized to the
	# widest account it actually carries and that is not known until the last
	# row has been built. Everything measured is already in memory — this pass
	# spends no lookup the streaming version did not.
	#
	# BY alone is measured. VERDICT keeps its fixed width and its clipping: it
	# is free text out of a markdown heading with no upper bound, which is the
	# case auto-sizing handles worst. A login is bounded and, unlike a verdict,
	# has to be copyable back into --account to be worth printing at all.
	row_pr=()
	row_state=()
	row_verdict=()
	row_by=()
	row_reviewed=()
	row_effort=()
	# The floor is the heading's own width, so a column with nothing in it keeps
	# a readable title instead of collapsing to a single letter. Measured with
	# ${#...}, the same character count `cell` pads with — a byte count would
	# put the header and the body two places apart on every row carrying an em
	# dash.
	by_width="${#BY_HEADING}"
	# Set when any row rests on a verdict from another account, which is the one
	# thing that stops STATE from being a strict prediction of the driver.
	starred=0
	# The head sha is read and discarded: the table is keyed on the PR number, and
	# what the verdict is compared against is already settled inside classify_prs.
	while IFS=$'\t' read -r pr _; do
		[[ -n "$pr" ]] || continue
		state="$(state_of "$pr")"
		# A verdict that was counted but not posted by us: the state is real, and
		# the star is what says the reader's own driver would not agree with it.
		if [[ -n "${REVIEWED_SHA[$pr]:-}" ]] && [[ "${REVIEWED_IS_OURS[$pr]:-0}" != "1" ]]; then
			state="${state}*"
			starred=1
		fi
		# Same scope the state was decided under, so the word describes the very
		# comment the row rests on rather than a different account's review.
		verdict="$(council_verdict_word "${COMMENTS_JSON[$pr]:-}" "$VERDICT_SCOPE")"
		[[ -n "$verdict" ]] || verdict="—"
		by="${REVIEWED_BY[$pr]:-}"
		[[ -n "$by" ]] || by="—"
		reviewed="$(age_human "${REVIEWED_AT[$pr]:-}")"
		if [[ "$state" = "ignored" ]]; then
			effort="—"
		else
			effort="$(effort_for "$pr")"
		fi
		row_pr+=("#${pr}")
		row_state+=("$state")
		row_verdict+=("$verdict")
		row_by+=("$by")
		row_reviewed+=("$reviewed")
		row_effort+=("$effort")
		[[ "${#by}" -le "$by_width" ]] || by_width="${#by}"
	done <<<"$prs_raw"

	row "$by_width" "PR" "STATE" "VERDICT" "$BY_HEADING" "REVIEWED" "WOULD RUN"
	for i in "${!row_pr[@]}"; do
		row "$by_width" "${row_pr[$i]}" "${row_state[$i]}" "${row_verdict[$i]}" \
			"${row_by[$i]}" "${row_reviewed[$i]}" "${row_effort[$i]}"
	done

	if [[ "$starred" -eq 1 ]]; then
		echo
		echo "* reviewed by another account; your driver would review it again"
	fi

	if [[ "${#FOREIGN[@]}" -gt 0 ]]; then
		echo
		echo "Council marker from another account: ${FOREIGN[*]}"
		echo "      A token rotated between runs reads this way, and so does a forged"
		echo "      marker. Neither is trusted, so these PRs report as unreviewed."
		if [[ "$VERDICT_SCOPE" != "self" ]]; then
			echo "      A marker the --account scope in force DID count is named in the BY"
			echo "      column above and is not repeated here."
		fi
	fi
fi

# Without --exit-code the report IS the answer and a backlog is not a
# failure. With it, 10 rather than 1 is the whole point: reusing 1 would make
# `review-pr-status.sh --exit-code || alert` fire identically for "three PRs
# are waiting" and "GitHub is down" — opposite operational situations. One is
# the system working and telling you so; the other is the check having failed
# and telling you nothing. 1 and 2 keep the meanings they already have
# throughout both scripts, so this ADDS a code rather than redefining any.
if [[ "$EXIT_CODE" -eq 1 ]] && [[ "$pending" -gt 0 ]]; then
	exit 10
fi
