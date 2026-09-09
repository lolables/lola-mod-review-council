#!/usr/bin/env bash
#
# review-open-prs.sh
#
# Run the Claude Code `/review-council` command against the pull requests of a
# GitHub repository that need attention — either every open PR, or a single PR
# you name. The target repository and PR are resolved from the arguments and the
# current directory, so the script is not tied to any one project.
#
# For each PR that needs review it invokes whichever agent CLI is installed:
#
#   claude -p "/review-council [effort] <pr-url> -- post the verdict, auto-send without asking" \
#          --permission-mode bypassPermissions --output-format stream-json --verbose
#
#   opencode run --command review-council --auto \
#            "[effort] <pr-url> -- post the verdict, auto-send without asking"
#
# Both reach the same council command, by the route each host provides for it:
# claude expands a leading /review-council inside the prompt it is given, while
# opencode selects the command with --command and hands the message to it as
# $ARGUMENTS. Everything after the command name is identical between them.
#
# claude is preferred when both are installed. --cli <claude|opencode> picks one
# explicitly, and fails if that one is not on PATH rather than falling back —
# the two hosts do not cost the same or reach the same models.
#
# The auto-send directive and the effort word are natural-language tokens
# interpreted by the review-council command itself (run at the chosen depth,
# then post the verdict without pausing for a per-PR confirmation). They are
# not flags the council parses as CLI options. Note: the council's
# finding-verification pipeline is a mandatory integrity phase — this script
# never asks it to skip verification, only to post without a human confirm
# prompt. (quick effort runs a lighter verification per the council's own
# rules; it is never "no verification".)
#
# Effort tiering — so a one-line bump does not pay for a 25-agent deep review:
# each queued PR is classified from its GitHub metadata and the matching effort
# word is passed to the council. This is the deterministic half of a hybrid
# design; the council was expected to gain its own cheap pre-review triage for
# the ambiguous middle, which has not been built. Until it is, the middle tier
# omits the effort word so the council applies its standard default.
#
#   deep      changedFiles >= DEEP_FILES, or any changed path looks
#             security-sensitive (SECURITY_PATHS). Full subsystem decomposition.
#   quick     bot-authored AND changedFiles <= QUICK_FILES (e.g. a Renovate
#             digest or lockfile bump). Single pass, lighter verification.
#   standard  everything else. The effort word is omitted so the council uses
#             its default (and, once available, its own triage).
#
# --effort <quick|standard|deep> forces one tier for the whole batch, bypassing
# the classifier (--effort deep reproduces the original always-deep behavior).
#
# Which PRs get reviewed, and in what order:
#
#   1. PRs with NO prior Review Council comment (unreviewed) go first.
#   2. PRs whose prior review was for an older commit (new commits since)
#      go next — a re-review.
#   3. PRs already reviewed at head where someone asked for another look
#      go last — a requested re-review (see below).
#   4. Everything else is SKIPPED. Pass --force to review those anyway.
#
# Prior reviews and the reviewed commit are detected from the hidden marker
# the council embeds in every comment it posts:
#
#   <!-- review-council:marker sha=<full-head-sha> -->
#
# A PR is "already reviewed at head" when that marker's sha equals the PR's
# current headRefOid. Three things have to hold before a comment counts as that
# review, because the marker above is public and anyone can type one:
#
#   * the marker starts a LINE, at column 0. GitHub's "Quote reply" copies it
#     behind a "> " prefix, and a finding's evidence can quote a sha= of its own.
#   * the comment was authored by the account gh is authenticated as.
#   * the comment is not collapsed. Collapsing a verdict on GitHub is therefore
#     a way to force a fresh review of that PR by hand.
#
# A marker posted by any other account is named in the plan output and the PR is
# reviewed anyway: a token that rotated between runs and a forged marker look
# identical from the timeline, and reviewing is the safe answer to both. If a
# lookup fails outright, the PR is likewise treated as needing review.
#
# Asking for a re-review in a comment:
#
# Sometimes nothing has been pushed and the PR still needs another look — the
# maintainer has answered the findings, or argued one down, and wants the
# council to take the conversation into account. A comment whose line reads
#
#   /review-council review
#
# queues the PR for exactly that. The line must stand alone at column 0, so
# quoting someone else's request is not making one, and the comment must be
# newer than the verdict it asks to replace, so one request cannot re-fire on
# every run. Trailing words are not accepted: the effort tier decides what a
# review costs, and a requester does not choose it.
#
# A request is honoured only from an account with admin or write permission on
# the repository. Requests are money, and an unreadable permission answer is
# refused rather than assumed — the one lookup in this script that fails closed.
#
# --requests-per-hour <n> caps how many requested re-reviews a run will admit,
# counting every verdict this account posted in the trailing hour. Requests are
# admitted oldest-first; the rest are deferred and told so on their own PR, at
# most once per pull request per hour. Usage is printed either way. The count
# comes from the verdict comments themselves rather than from a state file, so
# it survives running from another machine — and so a single-PR run sees a
# narrower window than a batch, since it reads only that PR's history.
#
# Ignoring dependency bots:
#
# Dependency bots open PRs faster than a council can review them, and every
# review costs real money, so PRs written entirely by a known bot address are
# dropped before they reach the queue. The default list covers Dependabot and
# Renovate, in both their GitHub App and self-hosted commit-author forms.
#
# GitHub exposes no email on the pull request itself, so the addresses compared
# are the commit authors' (.commits[].authors[].email), matched case-
# insensitively against the whole address. A PR is ignored only when it has at
# least one commit author and EVERY one of them is on the list: a Renovate
# branch that someone has pushed a fix onto contains human work and comes back
# for review. The at-least-one requirement also keeps an authorship lookup that
# returns nothing from being vacuously true — a transient gh failure fails open
# to reviewing, as everywhere else here.
#
# The list is batch triage, so it does not apply to a PR you name explicitly:
# asking for #123 by number or URL says which PR you want.
#
#   --ignore-email <addr>   Add an address to the list. Repeatable.
#   --no-ignore-emails      Clear the list; consider every PR.
#   IGNORE_EMAILS           Replace the built-in list (see Environment).
#
# Ignoring PRs that are already approved:
#
# --ignore-approved drops any PR the forge reports as approved before it is
# classified at all. A PR somebody has approved has already had a human decide
# on it, and this is the cheapest way to keep the council off the ones that are
# only waiting to be merged.
#
# The value read is GitHub's own reviewDecision, and only APPROVED counts:
# CHANGES_REQUESTED and REVIEW_REQUIRED both mean the PR is still waiting on
# someone, and a PR with no decision at all has been approved by nobody. A
# lookup that cannot be read is not an approval either, so it fails open to
# reviewing like every other per-PR lookup here.
#
# It is off by default and has no environment default, because an approval says
# what should happen to a PR rather than that this council has looked at it.
# Note also what reviewDecision does not track: unless the branch is protected
# with "dismiss stale approvals", GitHub keeps an approval across later pushes,
# so a PR approved and then pushed to still reads as APPROVED and is skipped
# with those new commits unreviewed. Leave the flag off for a run that should
# see them.
#
# Like the address list above, this is batch triage and does not apply to a PR
# you name explicitly.
#
# Default is a DRY RUN: it classifies the PRs and prints the plan, but does
# not invoke claude or post anything. Pass --run to execute.
#
# --run alone is not enough. Every review ends in a public comment on someone
# else's pull request, posted by the account gh is authenticated with, so --run
# describes the GitHub edits it is about to make and waits for you to type
# "yes" against the queue you were just shown. Anything else — including no
# answer at all, as under cron or a closed stdin — aborts without posting.
# Pass --yes (alias --no-confirm) to give that consent up front instead.
#
# Usage:
#   ./review-open-prs.sh                        # dry run: all open PRs of the current repo
#   ./review-open-prs.sh --run                  # review every open PR that needs it
#   ./review-open-prs.sh 123 --run              # review only PR #123 (current repo)
#   ./review-open-prs.sh https://github.com/owner/name/pull/123 --run  # by URL
#   ./review-open-prs.sh --repo owner/name --run                       # a different repo
#   ./review-open-prs.sh --force --run          # also re-review unchanged PRs
#   ./review-open-prs.sh --effort deep --run    # force deep on every PR (old behavior)
#   ./review-open-prs.sh --run --yes            # unattended: no confirmation prompt
#   ./review-open-prs.sh --cli opencode --run   # review through opencode, not claude
#   ./review-open-prs.sh --ignore-email ci@corp.example --run  # also skip CI's PRs
#   ./review-open-prs.sh --no-ignore-emails --run              # review bot PRs too
#   ./review-open-prs.sh --ignore-approved --run  # skip PRs someone already approved
#   ./review-open-prs.sh --requests-per-hour 3 --run  # admit at most 3 requests/hour
#
# Target selection:
#   * A positional argument may be a PR number (123) or a GitHub PR URL. Either
#     restricts the run to that single PR; a URL also sets the repository.
#   * The repository is taken from, in order: a PR URL argument, --repo, then the
#     GitHub remote of the current directory. Run inside a checkout, or pass one
#     of the first two, to target any repository from anywhere.
#
# Watching a run:
#
# A single council review takes tens of minutes, so claude is asked for its
# structured event stream (--output-format stream-json, which --print rejects
# without --verbose) rather than the default text, where a `-p` run prints
# nothing at all until its closing message. The events land verbatim in the
# per-PR log and are rendered to the terminal a line at a time as the run
# makes them:
#
#   14:02:31 → Task divisor-adversary-code
#   14:02:33   Dispatching 5 reviewers over 2 subsystems.
#   14:41:08 done — $8.23, 57 turns
#
# The log itself stays machine-readable, so a finished run can be re-read for
# whatever the terminal did not show:
#
#   jq -Rr 'fromjson? | select(.type=="assistant") | .message.content[]?
#           | select(.type=="tool_use") | .name' \
#      .review-council-logs/<owner>-<repo>-pr-<n>.log
#
# -R because stderr is merged into the same file and is not JSON; reading the
# log as a JSON stream stops at the first diagnostic in it.
#
# opencode writes its own human-readable output and is passed through as-is.
#
# Environment:
#   MAX_BUDGET_USD      If set, passed to claude as --max-budget-usd to cap
#                       the API spend of each individual PR review. opencode
#                       has no equivalent flag, so asking for a cap on an
#                       opencode run is an error rather than an uncapped batch.
#   EXTRA_CLAUDE_ARGS   Extra whitespace-separated args appended to every
#                       claude invocation (e.g. "--model opus"). Naming an
#                       --output-format here replaces the streaming default
#                       described under Watching a run, and with it the
#                       progress rendering that reads those events.
#   EXTRA_OPENCODE_ARGS The same, for opencode (e.g. "--model anthropic/opus").
#   DEEP_FILES          changedFiles at or above this force deep effort (default 10).
#   QUICK_FILES         bot PRs at or below this many files get quick effort (default 2).
#   SECURITY_PATHS      Extended-regex; any changed path matching it (case-
#                       insensitive) forces deep effort. Default covers
#                       ca/crl/cert/key/auth/crypto/tls/token/rbac/sign/... .
#   REREVIEW_PER_HOUR   Default for --requests-per-hour. Unset or empty means
#                       no cap. A non-numeric value is an error rather than a
#                       silent "unlimited" — that misconfiguration is the one
#                       this setting exists to prevent.
#   IGNORE_EMAILS       Comma- or whitespace-separated commit-author addresses
#                       whose PRs are skipped. REPLACES the built-in Dependabot
#                       and Renovate list rather than extending it; set it to
#                       the empty string to consider every PR. --ignore-email
#                       appends to whichever list is in effect.
#
# Requirements: gh (authenticated), jq, and one of claude or opencode.

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
TARGET="" # positional PR number or URL; empty => review all open PRs
RUN=0
FORCE=0
YES=0 # consent to the GitHub edits given up front, so --run does not prompt
FORCE_EFFORT=""
FORCE_CLI=""      # --cli; empty => detect, preferring claude
IGNORE_APPROVED=0 # --ignore-approved; read by classify_prs
LOG_DIR="./.review-council-logs"

# Renders claude's stream-json events into one progress line per step, so the
# terminal shows a run advancing while the log keeps the events themselves.
# Reads with -R rather than as JSON: stderr is merged into the same stream and
# is not JSON, and a diagnostic is the last thing that should be swallowed.
# Only the events that answer "is this still making progress, and at what
# cost" are printed; the rest are dropped rather than scrolled past.
PROGRESS_FILTER='
def clip: if (. | length) > 100 then .[0:100] + "…" else . end;
def stamp: (now | strflocaltime("%H:%M:%S"));
(fromjson? // {type: "raw", line: .})
| if .type == "assistant" then
    .message.content[]?
    | if .type == "tool_use" then
        "\(stamp) → \(.name) \((.input.description // .input.subagent_type // .input.command // .input.file_path // "") | tostring | clip)"
      elif .type == "text" and (.text | test("\\S")) then
        "\(stamp)   \(.text | split("\n")[0] | clip)"
      else empty end
  elif .type == "result" then
    "\(stamp) \(if .subtype == "success" then "done" else "FAILED: " + .subtype end) — $\(((.total_cost_usd // 0) * 100 | round) / 100), \(.num_turns // 0) turns"
  elif .type == "raw" then .line
  else empty end
'

usage() {
	sed -n '2,/^$/p' "$SCRIPT_REAL" | sed 's/^#\{0,1\} \{0,1\}//'
}

# ---- Parse arguments -------------------------------------------------------
while [[ "$#" -gt 0 ]]; do
	case "$1" in
	--run)
		RUN=1
		;;
	--force)
		FORCE=1
		;;
	--yes | --no-confirm)
		YES=1
		;;
	--effort)
		[[ "$#" -ge 2 ]] || {
			echo "--effort requires an argument (quick|standard|deep)" >&2
			exit 2
		}
		case "$2" in
		quick | standard | deep) FORCE_EFFORT="$2" ;;
		*)
			echo "--effort must be one of: quick, standard, deep" >&2
			exit 2
			;;
		esac
		shift
		;;
	--cli)
		[[ "$#" -ge 2 ]] || {
			echo "--cli requires an argument (claude|opencode)" >&2
			exit 2
		}
		case "$2" in
		claude | opencode) FORCE_CLI="$2" ;;
		*)
			echo "--cli must be one of: claude, opencode" >&2
			exit 2
			;;
		esac
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
	--ignore-approved)
		IGNORE_APPROVED=1
		;;
	--requests-per-hour)
		[[ "$#" -ge 2 ]] || {
			echo "--requests-per-hour requires an argument (a non-negative integer)" >&2
			exit 2
		}
		[[ "$2" =~ ^[0-9]+$ ]] || {
			echo "--requests-per-hour must be a non-negative integer, got: '$2'" >&2
			exit 2
		}
		REQUESTS_PER_HOUR="$2"
		shift
		;;
	--repo)
		[[ "$#" -ge 2 ]] || {
			echo "--repo requires an argument (owner/name)" >&2
			exit 2
		}
		REPO="$2"
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
require_commands gh jq

# Pick the agent CLI that will run the council. --cli is a demand, not a
# preference: falling back to the other host would silently change which models
# review the code and what the batch costs.
if [[ -n "$FORCE_CLI" ]]; then
	command -v "$FORCE_CLI" >/dev/null 2>&1 || {
		echo "--cli ${FORCE_CLI} was requested but ${FORCE_CLI} is not on PATH." >&2
		exit 1
	}
	AGENT_CLI="$FORCE_CLI"
elif command -v claude >/dev/null 2>&1; then
	AGENT_CLI="claude"
elif command -v opencode >/dev/null 2>&1; then
	AGENT_CLI="opencode"
else
	echo "No agent CLI found: install claude or opencode, or pass --cli." >&2
	exit 1
fi

# How the chosen CLI is told to stop asking. Named in the confirmation prompt,
# where "permissions are bypassed" is the whole point being confirmed.
case "$AGENT_CLI" in
opencode) CLI_BYPASS="--auto" ;;
*) CLI_BYPASS="--permission-mode bypassPermissions" ;;
esac

# opencode's run flags carry no spend cap (`opencode run --help`), so there is
# nothing to translate MAX_BUDGET_USD into. Honouring the flag by ignoring it
# would run the batch uncapped on the strength of a setting that asked for the
# opposite — across every queued PR, and only visible on the invoice.
if [[ "$AGENT_CLI" = "opencode" ]] && [[ -n "${MAX_BUDGET_USD:-}" ]]; then
	echo "MAX_BUDGET_USD is set, but opencode has no per-review budget cap to pass it to." >&2
	echo "Unset it, or use --cli claude, rather than review this batch uncapped." >&2
	exit 2
fi

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
# requests" — a clean exit 0 having reviewed nothing.
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
	echo "The lookup failed, which is not the same as there being nothing to review; no PRs were queued." >&2
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

DEFERRED=() # an authorised request the hourly cap could not admit
# Admit the oldest request first, so a cap resolves in the order people asked.
# --force queues every PR anyway, so under it nothing is deferred and nothing is
# declined — which is why the queue below needs no DEFERRED branch.
if [[ "$FORCE" -eq 0 ]] && [[ "${#REQ_PR[@]}" -gt 0 ]]; then
	# Requests queue oldest-first whether or not a cap is set, so the cap
	# changes how many are admitted and never what order they run in.
	capped=0
	remaining=0
	if [[ -n "$REQUESTS_PER_HOUR" ]]; then
		capped=1
		remaining=$((REQUESTS_PER_HOUR - SPENT))
		[[ "$remaining" -ge 0 ]] || remaining=0
	fi
	request_lines=""
	for i in "${!REQ_PR[@]}"; do
		request_lines+="${REQ_AT[$i]}"$'\t'"${REQ_PR[$i]}"$'\n'
	done
	# ISO-8601 UTC sorts lexically, so a plain sort puts the earliest request
	# first. Built into a variable and sorted separately rather than piping the
	# loop, which would discard the sort's exit status.
	sorted_requests="$(printf '%s' "$request_lines" | sort)"
	admitted=()
	while IFS=$'\t' read -r _ req_pr; do
		[[ -n "$req_pr" ]] || continue
		if [[ "$capped" -eq 0 ]] || [[ "${#admitted[@]}" -lt "$remaining" ]]; then
			admitted+=("$req_pr")
		else
			DEFERRED+=("$req_pr")
		fi
	done <<<"$sorted_requests"
	REQUESTED=("${admitted[@]}")
fi

# Build the work queue: unreviewed first, then stale re-reviews. With --force,
# append the otherwise-skipped (unchanged) PRs to the end and clear the skip list.
QUEUE=("${UNREVIEWED[@]}" "${STALE[@]}" "${REQUESTED[@]}")
if [[ "$FORCE" -eq 1 ]] && [[ "${#SKIPPED[@]}" -gt 0 ]]; then
	QUEUE+=("${SKIPPED[@]}")
	SKIPPED=()
fi

# Classify each queued PR's review effort (see effort_for / header). Computed
# up front so the dry-run plan shows the depth each PR will get.
declare -A EFFORT
QUEUE_DISPLAY=()
for pr in "${QUEUE[@]}"; do
	EFFORT["$pr"]="$(effort_for "$pr")"
	QUEUE_DISPLAY+=("${pr}[${EFFORT[$pr]}]")
done

# ---- Report the plan -------------------------------------------------------
echo "Repository: ${REPO}"
echo "Agent CLI: ${AGENT_CLI}"
echo "Unreviewed: ${UNREVIEWED[*]:-(none)}"
echo "Re-review (new commits): ${STALE[*]:-(none)}"
echo "Requested re-review: ${REQUESTED[*]:-(none)}"
if [[ "${#DEFERRED[@]}" -gt 0 ]]; then
	echo "Deferred (hourly cap): ${DEFERRED[*]}"
fi
# The window slides far enough to free a slot one hour after its oldest verdict.
NEXT_SLOT="(now)"
if [[ -n "$OLDEST_IN_WINDOW" ]]; then
	NEXT_SLOT="$(jq -rn --arg t "$OLDEST_IN_WINDOW" '($t | fromdateiso8601 + 3600) | todate')"
fi
echo "Requested re-reviews: ${SPENT}/${REQUESTS_PER_HOUR:-unlimited} used this hour, next slot ${NEXT_SLOT}"
if [[ "$FORCE" -eq 1 ]]; then
	echo "Forced re-review of unchanged PRs enabled (--force)."
else
	echo "Skipped (already reviewed at head, unchanged): ${SKIPPED[*]:-(none)}"
fi
if [[ "${#IGNORE_EMAIL_LIST[@]}" -gt 0 ]] && [[ -z "$TARGET_PR" ]]; then
	echo "Ignored (author email): ${IGNORED[*]:-(none)}"
fi
# Reported only when the filter is on, so a run that did not ask for it is not
# told about a line of triage that could not have applied.
if [[ "$IGNORE_APPROVED" -eq 1 ]] && [[ -z "$TARGET_PR" ]]; then
	echo "Ignored (approved): ${IGNORED_APPROVED[*]:-(none)}"
fi
if [[ "${#FOREIGN[@]}" -gt 0 ]]; then
	echo "Council marker from another account (queued anyway): ${FOREIGN[*]}"
	echo "      A token rotated between runs reads this way, and so does a forged"
	echo "      marker. Both are reviewed rather than trusted. If these are your own"
	echo "      earlier verdicts, expect to pay for them again."
fi
if [[ -n "$FORCE_EFFORT" ]]; then
	echo "Effort: forced to '${FORCE_EFFORT}' for every PR (--effort)."
fi
echo "Queue (${#QUEUE[@]}): ${QUEUE_DISPLAY[*]:-(none)}"
echo

if [[ "${#QUEUE[@]}" -eq 0 ]]; then
	echo "Nothing to review."
	if [[ "${#SKIPPED[@]}" -gt 0 ]]; then
		echo "(${#SKIPPED[@]} PR(s) already reviewed at head; pass --force to re-review.)"
	fi
	if [[ "${#IGNORED[@]}" -gt 0 ]]; then
		echo "(${#IGNORED[@]} PR(s) skipped by author email; pass --no-ignore-emails to review them.)"
	fi
	if [[ "${#IGNORED_APPROVED[@]}" -gt 0 ]]; then
		echo "(${#IGNORED_APPROVED[@]} PR(s) skipped as approved; drop --ignore-approved to review them.)"
	fi
	exit 0
fi

if [[ "$RUN" -eq 0 ]]; then
	echo "DRY RUN — nothing will be executed or posted. Re-run with --run to execute."
	echo
fi

# ---- Confirm the GitHub edits ----------------------------------------------
# A --run batch is not a local operation. Each PR is handed to claude with
# permissions bypassed and a prompt telling the council to post without asking,
# so the first visible sign of a wrong repository or an unintended queue is a
# public comment on somebody else's pull request. Say so, then make the
# operator type it out against the queue printed above.
#
# The answer is read from stdin rather than from a terminal the script demands:
# that keeps it usable from a wrapper, and EOF — cron, `</dev/null`, a closed
# pipe — is not an answer, so the silent path aborts instead of posting.
if [[ "$RUN" -eq 1 ]] && [[ "$YES" -eq 0 ]]; then
	cat >&2 <<CONFIRM
WARNING: this makes visible edits on GitHub.

Reviewing ${#QUEUE[@]} pull request(s) in ${REPO}, each handed to ${AGENT_CLI}
with permissions bypassed:

  ${CLI_BYPASS}

and a prompt telling the council to post its verdict without asking. Expect a
public review comment on every PR in the queue above, authored by the account
gh is authenticated with, plus the API spend of each review.

A re-review request the hourly cap could not admit also draws a short reply on
its own pull request explaining the limit — at most one per pull request per
hour, and only for requests that were authorised in the first place.

Re-run without --run to see the plan alone, or with --yes to skip this prompt.
CONFIRM
	printf 'Type "yes" to proceed: ' >&2
	if ! read -r reply; then
		reply=""
	fi
	if [[ "${reply,,}" != "yes" ]]; then
		echo "Aborted: nothing was run and nothing was posted." >&2
		exit 1
	fi
	echo >&2
fi

# ---- Tell deferred requesters why nothing happened -------------------------
# Once per PR per window. A reply per request would hand anyone with write
# access a way to make this account post repeatedly on a public thread; a reply
# per window tells them what they need once. Only authorised requests reach
# here, so an unauthorised one is answered with silence rather than with a
# comment it could have provoked.
if [[ "$RUN" -eq 1 ]] && [[ "${#DEFERRED[@]}" -gt 0 ]]; then
	for pr in "${DEFERRED[@]}"; do
		# shellcheck disable=SC2310 # a non-zero return is "not yet declined",
		# which is the answer being asked for, not a failure.
		if declined_in_window "${COMMENTS_JSON[$pr]:-}" "$WINDOW_START"; then
			continue
		fi
		who=""
		for i in "${!REQ_PR[@]}"; do
			[[ "${REQ_PR[$i]}" = "$pr" ]] && who="${REQ_LOGIN[$i]}"
		done
		decline_body="$(mktemp)"
		{
			printf 'Re-review requested by @%s is rate limited: %s of %s already used this hour.\n\n' \
				"$who" "$SPENT" "$REQUESTS_PER_HOUR"
			printf 'The next slot opens at %s. Nothing to do — ask again after then.\n\n' "$NEXT_SLOT"
			printf '%s%s -->\n' "$RATE_MARKER_OPEN" "$NEXT_SLOT"
		} >"$decline_body"
		gh pr comment "$pr" --repo "$REPO" --body-file "$decline_body" >/dev/null 2>&1 ||
			echo "PR #${pr}: could not post the rate-limit reply; continuing." >&2
		rm -f "$decline_body"
	done
fi

# ---- Process each queued PR sequentially -----------------------------------
failures=()

for pr in "${QUEUE[@]}"; do
	pr_url="https://github.com/${REPO}/pull/${pr}"
	# standard effort omits the keyword so the council applies its default
	# (and, upstream, its own triage); quick/deep pass the word explicitly.
	case "${EFFORT[$pr]}" in
	quick) effort_kw="quick " ;;
	deep) effort_kw="deep " ;;
	*) effort_kw="" ;;
	esac
	# Everything the council itself reads, minus the command name: the two hosts
	# differ only in how they are told which command these arguments belong to.
	council_args="${effort_kw}${pr_url} -- post the verdict, auto-send without asking"

	# Build the invocation once so the dry-run preview is exactly what --run
	# executes. `render` is what the terminal sees; anything whose output is
	# already human-readable passes through untouched.
	render=(cat)
	if [[ "$AGENT_CLI" = "opencode" ]]; then
		cmd=(opencode run --command review-council --auto "$council_args")
		if [[ -n "${EXTRA_OPENCODE_ARGS:-}" ]]; then
			# Intentional word-splitting so EXTRA_OPENCODE_ARGS="--model x/y"
			# expands into separate arguments.
			# shellcheck disable=SC2206
			cmd+=(${EXTRA_OPENCODE_ARGS})
		fi
	else
		cmd=(claude -p "/review-council ${council_args}" --permission-mode bypassPermissions)
		# A council review runs for tens of minutes with nothing to show for it:
		# under the default text format `claude -p` prints only its final
		# message, so the log below stays empty until the run is already over
		# and an operator watching it cannot tell work from a wedge. Stream
		# structured events instead — the log keeps them verbatim for a later
		# pass, and PROGRESS_FILTER renders them a line at a time for the
		# terminal. --verbose is not decoration: --print rejects stream-json
		# without it. An operator who names a format in EXTRA_CLAUDE_ARGS gets
		# that one alone rather than two --output-format flags whose winner is
		# decided by claude's argument parser.
		if [[ "${EXTRA_CLAUDE_ARGS:-}" != *--output-format* ]]; then
			cmd+=(--output-format stream-json --verbose)
			render=(jq -Rr --unbuffered "$PROGRESS_FILTER")
		fi
		if [[ -n "${MAX_BUDGET_USD:-}" ]]; then
			cmd+=(--max-budget-usd "$MAX_BUDGET_USD")
		fi
		if [[ -n "${EXTRA_CLAUDE_ARGS:-}" ]]; then
			# Intentional word-splitting so EXTRA_CLAUDE_ARGS="--model opus"
			# expands into separate arguments.
			# shellcheck disable=SC2206
			cmd+=(${EXTRA_CLAUDE_ARGS})
		fi
	fi

	if [[ "$RUN" -eq 0 ]]; then
		printf 'PR #%s -> %s\n' "$pr" "$(printf '%q ' "${cmd[@]}")"
		continue
	fi

	# Namespace logs by repo so the same PR number in two repos does not collide.
	repo_slug="${REPO//\//-}"
	mkdir -p "$LOG_DIR"
	log="${LOG_DIR}/${repo_slug}-pr-${pr}.log"
	echo "=== PR #${pr} : reviewing ${REPO} at ${EFFORT[$pr]} effort (log: ${log}) ==="

	# A failure on one PR must not abort the whole batch. Lift BOTH errexit and
	# the ERR trap around the invocation: the trap fires on a failed pipeline
	# even under `set +e`, and its exit would kill the run. Re-arm both after.
	trap - ERR
	set +e
	"${cmd[@]}" 2>&1 | tee "$log" | "${render[@]}"
	rc=${PIPESTATUS[0]}
	set -e
	# shellcheck disable=SC2064  # re-arm with ERR_TRAP's literal body (deferred $?/$LINENO)
	trap "$ERR_TRAP" ERR

	if [[ "$rc" -ne 0 ]]; then
		echo "PR #${pr}: claude exited ${rc} (see ${log}); continuing with next PR." >&2
		failures+=("$pr")
	else
		echo "PR #${pr}: done."
	fi
done

# ---- Summary ---------------------------------------------------------------
if [[ "$RUN" -eq 1 ]]; then
	if [[ "${#failures[@]}" -gt 0 ]]; then
		echo "Completed with ${#failures[@]} failed PR(s): ${failures[*]}" >&2
		exit 1
	fi
	echo "All ${#QUEUE[@]} PR review(s) completed."
fi
