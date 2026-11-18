# check-disposition.jq — the closed set of edits Disposition may make to
# findings.json, checked against the snapshot taken before it was dispatched.
#
# Input: findings.json as Disposition left it. Args: $mode ("check" or
# "snapshot"), $pre (--slurpfile: the snapshot rc-check-disposition.sh
# --snapshot wrote; unused, and may be null, in snapshot mode), $pairs (the
# column-0 Author/Timestamp pairs of pr-conversation.txt, as [{by, at}]),
# $ledger (the prior ledger's entries by id, from the snapshot's copy) and
# $revoked (ledger-revoked.json, [] when absent; null when it did not parse; "not-a-file" when it is not a regular file).
# Output, check mode: {violations: [string], counts: {resolved, suppressed_low,
# kept}}. No violations means every edit is within the rules.
# Output, snapshot mode: whether the input is a document the check can tie
# finding by finding (snapshot_ok), so --snapshot and the check share one
# definition of it.
#
# The subagent reads PR conversation the PR author controls, and the council
# verdict depends only on the severities left in `verified`. So the rules bound
# what a reply can do, whatever the subagent was talked into: it may write
# status, reason and provenance.disposition on a finding, and move a finding
# from verified to stripped as resolved (MEDIUM/LOW only) or suppressed-low (LOW
# only). Nothing else. `verdicts` is not checked here: rc-check-disposition.sh
# derives it afresh from what passes these rules (jq/recompute-verdicts.jq), so
# no edit to it survives the check.
#
# Every id a message echoes from the edited document is truncated and quoted:
# the subagent writes that document, and the message reaches the orchestrator.

def nonblank: type == "string" and test("\\S");
def str_or_null: . == null or type == "string";
def show: tostring | .[:64] | tojson;
def disp_keys: ["action", "at", "by", "claim", "claim_verified", "evidence", "ledger_id", "note", "reason", "source"];
def move_reason: {"resolved": "DISPOSITION_RESOLVED", "suppressed-low": "DISPOSITION_SUPPRESSED_LOW"};
def is_doc: type == "object"
	and all(.verified, .correctable, .stripped; type == "array" and all(.[]; type == "object"));
def all_ids: [.verified[], .correctable[], .stripped[] | .id];
def snapshot_ok: is_doc and (all_ids | all(type == "string") and length == (unique | length));
def where($id): if any(.verified[]; .id == $id) then "verified"
	elif any(.stripped[]; .id == $id) then "stripped"
	elif any(.correctable[]; .id == $id) then "correctable"
	else null end;
# A finding minus the three fields Disposition may write.
def frozen: del(.status, .reason)
	| if (.provenance | type) == "object" then del(.provenance.disposition) else . end;

# Who the disposition says it acts for (#138). A reply is named by the column-0
# Author and Timestamp pr-conversation.txt holds, so a disposition cannot be
# attributed to someone who never wrote; a settlement by its id in the prior
# ledger, with that entry's own who and at, so the ledger the next comment
# carries says who asked for what. A deferral only ever suppresses, and a kept
# claim only ever resolves or stays kept: a settlement cannot change kind.
def disp_source_problems($pairs; $ledger):
	if .source == "pr-comment" then
		if .ledger_id != null then "provenance.disposition from a reply (source \"pr-comment\") must have ledger_id null"
		elif ({by, at} | IN($pairs[]) | not) then "provenance.disposition names a reply (by, at) that pr-conversation.txt does not hold"
		else empty end
	elif .source == "ledger" then
		.ledger_id as $id
		| if ($id | type) != "string" or ($ledger | has($id) | not)
		  then "provenance.disposition names a settlement (ledger_id) that prior-settlements.json does not hold"
		  elif .by != $ledger[$id].who or .at != $ledger[$id].at then "provenance.disposition by and at must be the settlement's Who and At"
		  elif $ledger[$id].action == "deferred" and .action != "suppressed-low" then "a deferred settlement may only produce suppressed-low"
		  elif $ledger[$id].action == "kept" and .action == "suppressed-low" then "a kept settlement may only produce resolved or kept"
		  else empty end
	else "provenance.disposition.source is not \"pr-comment\" or \"ledger\"" end;

# The shape and null pattern disposition.md's Step 3 prompt specifies.
def disp_problems($pairs; $ledger):
	if type != "object" then "provenance.disposition is not an object"
	elif keys != disp_keys then "provenance.disposition must have exactly the keys source, ledger_id, by, at, action, claim, claim_verified, evidence, reason, note"
	elif ([.claim, .evidence, .reason, .note] | all(str_or_null) | not) then "provenance.disposition claim, evidence, reason and note must each be a string or null"
	else
		disp_source_problems($pairs; $ledger),
		(if .action == "resolved" then
			if .claim_verified != true or (.evidence | nonblank | not) or .reason != null or .note != null
			then "resolved needs claim_verified true, evidence set, reason and note null" else empty end
		elif .action == "kept" then
			if .claim_verified != false or (.note | nonblank | not) or .evidence != null or .reason != null
			then "kept needs claim_verified false, note set, evidence and reason null" else empty end
		elif .action == "suppressed-low" then
			if .claim_verified != null or (.reason | nonblank | not)
			then "suppressed-low needs claim_verified null and reason set" else empty end
		else "provenance.disposition.action is not resolved, kept or suppressed-low" end)
	end;

# Violations for one finding the snapshot holds in verified or stripped.
def finding_problems($o; $n; $from; $to):
	"\($o.id): " as $p
	| ($n.provenance | type == "object" and has("disposition")) as $has_d
	| (if $has_d then $n.provenance.disposition else null end) as $d
	| ($d | if type == "object" then .action else null end) as $act
	| if ($o.provenance.validator.result? // null) == "SCRIPT" then
		if $n != $o or $to != $from then $p + "is a script finding (rc-check-symlinks); Disposition never edits or moves it" else empty end
	elif $from == "stripped" then
		if $n != $o or $to != $from then $p + "was already stripped; Disposition never edits or moves it" else empty end
	# Safe only because the top-level "correctable changed" rule fires for it.
	elif $to == "correctable" then empty
	else
		(($o | frozen) as $a | ($n | frozen) as $b
		 | [$a | keys[] | select($a[.] != $b[.])] as $changed
		 | ([$b | keys[]] - [$a | keys[]] | length) as $added
		 | if ($changed | length) > 0 or $added > 0 then
			$p + "changed " + ($changed + (if $added > 0 then ["\($added) added key(s)"] else [] end) | join(", "))
			+ "; Disposition may write only status, reason and provenance.disposition"
		   else empty end),
		(if $has_d then ($d | disp_problems($pairs; $ledger) | $p + .) else empty end),
		(if $to == "verified" then
			(if $n.status != $o.status or $n.reason != $o.reason
			 then $p + "status or reason changed but the finding stayed in verified" else empty end),
			(if $act == "resolved" or $act == "suppressed-low"
			 then $p + "marked \($act) but left in verified; Step 4 moves it to stripped" else empty end)
		else
			if $act != "resolved" and $act != "suppressed-low" then
				$p + "moved to stripped without a resolved or suppressed-low disposition"
			else
				(if $n.status != "stripped" or $n.reason != move_reason[$act]
				 then $p + "moved as \($act) needs status \"stripped\" and reason \"\(move_reason[$act])\"" else empty end),
				(if $act == "suppressed-low" and $o.severity != "LOW"
				 then $p + "suppressed-low on a \($o.severity) finding; a scoping hint may suppress only LOW" else empty end),
				(if $act == "resolved" and $o.severity != "MEDIUM" and $o.severity != "LOW"
				 then $p + "resolved on a \($o.severity) finding; a reply may resolve only MEDIUM or LOW, never HIGH or CRITICAL" else empty end)
			end
		end)
	end;

if $mode == "snapshot" then snapshot_ok
else
$pre[0] as $old
| . as $new
| if (is_doc | not) then
	{violations: ["findings.json is not a findings document (an object with verified, correctable and stripped arrays of findings)"], counts: {}}
else
	($old | all_ids) as $old_ids
	| ($new | all_ids) as $new_ids
	| ($new.verified + $new.correctable + $new.stripped
	   | map(select(.id | type == "string") | {key: .id, value: .}) | from_entries) as $by_id
	| [
		(if ($new | keys) != ($old | keys) then "top-level keys changed" else empty end),
		(("correctable", "total_findings", "duplicates_consolidated", "missing_verdicts") as $k
		 | if $new[$k] != $old[$k] then "\($k) changed" else empty end),
		(if any($new_ids[]; type != "string") then "a finding has a missing or non-string id" else empty end),
		([$new_ids[] | select(type == "string")] | group_by(.) | map(select(length > 1) | .[0])
		 | if length > 0 then "duplicate id(s): \(map(show) | join(", "))" else empty end),
		(($old_ids - $new_ids) | if length > 0 then "finding(s) removed: \(map(show) | join(", "))" else empty end),
		([$new_ids[] | select(type == "string")] - $old_ids
		 | if length > 0 then "finding(s) added: \(map(show) | join(", "))" else empty end),
		(if $revoked == "not-a-file" then "ledger-revoked.json is not a regular file"
		 elif $revoked == null then "ledger-revoked.json is not a JSON array of settlement ids"
		 elif ($revoked | type) != "array" or any($revoked[]; type != "string") then "ledger-revoked.json is not a JSON array of settlement ids"
		 else [$revoked[] | select(. as $i | $ledger | has($i) | not)]
		      | if length > 0 then "ledger-revoked.json names settlement(s) prior-settlements.json does not hold: \(map(show) | join(", "))" else empty end
		 end),
		($old.verified[], $old.stripped[]
		 | . as $o
		 | select($by_id | has($o.id))
		 | finding_problems($o; $by_id[$o.id]; ($old | where($o.id)); ($new | where($o.id))))
	] as $violations
	| {violations: $violations,
	   counts: {
		resolved: [$new.stripped[] | select(.reason == "DISPOSITION_RESOLVED")] | length,
		suppressed_low: [$new.stripped[] | select(.reason == "DISPOSITION_SUPPRESSED_LOW")] | length,
		kept: [$new.verified[] | select((.provenance | objects | .disposition | objects | .action) == "kept")] | length
	   }}
end
end
