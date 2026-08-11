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
#   3. PRs already reviewed at their current head commit are SKIPPED
#      (no changes to re-review). Pass --force to review them anyway.
#
# Prior reviews and the reviewed commit are detected from the hidden marker
# the council embeds in every comment it posts:
#
#   <!-- review-council:marker sha=<full-head-sha> -->
#
# A PR is "already reviewed at head" when that marker's sha equals the PR's
# current headRefOid. If a lookup fails, the PR is treated as needing review
# (fail-open) rather than skipped.
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

# Print the failing line and exit code on any unhandled error. Kept in a
# variable so the review loop can lift it around the per-PR claude call and
# re-arm it afterwards (a failed pipeline fires the ERR trap even under
# `set +e`, and its exit would otherwise abort the whole batch).
# shellcheck disable=SC2016  # $?/$LINENO are meant to stay literal until the trap fires
err_trap='rc=$?; echo "ERROR: ${BASH_SOURCE[0]}:${LINENO} exited ${rc}" >&2; exit ${rc}'
# shellcheck disable=SC2064  # install err_trap's literal body; its $?/$LINENO stay deferred
trap "$err_trap" ERR

REPO=""   # owner/name; resolved below from URL arg, --repo, or the CWD repo
TARGET="" # positional PR number or URL; empty => review all open PRs
RUN=0
FORCE=0
YES=0 # consent to the GitHub edits given up front, so --run does not prompt
FORCE_EFFORT=""
FORCE_CLI="" # --cli; empty => detect, preferring claude
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

# Effort-classifier thresholds (env-overridable; see header).
DEEP_FILES="${DEEP_FILES:-10}"
QUICK_FILES="${QUICK_FILES:-2}"
# Reject non-numeric thresholds up front: otherwise the `-ge`/`-le` tests below
# error mid-classification and (being inside a `||`) silently misclassify.
[[ "$DEEP_FILES" =~ ^[0-9]+$ ]] || {
	echo "DEEP_FILES must be a non-negative integer, got: '${DEEP_FILES}'" >&2
	exit 2
}
[[ "$QUICK_FILES" =~ ^[0-9]+$ ]] || {
	echo "QUICK_FILES must be a non-negative integer, got: '${QUICK_FILES}'" >&2
	exit 2
}
# Any changed path matching this extended-regex (case-insensitive) forces deep.
# Short/ambiguous tokens (ca, crl, tls, rbac, cert, key) stay segment-anchored
# by the trailing boundary; the distinctive compound forms (certificates,
# authentication, cryptography, ...) are spelled out so they are not missed.
SECURITY_PATHS="${SECURITY_PATHS:-(^|/)(ca|crl|certs?|certificates?|keys?|keystores?|keypairs?|auth|authn|authz|authentication|authorization|crypto|cryptography|secrets?|tls|tokens?|rbac|sign|signing|signature|passwords?|credentials?)([/._-]|$)}"

# Commit-author addresses whose PRs are skipped (see header). The GitHub App
# forms are the numeric +<id> addresses; the bare and vendor addresses cover
# self-hosted and older deployments of the same two bots.
IGNORE_EMAILS_DEFAULT="49699333+dependabot[bot]@users.noreply.github.com
dependabot[bot]@users.noreply.github.com
support@dependabot.com
29139614+renovate[bot]@users.noreply.github.com
renovate[bot]@users.noreply.github.com
renovate@whitesourcesoftware.com
bot@renovateapp.com"
# `-` rather than `:-`, unlike the thresholds above: IGNORE_EMAILS="" has to
# mean "ignore nobody", not "fall back to the default list".
IGNORE_EMAILS="${IGNORE_EMAILS-$IGNORE_EMAILS_DEFAULT}"

# Split on commas and whitespace. Pathname expansion is off around the unquoted
# expansion that does the splitting because every default entry contains
# "[bot]", which globbing reads as a bracket expression: with a file named
# e.g. `dependabotb@users.noreply.github.com` in the working directory, the
# address would be silently rewritten to that filename and match nothing.
IGNORE_EMAIL_LIST=()
set -f
for entry in ${IGNORE_EMAILS//,/ }; do
	IGNORE_EMAIL_LIST+=("$entry")
done
set +f
unset entry

usage() {
	sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^#\{0,1\} \{0,1\}//'
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
for bin in gh jq; do
	command -v "$bin" >/dev/null 2>&1 || {
		echo "Required command not found: $bin" >&2
		exit 1
	}
done

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

# ---- Resolve target repository and (optional) single PR --------------------
# A positional TARGET may be a PR number or a GitHub PR URL. A URL also fixes
# the repository. TARGET_PR empty => review all open PRs.
TARGET_PR=""
if [[ -n "$TARGET" ]]; then
	if [[ "$TARGET" =~ ^[0-9]+$ ]]; then
		TARGET_PR="$TARGET"
	elif [[ "$TARGET" =~ github\.com/([^/]+)/([^/]+)/pull/([0-9]+) ]]; then
		url_owner="${BASH_REMATCH[1]}"
		url_repo="${BASH_REMATCH[2]%.git}"
		TARGET_PR="${BASH_REMATCH[3]}"
		if [[ -n "$REPO" ]] && [[ "$REPO" != "${url_owner}/${url_repo}" ]]; then
			echo "Conflicting repository: --repo '${REPO}' vs URL '${url_owner}/${url_repo}'." >&2
			exit 2
		fi
		REPO="${url_owner}/${url_repo}"
	else
		echo "Target must be a PR number or a GitHub PR URL, got: ${TARGET}" >&2
		exit 2
	fi
fi

# No explicit repo? Fall back to the GitHub repo of the current directory.
if [[ -z "$REPO" ]]; then
	REPO="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)"
fi
if [[ -z "$REPO" ]]; then
	echo "Could not determine the target repository." >&2
	echo "Pass --repo owner/name, give a PR URL, or run inside a checkout of the repo." >&2
	exit 1
fi

# ---- Collect the PRs to consider (number + head SHA) -----------------------
# Single target: just that PR. Otherwise every open PR, newest first.
if [[ -n "$TARGET_PR" ]]; then
	prs_raw="$(gh pr view "$TARGET_PR" --repo "$REPO" \
		--json number,headRefOid --jq '[.number, .headRefOid] | @tsv' 2>/dev/null || true)"
	if [[ -z "$prs_raw" ]]; then
		echo "PR #${TARGET_PR} not found in ${REPO}." >&2
		exit 1
	fi
else
	prs_raw="$(gh pr list --repo "$REPO" --state open --limit 500 \
		--json number,headRefOid --jq 'sort_by(.number) | reverse | .[] | [.number, .headRefOid] | @tsv')"
	if [[ -z "$prs_raw" ]]; then
		echo "No open pull requests found in ${REPO}."
		exit 0
	fi
fi

# ---- Classify each PR against its prior Review Council comment --------------
# reviewed_sha_for <pr> -> the sha= from the most recent review-council marker
# comment, or empty if none (or on lookup failure -> fail-open to "needs review").
reviewed_sha_for() {
	local pr="$1" body
	body="$(gh pr view "$pr" --repo "$REPO" --json comments \
		--jq '[.comments[] | select(.body | contains("review-council:marker")) | .body] | last // ""' \
		2>/dev/null || true)"
	if [[ "$body" =~ sha=([0-9a-fA-F]+) ]]; then
		printf '%s' "${BASH_REMATCH[1]}"
	fi
}

# ignored_author <pr> -> success when the PR was written entirely by addresses
# on IGNORE_EMAIL_LIST, and so should not be reviewed at all.
#
# "Entirely", not "at all": one human commit on a Renovate branch is human work
# and has to come back for review, and a rebase or merge commit a bot authored
# must not disqualify a human's PR. The `seen` guard makes the empty case false
# rather than vacuously true, so a gh failure (which yields no addresses) fails
# open to reviewing — the same stance reviewed_sha_for takes.
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
	if [[ "$files" -ge "$DEEP_FILES" ]] ||
		printf '%s' "$json" | jq -r '.files[].path' 2>/dev/null | grep -qiE "$SECURITY_PATHS"; then
		printf 'deep'
	elif [[ "$is_bot" = 1 ]] && [[ "$files" -le "$QUICK_FILES" ]]; then
		printf 'quick'
	else
		printf 'standard'
	fi
}

UNREVIEWED=() # no prior council comment
STALE=()      # reviewed, but at an older commit (new changes since)
SKIPPED=()    # reviewed at current head, nothing changed
IGNORED=()    # written entirely by a denied address (batch runs only)

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
	if [[ -z "$TARGET_PR" ]] && ignored_author "$pr"; then
		IGNORED+=("$pr")
		continue
	fi
	reviewed="$(reviewed_sha_for "$pr")"
	if [[ -z "$reviewed" ]]; then
		UNREVIEWED+=("$pr")
	elif [[ "$reviewed" = "$head" ]]; then
		SKIPPED+=("$pr")
	else
		STALE+=("$pr")
	fi
done <<<"$prs_raw"

# Build the work queue: unreviewed first, then stale re-reviews. With --force,
# append the otherwise-skipped (unchanged) PRs to the end and clear the skip list.
QUEUE=("${UNREVIEWED[@]}" "${STALE[@]}")
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
if [[ "$FORCE" -eq 1 ]]; then
	echo "Forced re-review of unchanged PRs enabled (--force)."
else
	echo "Skipped (already reviewed at head, unchanged): ${SKIPPED[*]:-(none)}"
fi
if [[ "${#IGNORE_EMAIL_LIST[@]}" -gt 0 ]] && [[ -z "$TARGET_PR" ]]; then
	echo "Ignored (author email): ${IGNORED[*]:-(none)}"
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
	# shellcheck disable=SC2064  # re-arm with err_trap's literal body (deferred $?/$LINENO)
	trap "$err_trap" ERR

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
