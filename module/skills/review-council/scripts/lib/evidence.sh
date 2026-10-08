#!/usr/bin/env bash
# lib/evidence.sh — the evidence matcher shared by rc-verify-evidence.sh, which
# classifies every filed finding, and rc-apply-corrections.sh, which re-checks a
# finding after the correction round. One copy, so a corrected quote meets
# exactly the test the original failed. Sourced, never run.
#
# Callers set `review_root` (relative or absolute) and `root_abs` (its
# symlink-resolved absolute path) before calling anything here.
#
# shellcheck shell=bash
# shellcheck disable=SC2154 # review_root and root_abs are the caller's globals,
# set before sourcing as described above; standalone they look unassigned.

resolve() { [[ "$review_root" == "." ]] && echo "$1" || echo "${review_root%/}/$1"; }

# True when <path> resolves inside the review root. The `file` field is
# LLM-authored: without this, `../../etc/shadow` (or any absolute path reachable
# from the root) resolves, reads, and verifies, letting a reviewer launder
# content from outside the changeset as evidence.
#
# The leaf is resolved as well as the directory, because resolving only the
# directory leaves a symlink AT the leaf pointing wherever it likes and the
# evidence reader follows it. That is reachable on a materialised foreign-PR
# review, where the tree under the root is PR-author-controlled and the review
# root IS the PR head. Resolving the leaf costs no legitimate coverage: a
# symlink tracked inside the repository resolves back under root_abs and still
# verifies, and a dangling one never gets this far — the `-f` test above has
# already filed it as FILE_NOT_FOUND. Only a link that escapes the root changes
# outcome, and it becomes PATH_OUTSIDE_ROOT.
#
# The chain is walked a hop at a time rather than handed to `readlink -f`: the
# canonicalising flags are GNU extensions, Homebrew installs GNU readlink as
# `greadlink` and leaves BSD readlink on PATH, and the CI matrix runs macOS.
# Flagless `readlink` is portable, and each hop canonicalises its directory with
# the same `cd … && pwd -P` used for the review root above. Walking is required
# rather than resolving one hop: a single hop lands on an intermediate link and
# reports that name's containment, which passes an escaping chain whose first
# hop sits inside the root. The hop budget matches the kernel's own MAXSYMLINKS,
# so any chain the evidence reader could follow resolves here too, and a cycle
# — which the reader cannot follow either — reports as not contained.
path_in_root() { # path
	local dir base dir_abs tgt hops=0
	dir=$(dirname -- "$1")
	base=$(basename -- "$1")
	dir_abs=$(cd "$dir" 2>/dev/null && pwd -P) || return 1
	while [[ -L "$dir_abs/$base" ]]; do
		hops=$((hops + 1))
		[[ $hops -le 40 ]] || return 1
		tgt=$(readlink -- "$dir_abs/$base") || return 1
		[[ "$tgt" == /* ]] || tgt="$dir_abs/$tgt"
		dir_abs=$(cd "$(dirname -- "$tgt")" 2>/dev/null && pwd -P) || return 1
		base=$(basename -- "$tgt")
	done
	[[ "$dir_abs/$base" == "$root_abs" || "$dir_abs/$base" == "$root_abs"/* ]]
}

# Print the 1-based start line of every contiguous occurrence of <evidence> in
# <file>, one per line; print nothing when it does not occur.
#
# This replaces `grep -F`, whose POSIX semantics treat each newline in the
# pattern as a PATTERN SEPARATOR rather than a literal character. A multi-line
# quote was therefore searched as N independent literals and matched if any one
# of them did, which broke verification in both directions: fabricated blocks
# ending on a line that exists anywhere in the file were accepted, and accurate
# citations were rejected because the reported line came from whichever short
# literal happened to appear first in the file.
#
# Evidence crosses into awk through the environment, not `-v`: awk applies
# escape processing to `-v` assignments, so a literal backslash in the evidence
# would be silently rewritten before the comparison.
evidence_lines() { # file evidence
	RC_EV="$2" awk '
		BEGIN { ev = ENVIRON["RC_EV"]; k = split(ev, evl, "\n") }
		{ buf[NR] = $0 }
		END {
			for (i = 1; i <= NR; i++) {
				# evl[1] is a substring of the start line in every case: for
				# single-line evidence it is the whole pattern, and for
				# multi-line evidence it is the (possibly partial) first line.
				# Cheap reject before building a window.
				if (index(buf[i], evl[1]) == 0) continue
				if (k == 1) { print i; continue }
				# Evidence spanning k lines touches at most k file lines,
				# wherever within line i it begins. Trailing "\n" on each line
				# lets evidence that ends on a line boundary match at EOF.
				win = ""
				for (j = 0; j < k && i + j <= NR; j++) win = win buf[i + j] "\n"
				p = index(win, ev)
				# Require the match to begin within line i so each occurrence is
				# reported once, at its true start line.
				if (p > 0 && p <= length(buf[i]) + 1) print i
			}
		}
	' "$1"
}

# Print the evidence status of one finding: `verified`, or the reason it is not.
# FILE_NOT_FOUND and PATH_OUTSIDE_ROOT are strip reasons; EVIDENCE_EMPTY,
# EVIDENCE_SCAN_ERROR, EVIDENCE_NOT_FOUND and LINE_MISMATCH are correctable.
# <line> is the cited line already floored by the caller, or empty when uncited.
rc_evidence_status() { # file line evidence
	local f="$1" line="$2" ev="$3" fpath astatus occurrences lo hi near occ
	fpath=$(resolve "$f")
	if [[ ! -f "$fpath" ]]; then
		echo FILE_NOT_FOUND
		return 0
	fi
	# shellcheck disable=SC2310 # path_in_root is a predicate; suspending set -e
	# inside it is the intended contract (it reports containment as 0/1, and a
	# path whose directory cannot be entered is "not contained", not fatal).
	if ! path_in_root "$fpath"; then
		echo PATH_OUTSIDE_ROOT
		return 0
	fi
	# An evidence-free finding is unverifiable by construction, and the empty
	# string is a substring of every file — it must never reach the matcher.
	if [[ -z "$ev" || "$ev" == "null" ]]; then
		echo EVIDENCE_EMPTY
		return 0
	fi
	# Capture the status so a matcher failure (unreadable file, awk error) is
	# surfaced loudly rather than silently folded into EVIDENCE_NOT_FOUND.
	astatus=0
	# shellcheck disable=SC2310 # suspending set -e here is the point: the
	# status is captured into $astatus and handled explicitly below, which is
	# what keeps a scan failure distinguishable from a clean miss.
	occurrences=$(evidence_lines "$fpath" "$ev") || astatus=$?
	if [[ $astatus -ne 0 ]]; then
		echo "rc-evidence: evidence scan failed (exit $astatus) on $fpath" >&2
		echo EVIDENCE_SCAN_ERROR
		return 0
	fi
	if [[ -z "$occurrences" ]]; then
		echo EVIDENCE_NOT_FOUND
		return 0
	fi
	# Only a value bash arithmetic accepts may reach it. The caller's flooring
	# fixes 12.0, but two shapes still get through: a magnitude large enough to be
	# rendered in exponent form ("1e+300"), and a leading-zero run ("08"), which
	# bash reads as octal. Bash reports neither as a failed command — it tears
	# down this loop, so the finding AND every finding after it disappear from
	# all three buckets while findings.json is still written and total_findings
	# still claims them.
	#
	# The pattern is therefore keyed to the schema's own bounds: the leading
	# [1-9] is `minimum: 1`, which rejects the leading zero along with 0 itself,
	# and the digit count is that of `maximum: 10000000` — a digit-width cap
	# rather than the exact bound, but far below the magnitude at which jq
	# switches to exponent form. Bounding rather than "digits" is also what makes
	# `10#` unnecessary here: an octal-looking token cannot reach the arithmetic
	# to be reinterpreted. A value outside the bounds is read as an uncited line
	# instead — the evidence match is still required, the finding is simply not
	# line-anchored.
	if [[ "$line" =~ ^[1-9][0-9]{0,7}$ ]]; then
		lo=$((line - 5))
		hi=$((line + 5))
		[[ $lo -lt 1 ]] && lo=1
		# Accept when ANY occurrence lands in the window, not just the first:
		# identical blocks legitimately repeat across sibling test functions and
		# sibling handlers, and a citation of the second or third is accurate.
		near=0
		while IFS= read -r occ; do
			[[ -n "$occ" ]] || continue
			if [[ $occ -ge $lo && $occ -le $hi ]]; then
				near=1
				break
			fi
		done <<<"$occurrences"
		if [[ $near -eq 0 ]]; then
			echo LINE_MISMATCH
			return 0
		fi
	fi
	echo verified
}
