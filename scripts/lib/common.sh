#!/usr/bin/env bash
# Process setup shared by the review-council operator scripts. Source this
# file; do not execute it.
#
# Nothing here touches the network. It installs the error trap, checks for the
# binaries the callers need, and turns the environment into validated globals —
# the last of which is the point: a threshold that reads as a string makes the
# numeric tests below it error mid-classification, and because those tests sit
# inside a `||` the failure surfaces as a silently wrong effort tier rather
# than as an error.
#
# shellcheck disable=SC2250 # Bare $var, as every other shell source here writes
# it. Enabling the braces-always style in these files would make them the only
# ones of their kind in the tree; consistency is worth more than the check.

[[ -n "${_RC_COMMON_LOADED:-}" ]] && return 0
_RC_COMMON_LOADED=1

# Print the failing line and exit code on any unhandled error. Kept in a
# variable because the driver lifts the trap around each agent invocation and
# re-arms it afterwards, and the two spellings must not drift apart.
# shellcheck disable=SC2016  # $?/$LINENO are meant to stay literal until the trap fires
# shellcheck disable=SC2034  # read by the scripts that source this file
ERR_TRAP='rc=$?; echo "ERROR: ${BASH_SOURCE[0]}:${LINENO} exited ${rc}" >&2; exit ${rc}'

# require_commands <cmd>... -> exits 1 naming the first binary that is missing.
#
# Exits rather than returns non-zero: this project sets neither errtrace nor
# set -E, so a caller's ERR trap does not fire on a non-zero return from inside
# a function body. Returning 1 here and trusting the trap to report it would
# fail silently.
require_commands() {
	local bin
	for bin in "$@"; do
		command -v "$bin" >/dev/null 2>&1 || {
			echo "Required command not found: $bin" >&2
			exit 1
		}
	done
}

# Cap on comment-requested re-reviews per hour; empty means no cap. `-` rather
# than `:-`, as with IGNORE_EMAILS below: REREVIEW_PER_HOUR="" has to mean
# "unlimited", not "fall back to the default". --requests-per-hour overrides it.
REQUESTS_PER_HOUR="${REREVIEW_PER_HOUR-}"

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
# Checked here rather than at the flag, so REREVIEW_PER_HOUR gets the same
# rejection the flag gives: a cap that silently reads as "unlimited" is the one
# misconfiguration this setting exists to prevent.
[[ -z "$REQUESTS_PER_HOUR" || "$REQUESTS_PER_HOUR" =~ ^[0-9]+$ ]] || {
	echo "REREVIEW_PER_HOUR must be a non-negative integer, got: '${REQUESTS_PER_HOUR}'" >&2
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
