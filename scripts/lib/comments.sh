#!/usr/bin/env bash
# Readers for the traces review-council leaves on a pull request's comment
# timeline. Source this file; do not execute it.
#
# Every function here is pure: it takes a comments payload as a string and
# writes to stdout. No gh, no globals beyond the two marker constants. That is
# deliberate — the forgery boundary lives in these jq programs, and a boundary
# you can test with a string and no mock is one that actually gets tested.
#
# Empty output means "no usable verdict", and a gh failure upstream produces
# exactly that. Callers treat it as "needs review": the fail-open stance the
# driver takes everywhere except requester_authorised.
#
# shellcheck disable=SC2250 # Bare $var, as every other shell source here writes
# it. Enabling the braces-always style in these files would make them the only
# ones of their kind in the tree; consistency is worth more than the check.

[[ -n "${_RC_COMMENTS_LOADED:-}" ]] && return 0
_RC_COMMENTS_LOADED=1

# A verdict is a comment carrying a LINE that starts, at column 0, with this.
# The council's own scripts test the same way — rc-lib.sh defines it as
# RC_MARKER_OPEN, rc-post-comment-github.sh applies it as RC_MARKER_LINE_JQ,
# prepare-context.sh anchors its conversation window on it — for a reason worth
# restating here: the marker is public. GitHub's "Quote reply" copies it
# verbatim behind a "> " prefix, anyone who can comment can type one, and a
# finding's evidence can quote a sha= of its own. Column 0 separates a verdict
# from a quote of one; viewerDidAuthor separates ours from a forgery. Matching
# the bare key anywhere in the body accepts all three, and each of them can pin
# a PR at its current head and suppress every later review.
#
# Restated rather than sourced: these scripts point at whichever council the
# host has installed, and must not depend on that skill's file layout.
MARKER_OPEN='<!-- review-council:marker sha='

# The driver's own marker, for the reply it posts when a request is deferred.
# Deliberately a different key from the verdict marker rather than a variant of
# it: a decline must never be readable as a verdict — not by the lookup above,
# not by the council, not by the next person to read the thread.
RATE_MARKER_OPEN='<!-- review-council:rate-limited until='

# council_verdict_for <comments-json> -> "<sha>\t<createdAt>" of the newest
# verdict THIS account posted, or empty when there is none.
#
# Empty output means "needs review": a gh failure, an unparseable body and a
# genuinely unreviewed PR are one answer here, and it is the safe one.
#
# gsub("\r"; "") is not decoration. GitHub stores web-authored bodies with CRLF,
# and a trailing \r defeats both startswith() on a marker and the anchored
# request match in rereview_requests_for.
council_verdict_for() {
	printf '%s' "$1" | jq -r --arg open "$MARKER_OPEN" '
		[ .comments[]?
		  | select(.viewerDidAuthor // false)
		  | select((.isMinimized // false) | not)
		  | select(((.body // "") | gsub("\r"; "") | split("\n") | any(startswith($open))))
		] | sort_by(.createdAt) | last as $v
		| if $v == null then "" else
		    (($v.body | gsub("\r"; "") | split("\n") | map(select(startswith($open))) | last
		      | ltrimstr($open) | split(" ")[0] | split("-->")[0])) as $sha
		    | [$sha, $v.createdAt] | @tsv
		  end
	' 2>/dev/null || true
}

# council_verdict_any_for <comments-json> <scope> ->
# "<sha>\t<createdAt>\t<login>\t<viewerDidAuthor>" of the newest verdict inside
# <scope>, or empty when there is none.
#
# <scope> is "all" (any author) or a single login (only that account's).
# "self" is not a value here: that scope is council_verdict_for's, and the
# caller branches to it rather than passing it down.
#
# THIS READER IS FOR REPORTING, NOT FOR SPENDING. It relaxes exactly one of its
# sibling's three gates — authorship — and the marker is public, so a verdict
# it returns may be one anybody typed. That is tolerable for a table saying
# "somebody reviewed this" and is not tolerable for a driver deciding whether
# to review, which is why council_verdict_for keeps its viewerDidAuthor gate
# and keeps being what the driver calls. The other two gates are untouched: a
# quoted marker and a collapsed comment are no more a verdict from a stranger
# than from us.
#
# The fourth field is what lets a caller say which of the two it got. It comes
# from the payload already fetched, so telling ours from someone else's costs
# no second lookup.
#
# A login is compared, never interpolated: it arrives as a jq --arg and is
# tested with ==, so a login carrying quotes, a bracket ("dependabot[bot]") or
# a newline is matched literally rather than parsed.
council_verdict_any_for() {
	printf '%s' "$1" | jq -r --arg open "$MARKER_OPEN" --arg scope "$2" '
		[ .comments[]?
		  | select($scope == "all" or ((.author.login // "") == $scope))
		  | select((.isMinimized // false) | not)
		  | select(((.body // "") | gsub("\r"; "") | split("\n") | any(startswith($open))))
		] | sort_by(.createdAt) | last as $v
		| if $v == null then "" else
		    (($v.body | gsub("\r"; "") | split("\n") | map(select(startswith($open))) | last
		      | ltrimstr($open) | split(" ")[0] | split("-->")[0])) as $sha
		    | [ $sha, $v.createdAt, ($v.author.login // ""),
		        (if ($v.viewerDidAuthor // false) then "1" else "0" end) ] | @tsv
		  end
	' 2>/dev/null || true
}

# council_verdict_word <comments-json> [scope] -> the verdict word from the
# newest verdict inside <scope>, or empty when there is none to read.
#
# <scope> is "self" (the default, and the only value that existed before this
# reader had one), "all", or a single login — the same vocabulary
# council_verdict_any_for takes, and it must be given the same value that
# chose the verdict being described. It changes WHICH comments are candidates
# and nothing else: the part=1 preference and its pre-ec0dbbc fallback below
# apply unchanged to whatever set the scope admits.
#
# A caller passing nothing gets the gated reading, exactly as before. The
# default carries no money — nothing gates on this word — but it keeps this
# function's answer matching council_verdict_for's when neither is told
# otherwise, so a caller cannot half-widen its report by forgetting an
# argument.
#
# rc-render-comment.sh:610 emits `part=<n> of=<total>` on every marker line, but
# only part 1 carries the `## <emoji> Review Council: <VERDICT>` heading
# (rc-render-comment.sh:380). council_verdict_for takes the newest comment,
# which for a chained verdict is the last part — so this reader prefers our
# newest comment whose marker line carries part=1, not the newest comment
# outright.
#
# `part=` itself is recent (commit ec0dbbc, 2026-08-17); before it the marker
# carried no part key at all, and older verdicts on real PRs are still in that
# shape. So the part=1 preference falls back to the newest marker comment, but
# only when NO comment anywhere in the timeline carries a part= key — if one
# does, this is a chained verdict whose part 1 is out of reach (minimised, or
# posted by someone else), and the honest answer is empty, not a tail part's
# body.
#
# The word is taken verbatim and not normalised against a known vocabulary: a
# status tool that quietly maps an unrecognised verdict onto a recognised one
# is worse than one that shows an unfamiliar string.
#
# Display only. Nothing gates on this, so every failure path is empty output
# rather than an error.
council_verdict_word() {
	printf '%s' "$1" | jq -r --arg open "$MARKER_OPEN" --arg scope "${2:-self}" '
		def marker_line:
			((.body // "") | gsub("\r"; "") | split("\n")
			 | map(select(startswith($open))) | last);

		# Whether ANY comment in the timeline — ours or not, collapsed or not —
		# has ever carried a part= key. This is not a trust decision, only a
		# check of which marker shape this thread has used, which is what tells
		# the pre-ec0dbbc shape apart from a chained verdict whose part 1 this
		# account cannot currently see.
		([ .comments[]? | marker_line | select(. != null) ]
		 | any(test("(^| )part="))) as $any_part_seen
		| [ .comments[]?
		    # The scope decides who may be read, and only that. A collapsed
		    # comment and a quoted marker are no more readable from a stranger
		    # than from us, so both gates below stay where they are.
		    | select(if $scope == "self" then (.viewerDidAuthor // false)
		             elif $scope == "all" then true
		             else ((.author.login // "") == $scope) end)
		    | select((.isMinimized // false) | not)
		    | marker_line as $line
		    | select($line != null)
		    | { createdAt, body: (.body // ""), part1: ($line | test("(^| )part=1( |$)")) }
		  ] as $candidates
		| ( ($candidates | map(select(.part1)) | sort_by(.createdAt) | last)
		    // (if $any_part_seen then null
		        else ($candidates | sort_by(.createdAt) | last)
		        end)
		  ) as $chosen
		| if $chosen == null then ""
		  else
		    ( $chosen.body | gsub("\r"; "") | split("\n")
		      | map(select(test("^## .* Review Council: "))) | first
		    ) as $heading
		    | if $heading == null then "" else ($heading | sub("^## .* Review Council: "; "")) end
		  end
	' 2>/dev/null || true
}

# foreign_verdict_login <comments-json> -> the author of the newest marker-line
# comment this account did NOT post, or empty when there is none.
#
# Two very different things produce that comment and the payload cannot tell
# them apart: a token rotated between runs (or CI filing verdicts under a bot
# account), and a forged marker from anyone who can type one.
#
# So do not choose. Both are reported as unreviewed and get reviewed, which is
# these scripts' answer to every unanswered question — an attacker gains
# nothing, because the review they tried to suppress happens anyway, and a
# rotated token costs one round of re-reviews that the caller is told about
# before it pays for them. Trusting the marker instead would keep the rotated
# token working at the price of letting a stranger switch reviewing off.
#
# prepare-context.sh:281 makes the opposite call on its own lookup, and is
# right to: what it loses by refusing is a maintainer's reply that Disposition
# never reads. Losing data is not the same as suppressing a review.
foreign_verdict_login() {
	printf '%s' "$1" | jq -r --arg open "$MARKER_OPEN" '
		[ .comments[]?
		  | select((.viewerDidAuthor // false) | not)
		  | select((.isMinimized // false) | not)
		  | select(((.body // "") | gsub("\r"; "") | split("\n") | any(startswith($open))))
		] | sort_by(.createdAt) | last | (.author.login // "") // ""
	' 2>/dev/null || true
}

# verdicts_since <comments-json> <iso> -> how many verdicts this account posted
# at or after <iso>. The verdict comments ARE the hourly ledger: timestamped,
# attributable, and already fetched, so the window needs no state file that a
# second checkout or a cron wrapper with a different CWD would silently reset.
#
# Every review posted in the hour spends the window, not only the requested
# ones — the budget being protected is the API bill. What the cap gates is the
# admission of requests: a genuine code change is never held back by it.
#
# Counted across the PRs this run examined, so a single-PR run sees a narrower
# window than a batch. Said plainly in --help rather than papered over.
verdicts_since() {
	printf '%s' "$1" | jq -r --arg open "$MARKER_OPEN" --arg since "$2" '
		[ .comments[]?
		  | select(.viewerDidAuthor // false)
		  | select(((.body // "") | gsub("\r"; "") | split("\n") | any(startswith($open))))
		  | select(.createdAt >= $since)
		] | length
	' 2>/dev/null || echo 0
}

# declined_in_window <comments-json> <window-start-iso> -> success when we have
# already replied to a deferred request on this PR inside the current window.
# Same stateless trick as the ledger: the reply is its own record.
declined_in_window() {
	local n
	n="$(printf '%s' "$1" | jq -r --arg open "$RATE_MARKER_OPEN" --arg since "$2" '
		[ .comments[]?
		  | select(.viewerDidAuthor // false)
		  | select(((.body // "") | gsub("\r"; "") | split("\n") | any(startswith($open))))
		  | select(.createdAt >= $since)
		] | length
	' 2>/dev/null || echo 0)"
	[[ "$n" =~ ^[0-9]+$ ]] && [[ "$n" -gt 0 ]]
}

# rereview_requests_for <comments-json> <since-iso> -> "<login>\t<createdAt>\t<association>"
# lines. A request is a comment newer than the verdict it asks to replace, not
# ours, not collapsed, carrying a line that is exactly the command.
#
# Anchored at column 0 and to end-of-line for the same reason the marker is:
# "> /review-council review" is someone quoting a request, not making one, and
# the command named mid-sentence is a mention. Trailing arguments are
# deliberately not accepted — the effort tier decides what a review costs, and
# a requester does not get to pick it.
rereview_requests_for() {
	printf '%s' "$1" | jq -r --arg since "$2" '
		.comments[]?
		| select((.isMinimized // false) | not)
		| select((.viewerDidAuthor // false) | not)
		| select($since == "" or .createdAt > $since)
		| select(((.body // "") | gsub("\r"; "") | split("\n")
		          | any(test("^/review-council[ \t]+review[ \t]*$"))))
		| [ (.author.login // ""), .createdAt, (.authorAssociation // "") ] | @tsv
	' 2>/dev/null || true
}
