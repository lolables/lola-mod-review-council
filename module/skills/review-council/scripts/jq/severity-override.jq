# severity-override.jq — the project's Severity override applied to the
# verified findings in findings.json.
#
# Input: findings.json, already checked by the script: an object whose
# verified findings are objects with a CRITICAL/HIGH/MEDIUM/LOW severity and
# an object (or absent) provenance. Args: $terms (--argjson), one entry per
# configured persona, {"guard": {op, level, term}}, op one of "<=" (cap), ">="
# (floor), "=" (set).
#
# Output: {doc: <findings.json, re-levelled>, changes: [{id, agent, from, to,
# term}]}, one change per finding whose severity moved.
#
# A term matches the finding's own `agent`, divisor-<persona>-code or -spec.
# For a merged finding that is the surviving author: credits in
# provenance.consolidated_from are attribution and keep the level each
# reviewer filed. A script finding (provenance.validator.result "SCRIPT") is
# computed from the diff and is never re-levelled; the mark, not the agent
# name, identifies it (verify.md Step 4).
#
# Each change is appended to provenance.calibrated_from, the one audit record
# of severity changes. A finding raised to HIGH or CRITICAL without an impact
# gets one, because every blocking finding carries one. A finding already
# within its bound is left exactly as it is, so a re-run changes nothing.

def rank: {"LOW": 0, "MEDIUM": 1, "HIGH": 2, "CRITICAL": 3}[.];

# The level a finding ends at under term $t.
def bounded($t):
	(.severity | rank) as $have
	| ($t.level | rank) as $want
	| if $t.op == "<=" then (if $have > $want then $t.level else .severity end)
	  elif $t.op == ">=" then (if $have < $want then $t.level else .severity end)
	  else $t.level end;

# The term configured for a finding's own agent, or null.
def term_for($terms):
	.agent as $a
	| [$terms | to_entries[] | select($a == "divisor-\(.key)-code" or $a == "divisor-\(.key)-spec") | .value]
	| first;

[(.verified // []) | to_entries[]
	| .key as $i
	| .value as $f
	| select(($f.provenance.validator.result? // null) != "SCRIPT")
	| ($f | term_for($terms)) as $t
	| select($t != null)
	| ($f | bounded($t)) as $to
	| select($to != $f.severity)
	| {i: $i, id: $f.id, agent: $f.agent, from: $f.severity, to: $to, term: $t.term}] as $changes
| {doc: (reduce $changes[] as $c (.;
	.verified[$c.i] |= (
		.severity = $c.to
		| .provenance = ((.provenance // {})
			| .calibrated_from = ((.calibrated_from // [])
				+ [{from: $c.from, to: $c.to, reason: "config: Severity override \($c.term)"}]))
		| if ($c.to == "HIGH" or $c.to == "CRITICAL") and ((.impact // "") == "")
		  then .impact = "Raised by project configuration (Severity override: \($c.term))."
		  else . end))),
   changes: [$changes[] | del(.i)]}
