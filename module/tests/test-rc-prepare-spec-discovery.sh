#!/usr/bin/env bash
# Spec-mode artifact discovery: which directories are scanned and which file
# extensions count as a spec.
#
# The bug this suite was written for: discovery recognised `.md`/`.txt` under a
# hardcoded five-directory list and nothing else. The MCP specification repo —
# 142 spec files under `docs/specification/`, every one `.mdx` — missed on both
# axes and reported "No spec artifacts found to review." So did the recovery the
# skill suggests in that situation (`--scope paths docs/specification`), because
# the extension filter rejected all 142 files there too. `.mdx` is the format
# Mintlify, Docusaurus and Nextra all publish.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$SCRIPT_DIR/../skills/review-council/scripts/rc-prepare.sh"
AGENTS="$SCRIPT_DIR/../agents"
# shellcheck source=module/tests/helpers.sh
source "$SCRIPT_DIR/helpers.sh"

# A repo whose specs live where a real docs site puts them: .mdx under
# docs/specification/, plus one .go so a spec review can be caught sweeping in
# source it has no business reviewing.
make_mdx_repo() {
	local work
	work=$(mktemp -d)
	(
		cd "$work" || exit 1
		git_init_sandbox
		git checkout -q -b main
		mkdir -p docs/specification/basic src
		echo "# Base protocol" >docs/specification/index.mdx
		echo "# Lifecycle" >docs/specification/basic/lifecycle.mdx
		echo "package main" >src/main.go
		git add docs src
		git commit -qm init
	)
	printf '%s' "$work"
}

run_prepare() { # <workdir> <args...> -> prints the JSON result
	local work="$1"
	shift
	(cd "$work" && AGENTS_DIR="$AGENTS" bash "$SCRIPT" "$@" 2>/dev/null)
}

changeset_of() { # <result json> -> prints changeset.txt, or nothing
	# Always succeeds: an empty result is a normal outcome here (several cases
	# assert on it), and under `set -e` a non-zero return would abort the suite
	# at the first such case instead of reporting it.
	local sess
	sess=$(jq -r '.session_dir // empty' <<<"$1")
	if [[ -n "$sess" && -f "$sess/changeset.txt" ]]; then
		cat "$sess/changeset.txt"
	fi
	return 0
}

echo "Test 1: .mdx specs under docs/specification are discovered by --scope all"
work=$(make_mdx_repo)
result=$(run_prepare "$work" --mode specs --scope all)
assert_json_field "$result" "status" "ok" "status is ok for an mdx spec repo"
changeset=$(changeset_of "$result")
if grep -qF 'docs/specification/index.mdx' <<<"$changeset" &&
	grep -qF 'docs/specification/basic/lifecycle.mdx' <<<"$changeset"; then
	echo "  PASS: both .mdx specs discovered"
	PASS=$((PASS + 1))
else
	flattened=$(tr '\n' ' ' <<<"$changeset")
	echo "  FAIL: .mdx specs missing from changeset (got: $flattened)"
	FAIL=$((FAIL + 1))
fi
if grep -qF 'src/main.go' <<<"$changeset"; then
	echo "  FAIL: spec review swept in source files"
	FAIL=$((FAIL + 1))
else
	echo "  PASS: source files stay out of a spec review"
	PASS=$((PASS + 1))
fi
rm -rf "$work"

echo "Test 2: the suggested recovery (--scope paths) finds the same files"
# The skill tells a user whose specs are elsewhere to re-run with an explicit
# path. That advice was useless while the path branch applied the same
# extension filter — pointing it straight at the specs still found nothing.
work=$(make_mdx_repo)
result=$(run_prepare "$work" --mode specs --scope paths --scope-value docs/specification)
assert_json_field "$result" "status" "ok" "status is ok for an explicit spec path"
changeset=$(changeset_of "$result")
if grep -qF 'docs/specification/index.mdx' <<<"$changeset"; then
	echo "  PASS: explicit path finds .mdx specs"
	PASS=$((PASS + 1))
else
	echo "  FAIL: explicit path still finds nothing"
	FAIL=$((FAIL + 1))
fi
rm -rf "$work"

echo "Test 3: a changed .mdx spec is discovered by a ref range"
work=$(make_mdx_repo)
(
	cd "$work" || exit 1
	git checkout -q -b docs/update
	echo "# Revised" >>docs/specification/index.mdx
	git commit -qam revise
)
result=$(run_prepare "$work" --mode specs --scope range --scope-value main..HEAD)
assert_json_field "$result" "status" "ok" "status is ok for a spec ref range"
changeset=$(changeset_of "$result")
if grep -qF 'docs/specification/index.mdx' <<<"$changeset"; then
	echo "  PASS: changed .mdx spec discovered in a range"
	PASS=$((PASS + 1))
else
	echo "  FAIL: changed .mdx spec missing from a range review"
	FAIL=$((FAIL + 1))
fi
rm -rf "$work"

echo "Test 4: REVIEW_COUNCIL_SPEC_DIRS points discovery at a bespoke layout"
# No fixed list can cover every project. The override is what keeps a repo
# using neither `specs/` nor `docs/` from being unreviewable.
work=$(mktemp -d)
(
	cd "$work" || exit 1
	git_init_sandbox
	git checkout -q -b main
	mkdir -p architecture
	echo "# House layout" >architecture/overview.md
	git add architecture
	git commit -qm init
)
result=$(cd "$work" && AGENTS_DIR="$AGENTS" REVIEW_COUNCIL_SPEC_DIRS="architecture" \
	bash "$SCRIPT" --mode specs --scope all 2>/dev/null)
assert_json_field "$result" "status" "ok" "status is ok with a directory override"
changeset=$(changeset_of "$result")
if grep -qF 'architecture/overview.md' <<<"$changeset"; then
	echo "  PASS: overridden directory scanned"
	PASS=$((PASS + 1))
else
	echo "  FAIL: overridden directory not scanned"
	FAIL=$((FAIL + 1))
fi
# Without the override the same repo has no specs at all, which is what makes
# the test above meaningful rather than incidentally true.
result=$(run_prepare "$work" --mode specs --scope all)
assert_json_field "$result" "status" "empty" "same repo is empty without the override"
rm -rf "$work"

echo "Test 5: REVIEW_COUNCIL_SPEC_EXTS admits a project's own spec format"
work=$(mktemp -d)
(
	cd "$work" || exit 1
	git_init_sandbox
	git checkout -q -b main
	mkdir -p specs
	echo "= Title" >specs/protocol.asciidoc
	git add specs
	git commit -qm init
)
result=$(cd "$work" && AGENTS_DIR="$AGENTS" REVIEW_COUNCIL_SPEC_EXTS="asciidoc" \
	bash "$SCRIPT" --mode specs --scope all 2>/dev/null)
assert_json_field "$result" "status" "ok" "status is ok with an extension override"
changeset=$(changeset_of "$result")
if grep -qF 'specs/protocol.asciidoc' <<<"$changeset"; then
	echo "  PASS: overridden extension discovered"
	PASS=$((PASS + 1))
else
	echo "  FAIL: overridden extension not discovered"
	FAIL=$((FAIL + 1))
fi
rm -rf "$work"

echo "Test 6: the empty result names where it looked"
# "No spec artifacts found to review." on its own gives a user nothing to act
# on. The message has to say which directories were searched, so the next
# command is obvious without reading the source.
work=$(mktemp -d)
(
	cd "$work" || exit 1
	git_init_sandbox
	git checkout -q -b main
	echo "package main" >main.go
	git add main.go
	git commit -qm init
)
result=$(run_prepare "$work" --mode specs --scope all)
assert_json_field "$result" "status" "empty" "status is empty with no specs anywhere"
message=$(jq -r '.message // ""' <<<"$result")
if grep -qF 'specs' <<<"$message" && grep -qF 'docs/specification' <<<"$message"; then
	echo "  PASS: empty message lists the searched directories"
	PASS=$((PASS + 1))
else
	echo "  FAIL: empty message does not say where it looked (got: $message)"
	FAIL=$((FAIL + 1))
fi
if grep -qF 'REVIEW_COUNCIL_SPEC_DIRS' <<<"$message"; then
	echo "  PASS: empty message names the override"
	PASS=$((PASS + 1))
else
	echo "  FAIL: empty message does not name the override"
	FAIL=$((FAIL + 1))
fi
rm -rf "$work"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
