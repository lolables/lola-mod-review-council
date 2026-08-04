# Apply a cross-agent consolidation manifest to a findings document.
#
# Input:  findings.json (the whole document).
# Args:   --argjson clusters '[{"members":[{file,line,agent}, ...]}, ...]'
# Output: the same document with each cluster's members merged into one
#         surviving primary.
#
# For each cluster the most severe member becomes the primary; the rest are
# folded into primary.provenance.consolidated_from and removed. A cluster whose
# manifest names fewer than two findings actually present is a no-op — a
# manifest can cite a member that verification stripped, and rewriting a lone
# finding as its own merge would be a lie about what happened.
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
	| if ($found | length) < 2 then .
	  else
	    ( $found | sort_by([ (.severity | rank), (.evidence | length), .agent ]) | last ) as $primary
	    # `map(select(...))` rebinds `.` to each element, so a bare `ident`
	    # here IS evaluated against the element being tested. That is the
	    # opposite of the `any()` case below — the difference is why the two
	    # are written differently.
	    | ( $found | map(select(ident != ($primary | ident))) ) as $secs
	    | ( $secs | map({agent, severity, angle: .description, recommendation}) ) as $folded
	    | ( if ($found | any(.verdict == "REQUEST CHANGES"))
	        then "REQUEST CHANGES" else $primary.verdict end ) as $verdict
	    | ( $primary + {verdict: $verdict}
	        + {provenance: (($primary.provenance // {})
	            + {consolidated_from: (($primary.provenance.consolidated_from // []) + $folded)})} ) as $newprimary
	    | ( [ $secs[] | ident ] ) as $secids
	    # `any(f)` rebinds `.` to each element of ITS input, so a bare `ident`
	    # inside would be evaluated against the $secids element rather than the
	    # finding being filtered — reducing the test to `secid == secid`, always
	    # true, which deletes every non-primary finding in the array. Capture
	    # the finding as $f at the boundary.
	    | .verified = ( [ .verified[] | . as $f
	        | if (($f | ident) == ($primary | ident)) then $newprimary
	          elif ($secids | any(. == ($f | ident))) then empty
	          else . end ] )
	    | .records += [ {primary: ($primary | ident), merged: $secids} ]
	    | .semantic += ($secs | length)
	  end
)) as $acc
| $root
	+ {verified: $acc.verified}
	+ {duplicates_consolidated: (($root.duplicates_consolidated // 0) + $acc.semantic)}
	+ {consolidation_records: (($root.consolidation_records // []) + $acc.records)}
