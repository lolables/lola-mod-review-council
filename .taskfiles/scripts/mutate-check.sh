#!/usr/bin/env bash
# Mutation check: break each fixed defect on purpose and confirm a suite fails.
#
# A green suite tells you nothing on its own — it might be green because the
# code is right, or because the tests assert nothing that matters. Two of the
# regression tests written for these very defects passed on their first run,
# before any fix existed, because the fixture geometry happened to satisfy
# them. They only became real tests after being reshaped until they failed
# against the broken code.
#
# This makes that check routine rather than something someone remembers to do.
# Each mutation below reintroduces one defect into a throwaway copy of the
# module and asserts the named suite goes red. A mutation nobody catches is a
# hole in the suite and is reported as a failure.
# Every mutation below is a sed expression. The `$` in them is sed's
# end-of-line anchor or a literal dollar in the target source, never a shell
# expansion — single quotes are required, not an oversight. The directive has
# to sit immediately before the first command to apply file-wide.
#
# The expressions are POSIX BRE, which rules out GNU escapes on both sides of
# the substitution. `\t` in particular is a GNU extension: BSD sed hands the
# pattern to regcomp untouched, which reads `\t` as the letter `t`, so a
# leading-tab anchor would match nothing and every mutation using one would be
# reported as BROKEN on macOS. Leading indentation is matched with
# `^[[:space:]]*` and dropped from the replacement — the mutated copy is only
# ever fed to bash, which does not care what column a statement starts in.
# shellcheck disable=SC2016
set -uo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
caught=0
missed=0
broken=0
snapshot=""

# Freeze module/ once, and hand every mutation a copy of that rather than of the
# tree as it currently stands.
#
# Each mutation used to copy `$root/module` itself, so a run was 44 separate
# reads of a directory anything else may be writing. Two mutations either side
# of an edit ran against different source, and one that copied a file mid-write
# mutated a half-written script. Neither announces itself: both come out as
# MISSED or BROKEN against code that is in fact guarded, which reads as a hole
# in a suite and sends whoever acts on the report looking for a defect that is
# not there. It is not hypothetical — an edit landing during a run produced a
# false MISSED and a mutation count that could not be reconciled against the
# number of entries in this file.
#
# Taken on first use rather than at load so that the harness can be sourced,
# pointed at a fixture tree and driven by test-mutate-check.sh. In a real run
# first use is the first mutation, so the snapshot is still the tree as it stood
# when the run began.
module_snapshot() {
	[[ -n "$snapshot" ]] && return 0
	snapshot=$(mktemp -d)
	cp -R "$root/module" "$snapshot/module"
}

# check_mutation <label> <script> <sed-expr> <suite>
#
# <script> is relative to module/skills/review-council/scripts/, <suite> to
# module/tests/. Preparation targets carry a lib/ prefix: rc-prepare.sh is an
# entry point that sources six stages, and each defect lives in the stage that
# owns that step. Anchor each expression tightly: a mutation that fails to apply
# is reported as BROKEN rather than silently counted as caught, because "the
# suite went red" means nothing if the code was never actually changed. A suite
# that goes red without firing a single assertion is BROKEN for the same reason.
check_mutation() {
	local label="$1" script="$2" expr="$3" suite="$4"
	local work target before after detail
	work=$(mktemp -d)
	module_snapshot
	cp -R "$snapshot/module" "$work/module"
	target="$work/module/skills/review-council/scripts/$script"

	# cksum, not md5sum: the latter is GNU coreutils and absent on macOS. A
	# CRC is weak against a forger and entirely adequate here — the only
	# question being asked is whether sed changed the bytes at all.
	before=$(cksum <"$target")
	# Filter on write rather than `sed -i`: BSD sed reads `-i EXPR` as a backup
	# suffix, so an in-place edit silently leaves the file untouched.
	if ! sed "$expr" "$target" >"$work/mutated"; then
		echo "BROKEN  $label"
		echo "        sed rejected the mutation expression"
		broken=$((broken + 1))
		rm -rf "$work"
		return
	fi
	# Redirect into the existing file rather than renaming over it. The
	# redirection truncates the inode in place and keeps its mode; a rename
	# would replace the 0755 script with sed's 0644 output. Every suite today
	# runs `bash "$SCRIPT"`, so the exec bit does not matter yet, but one that
	# ran the mutant directly would fail on the missing bit and score a
	# spurious `caught`. `chmod --reference` is not the fix — it is GNU-only.
	if ! cat "$work/mutated" >"$target"; then
		echo "BROKEN  $label"
		echo "        could not write the mutated $script back"
		broken=$((broken + 1))
		rm -rf "$work"
		return
	fi
	after=$(cksum <"$target")

	if [[ "$before" == "$after" ]]; then
		echo "BROKEN  $label"
		echo "        expression no longer matches $script, so this defect is unguarded here"
		broken=$((broken + 1))
		rm -rf "$work"
		return
	fi

	if bash "$work/module/tests/$suite" >"$work/out.log" 2>&1; then
		echo "MISSED  $label"
		echo "        $suite still passes with the defect reintroduced"
		missed=$((missed + 1))
	else
		detail=$(grep -cE '^[[:space:]]+FAIL:' "$work/out.log" || true)
		if [[ "$detail" -eq 0 ]]; then
			# A non-zero exit with no failed assertion means the suite died
			# rather than detected anything — a syntax error, or jq erroring
			# against a half-applied mutation. That demonstrates nothing about
			# the guard, so it is not a catch. This is precisely how a
			# partially-applied RC-11 scored `caught` while three of its four
			# substitutions silently no-oped.
			echo "BROKEN  $label"
			echo "        $suite hard-errored with no assertion fired, so nothing here proves the defect is guarded"
			broken=$((broken + 1))
		else
			echo "caught  $label"
			echo "        $suite: $detail failing assertion(s)"
			caught=$((caught + 1))
		fi
	fi
	rm -rf "$work"
}

# Sourced rather than executed: hand back the definitions above and run nothing.
# test-mutate-check.sh drives check_mutation against a fixture tree of its own,
# which it cannot do if loading this file runs every mutation below it first.
if (return 0 2>/dev/null); then
	return 0
fi

# Only when executed: a sourced copy leaves its snapshot to the caller, whose
# own EXIT trap this would otherwise replace.
trap '[[ -n "$snapshot" ]] && rm -rf "$snapshot"' EXIT

# Consolidation deleted every finding except one cluster primary because a jq
# `def` was evaluated against the wrong subject inside `any()`.
#
# Retargeted when the array rewrite became a `reduce`: the old expression
# mutated `($f | ident)`, which under a reduce indexes the accumulator ARRAY and
# makes jq hard-error. A mutation that crashes proves nothing — the defect being
# guarded here is the silent one, where `.` inside `any()` binds to the element
# of $secids rather than the finding, every test reduces to `secid == secid`,
# and every non-primary finding including the bystanders is deleted without a
# word. Mutating the `any()` body reproduces exactly that.
check_mutation "RC-1  consolidation ident scoping" \
	jq/consolidate-clusters.jq \
	's/any(. == \$fid)/any(. == ident)/' \
	test-rc-jq-programs.sh

# Multi-line evidence was searched as N independent literals by `grep -F`.
check_mutation "RC-2  contiguous evidence matching" \
	rc-verify-evidence.sh \
	's#^[[:space:]]*occurrences=\$(evidence_lines.*#occurrences=$(grep -nF -- "$ev" "$fpath" | cut -d: -f1)#' \
	test-rc-verify-evidence.sh

# `head -1` on the matcher took SIGPIPE under pipefail once the quote occurred
# more times than the pipe buffer held, killing the phase before findings.json
# was written. The substitution drops the `|| astatus=$?` capture along with the
# pipe, and has to: leaving the capture in place absorbs the 141 into
# EVIDENCE_SCAN_ERROR, so the phase writes findings.json and exits 0. The suite
# still goes red — but on the truncation assertions, because `head -1` also
# discards every occurrence after the first. Test 15's own SIGPIPE assertion
# passes, so that form of the mutation is scored `caught` while proving nothing
# about the abort this entry exists to guard.
check_mutation "RC-3  full matcher output" \
	rc-verify-evidence.sh \
	's#^[[:space:]]*occurrences=\$(evidence_lines.*#occurrences=$(evidence_lines "$fpath" "$ev" | head -1)#' \
	test-rc-verify-evidence.sh

# The verdict glob ingested clusters.json, which verify.md mandates writing.
check_mutation "RC-4  verdict allow-list glob" \
	rc-verify-evidence.sh \
	"s/-name 'divisor-\*\.json'/-name '*.json' ! -name 'findings.json' ! -name 'verdicts-map.json'/" \
	test-rc-verify-evidence.sh

# The renderer emitted no council verdict at all. Both lines live inside the
# header heredoc since the verdict moved to the head of the report, so the
# mutation deletes the heading and its value rather than neutering an `echo`.
check_mutation "RC-5  council verdict rendering" \
	rc-render-report.sh \
	'/^## Council Verdict$/d; /^\$council_verdict_line$/d' \
	test-rc-render-report.sh

# The jq fallback ignored "additionalProperties": false.
check_mutation "RC-6  additionalProperties enforcement" \
	rc-extract-verdict.sh \
	's/((\[keys\[\]\] - \$topkeys) | length) == 0 and/true and/' \
	test-rc-extract-verdict.sh

# The jq fallback compared enums with substring containment, so "HIG" passed.
check_mutation "RC-7  exact enum membership" \
	rc-extract-verdict.sh \
	's/any(\$allowed\[\]; \. == \$v)/true/' \
	test-rc-extract-verdict.sh

# Findings citing a path outside the review root were verified, not stripped.
check_mutation "RC-8  review-root containment" \
	rc-verify-evidence.sh \
	's/^[[:space:]]*if ! path_in_root "\$fpath"; then$/if false; then/' \
	test-rc-verify-evidence.sh

# Numbering jumps 8 -> 10. The RC-N labels come from a defect list that predates
# this file and is not tracked in the repo, so RC-9 itself cannot be looked up
# from here. What is checkable is that no suite under module/tests/ asserts
# anything about it — which is why there is no entry. A mutation with no
# regression test behind it could only ever report MISSED.

# An unresolvable ref range reported "no changes to review".
check_mutation "RC-10 ref range resolution" \
	lib/prepare-changes.sh \
	's/^[[:space:]]*require_resolvable_range .*$/:/' \
	test-rc-prepare-git-edges.sh

# The findings arrays were passed to jq as single argv entries, so a review
# large enough to push one past MAX_ARG_STRLEN aborted the phase.
check_mutation "RC-11 findings assembly via files" \
	rc-verify-evidence.sh \
	's#^[[:space:]]*--slurpfile verified ".*#--argjson verified "$verified" \\#;
	 s#^[[:space:]]*--slurpfile correctable ".*#--argjson correctable "$correctable" \\#;
	 s#^[[:space:]]*--slurpfile stripped ".*#--argjson stripped "$stripped" \\#;
	 s/verified:\$verified\[0\], correctable:\$correctable\[0\], stripped:\$stripped\[0\]/verified:$verified, correctable:$correctable, stripped:$stripped/' \
	test-rc-verify-evidence.sh

# The repo name parsed from the local remote kept its trailing `.git`. The strip
# now lives in parse_remote in rc-lib.sh, which rc-prepare.sh shares with
# rc-clone-target.sh; the suite asserting it is still the prepare one.
check_mutation "RC-12 remote .git suffix strip" \
	rc-lib.sh \
	's/%\.git}/}/' \
	test-rc-prepare-owner.sh

# The language tally counted every extension, so CI YAML outvoted the source.
check_mutation "RC-13 language tally source filter" \
	lib/prepare-changes.sh \
	's/^[[:space:]]*\*) continue ;;.*$/*) bucket="$ext" ;;/' \
	test-rc-prepare-framework.sh

# APPROVE filed over a CRITICAL or HIGH finding was accepted as coherent.
check_mutation "RC-14 verdict/severity coupling" \
	rc-extract-verdict.sh \
	's/^[[:space:]]*if \[\[ "\$verdict_mismatch" != "no" \]\]; then$/if false; then/' \
	test-rc-extract-verdict.sh

# in_place asked only for a matching owner/repo, which any host can serve.
check_mutation "RC-15 clone target host identity" \
	rc-clone-target.sh \
	's/"\${cur_host,,}" == "\${target_host,,}"/true/' \
	test-rc-clone-target.sh

# The clone cache was keyed on owner/repo, so one host's checkout was served
# back for another host's same-named repository and the PR head was fetched
# from the wrong origin. The substitution drops the host from the entry name
# and leaves the slug computed but unused, which is exactly the shipped state
# before the fix.
check_mutation "RC-16 clone cache endpoint key" \
	rc-clone-target.sh \
	's#^[[:space:]]*dest="\$.cache_root./\$.host_slug.-#dest="${cache_root}/#' \
	test-rc-clone-target.sh

# The coherence gate fired and left no trace. The rejection buys one
# re-dispatch which overwrites <agent>.raw.md and <agent>.json, so an agent that
# answers the gate by deleting its own CRITICAL produces a session
# indistinguishable from a reviewer that found nothing. Redirecting the record
# to /dev/null is the shipped state before this log existed: the gate still
# rejects, the remediation still goes out, and nothing survives the second pass.
check_mutation "RC-17 gate firing log" \
	rc-extract-verdict.sh \
	's#^[[:space:]]*>>"\$session_dir/gate-firings\.jsonl"$#>/dev/null#' \
	test-rc-extract-verdict.sh

# The seven tracking fields were read with `grep | cut | xargs`. xargs applies
# shell quoting to its input, so a branch name containing an apostrophe — which
# git permits — was rejected and the report published "Branch: unknown".
check_mutation "RC-18 tracking parse quoting" \
	rc-render-report.sh \
	's#^branch=\$(rc_parse_kv "\$tracking_file" "Branch")$#branch=$(grep "^- Branch:" "$tracking_file" | cut -d: -f2- | xargs || echo "unknown")#' \
	test-rc-render-report.sh

# "Agents absent" was the literal string "none", written once and updated by
# nothing, so a host missing half its council published a report whose Discovery
# Summary claimed complete coverage.
check_mutation "RC-19 absent persona roster" \
	lib/prepare-emit.sh \
	's#^[[:space:]]*echo "- Agents absent: \${agents_absent_line}"$#\techo "- Agents absent: none"#' \
	test-rc-prepare.sh

# Exact dedup kept the higher severity and discarded everything else about the
# duplicate, so a second reviewer's angle vanished — while semantic
# consolidation, describing the same event, preserved it in consolidated_from.
check_mutation "RC-20 dedup credits the other agent" \
	jq/dedup-findings.jq \
	's#^[[:space:]]*( if \$x\.agent != \.\[\$idx\]\.agent$#\t    ( if false#' \
	test-rc-jq-programs.sh

# --mode accepted any string and fell through to a `code` default, so `--mode
# spec` — the natural typo, since the mode is called `spec` everywhere but the
# flag — silently ran a code review under a mode the caller never asked for.
check_mutation "RC-21 mode value validation" \
	lib/prepare-args.sh \
	's/^\t\tcode | specs | auto) mode_override="\$2" ;;$/\t\t*) mode_override="$2" ;;/' \
	test-rc-prepare-mode.sh

# A dispatched reviewer that returned nothing was indistinguishable from one
# that was never in the council: both are simply absent from the verdicts glob.
# Reporting the empty list is the shipped state before the manifest diff.
check_mutation "RC-22 missing verdict detection" \
	rc-verify-evidence.sh \
	's|^if \[\[ -f "\$manifest" \]\]; then$|if false; then|' \
	test-rc-verify-evidence.sh

# Pipeline state written beside the verdicts rather than under _meta/ is how
# RC-4 happened: clusters.json parsed as an agent verdict, aborting the phase.
check_mutation "RC-23 phase state kept out of verdicts/" \
	rc-consolidate.sh \
	's|^manifest="\$vdir/_meta/clusters.json"$|manifest="$vdir/clusters.json"|' \
	test-rc-consolidate.sh

# Verdict files were ingested in `find` order, which is the filesystem's
# directory order, so the same session credited a different reviewer under "Also
# flagged by" depending on the host it ran on.
#
# Test 30 used to make that visible by writing its two verdict files in reverse
# agent order, which only reads back adversely on a filesystem reporting
# creation order. On one reporting hash order that happens to agree with the
# sort for those two names, the unsorted read and the sorted read are the same
# sequence and this scored MISSED — green on a developer's XFS box, MISSED on
# both CI legs, over code that was never at fault. Test 30 now mocks `find` to
# return the entries in descending order on any host, so what this mutation
# reintroduces is observable everywhere and the entry is as strong as the rest.
check_mutation "RC-24 deterministic verdict ingestion" \
	rc-verify-evidence.sh \
	's/ | LC_ALL=C sort -z//' \
	test-rc-verify-evidence.sh

# Counting matched findings rather than distinct ones let a cluster naming one
# member twice through the guard. Nothing was folded, so a record claiming a
# merge was appended — and nothing was removed, so the guard never engaged on
# the next pass and the record was appended again on every run of the iteration
# loop.
check_mutation "RC-25 cluster guard counts distinct findings" \
	jq/consolidate-clusters.jq \
	's/(\$idents | length) < 2/($found | length) < 2/' \
	test-rc-consolidate.sh

# Two findings in one cluster can share {file,line,agent}. Emitting the primary
# on every identity match rather than only the first duplicated it in the
# surviving array, while the sibling's angle was folded nowhere.
check_mutation "RC-26 cluster primary emitted once" \
	jq/consolidate-clusters.jq \
	's/map(ident) | any(. == \$fid)/false/' \
	test-rc-consolidate.sh

# Every finding headline in every artifact was a 60-byte mid-word cut, because
# .title could not reach findings.json and the fallback was the only path.
check_mutation "RC-27 finding headline is not byte-truncated" \
	lib/render-findings.sh \
	's/.title \/\/ (.description | split(". ")\[0\] | rtrimstr("."))/.title \/\/ (.description[0:60])/' \
	test-rc-render-report.sh

# An optional property the schema does not declare is one additionalProperties
# rejects outright, taking the whole verdict with it.
check_mutation "RC-28 schema declares the title property" \
	../references/verdict-schema.json \
	's/"title": { "type": "string", "minLength": 1 },//' \
	test-rc-extract-verdict.sh

# consolidation_records accumulate across runs by design, so reporting the
# document's running total told the reader the re-run had merged everything the
# session had ever merged. Reverting to the total is the shipped defect.
check_mutation "RC-29 merge count is this run's delta" \
	rc-consolidate.sh \
	's/^sem=\$((after - before))$/sem=$after/' \
	test-rc-consolidate.sh

# Each finding is labelled with a persona glyph. While this table printed agent
# filenames, nothing in report.md decoded that glyph — and on a report with no
# consolidation no persona label appeared anywhere in the file.
check_mutation "RC-30 report table names the persona" \
	rc-render-report.sh \
	's/^[[:space:]]*agent_persona=\$(persona_label "\$agent_name")$/agent_persona="$agent_name"/' \
	test-rc-render-report.sh

# Consolidation wrote whatever the reducer returned. RC-1 is the defect that
# makes this matter: it deleted every finding outside the cluster while the
# `consolidated` count stayed plausible, so nothing downstream could tell a
# thinned set from a correctly merged one. Neutering the condition is the
# shipped state before the guard — the fold still runs and its result is still
# written, exactly as it was.
check_mutation "RC-31 consolidation conserves findings" \
	rc-consolidate.sh \
	's/^if \[\[ \$removed -lt 0 || \$removed -gt \$sem \]\]; then$/if false; then/' \
	test-rc-consolidate.sh

# The format gate rejected a block and told the agent only that the block had
# "a missing required key, bad enum, or non-array findings" — one constant
# sentence for every defect. An extra key, the commonest defect of all, is none
# of those three, so the agent was handed a diagnosis that ruled out its own
# problem and spent its single re-dispatch re-emitting the same block. Dropping
# the key name from the message is the shipped state before the fix: the
# sentence still renders, still reads like a diagnosis, and still names nothing.
check_mutation "RC-34 rejection detail names the offending key" \
	rc-extract-verdict.sh \
	's/^[[:space:]]*\["unrecognised top-level key(s): " + quote(\$extra)$/["unrecognised top-level key(s): " + ""/' \
	test-rc-extract-verdict.sh

# The council's own comment is identified by marker AND author. The marker is
# public and GitHub's "Quote reply" copies the body it quotes wholesale, HTML
# comment included, so any participant can post one. Dropping the author clause
# is the shipped state before the fix, and it is the silent kind: the file is
# still written, it is simply missing the reply that quotes a finding to argue
# with it -- the most engaged human on the thread.
#
# Two entries, because the clause is tested in two jq programs that fail apart.
# The exclusion decides WHICH comments are dropped; the anchor decides WHERE the
# window opens. Since the marker is matched at the start of a line, quoting no
# longer trips either one, so what the exclusion's clause now guards is a
# participant putting a marker at column 0 deliberately -- and what the anchor's
# guards is the window opening on someone else's comment. Neither mutation
# reproduces the other's symptom.
check_mutation "RC-039 re-review exclusion tests the author" \
	lib/prepare-context.sh \
	's#and (\$me == "" or (\.author // "") == \$me)) | not#and true) | not#' \
	test-rc-prepare-conversation.sh

check_mutation "RC-039 re-review anchor tests the author" \
	lib/prepare-context.sh \
	's#and (\$me == "" or (\.author // "") == \$me))\] | last#and true)] | last#' \
	test-rc-prepare-conversation.sh

# The marker only counts at the START of a line. rc-render-comment.sh emits it
# that way and GitHub's "Quote reply" indents what it copies, so column 0 is
# what tells a verdict from a quote of one when there is no author to compare
# against. Matching it anywhere in the body -- the shipped state before the fix
# -- costs the whole artifact on that path: the anchor lands on the quote, the
# exclusion then drops that same quote as ours, nothing is left to write, and
# the disclosure that exists to say "your input may be short" goes with it.
#
# Two entries again, and again they fail apart: neutering the anchor closes the
# window, neutering the exclusion drops the quoting reply out of a file that is
# still written. `.*` spans the `split("\n")` rather than spelling it -- `\n` in
# a POSIX BRE is a GNU escape that BSD sed reads as the letter `n`, the same
# portability trap as `\t` described at the top of this file.
check_mutation "RC-039 anchor matches a marker line, not the body" \
	lib/prepare-context.sh \
	's#^[[:space:]]*| select(((\.body // "") | split(.*any(startswith(\$open)))#| select(((.body // "") | contains($open))#' \
	test-rc-prepare-conversation.sh

check_mutation "RC-039 exclusion matches a marker line, not the body" \
	lib/prepare-context.sh \
	's#^[[:space:]]*(((\.body // "") | split(.*any(startswith(\$open)))#(((.body // "") | contains($open))#' \
	test-rc-prepare-conversation.sh

# Testing the author is right; requiring it is not. The login names the account
# this RUN holds a token for, and the verdict on the PR may have been posted by
# another one — CI files it as a bot, a maintainer re-runs locally, the token
# rotates. The author-filtered anchor then matches nothing, which reads as "no
# prior verdict", so the whole block is skipped: no conversation file and no
# disclosure, on a PR that is mid-argument. Deleting the fallback is the
# quietest failure of the three, which is why it is guarded like the others.
check_mutation "RC-039 anchor falls back when no comment matches" \
	lib/prepare-context.sh \
	's/^[[:space:]]*if \[\[ -n "\$council_login" \]\] && \[\[ -z "\$marker_created_at" \]\]; then$/if false; then/' \
	test-rc-prepare-conversation.sh

# The renderer's last resort keeps whole lines from the top until the limit is
# reached, and the marker is the last line of the body — so the cut took it.
# Dropping the re-append is the shipped state: the body is still written, still
# fits, and still carries the verdict heading and the finding counts, but no
# listing selects on it. The next run finds no part to update, posts a fresh
# comment beside the orphan, and the pull request accumulates one more on every
# run after that.
check_mutation "RC-041 a cut body keeps its marker" \
	rc-render-comment.sh \
	's/^[[:space:]]*_RC_PART_BODIES=("\${out}\${marker}")$/_RC_PART_BODIES=("$out")/' \
	test-rc-render-comment.sh

# The cut took the disclosure with it for the same reason, and that half is the
# one the ladder's own doctrine calls worse than an overflow error: what is left
# announces a finding count, shows no findings, and says nothing was trimmed, so
# a maintainer cannot tell a cut review from a clean one. Neutering the
# re-append leaves the reserve in place, so the body still fits — it is only
# silent.
check_mutation "RC-041 a cut body keeps its disclosure" \
	rc-render-comment.sh \
	's/^[[:space:]]*out+="\$disc"$/:/' \
	test-rc-render-comment.sh

# Reserving the two before the fill rather than after is what keeps the result
# inside the limit; filling to the whole limit and then appending overshoots by
# their combined length every time. Guarded separately because the two entries
# above pass with the reserve gone: the marker and the disclosure are both still
# there, the body is simply too big.
check_mutation "RC-041 the cut reserves what it re-appends" \
	rc-render-comment.sh \
	's/^[[:space:]]*fill_budget=\$((limit - \$(_rc_bytes "\${disc}\${marker}")))$/fill_budget="$limit"/' \
	test-rc-render-comment.sh

# The GitHub poster decides which comments on a pull request are the council's
# and which part of a chained verdict each one holds, and it decides both by
# reading a marker out of the comment. A finding's evidence is a verbatim quote
# of the source under review, so it is author-controlled text rendered into that
# same comment, and the marker key is public — it ships in every verdict and
# verbatim in references/forge-adapters.md. Every entry below reintroduces one
# way of reading that marker loosely enough for the quote to answer instead.
#
# The failure is never an error. The run reports `posted`, and the pull request
# quietly ends up with a duplicate verdict, an overwritten third-party comment,
# or its fresh verdict folded away as outdated.

# The subject. Matching over the whole body finds the counterfeit in the quoted
# source, because jq's `capture` returns the FIRST match and the real marker is
# the LAST line. Widest of the five: it takes the ordinary single-comment upsert
# down with it, which is what Test 9 reports.
check_mutation "RC-042 marker read from its own line" \
	rc-post-comment-github.sh \
	's/^RC_MARKER_LINE_JQ=.*$/RC_MARKER_LINE_JQ=".body"/' \
	test-rc-post-comment-github.sh

# The direction. Scanning back is what makes the real marker win: a counterfeit
# lives in the evidence, and evidence renders ABOVE the marker the renderer
# appends after the footer. Taking the first marker line instead reads the
# forgery — with the subject and both patterns otherwise intact, which is why
# this is guarded apart from the entry above.
check_mutation "RC-042 the last marker line wins" \
	rc-post-comment-github.sh \
	's/^\(RC_MARKER_LINE_JQ=.*\)| last)/\1| first)/' \
	test-rc-post-comment-github.sh

# The selector. "Is this comment part of the verdict for the commit under
# review?" answered by searching the body for `sha=<head>` adopts a PRIOR
# commit's verdict that merely quotes this commit's sha: it is overwritten in
# place with the new verdict instead of being banner-stamped and folded away.
# Distinct symptom — the comment is claimed rather than misread.
check_mutation "RC-042 sha selector tests the marker line" \
	rc-post-comment-github.sh \
	's/^[[:space:]]*| select(\\\$m | startswith.*$/| select(.body | contains(\\"sha=$4\\"))/' \
	test-rc-post-comment-github.sh

# The sweep's half of the same read. Searching the body for the sha makes the
# supersede listing report a counterfeit sha for a comment it just posted, and
# an edited prior verdict as one it has never seen — so the prior verdict is
# never retired and the pull request carries two live verdicts for good. No
# other entry here produces that: the others lose comments, this one keeps one
# too many.
check_mutation "RC-042 supersede sha read off the marker line" \
	rc-post-comment-github.sh \
	's/((\\\$m | capture(\\"\^\${RC_MARKER_OPEN}(?<s>/((.body | capture(\\"sha=(?<s>/' \
	test-rc-post-comment-github.sh

# The field's shape. `sha=` is one space-delimited token and NOT necessarily
# hex: an unresolvable HEAD renders `sha=unknown`. A hex-only class reads
# nothing out of those markers, so every part of a chain falls back to its
# `part=1` default — parts 2..N are re-created as duplicates on every run while
# part 1 is written over whichever comment last landed in that slot. Invisible
# on a hex sha, which is every other test here.
check_mutation "RC-042 marker captures accept a non-hex sha" \
	rc-post-comment-github.sh \
	's/capture(\\"\^\${RC_MARKER_OPEN}\[\^ \]+ part=/capture(\\"^${RC_MARKER_OPEN}[0-9a-fA-F]+ part=/' \
	test-rc-post-comment-github.sh

# --- RC-043: `--scope paths` could not name a file ---------------------------
#
# Six ways to lose the same capability. `--scope paths` was a filter over a git
# diff and nothing more, so it could only ever surface a path that already had
# changes in it: "review this one file" came back "No changes to review" for
# every untracked, ignored, or committed-and-unmodified file in the repository.

# The disk read itself. Without it the scope reverts to diff-only discovery,
# which is the whole defect — every file target that is not already in the diff
# vanishes and the run reports a clean tree.
check_mutation "RC-043 a named file is taken from disk" \
	lib/prepare-changes.sh \
	's/^[[:space:]]*\[\[ -f "\$scope_path" \]\] && changeset_files+=.*$/:/' \
	test-rc-prepare-file-targets.sh

# The split. scope_dir is comma-separated everywhere else; passing it to git as
# one pathspec makes a two-target run match nothing at all — and, because each
# entry is then tested for existence as one glued string, refuses it as a
# missing path rather than reviewing either half.
check_mutation "RC-043 targets split on commas" \
	lib/prepare-changes.sh \
	"s/^[[:space:]]*IFS=',' read -ra scope_paths <<<\"\$scope_dir\"\$/scope_paths=(\"\$scope_dir\")/" \
	test-rc-prepare-file-targets.sh

# The refusal. A path that is neither on disk nor in the changeset was never
# reviewed, and reporting that as "no changes" makes a mistyped target read as a
# clean result — including the subset case, where one good path fills the
# changeset and the mistyped one beside it goes unmentioned.
check_mutation "RC-043 a missing target is refused" \
	lib/prepare-changes.sh \
	's/^[[:space:]]*if \[\[ ${#scope_missing.*$/if false; then/' \
	test-rc-prepare-file-targets.sh

# The filter's match. `$file == $fp*` is a prefix test, so a target of
# `src/fresh.go` also admits `src/fresh.go.bak`: a review that quietly covers a
# file nobody named. Distinct from the entries above — this one adds files
# rather than losing them.
check_mutation "RC-043 path filter matches a path, not a prefix" \
	lib/prepare-changes.sh \
	's/if \[\[ "\$file" == "\$fp" \]\]/if [[ "$file" == "$fp"* ]]/' \
	test-rc-prepare-file-targets.sh

# Spec mode's half. collect_specs_in walks directories, so a named spec FILE
# falls straight through it and the run reports "no spec artifacts found" for a
# document sitting right there on disk.
check_mutation "RC-043 spec mode accepts a file target" \
	lib/prepare-changes.sh \
	's/^[[:space:]]*if \[\[ -f "\$dir" \]\]; then$/if false; then/' \
	test-rc-prepare-file-targets.sh

# Mode detection. Classifying the whole branch diff instead of what was named
# dispatches the wrong council at full confidence: one Go file named on a branch
# that otherwise touched only docs is reviewed by the spec personas, with every
# code convention pack unloaded. The review completes and reads as normal.
check_mutation "RC-043 the named target decides the mode" \
	lib/prepare-target.sh \
	's/^[[:space:]]*elif \[\[ -n "\${scope_dir:-}" \]\]; then$/elif false; then/' \
	test-rc-prepare-file-targets.sh

# The same stage's empty case. Appending unconditionally leaves a lone newline
# behind for a directory with no changes under it, and a newline is not the
# empty string: the no-changes branch is skipped, classification counts zero
# files of either kind, and the run resolves to spec mode by falling off the
# end of a tally that never ran.
check_mutation "RC-043 an empty target diff stays empty" \
	lib/prepare-target.sh \
	's/^[[:space:]]*\[\[ -n "\$mode_scope_diff" \]\] && \(changeset_for_mode_detection+=.*\)$/\1/' \
	test-rc-prepare-file-targets.sh

# The normalisation, which lives in the arg parser so that the changeset
# builders and mode detection cannot disagree about what was named. `-e path/`
# and `-f path/` are false for a regular file, so a target carrying a trailing
# slash was refused as "Target not found: <path>" — naming as missing a path
# that is plainly there — and, where only one stage normalised, sent a Go file
# to the spec council.
#
# The loop CONDITION is what gets broken, not the strip inside it: replacing the
# body leaves `while [[ $x == */ ]]; do : ; done` spinning forever, and a
# mutation that hangs takes the whole run with it rather than reporting.
check_mutation "RC-043 a trailing slash is dropped from a target" \
	lib/prepare-args.sh \
	's/^[[:space:]]*while \[\[ "\$scope_entry" == \*\/ \]\]; do$/while false; do/' \
	test-rc-prepare-file-targets.sh

# The blank. `read -ra` keeps an interior empty field, so a doubled comma in a
# generated flag string becomes an entry that exists nowhere and refuses the
# whole run — naming, in the message, nothing at all.
check_mutation "RC-043 an empty entry is dropped, not refused" \
	lib/prepare-args.sh \
	's/^[[:space:]]*\[\[ -z "\$scope_entry" \]\] && continue$/:/' \
	test-rc-prepare-file-targets.sh

total=$((caught + missed + broken))
echo ""
echo "========================================"
echo "Mutations: $total  caught: $caught  missed: $missed  broken: $broken"
echo "========================================"
[[ $missed -eq 0 && $broken -eq 0 ]] || exit 1
exit 0
