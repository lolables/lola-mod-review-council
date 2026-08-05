# Deduplicate an array of verified findings.
#
# Input:  the `verified` array from rc-verify-evidence.sh.
# Output: the same array with exact duplicates merged.
#
# Two findings are duplicates when they cite the same file and the same
# evidence, and their lines are either both null or within +-5 of each other.
# The window exists because a citation may be slightly off and still verify;
# matching on the exact line would leave those unmerged.
#
# On merge the survivor keeps the MOST SEVERE severity, so a HIGH citing the
# same line as a LOW is never silently downgraded, and the outcome does not
# depend on the order agents happened to be dispatched in. Every other field
# stays from the first occurrence.
#
# The loser is folded into the survivor's provenance.consolidated_from in the
# shape consolidate-clusters.jq writes, so the report's "Also flagged by" list
# covers both paths. Two reviewers converging on one line is the same event
# whether they quoted the same bytes (here) or were clustered as semantically
# equal (there); crediting it in one and dropping it in the other loses a
# reviewer's angle with nothing recording it was ever filed.
#
# Only a duplicate from a DIFFERENT agent is credited. The dedup key excludes
# the agent deliberately, so one reviewer listing the same finding twice merges
# here too — and folding that would publish "Also flagged by" naming the
# survivor's own author.

# Anything unlisted ranks 0, below every real severity, so a typo'd value can
# never displace a genuine CRITICAL.
def sevrank(s): {"CRITICAL": 4, "HIGH": 3, "MEDIUM": 2, "LOW": 1}[s] // 0;

reduce .[] as $x ([];
	( [ range(0; length) as $j
	    | select(.[$j].file == $x.file and .[$j].evidence == $x.evidence and
	        ((.[$j].line == null and $x.line == null) or
	         (.[$j].line != null and $x.line != null and
	          ((.[$j].line - $x.line | if . < 0 then -. else . end) <= 5))))
	    | $j ] | first) as $idx
	| if $idx == null then . + [$x]
	  else
	    ( if $x.agent != .[$idx].agent
	      then .[$idx].provenance.consolidated_from =
	        ((.[$idx].provenance.consolidated_from // [])
	         + [{agent: $x.agent, severity: $x.severity,
	             angle: $x.description, recommendation: $x.recommendation}])
	      else . end )
	    | ( if sevrank($x.severity) > sevrank(.[$idx].severity)
	        then .[$idx].severity = $x.severity
	        else . end )
	  end)
