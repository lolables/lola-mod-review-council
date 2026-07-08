#!/usr/bin/env bash
# snapshot.sh — capture eval results with git provenance to an
# append-only JSONL ledger and a human-readable markdown snapshot.
#
# Usage: snapshot.sh <module_dir> <results_dir>
#
# The ledger at <results_dir>/ledger.jsonl is the durable, committed
# record of eval history. Each line is one matrix cell result enriched
# with git provenance, module version, and task description. The
# markdown snapshot at <results_dir>/snapshots/<id>.md is the
# human-readable companion.
set -euo pipefail

MODULE_DIR="${1:?Usage: snapshot.sh <module_dir> <results_dir>}"
RESULTS_DIR="${2:?Usage: snapshot.sh <module_dir> <results_dir>}"
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

LEDGER="$RESULTS_DIR/ledger.jsonl"
SNAPSHOTS_DIR="$RESULTS_DIR/snapshots"
TESTS_DIR="$RESULTS_DIR/tests"
LOLA_EVAL="${LOLA_EVAL:-$(command -v lola-eval 2>/dev/null || echo "")}"
if [[ -z "$LOLA_EVAL" ]]; then
	echo "snapshot.sh: lola-eval not found in PATH or LOLA_EVAL env var" >&2
	exit 1
fi

for cmd in jq git; do
	command -v "$cmd" >/dev/null 2>&1 || {
		echo "snapshot.sh: $cmd is required but not found" >&2
		exit 1
	}
done

SNAPSHOT_ID="$(date -u +%Y%m%dT%H%M%SZ)"

# --- Generate JSON report to a temp file ---
TMPFILE="$(mktemp)"
trap 'rm -f "$TMPFILE"' EXIT

"$LOLA_EVAL" report --format json --out "$TMPFILE" >/dev/null 2>&1

# Handle both flat array and {rows:[…]} envelope formats
if jq -e 'type == "object" and has("rows")' "$TMPFILE" >/dev/null 2>&1; then
	# New envelope format — extract .rows to a flat array in-place
	jq '.rows' "$TMPFILE" >"${TMPFILE}.flat" && mv "${TMPFILE}.flat" "$TMPFILE"
fi

ROW_COUNT=$(jq 'length' "$TMPFILE")
if [[ "$ROW_COUNT" -eq 0 ]]; then
	echo "snapshot.sh: no results in report (run 'task eval:test' first)" >&2
	exit 1
fi

# --- Capture git provenance ---
GIT_SHA=$(git -C "$PROJECT_ROOT" rev-parse HEAD)
GIT_SHA_SHORT=$(git -C "$PROJECT_ROOT" rev-parse --short HEAD)
GIT_BRANCH=$(git -C "$PROJECT_ROOT" rev-parse --abbrev-ref HEAD)
GIT_REMOTE=$(git -C "$PROJECT_ROOT" remote get-url origin 2>/dev/null || echo "")
GIT_COMMIT_MSG=$(git -C "$PROJECT_ROOT" log -1 --format='%s')
GIT_AUTHOR=$(git -C "$PROJECT_ROOT" log -1 --format='%an')
GIT_DATE=$(git -C "$PROJECT_ROOT" log -1 --format='%aI')
if git -C "$PROJECT_ROOT" diff --quiet HEAD 2>/dev/null; then
	GIT_DIRTY=false
else
	GIT_DIRTY=true
fi

# --- Extract module version ---
MODULE_VERSION="unknown"
if [[ -f "$MODULE_DIR/AGENTS.md" ]]; then
	MODULE_VERSION=$(grep -oP '\*\*Version\*\*:\s*\K[0-9]+\.[0-9]+\.[0-9]+' "$MODULE_DIR/AGENTS.md" 2>/dev/null || echo "unknown")
fi

# --- Build provenance object (shared across all rows) ---
PROVENANCE=$(jq -n \
	--arg sid "$SNAPSHOT_ID" \
	--arg sha "$GIT_SHA" \
	--arg sha_short "$GIT_SHA_SHORT" \
	--arg branch "$GIT_BRANCH" \
	--arg remote "$GIT_REMOTE" \
	--arg msg "$GIT_COMMIT_MSG" \
	--arg author "$GIT_AUTHOR" \
	--arg date "$GIT_DATE" \
	--argjson dirty "$GIT_DIRTY" \
	--arg modver "$MODULE_VERSION" \
	'{
    snapshot_id: $sid,
    git_sha: $sha,
    git_sha_short: $sha_short,
    git_branch: $branch,
    git_remote: $remote,
    git_commit_msg: $msg,
    git_author: $author,
    git_date: $date,
    git_dirty: $dirty,
    module_version: $modver
  }')

# --- Append enriched rows to ledger ---
mkdir -p "$SNAPSHOTS_DIR"

while IFS= read -r row; do
	TASK_ID=$(echo "$row" | jq -r '.task_id')

	TASK_DESC=""
	TASK_YAML="$TESTS_DIR/$TASK_ID/task.yaml"
	if [[ -f "$TASK_YAML" ]]; then
		TASK_DESC=$(sed -n '/^description:/,/^[a-z_]*:/{
      /^description:/d
      /^[a-z_]*:/d
      p
    }' "$TASK_YAML" | tr '\n' ' ' | sed 's/  */ /g; s/^ *//; s/ *$//')
	fi

	echo "$row" | jq -c \
		--argjson prov "$PROVENANCE" \
		--arg desc "$TASK_DESC" \
		'$prov + . + {task_description: $desc} | del(.transcript_path)' \
		>>"$LEDGER"
done < <(jq -c '.[]' "$TMPFILE" || true)

# --- Generate markdown snapshot ---
SNAPSHOT_MD="$SNAPSHOTS_DIR/${SNAPSHOT_ID}.md"
TS_HUMAN="${SNAPSHOT_ID:0:4}-${SNAPSHOT_ID:4:2}-${SNAPSHOT_ID:6:2} ${SNAPSHOT_ID:9:2}:${SNAPSHOT_ID:11:2} UTC"
DIRTY_LABEL="clean"
if [[ "$GIT_DIRTY" == "true" ]]; then DIRTY_LABEL="dirty"; fi

{
	echo "# Eval Snapshot — $TS_HUMAN"
	echo ""
	echo "## Provenance"
	echo ""
	echo "| Field | Value |"
	echo "| --- | --- |"
	echo "| **Commit** | \`$GIT_SHA_SHORT\` ($GIT_SHA) |"
	echo "| **Branch** | \`$GIT_BRANCH\` |"
	echo "| **Author** | $GIT_AUTHOR |"
	echo "| **Date** | $GIT_DATE |"
	echo "| **Message** | $GIT_COMMIT_MSG |"
	echo "| **Module** | Review Council v$MODULE_VERSION |"
	echo "| **Working tree** | $DIRTY_LABEL |"
	echo ""

	# Matrix summary
	echo "## Matrix Summary"
	echo ""
	echo "| Case | Cell | Composite | Cost | Duration | Exit |"
	echo "| --- | --- | --- | --- | --- | --- |"
	jq -r '.[] |
    def fmt_cost: if .cost_usd then "$\(.cost_usd | tostring | split(".") | .[0] + "." + (.[1] + "00")[0:2])" else "-" end;
    def fmt_dur: if .duration_s then (if .duration_s >= 60 then "\(.duration_s / 60 | . * 10 | floor / 10)m" else "\(.duration_s | floor)s" end) else "-" end;
    def fmt_comp: if .composite then "\(.composite)" else "-" end;
    "| \(.task_id) | \(.cli)/\(.model) | **\(fmt_comp)** | \(fmt_cost) | \(fmt_dur) | \(.exit_status) |"
  ' "$TMPFILE"
	# Summary row for matrix
	jq -r '
    def fmt_cost: "$\(. | tostring | split(".") | .[0] + "." + (.[1] + "00")[0:2])";
    def fmt_dur: if . >= 60 then "\(. / 60 | . * 10 | floor / 10)m" else "\(. | floor)s" end;
    (length) as $n |
    ([.[] | select(.composite != null) | .composite] | if length > 0 then (add / length | . * 100 | floor / 100) else 0 end) as $avg |
    ([.[] | select(.cost_usd != null) | .cost_usd] | add // 0) as $cost |
    ([.[] | select(.duration_s != null) | .duration_s] | add // 0) as $dur |
    ([.[] | select(.exit_status == "success")] | length) as $pass |
    ($n - $pass) as $fail |
    "| **Total** | **\($n) cells** | **avg \($avg)** | **\($cost | fmt_cost)** | **\($dur | fmt_dur)** | **\($pass)p/\($fail)f** |"
  ' "$TMPFILE"
	echo ""

	# Per-dimension breakdown — collect all component names dynamically
	DIMS=$(jq -r '[.[].components | keys[]] | unique | .[]' "$TMPFILE" 2>/dev/null)
	if [[ -n "$DIMS" ]]; then
		echo "## Per-Dimension Breakdown"
		echo ""
		HEADER="| Case | Cell"
		SEP="| --- | ---"
		for d in $DIMS; do
			HEADER="$HEADER | $d"
			SEP="$SEP | ---"
		done
		echo "$HEADER |"
		echo "$SEP |"

		jq -r --arg dims "$DIMS" '
      .[] |
      . as $r |
      "| \(.task_id) | \(.cli)/\(.model)" + (
        ($dims | split("\n")) | map(
          . as $d | $r.components[$d] // null |
          if . then " | \(. | tostring)" else " | -" end
        ) | join("")
      ) + " |"
    ' "$TMPFILE"
		echo ""
	fi

	# Judge rationale
	echo "## Judge Rationale"
	echo ""
	jq -r '.[] |
    "### \(.task_id) — \(.cli)/\(.model) (\(if .composite then .composite else "n/a" end))\n\n\(.explanation // "(no explanation)")\n"
  ' "$TMPFILE"

	# Token economics
	echo "## Token Economics"
	echo ""
	echo "| Case | Cell | Input | Output | Cache Read | Cache Write | Cost |"
	echo "| --- | --- | --- | --- | --- | --- | --- |"
	jq -r '.[] |
    def fmt_tok: if . and . > 0 then (if . >= 1000 then "\(. / 1000 | . * 10 | floor / 10)K" else "\(.)" end) else "-" end;
    def fmt_cost: if .cost_usd then "$\(.cost_usd | tostring | split(".") | .[0] + "." + (.[1] + "00")[0:2])" else "-" end;
    "| \(.task_id) | \(.cli)/\(.model) | \(.input_tokens | fmt_tok) | \(.output_tokens | fmt_tok) | \(.cache_read_tokens | fmt_tok) | \(.cache_creation_tokens | fmt_tok) | \(fmt_cost) |"
  ' "$TMPFILE"
	# Summary row for token economics
	jq -r '
    def fmt_tok: if . and . > 0 then (if . >= 1000 then "\(. / 1000 | . * 10 | floor / 10)K" else "\(.)" end) else "-" end;
    def fmt_cost: "$\(. | tostring | split(".") | .[0] + "." + (.[1] + "00")[0:2])";
    ([.[] | .input_tokens // 0] | add) as $in |
    ([.[] | .output_tokens // 0] | add) as $out |
    ([.[] | .cache_read_tokens // 0] | add) as $cr |
    ([.[] | .cache_creation_tokens // 0] | add) as $cw |
    ([.[] | .cost_usd // 0] | add) as $cost |
    "| **Total** | **\(length) cells** | **\($in | fmt_tok)** | **\($out | fmt_tok)** | **\($cr | fmt_tok)** | **\($cw | fmt_tok)** | **\($cost | fmt_cost)** |"
  ' "$TMPFILE"
	echo ""
} >"$SNAPSHOT_MD"

LEDGER_LINES=$(wc -l <"$LEDGER")
LEDGER_BYTES=$(wc -c <"$LEDGER")
echo "snapshot.sh: appended $ROW_COUNT rows (snapshot $SNAPSHOT_ID)"
echo "snapshot.sh: ledger at $LEDGER ($LEDGER_BYTES bytes, $LEDGER_LINES total rows)"
echo "snapshot.sh: report at $SNAPSHOT_MD"
