#!/usr/bin/env bash
# Select the unit suites worth re-running with one optional tool hidden.
#
# The degraded layer exists because a fallback branch is either always taken or
# never taken on a given host, so it is never deliberately exercised — that is
# how the jq fallback validator shipped accepting "HIG" as a severity. It hid
# each of `jsonschema`, `gh` and `glab` in turn and re-ran all 39 suites for
# each, which is three complete unit passes and was the largest single block of
# CI wall clock. Most of those suites never reach a line that consults the tool.
#
# A suite is worth re-running for a tool when some script it exercises can
# reach a call to that tool. That is a reachability question over two edges the
# tree already makes visible:
#
#   invocation  a script names the tool outside a full-line comment
#   reference   a file names another file's basename
#
# so the answer is discovered from the tree rather than hand-listed, in the
# same spirit as run-unit-tests.sh discovering the suites themselves. A list
# maintained by hand goes stale silently: a new script that calls `gh` would
# simply never be covered, and nothing would say so.
#
# Every judgement call here resolves toward including a suite. Including one
# that did not need it costs seconds; excluding one that did costs the only
# guarantee the layer offers, and leaves it printing green.
#
# Requires bash 4+ for associative arrays — the same prerequisite the module
# already carries (see Brewfile, and `task doctor` which enforces it).
set -uo pipefail

# tool_call_pattern <tool>
#
# An ERE matching the three shapes an actual use of <tool> takes in this tree.
# Merely naming the tool is not enough: module/tests/helpers.sh writes a fixture
# report containing the line "- Tooling: gh" on a live line, and because every
# suite sources helpers.sh that one line put all 40 suites in the gh selection.
# Hiding gh from PATH cannot change what that line prints.
#
# The three shapes, checked against every real call site in the tree:
#
#   command -v gh          the availability probe; how graceful degradation is
#                          spelled here, so it is the most important to catch
#   gh pr view ...         the tool in command position with an argument, after
#                          start-of-line, whitespace, `;`, `&`, `|` or `(`
#   forge_tool="gh"        assigned for indirect invocation later as "$forge_tool",
#                          which lib/prepare-repo.sh does and which no
#                          command-position rule would ever see
#
# The last one is why this is not simply "tool in command position". Narrowing
# the seed set is the one change here that can lose coverage rather than time,
# so each form it excludes is pinned by a test in
# module/tests/test-degraded-selection.sh.
tool_call_pattern() {
	local tool="$1"
	printf '(command -v[[:space:]]+%s([^A-Za-z0-9_-]|$))' "$tool"
	printf '|((^|[;&|(]|[[:space:]])%s[[:space:]]+[-a-zA-Z])' "$tool"
	printf '|(=["'"'"']?%s["'"'"']?[[:space:]]*$)' "$tool"
}

# suites_touching_tool <tool> <root>
#
# Prints, one absolute path per line and sorted, each suite under
# <root>/module/tests that can reach a call to <tool>. Returns 1 without
# printing if nothing in the tree names the tool.
suites_touching_tool() {
	local tool="$1" root="$2"
	local file base
	# Keyed by basename: a grep-based reference detector cannot resolve
	# `source "$(dirname "$0")/lib/helper.sh"` to a path anyway, and every
	# basename under module/ is distinct today. Full paths are kept alongside
	# for the output.
	local -A path_of=() refs_of=() affected=()
	local -a nodes=()

	# The suites drive code from three trees, not one: module/ holds the skill
	# itself, scripts/ holds repo-level drivers, and .taskfiles/scripts/ holds
	# the test harnesses that some suites test in turn. A walk rooted at module/
	# alone silently dropped test-review-open-prs.sh from the gh selection —
	# scripts/review-open-prs.sh calls `gh` twelve times, and none of them were
	# visible from inside module/.
	#
	# Listed rather than discovered from the repo root on purpose. The root also
	# holds .lola/, an installed snapshot of this same module, and walking it
	# would put a second `helpers.sh` and a second `test-review-open-prs.sh` into
	# a graph keyed by basename — the snapshot's copy would silently displace the
	# real one. Adding a tree here is a deliberate act; inheriting one is not.
	local -a search_roots=()
	local candidate
	for candidate in "$root/module" "$root/scripts" "$root/.taskfiles"; do
		[[ -d "$candidate" ]] && search_roots+=("$candidate")
	done
	if [[ ${#search_roots[@]} -eq 0 ]]; then
		echo "ERROR: none of module/, scripts/ or .taskfiles/ exist under $root." >&2
		return 1
	fi

	# Hoisted: the pattern depends only on the tool, and building it inside the
	# loop also buried a function call in an `if` condition, where a failure
	# would be discarded rather than aborting.
	local pattern
	pattern=$(tool_call_pattern "$tool")

	# Collected by assignment rather than streamed straight into the loop, so
	# that a find or sort that fails is the value of a plain assignment and not
	# a status swallowed inside a process substitution.
	local listing
	listing=$(find "${search_roots[@]}" -name '*.sh' -type f | sort)

	local stripped
	while IFS= read -r file; do
		[[ -n "$file" ]] || continue
		base="${file##*/}"
		path_of["$base"]="$file"
		nodes+=("$base")

		# Read once, matched twice. Both rules below see the same text, with
		# full-line comments removed and nothing else touched.
		#
		# Held in a variable rather than piped into each reader. `sed ... |
		# grep -q` looks equivalent and is not: grep exits the instant it
		# matches, sed is left writing into a closed pipe, and `set -o pipefail`
		# — on for this whole file — then reports the pipeline as 141, so a
		# match reads as a miss. It only bites once sed's output outgrows the
		# pipe buffer, which made it invisible on small files and cost roughly
		# four of every five detections on rc-extract-verdict.sh. Do not
		# "simplify" this back into a pipe; test-degraded-selection.sh fails
		# deterministically if you do.
		#
		# POSIX BRE only: BSD sed hands the pattern to regcomp untouched, so a
		# GNU escape here would misbehave on the macOS leg rather than fail.
		stripped=$(sed 's/^[[:space:]]*#.*$//' "$file")

		# Every *.sh basename this file names outside a full-line comment.
		#
		# Naming a script in prose is not a dependency on it, the same way
		# naming a tool in prose is not a call to it — the rule below and this
		# one have to agree or the graph means two different things at its two
		# ends. Counting comments was the first attempt, on the reasoning that
		# over-connecting is the safe direction. It is safe, and it is useless:
		# helpers.sh discusses rc-extract-verdict.sh in a comment, all 40 suites
		# source helpers.sh, and every tool therefore reached every suite. The
		# selection returned all 40 for each of the three tools and saved
		# nothing, while looking like it had worked.
		local names
		names=$(grep -oE '[A-Za-z0-9_.-]+\.sh' <<<"$stripped" | sort -u | tr '\n' ' ') || true
		refs_of["$base"]=" $names"

		# Trailing comments are deliberately left in place by the strip above.
		# Telling `foo # gh` from `foo "#gh"` means knowing where a `#` starts a
		# comment, which is not a question grep can answer; a wrong guess in
		# that direction drops a suite silently, and a wrong guess in this
		# direction runs one extra.
		if grep -qE -- "$pattern" <<<"$stripped"; then
			affected["$base"]=1
		fi
	done <<<"$listing"

	if [[ ${#affected[@]} -eq 0 ]]; then
		echo "ERROR: nothing under $root/module names '$tool' outside a comment." >&2
		echo "       Either the tool name is wrong, or the reference walk is broken." >&2
		echo "       Both mean a degraded run for '$tool' would prove nothing, so it" >&2
		echo "       is refused rather than reported green over an empty selection." >&2
		return 1
	fi

	# Close over the reference edge: a file that names an affected file's
	# basename can reach the tool through it. Iterated to a fixpoint because
	# the chain has depth — a suite reaches lib/forge/gitlab.sh through
	# rc-prepare.sh and lib/prepare-repo.sh, not directly.
	local changed=1 node hit
	while ((changed)); do
		changed=0
		for node in "${nodes[@]}"; do
			[[ -n "${affected[$node]:-}" ]] && continue
			for hit in "${!affected[@]}"; do
				if [[ "${refs_of[$node]}" == *" $hit "* ]]; then
					affected["$node"]=1
					changed=1
					break
				fi
			done
		done
	done

	# `nodes` is find-sorted, so the output order is stable across filesystems
	# — the readdir order a local disk happens to return is not the one CI
	# returns, and an order-dependent caller would pass here and fail there.
	local suite_dir="$root/module/tests"
	for node in "${nodes[@]}"; do
		[[ -n "${affected[$node]:-}" ]] || continue
		[[ "$node" == test-*.sh ]] || continue
		[[ "${path_of[$node]%/*}" == "$suite_dir" ]] || continue
		printf '%s\n' "${path_of[$node]}"
	done
}

# Sourced for its function by run-degraded-tests.sh and by the suite that
# guards it; run directly it prints the selection for one tool.
[[ "${BASH_SOURCE[0]}" != "${0}" ]] && return 0

if [[ $# -ne 1 ]]; then
	echo "usage: ${0##*/} <tool>" >&2
	exit 2
fi
here=$(dirname "$0")
repo_root=$(cd "$here/../.." && pwd)
suites_touching_tool "$1" "$repo_root"
