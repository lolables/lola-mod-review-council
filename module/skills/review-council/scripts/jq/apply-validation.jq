# apply-validation.jq — apply validator outcomes to findings.json by finding id.
#
# Input: findings.json. Args: $results (from --slurpfile: an array holding the
# .results array, or nothing), $final (bool), $disputed (array of finding ids
# whose RETRACTED outcome the orchestrator judged unsupported).
# Output: {doc: <findings.json>, report: {confirmed, corrected, retracted,
# retracted_now, rejected, pending, unvalidated}}. confirmed, corrected,
# retracted and unvalidated describe the OUTPUT document, so they are the same
# on every pass; retracted_now and rejected describe this pass only.
#
# An outcome is applied only when it ties back to exactly one verified finding:
# its id is known and unique, and its echoed file is that finding's file. The
# echo is what turns a transposed answer from a silent misapplication into a
# FILE_MISMATCH rejection. Every other check is shape: an outcome the pipeline
# cannot apply unambiguously is rejected by name, and the finding it was for
# stays pending — a retry, then UNVALIDATED, never a guess.
#
# The severity list is a copy of verdict-schema.json's enum;
# test-verdict-schema.sh compares every copy against the schema.

def outcomes: ["CONFIRMED", "CORRECTED", "RETRACTED"];
def correctable_fields: ["severity", "line", "title", "description", "recommendation"];
def severities: ["CRITICAL", "HIGH", "MEDIUM", "LOW"];
def nonblank: type == "string" and test("\\S");

# A correction may only touch the fields a validator is in a position to judge.
# line is allowed to change because the validator reads the file and may
# relocate a finding; it is capped so a reply cannot publish an absurd location.
# file and evidence are not allowed: they were verified mechanically, and
# letting the validator rewrite them would publish evidence nothing ever checked.
def bad_correction:
	.corrections as $c
	| ($c | type) != "object"
	  or ($c | length) == 0
	  or ((($c | keys) - correctable_fields) | length) > 0
	  or (($c | has("severity")) and (any(severities[]; . == $c.severity) | not))
	  or (($c | has("line")) and $c.line != null
	      and (($c.line | type) != "number" or $c.line < 1 or $c.line > 10000000 or ($c.line | floor) != $c.line))
	  or any($c | to_entries[] | select(.key == "title" or .key == "description" or .key == "recommendation");
	         .value | nonblank | not);

. as $doc
| ($doc.verified // []) as $verified
| ($doc.stripped // []) as $stripped
| (($results[0] // []) | if type == "array" then . else [] end) as $entries
| ([$entries[] | select(type == "object") | .id]
   | group_by(.) | map(select(length > 1) | .[0])) as $dups
| [ $entries[]
    | . as $e
    | if ($e | type) != "object" then {id: null, reject: "BAD_RESULT"}
      else
        $e.id as $id
        | ([$verified[] | select(.id == $id)] | first) as $f
        | if ($id | type) != "string" then {id: $id, reject: "UNKNOWN_ID"}
          elif any($dups[]; . == $id) then {id: $id, reject: "DUPLICATE_ID"}
          elif $f == null then
            if any($stripped[]; .id == $id and .provenance.validator.result == "RETRACTED")
            then {id: $id, reject: "ALREADY_FINAL"}
            else {id: $id, reject: "UNKNOWN_ID"} end
          elif $e.file != $f.file then {id: $id, reject: "FILE_MISMATCH"}
          elif ($f.provenance.validator.result // null) != null then {id: $id, reject: "ALREADY_FINAL"}
          elif (any(outcomes[]; . == $e.result) | not) or (($e.reason // null) | nonblank | not) then {id: $id, reject: "BAD_RESULT"}
          elif $e.result == "RETRACTED" and any($disputed[]; . == $id)
          then {id: $id, reject: "DISPUTED"}
          elif $e.result == "RETRACTED" and (($e.evidence // null) | nonblank | not)
          then {id: $id, reject: "NO_EVIDENCE"}
          elif $e.result == "CORRECTED" and ($e | bad_correction) then {id: $id, reject: "BAD_CORRECTION"}
          else {id: $id, accept: $e}
          end
      end ] as $judged
| ([$judged[] | select(has("accept")) | {key: .id, value: .accept}] | from_entries) as $acc
| [ $verified[]
    | . as $f
    | ($acc[$f.id] // null) as $e
    | if $e == null then
        if $final and ($f.provenance.validator.result // null) == null
        then .provenance.validator = {result: "UNVALIDATED",
                                      reason: "no accepted validator outcome after one retry"}
        else . end
      elif $e.result == "CONFIRMED" then
        .provenance.validator = {result: $e.result, reason: $e.reason}
      elif $e.result == "CORRECTED" then
        (reduce ($e.corrections | keys[]) as $k ({}; .[$k] = $f[$k])) as $was
        | . + $e.corrections
        | .provenance.validator = {result: $e.result, reason: $e.reason,
                                   changed_from: $was}
      else
        .status = "stripped" | .reason = "VALIDATOR_RETRACTED"
        | .provenance.validator = {result: $e.result, reason: $e.reason,
                                   evidence: $e.evidence}
      end ] as $applied
| ($applied | map(select(.status == "stripped"))) as $retracted
| ($applied | map(select(.status != "stripped"))) as $kept
| { doc: ($doc | .verified = $kept | .stripped = ($stripped + $retracted)),
    report: {
      confirmed: [$kept[] | select(.provenance.validator.result == "CONFIRMED") | .id],
      corrected: [$kept[] | select(.provenance.validator.result == "CORRECTED") | .id],
      retracted: [$stripped, $retracted | .[] | select(.reason == "VALIDATOR_RETRACTED") | .id],
      retracted_now: [$judged[] | select(.accept.result == "RETRACTED") | .id],
      rejected: [$judged[] | select(has("reject"))
                 | {id: (.id | if type == "string" then .[:64] else null end), reason: .reject}],
      pending: [$kept[] | select((.provenance.validator.result // null) == null) | .id],
      unvalidated: [$kept[] | select(.provenance.validator.result == "UNVALIDATED") | .id]
    } }
