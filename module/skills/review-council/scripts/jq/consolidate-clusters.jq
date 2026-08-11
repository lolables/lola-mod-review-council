# Apply a cross-agent consolidation manifest to a findings document.
#
# Input:  findings.json (the whole document).
# Args:   --argjson clusters '[{"members":[{file,line,agent}, ...]}, ...]'
# Output: the same document with each cluster's members merged into one
#         surviving primary.
#
# For each cluster the most severe member becomes the primary; the rest are
# folded into primary.provenance.consolidated_from and removed. A cluster
# resolving to fewer than two DISTINCT findings is a no-op — a manifest can cite
# a member that verification stripped, or name one member twice, and rewriting a
# lone finding as its own merge would be a lie about what happened.
#
# duplicates_consolidated and consolidation_records accumulate across clusters
# rather than being replaced, so an exact-dedup count already in the document
# survives.

def rank: {"CRITICAL": 5, "HIGH": 4, "MEDIUM": 3, "LOW": 2, "INFO": 1}[.] // 0;
def ident: {file: .file, line: .line, agent: .agent};

. as $root
| (reduce $clusters[] as $c (
	{verified: ($root.verified // []), records: [], semantic: 0};
	( [ $c.members[] as $m | .verified[]
	    | select(.file == $m.file and .line == $m.line and .agent == $m.agent) ] ) as $found
	# Distinct identities, not raw matches. A manifest can name one member
	# twice, and one agent can file two findings at the same line; either way
	# `$found` holds two entries the reducer has nothing to fold between. The
	# old `($found | length) < 2` let that through, appended a record claiming a
	# merge that never happened, and — because nothing was removed — never
	# engaged on the next pass, so the record was appended again on every run of
	# the iteration loop.
	| ( $found | map(ident) | unique ) as $idents
	| if ($idents | length) < 2 then .
	  else
	    ( $found | to_entries ) as $entries
	    # Secondaries are selected by POSITION, not by identity. Two findings in
	    # one cluster can share {file,line,agent} — one agent filing two claims
	    # at the same line — and an identity filter drops such a sibling from
	    # $secs while the rewrite below still matches it. It was folded nowhere
	    # and emitted as a second copy of the primary: the count looked right
	    # while the reviewer's actual claim vanished.
	    | ( $entries | sort_by([ (.value.severity | rank), (.value.evidence | length), .value.agent ]) | last ) as $pentry
	    | $pentry.value as $primary
	    | ( $entries | map(select(.key != $pentry.key)) | map(.value) ) as $secs
	    | ( $secs | map({agent, severity, angle: .description, recommendation}) ) as $folded
	    | ( if ($found | any(.verdict == "REQUEST CHANGES"))
	        then "REQUEST CHANGES" else $primary.verdict end ) as $verdict
	    | ( $primary + {verdict: $verdict}
	        + {provenance: (($primary.provenance // {})
	            + {consolidated_from: (($primary.provenance.consolidated_from // []) + $folded)})} ) as $newprimary
	    | ( [ $secs[] | ident ] ) as $secids
	    # Emit the primary on its FIRST identity match and drop every later one.
	    # A plain map would rewrite every finding sharing the primary's identity
	    # into $newprimary, duplicating it. Accumulating into an array is what
	    # makes "have I emitted it yet?" answerable at all — `map` has no memory
	    # of the elements it already produced.
	    #
	    # `any(f)` rebinds `.` to each element of ITS input, so a bare `ident`
	    # inside would be evaluated against the $secids element rather than the
	    # finding being filtered — reducing the test to `secid == secid`, always
	    # true, which deletes every non-primary finding in the array. Capture
	    # the finding as $fid at the boundary.
	    | .verified = ( reduce .verified[] as $f ([];
	        ($f | ident) as $fid
	        | if $fid == ($primary | ident)
	          then (if (map(ident) | any(. == $fid)) then . else . + [$newprimary] end)
	          elif ($secids | any(. == $fid)) then .
	          else . + [$f] end ) )
	    | .records += [ {primary: ($primary | ident), merged: $secids} ]
	    | .semantic += ($secs | length)
	  end
)) as $acc
| $root
	+ {verified: $acc.verified}
	+ {duplicates_consolidated: (($root.duplicates_consolidated // 0) + $acc.semantic)}
	+ {consolidation_records: (($root.consolidation_records // []) + $acc.records)}
