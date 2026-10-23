# recompute-verdicts.jq — each agent's verdict in findings.json `.verdicts`,
# derived from the findings and the verdict that agent filed.
#
# Input: findings.json. Args: $declared (--argjson), the per-agent verdicts the
# reviewers filed. Both callers, rc-recompute-verdicts.sh after validation and
# rc-check-disposition.sh after Disposition, pass verdicts/verdicts-map.json,
# which only rc-verify-evidence.sh writes.
# Output: {doc: <findings.json with .verdicts replaced>, changes: [{agent,
# from, to, rule}]}, one change per agent whose entry the document held
# differently; or {problem: string} when an input is not one the rules can read.
#
# The rules used to be prose that the orchestrator applied by hand-editing
# `.verdicts` (verify.md Step 6, disposition.md Step 4), and both renderers
# print that map as is (#52). For each agent in $declared, first match wins:
#
#   HIGH_OR_CRITICAL  it filed a verified HIGH or CRITICAL -> REQUEST CHANGES.
#                     Validator calibration and consolidation can raise a
#                     severity after intake, where the extractor checks it.
#   NO_FINDINGS       it holds no finding -> APPROVE. Stripping, retraction and
#                     a resolved reply can each empty an agent's findings.
#   DECLARED          otherwise -> the verdict it filed. Below HIGH, whether a
#                     finding blocks is the persona's call, not the pipeline's.
#
# An agent holds a finding it filed or is credited on
# (provenance.consolidated_from: Step 3c folded its finding into another
# agent's primary, and its concern survives there), in `verified` or stripped
# as DISPOSITION_SUPPRESSED_LOW: a commenter's scoping hint never changes a
# verdict (disposition.md rule 3). Only the filer is forced by a severity: a
# credited agent may have filed the same defect lower.
#
# Per-agent verdicts stay the reviewer enum, APPROVE or REQUEST CHANGES. APPROVE
# WITH ADVISORIES is a council verdict only (RC_COUNCIL_VERDICT_JQ, rc-lib.sh).
# The map holds exactly the declared agents: an entry for any other agent is a
# hand edit, and is dropped (NOT_DECLARED).

def verdict_ok: . == "APPROVE" or . == "REQUEST CHANGES";
def is_doc: type == "object"
	and all(.verified, .stripped; type == "array" and all(.[]; type == "object"));
def credits($a): .agent == $a
	or any((.provenance | objects | .consolidated_from | arrays)[]; (objects | .agent) == $a);
def holds($a): any(.verified[], (.stripped[] | select(.reason == "DISPOSITION_SUPPRESSED_LOW")); credits($a));
def blocks($a): any(.verified[]; .agent == $a and (.severity == "HIGH" or .severity == "CRITICAL"));

if ($declared | type == "object" and all(.[]; verdict_ok)) | not then
	{problem: "the declared verdict map is not an object of APPROVE or REQUEST CHANGES per agent"}
elif is_doc | not then
	{problem: "findings.json is not a findings document (an object with verified and stripped arrays of findings)"}
else
	. as $doc
	| ((.verdicts | objects) // {}) as $current
	| [$declared | keys[] as $a
		| (if $doc | blocks($a) then {to: "REQUEST CHANGES", rule: "HIGH_OR_CRITICAL"}
		   elif $doc | holds($a) | not then {to: "APPROVE", rule: "NO_FINDINGS"}
		   else {to: $declared[$a], rule: "DECLARED"} end)
		| {agent: $a} + .] as $derived
	| {doc: ($doc | .verdicts = ($derived | map({key: .agent, value: .to}) | from_entries)),
	   changes: ([$derived[] | select($current[.agent] != .to) | {agent, from: $current[.agent], to, rule}]
		+ [$current | keys[] as $a | select($declared | has($a) | not)
			| {agent: $a, from: $current[$a], to: null, rule: "NOT_DECLARED"}])}
end
