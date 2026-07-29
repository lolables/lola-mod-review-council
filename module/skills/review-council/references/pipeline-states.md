# Pipeline States & Status Vocabulary

Each stage is a script emitting a JSON `status`. The orchestrator dispatches on
these tokens. This is the machine-readable spine of the state diagram in SKILL.md.

| State            | Script                  | Emits (`status`)                                     | On status -> next                                                                                                                                           |
|------------------|-------------------------|------------------------------------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Prepare          | `rc-prepare.sh`         | `ok` \| `skip` \| `empty`                            | `ok`->Delegate; `skip`->stop (report reason); `empty`->one recovery retry with broader scope (see SKILL.md Step 1 recovery table), then stop if still empty |
| Extract          | `rc-extract-verdict.sh` | `ok` \| `extract_error` \| `nothing_to_do` \| `skip` | `extract_error`->re-dispatch (<=1)->Extract; `ok`->Verify; `nothing_to_do`->stop (delegation failure)                                                       |
| Verify           | `rc-verify-evidence.sh` | `ok` \| `nothing_to_do`                              | `ok` & correctable>0->Correction; `ok` & correctable=0->Calibrate; `nothing_to_do`->Render (empty)                                                          |
| Render (comment) | `rc-render-comment.sh`  | `rendered` \| `skip`                                 | ->post/Report                                                                                                                                               |
| Render (report)  | `rc-render-report.sh`   | (markdown to stdout)                                 | ->Report                                                                                                                                                    |

Effort gates (quick skips Correction/Calibrate/Validate/Narrative) and the
orchestrator-run states (Correction, Calibrate, Validate, Report) are LLM
judgment steps documented in `phases/verify.md` and `phases/report.md`.

Disposition is an orchestrator-run state too, but unlike the others it has no
script `status` — it dispatches a fresh-context subagent, not a script. It
runs after the verify cluster (Calibrate/Validate), gated on
`${session_dir}/pr-conversation.txt` existing AND effort != `quick`; when the
gate fails, execution passes straight to Render as before. When the gate
holds, the subagent consumes the untrusted PR conversation thread and moves
resolved findings from `verified` to `stripped` in `findings.json`
(provenance only — it never adds new findings). See `phases/disposition.md`.
