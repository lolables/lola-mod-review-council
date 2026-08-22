# Pipeline States & Status Vocabulary

Each stage is a script emitting a JSON `status`. The orchestrator dispatches on
these tokens. This is the machine-readable spine of the state diagram in SKILL.md.

| State            | Script                  | Emits (`status`)                                     | On status -> next                                                                                                                                           |
|------------------|-------------------------|------------------------------------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Prepare          | `rc-prepare.sh`         | `ok` \| `skip` \| `empty`                            | `ok`->Select; `skip`->stop (report reason); `empty`->one recovery retry with broader scope (see SKILL.md Step 1 recovery table), then stop if still empty |
| Select           | `rc-select-council.sh`  | `ok` \| `nothing_to_do`                              | Both ->Triage. `ok` narrows or confirms the council in `session-manifest.json`; `nothing_to_do` (session unreadable) leaves preparation's full council in place. Never `skip` — an unevaluatable session still gets every reviewer |
| Triage           | `rc-apply-triage.sh`    | `ok` \| `nothing_to_do` \| `triage_error`            | All three ->Delegate. `ok` applies the surviving exclusions to the per-subsystem councils; `nothing_to_do` (not deep, no subsystems, disabled, or no reply) and `triage_error` (no fenced json block, or schema-invalid) both leave every council as Select wrote it. No status stops the run |
| Extract          | `rc-extract-verdict.sh` | `ok` \| `extract_error` \| `nothing_to_do` \| `skip` | `extract_error`->re-dispatch (<=1)->Extract; `ok`->Verify; `nothing_to_do`->stop (delegation failure)                                                       |
| Verify           | `rc-verify-evidence.sh` | `ok` \| `nothing_to_do`                              | `ok` & correctable>0->Correction; `ok` & correctable=0->Calibrate; `nothing_to_do`->Render (empty)                                                          |
| Consolidate      | `rc-consolidate.sh`     | `ok` \| `consolidate_error` \| `nothing_to_do`       | `ok`->Validate; `consolidate_error`->stop; `nothing_to_do`->stop (no session dir or no findings.json). Skipped entirely when effort is `quick`              |
| Render (comment) | `rc-render-comment.sh`  | `rendered` \| `skip`                                 | ->post/Report                                                                                                                                               |
| Render (report)  | `rc-render-report.sh`   | (markdown to stdout)                                 | ->Report                                                                                                                                                    |

Select and Triage are the two stages that can change WHO reviews, and they
write into the same three coverage states in `session-manifest.json`: `agents`
(discovered), `council` (dispatched), and `deselected` (discovered,
deliberately skipped, with the reason and a `source` naming which stage
skipped it). `rc-verify-evidence.sh` diffs arriving verdicts against `council`,
so a deselected persona is expected-absent rather than a `missing_verdicts`
entry.

They differ in what they may claim. Select decides from filenames alone and may
remove a persona from the whole review. Triage decides from a cheap model's
reading of the diff and may only move a persona between subsystems: its
invariants refuse any matrix that would empty a lens (`row-coverage`), leave a
subsystem fewer than two reviewers (`column-floor`), or remove the reviewer
holding an unresolved finding there (`open-finding`). That asymmetry is why one
is on by default and the other is not.

Effort gates (quick skips Correction/Calibrate/Consolidate/Validate/Narrative)
and the orchestrator-run states (Correction, Calibrate, Validate, Report) are
LLM judgment steps documented in `phases/verify.md` and `phases/report.md`.

Consolidate is in the table rather than that list because it is both: the
orchestrator judges which findings describe the same defect and writes
`clusters.json`, then `rc-consolidate.sh` folds them and emits the status the
orchestrator dispatches on. Only the second half is a state token.

`consolidate_error` is the conservation guard: the fold would have taken more
findings out of the verified array than it declared merged. `findings.json` is
left exactly as verification wrote it, so the document behind the status is
complete and un-consolidated rather than partial. Stop and report the guard
rather than rendering — a set that a broken reducer has silently thinned is the
one thing no downstream state can detect.

Disposition is an orchestrator-run state too, but unlike the others it has no
script `status` — it dispatches a fresh-context subagent, not a script. It
runs after the verify cluster (Calibrate/Validate), gated on
`${session_dir}/pr-conversation.txt` existing AND effort != `quick`; when the
gate fails, execution passes straight to Render as before. When the gate
holds, the subagent consumes the untrusted PR conversation thread and moves
resolved findings from `verified` to `stripped` in `findings.json`
(provenance only — it never adds new findings). See `phases/disposition.md`.
