#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=module/skills/review-council/scripts/rc-lib.sh
source "$(dirname "$0")/rc-lib.sh"
rc_trap_errors # report script:line on any unhandled failure (never silent)

# rc-plan-batches.sh <session_dir>
# Splits the changeset into the delegation rounds Step 3 dispatches, on the
# resource a round actually consumes: context bytes. Writes batch-plan.json and
# batches.txt, appends a `## Phase: Batch Plan` block to tracking.md, and emits
# the plan as JSON on stdout.
#
# Batching used to trigger on FILE COUNT, in prose, in phases/delegate.md. Two
# consequences, both measured across 20 cached sessions (issue #26). Diff bytes
# per changed file spanned 0.9 KB to 18.4 KB there, so file count did not track
# context size at all: a 44 KB changeset was split because it touched 25 files
# while a 176 KB one went whole because it touched 18. And because nothing
# executed the rule, a run that never reached the decision left exactly what a
# run that decided against batching left — nothing. This script is the answer to
# both: the split is computed, and the decision is an artifact even when it is
# "no".
#
# The plan is written on EVERY run, including the single-batch case. That is not
# bookkeeping: a `batches.txt` that appears only when batching happened cannot
# distinguish a changeset that fit from a step that was skipped.
#
# This script makes no forge calls, so it does not require GNU timeout.

session_dir="${1:-}"
if [[ -z "$session_dir" ]] || [[ ! -d "$session_dir" ]]; then
	json_output "nothing_to_do" "Session directory does not exist."
	exit 0
fi

changeset_file="$session_dir/changeset.txt"
tracking_file="$session_dir/tracking.md"
diff_file="$session_dir/diff.patch"
if [[ ! -f "$changeset_file" ]]; then
	json_output "nothing_to_do" "Session is missing changeset.txt."
	exit 0
fi

# ============================================================================
# Configuration
# ============================================================================
#
# Both budgets come from tracking.md, where rc-prepare.sh records the project's
# "Review Council Configuration" block — the same route `Comment limit` and
# `Pin personas` take, and for the same reason: each stage runs in its own
# process and the config block is parsed exactly once, at preparation.
#
# An unusable value is reported and dropped in favour of the default, never
# clamped. A typo that silently became `1` would batch every changeset one file
# at a time while reading as though the configuration had been honoured, which
# is the failure `Max comments` guards against the same way.
#
# The keys are absent from a session prepared before they existed, and the
# defaults from rc-lib.sh cover that case — the same fail-open reading
# rc-select-council.sh gives a missing `Persona selection`, except that here the
# missing signal is a budget rather than a permission, so taking the default
# reviews exactly what preparation collected.

rc_config_int() { # key default -> positive integer
	local key="$1" default="$2" value
	value=$(rc_parse_kv "$tracking_file" "$key")
	if [[ -z "$value" ]]; then
		printf '%s' "$default"
		return 0
	fi
	if [[ "$value" =~ ^[1-9][0-9]*$ ]]; then
		printf '%s' "$value"
		return 0
	fi
	echo "rc-plan-batches: ignoring '${key}: ${value}' (expected a positive integer); using ${default}" >&2
	printf '%s' "$default"
}

byte_budget=$(rc_config_int "Batch bytes" "$RC_DEFAULT_BATCH_BYTES")
file_cap=$(rc_config_int "Batch size" "$RC_DEFAULT_BATCH_FILES")

# ============================================================================
# Byte attribution
# ============================================================================
#
# `context_bytes` is the whole diff — what a single unbatched dispatch would
# carry, and the same measurement rc-cost-estimate.sh takes. The per-file split
# below apportions it; whatever cannot be apportioned is published as
# `unattributed_bytes` rather than being dropped or charged to an arbitrary
# file, because a budget that quietly under-counts is one that quietly
# over-fills a dispatch.
context_bytes=0
[[ -f "$diff_file" ]] && context_bytes=$(wc -c <"$diff_file" | tr -d '[:space:]')

# Per-file diff bytes, as `path<TAB>bytes` rows.
#
# The path is read from the `+++ b/<path>` header rather than from the
# `diff --git a/<p> b/<p>` line, which is genuinely ambiguous for a path
# containing " b/" — git writes both halves unquoted and there is no way back.
# A deletion has `+++ /dev/null`, so the `--- a/<path>` half is kept as the
# fallback, and a binary or malformed section falls back to the first " b/" in
# the header line. Only the lines BEFORE the section's first `@@` are read as
# headers: an added line of content may itself begin with `+++`.
#
# LC_ALL=C makes awk's length() count bytes rather than characters, which is
# what a context budget is denominated in.
attribution=$(LC_ALL=C awk '
	function flush() { if (path != "") printf "%s\t%d\n", path, bytes; path = ""; bytes = 0 }
	/^diff --git / {
		flush()
		hdr = 1; apath = ""; bytes = length($0) + 1
		line = $0; sub(/^diff --git /, "", line)
		i = index(line, " b/")
		path = (i > 0) ? substr(line, i + 3) : ""
		next
	}
	{
		bytes += length($0) + 1
		if (!hdr) next
		if ($0 ~ /^--- /) {
			p = substr($0, 5)
			if (p != "/dev/null") { sub(/^a\//, "", p); apath = p }
		} else if ($0 ~ /^\+\+\+ /) {
			p = substr($0, 5)
			if (p != "/dev/null") { sub(/^b\//, "", p); path = p }
			else if (apath != "") path = apath
		} else if ($0 ~ /^@@/) {
			hdr = 0
		}
	}
	END { flush() }
' "$diff_file" 2>/dev/null || true)

declare -A file_bytes=()
while IFS=$'\t' read -r path bytes; do
	[[ -n "$path" ]] || continue
	file_bytes["$path"]=$((${file_bytes["$path"]:-0} + bytes))
done <<<"$attribution"

# ============================================================================
# Planning
# ============================================================================
#
# One batch is filled until the next group would breach EITHER budget. Bytes are
# the primary limit; the file cap is secondary and exists because diff bytes do
# not price the reviewer's mandatory read of every file in its batch — 300
# renames totalling 100 KB would otherwise be one over-full dispatch.
#
# Files are grouped by parent directory so a reviewer sees a coherent slice, and
# a group is placed whole whenever it fits. A group too large for a batch of its
# own is split alphabetically, and a single file too large for the budget takes
# a batch alone: a file cannot be split without handing a reviewer half a hunk.
#
# The order is the SORTED changeset, never the changeset's own order. Every
# local filesystem returns creation order and CI's does not, so a rule that
# depended on it would pass everywhere it was written and fail where it ran.
rc_assign() { # budget cap  < path<TAB>bytes rows  -> batch<TAB>path<TAB>bytes
	LC_ALL=C sort |
		LC_ALL=C awk -F'\t' -v budget="$1" -v cap="$2" '
		function dirname(p,   i) {
			i = length(p)
			while (i > 0 && substr(p, i, 1) != "/") i--
			return (i > 0) ? substr(p, 1, i - 1) : "."
		}
		function newbatch() { batch++; bytes = 0; count = 0 }
		function emit(i) {
			print batch "\t" paths[i] "\t" fbytes[i]
			bytes += fbytes[i]; count++
		}
		function place(s, e,   gb, gc, i) {
			gb = 0; gc = e - s + 1
			for (i = s; i <= e; i++) gb += fbytes[i]
			if (count > 0 && (bytes + gb > budget || count + gc > cap)) newbatch()
			if (gb <= budget && gc <= cap) {
				for (i = s; i <= e; i++) emit(i)
				return
			}
			for (i = s; i <= e; i++) {
				if (count > 0 && (bytes + fbytes[i] > budget || count + 1 > cap)) newbatch()
				emit(i)
			}
		}
		BEGIN { batch = 1; bytes = 0; count = 0; n = 0 }
		{ n++; paths[n] = $1; fbytes[n] = $2 + 0 }
		END {
			if (n == 0) exit 0
			s = 1
			for (i = 2; i <= n + 1; i++) {
				if (i == n + 1 || dirname(paths[i]) != dirname(paths[s])) { place(s, i - 1); s = i }
			}
		}
	'
}

# The `path<TAB>bytes` rows for one unit of planning: the whole changeset, or
# one subsystem's file list. A file with no diff section carries zero bytes and
# is bounded by the file cap alone — which is the whole `--- scope all` case,
# where diff.patch is empty by construction.
rc_rows() { # file...
	local f
	for f in "$@"; do
		[[ -n "$f" ]] || continue
		printf '%s\t%s\n' "$f" "${file_bytes["$f"]:-0}"
	done
}

# One unit's assignment rows as a JSON array of batch objects. Batch numbers
# restart within each subsystem because a deep-mode delegation round is
# identified by the pair, not by a running total nobody can locate.
rc_batches_json() { # subsystem  < batch<TAB>path<TAB>bytes rows
	jq -R -s -c --arg sub "$1" '
		split("\n") | map(select(length > 0)) | map(split("\t"))
		| group_by(.[0]) | sort_by(.[0][0] | tonumber)
		| map({batch: (.[0][0] | tonumber),
		       subsystem: (if $sub == "" then null else $sub end),
		       files: map(.[1]),
		       bytes: (map(.[2] | tonumber) | add)})'
}

mapfile -t changeset_files < <(grep -v '^[[:space:]]*$' "$changeset_file" 2>/dev/null || true)

subsystems_file="$session_dir/subsystems.json"
subsystem_count=0
batches_json='[]'

if [[ ${#changeset_files[@]} -eq 0 ]]; then
	: # nothing to plan; the empty array above is the answer
elif [[ -f "$subsystems_file" ]] && jq -e 'length > 0' "$subsystems_file" >/dev/null 2>&1; then
	# Deep mode delegates per subsystem, so the budget applies WITHIN one rather
	# than across the changeset — the same fork rc-select-council.sh takes on the
	# same file, and what satisfies phases/delegate.md's "apply the same batching
	# rules within that subsystem" with the same code instead of a second rule.
	while IFS= read -r sub_name; do
		[[ -n "$sub_name" ]] || continue
		subsystem_count=$((subsystem_count + 1))
		mapfile -t sub_files < <(jq -r --arg n "$sub_name" \
			'.[] | select(.name == $n) | (.files // [])[]' "$subsystems_file" 2>/dev/null || true)
		[[ ${#sub_files[@]} -gt 0 ]] || continue
		# Resolved into a variable first: a command substitution nested in another
		# command has its exit status discarded, so a failed assignment would reach
		# jq as an empty array and read as "this subsystem needs no dispatch".
		sub_batches=$(rc_rows "${sub_files[@]}" | rc_assign "$byte_budget" "$file_cap" |
			rc_batches_json "$sub_name")
		batches_json=$(jq -c --argjson b "$sub_batches" '. + $b' <<<"$batches_json")
	done < <(jq -r '.[].name // empty' "$subsystems_file" 2>/dev/null || true)
else
	batches_json=$(rc_rows "${changeset_files[@]}" | rc_assign "$byte_budget" "$file_cap" |
		rc_batches_json "")
fi

batch_count=$(jq -r 'length' <<<"$batches_json")
planned_bytes=$(jq -r '[.[].bytes] | add // 0' <<<"$batches_json")
unattributed_bytes=$((context_bytes - planned_bytes))
# A subsystem file list may name a file twice (a cross-cutting file belongs to
# every subsystem that claims it) and the diff is charged once per appearance,
# so the apportioned total can exceed the diff. Reporting a negative remainder
# would state something false about the diff on disk; the over-count is real and
# belongs to the batches, which already show it.
[[ "$unattributed_bytes" -lt 0 ]] && unattributed_bytes=0

if [[ "$batch_count" -eq 0 ]]; then
	applied=false
	reason="changeset is empty"
	message="Changeset is empty; nothing to batch."
elif [[ "$batch_count" -eq 1 ]]; then
	applied=false
	reason="changeset fits one dispatch within ${byte_budget} bytes and ${file_cap} files"
	message="Single batch: ${context_bytes} context bytes within the ${byte_budget}-byte budget."
else
	applied=true
	if [[ "$subsystem_count" -gt 0 ]]; then
		reason="split into ${batch_count} batches across ${subsystem_count} subsystem(s) to keep every dispatch within ${byte_budget} bytes and ${file_cap} files"
	else
		reason="split into ${batch_count} batches to keep every dispatch within ${byte_budget} bytes and ${file_cap} files"
	fi
	message="Changeset split into ${batch_count} batches over ${context_bytes} context bytes."
fi

# ============================================================================
# Persist
# ============================================================================

plan=$(jq -n --argjson applied "$applied" --arg reason "$reason" \
	--argjson byte_budget "$byte_budget" --argjson file_cap "$file_cap" \
	--argjson context_bytes "$context_bytes" \
	--argjson unattributed_bytes "$unattributed_bytes" \
	--argjson batches "$batches_json" \
	'{applied: $applied, reason: $reason, byte_budget: $byte_budget,
	  file_cap: $file_cap, context_bytes: $context_bytes,
	  unattributed_bytes: $unattributed_bytes, batches: $batches}')
printf '%s\n' "$plan" >"$session_dir/batch-plan.json"

# The same plan as prose. `phases/delegate.md` names this file, and a reader
# reconstructing a review after the fact should not have to run jq to see which
# files a reviewer was handed.
#
# Rendered by one jq pass into a variable rather than by a shell loop around a
# second one: a command substitution nested in another command has its exit
# status discarded, so a jq that died half way would leave a truncated file that
# reads as a complete plan with fewer files in it.
batches_body=$(jq -r '.batches[]
	| (if .subsystem == null then "Batch \(.batch)" else "Batch \(.batch) (\(.subsystem))" end) as $label
	| "\n## \($label) — \(.files | length) file(s), \(.bytes) bytes", (.files[])' <<<"$plan")
{
	printf '# Batch plan — %s batch(es) over %s context bytes\n' "$batch_count" "$context_bytes"
	printf '# Budget: %s bytes / %s files per batch\n' "$byte_budget" "$file_cap"
	[[ -n "$batches_body" ]] && printf '%s\n' "$batches_body"
} >"$session_dir/batches.txt"

batch_lines=$(jq -r '.batches[]
	| if .subsystem == null
	  then "- Batch \(.batch): \(.files | length) file(s), \(.bytes) bytes"
	  else "- Subsystem \(.subsystem) batch \(.batch): \(.files | length) file(s), \(.bytes) bytes"
	  end' <<<"$plan")

if [[ -f "$tracking_file" ]]; then
	# Replaced rather than appended, which is what makes a re-run a no-op: awk
	# drops any previous block from its heading to the next `## ` heading or end
	# of file. The filter and the move are separate statements, not an
	# `awk ... && mv` list — in a list the awk failure would be exempt from
	# `set -e`, the move would be skipped, and the run would end with the stale
	# block in place and a second one appended beneath it. Same shape as
	# rc-select-council.sh, for the same reason.
	if grep -q '^## Phase: Batch Plan$' "$tracking_file"; then
		tracking_tmp="${tracking_file}.tmp"
		awk '
			/^## Phase: Batch Plan$/ { skip = 1; next }
			skip && /^## / { skip = 0 }
			!skip { print }
		' "$tracking_file" >"$tracking_tmp"
		mv "$tracking_tmp" "$tracking_file"
	fi
	{
		echo "## Phase: Batch Plan"
		echo ""
		if [[ "$applied" == "true" ]]; then
			echo "- Batching: applied"
		else
			echo "- Batching: not applied"
		fi
		echo "- Reason: ${reason}"
		echo "- Context bytes: ${context_bytes}"
		echo "- Unattributed bytes: ${unattributed_bytes}"
		echo "- Byte budget: ${byte_budget}"
		echo "- File cap: ${file_cap}"
		echo "- Batches: ${batch_count}"
		# One line per dispatch round. The per-batch figures are what makes the
		# decision checkable after the fact: a reader who thinks a batch was too
		# large can see the number the rule accepted.
		[[ -n "$batch_lines" ]] && printf '%s\n' "$batch_lines"
		echo ""
	} >>"$tracking_file"
fi

json_output "ok" "$message" "$plan"
exit 0
