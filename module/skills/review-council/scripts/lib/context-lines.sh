#!/usr/bin/env bash
# Context-check lines (#107): which lines each code reviewer may quote.
#
# The gate (rc-extract-verdict.sh) claims a quoted line by round plus trimmed
# text, not by file or line number, and gives the claim to the first verdict it
# processes. So reviewers who each choose "the obvious line" collide, and the
# orchestrator spends a turn per re-dispatch. Offering each reviewer its own
# lines, unique in text across the round, removes the collisions that come from
# independent choices. The gate itself is unchanged.
#
# Sourced by rc-assemble-prompts.sh, which provides review_root and code_span.
# Needs RC_CONTEXT_LINE_MIN_BYTES and RC_CONTEXT_LINE_MAX_BYTES from rc-lib.sh.
#
# shellcheck shell=bash
# shellcheck disable=SC2154 # the RC_CONTEXT_LINE_* bounds are rc-lib.sh's globals,
# set before sourcing as described above; standalone they look unassigned.

# Rows `path<TAB>line<TAB>text` for every line of one file that may be offered:
# outside the hunks, between the byte bounds once trimmed of [ \t\r], and
# printable ASCII only. The ASCII rule drops NUL and control bytes, non-UTF-8,
# and the Unicode spaces the gate's locale-dependent trim would treat
# differently, so the assembler and the gate cannot disagree about whether two
# lines are the same text. Printed text is the trimmed text.
# $1 file on disk, $2 path to print, $3 hunks as `start end` pairs joined by `;`.
eligible_lines() { # fpath path hunks
	LC_ALL=C awk -v path="$2" -v hunks="$3" -v min="$RC_CONTEXT_LINE_MIN_BYTES" -v max="$RC_CONTEXT_LINE_MAX_BYTES" '
		BEGIN {
			n = split(hunks, h, ";")
			for (i = 1; i <= n; i++) {
				split(h[i], p, " ")
				lo[i] = p[1] + 0
				hi[i] = p[2] + 0
			}
		}
		{
			for (i = 1; i <= n; i++) if (NR >= lo[i] && NR <= hi[i]) next
			t = $0
			sub(/^[ \t\r]+/, "", t)
			sub(/[ \t\r]+$/, "", t)
			if (length(t) < min || length(t) > max) next
			if (t !~ /^[ -~]+$/) next
			printf "%s\t%d\t%s\n", path, NR, t
		}' "$1"
}

# Rows `agent<TAB>path<TAB>line`: the round's eligible lines whose text occurs
# once in the whole round, dealt one at a time across the agents in the order
# given, taking the files in turn so reviewers land in different files where
# there are several. A line is never given to one agent beside a line held by
# another, so an off-by-one citation lands on a line nobody holds. Whoever runs
# out of lines, or is hemmed in by neighbours, gets none: the context check then
# works as it did before this existed.
# $1 review root, $2 the round's JSON from prompts/context.json, $3 lines per
# agent, then the agents.
deal_lines() { # root round n agent...
	local root="$1" round="$2" n="$3"
	shift 3
	local rows="" path hunks fpath files_tsv
	files_tsv=$(jq -r '.files[] | select(.outside == true)
		| [.path, (.hunks | map("\(.[0]) \(.[1])") | join(";"))] | @tsv' <<<"$round")
	while IFS=$'\t' read -r path hunks; do
		[[ -n "$path" ]] || continue
		fpath="${root%/}/$path"
		# build-context already decided `outside`; this guards the files it
		# measured but a reviewer could not quote: a link, or a file with NULs
		# (an over-cap binary still gets `outside` computed).
		[[ -f "$fpath" && ! -L "$fpath" ]] || continue
		# shellcheck disable=SC2312,SC2094 # a failing tr leaves cmp unequal, so the file is skipped; both only read it.
		tr -d '\000' <"$fpath" | cmp -s - "$fpath" || continue
		rows+=$(eligible_lines "$fpath" "$path" "$hunks")$'\n'
	done <<<"$files_tsv"
	printf '%s' "$rows" | LC_ALL=C awk -F'\t' -v n="$n" -v agents="$*" '
		NF == 3 { seen[$3]++; row[++m] = $0 }
		END {
			na = split(agents, ag, " ")
			for (i = 1; i <= m; i++) {
				split(row[i], f, "\t")
				if (seen[f[3]] != 1) continue
				if (!(f[1] in fi)) { fi[f[1]] = ++nf; name[nf] = f[1] }
				cand[fi[f[1]], ++cnt[fi[f[1]]]] = f[2]
			}
			for (pos = 1; ; pos++) {
				any = 0
				for (x = 1; x <= nf; x++) if (pos <= cnt[x]) {
					any = 1
					order[++no] = x SUBSEP cand[x, pos]
				}
				if (!any) break
			}
			for (pass = 1; pass <= n; pass++)
				for (a = 1; a <= na; a++)
					for (i = 1; i <= no; i++) {
						if (used[i]) continue
						split(order[i], o, SUBSEP)
						x = o[1]
						ln = o[2] + 0
						h1 = held[x, ln - 1]
						h2 = held[x, ln + 1]
						if ((h1 != "" && h1 != a) || (h2 != "" && h2 != a)) continue
						used[i] = 1
						held[x, ln] = a
						printf "%s\t%s\t%d\n", ag[a], name[x], ln
						break
					}
		}'
}

# The block of prompt text naming one reviewer's lines, from its
# `path<TAB>line` rows. Locations only, never the lines' text: the reviewer
# still has to read the file to quote it. Paths go through code_span, as every
# changeset path in a prompt does.
context_lines_block() { # rows
	local path lines span sorted grouped
	sorted=$(sort -t $'\t' -k1,1 -k2,2n <<<"$1")
	grouped=$(awk -F'\t' '{ if (!($1 in l)) order[++n] = $1; l[$1] = l[$1] (l[$1] == "" ? "" : ", ") $2 }
		END { for (i = 1; i <= n; i++) printf "%s\t%s\n", order[i], l[order[i]] }' <<<"$sorted")
	echo "Lines to choose your \`context_check\` from. The script picked them for you alone, outside the diff hunks; quote one whole line from this list:"
	echo ""
	while IFS=$'\t' read -r path lines; do
		span=$(code_span "$path")
		printf -- '- %s: %s\n' "$span" "$lines"
	done <<<"$grouped"
}
