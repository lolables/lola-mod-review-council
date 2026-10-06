#!/usr/bin/env bash
# Mode detection classifies the files the requested scope reviews.
#
# The bug this suite was written for: `/review-council HEAD` on a merge commit
# that changed only Terraform came back `status: empty`, "No spec artifacts
# found to review". Mode detection had no branch for a ref range, so it read
# `base...HEAD` — empty once the branch is merged — and an empty list sent it
# looking for spec directories on disk. A gitignored docs/superpowers/ held
# one, so the run resolved to spec mode, and spec capture then read the real
# range and dropped every file in it for not being a spec. No reviewer ran.
#
# The rule these tests pin: detection and capture read the same file set, for
# every scope; an explicitly requested range or PR is never classified by
# documents outside it; and both stages share one definition of a spec.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$SCRIPT_DIR/../skills/review-council/scripts/rc-prepare.sh"
AGENTS="$SCRIPT_DIR/../agents"
# shellcheck source=module/tests/helpers.sh
source "$SCRIPT_DIR/helpers.sh"

run_prepare() { # dir args...
	local dir="$1"
	shift
	(cd "$dir" && AGENTS_DIR="$AGENTS" bash "$SCRIPT" "$@" 2>/dev/null)
}

# Assert <path> is (or, with "absent", is not) a line of the session's
# changeset.txt.
assert_captured() { # result path label [absent]
	local sess
	sess=$(jq -r '.session_dir // empty' <<<"$1")
	if [[ -n "$sess" ]] && grep -qxF -- "$2" "$sess/changeset.txt" 2>/dev/null; then
		[[ "${4:-}" == "absent" ]] && {
			echo "  FAIL: $3 (found $2)"
			FAIL=$((FAIL + 1))
			return
		}
	elif [[ "${4:-}" != "absent" ]]; then
		echo "  FAIL: $3 (missing $2)"
		FAIL=$((FAIL + 1))
		return
	fi
	echo "  PASS: $3"
	PASS=$((PASS + 1))
}

# A repo on main whose last commit is a --no-ff merge of a topic branch that
# changed <files>, so `main...HEAD` is empty while `HEAD~1..HEAD` is not —
# the shape of the original report. Every repo carries a gitignored local spec
# under docs/superpowers/, the document that hijacked detection.
make_merged_repo() { # files...
	local work
	work=$(mktemp -d)
	(
		cd "$work" || exit 1
		git_init_sandbox
		git checkout -q -b main
		printf 'docs/superpowers/\n' >.gitignore
		echo "# readme" >README.md
		git add .gitignore README.md
		git commit -qm init
		git checkout -q -b topic
		for f in "$@"; do
			mkdir -p "$(dirname "$f")"
			echo "change" >"$f"
			git add "$f"
		done
		git commit -qm topic
		git checkout -q main
		git merge -q --no-ff topic -m "Merge branch 'topic'"
		mkdir -p docs/superpowers/specs
		echo "# Local design" >docs/superpowers/specs/local-design.md
	)
	echo "$work"
}

echo "Test 1: a Terraform range on a merge commit is a code review despite ignored local specs"
work=$(make_merged_repo live/dev/main.tf live/dev/variables.tf)
result=$(run_prepare "$work" --scope range --scope-value "HEAD~1..HEAD")
assert_json_field "$result" "status" "ok" "status is ok"
assert_json_field "$result" "mode" "code" "mode is code"
assert_captured "$result" "live/dev/main.tf" "main.tf is captured"
assert_captured "$result" "live/dev/variables.tf" "variables.tf is captured"
assert_captured "$result" "docs/superpowers/specs/local-design.md" "the ignored local spec is not captured" absent
rm -rf "$work"

echo "Test 2: the same range without local specs gives the same result"
work=$(make_merged_repo live/dev/main.tf live/dev/variables.tf)
rm -rf "$work/docs"
result=$(run_prepare "$work" --scope range --scope-value "HEAD~1..HEAD")
assert_json_field "$result" "mode" "code" "mode is code"
assert_captured "$result" "live/dev/main.tf" "main.tf is captured"
rm -rf "$work"

echo "Test 3: a GitLab CI-only range is a code review"
work=$(make_merged_repo .gitlab-ci.yml .gitlab/full-pipeline.yml .gitlab/scripts/generate-child-config.sh)
result=$(run_prepare "$work" --scope range --scope-value "HEAD~1..HEAD")
assert_json_field "$result" "mode" "code" "mode is code"
assert_captured "$result" ".gitlab-ci.yml" ".gitlab-ci.yml is captured"
assert_captured "$result" ".gitlab/full-pipeline.yml" "child pipeline YAML is captured"
assert_captured "$result" ".gitlab/scripts/generate-child-config.sh" "CI script is captured"
rm -rf "$work"

echo "Test 4: a GitHub Actions-only range is a code review"
work=$(make_merged_repo .github/workflows/ci.yml .github/workflows/release.yaml)
result=$(run_prepare "$work" --scope range --scope-value "HEAD~1..HEAD")
assert_json_field "$result" "mode" "code" "mode is code"
assert_captured "$result" ".github/workflows/ci.yml" "ci.yml is captured"
assert_captured "$result" ".github/workflows/release.yaml" "release.yaml is captured"
rm -rf "$work"

echo "Test 5: a mixed code and spec range is a code review that keeps both"
work=$(make_merged_repo src/app.go docs/specs/feature.md)
result=$(run_prepare "$work" --scope range --scope-value "HEAD~1..HEAD")
assert_json_field "$result" "mode" "code" "mode is code"
assert_captured "$result" "src/app.go" "the code file is captured"
assert_captured "$result" "docs/specs/feature.md" "the spec file is captured"
rm -rf "$work"

echo "Test 6: a spec-only range is a spec review of the changed spec"
work=$(make_merged_repo docs/specs/feature.md)
result=$(run_prepare "$work" --scope range --scope-value "HEAD~1..HEAD")
assert_json_field "$result" "status" "ok" "status is ok"
assert_json_field "$result" "mode" "spec" "mode is spec"
assert_captured "$result" "docs/specs/feature.md" "the changed spec is captured"
assert_captured "$result" "docs/superpowers/specs/local-design.md" "the unchanged local spec is not captured" absent
rm -rf "$work"

echo "Test 7: a configured spec location is a spec to detection as well as capture"
# REVIEW_COUNCIL_SPEC_DIRS reached capture alone, so detection called a changed
# doc under a configured directory code and spec capture was never asked.
work=$(make_merged_repo handbook/rfc-1.adoc)
result=$(cd "$work" && REVIEW_COUNCIL_SPEC_DIRS=handbook AGENTS_DIR="$AGENTS" \
	bash "$SCRIPT" --scope range --scope-value "HEAD~1..HEAD" 2>/dev/null)
assert_json_field "$result" "mode" "spec" "mode is spec"
assert_captured "$result" "handbook/rfc-1.adoc" "the configured-location spec is captured"
rm -rf "$work"

echo "Test 8: a file detection calls a spec is one spec capture keeps"
# Detection used to call any root-level plan.md a spec while capture admitted
# only files under the spec directories, so the run came back empty.
work=$(make_merged_repo plan.md)
result=$(run_prepare "$work" --scope range --scope-value "HEAD~1..HEAD")
assert_json_field "$result" "status" "ok" "status is ok, not empty"
assert_captured "$result" "plan.md" "plan.md is captured"
rm -rf "$work"

echo "Test 9: a range with a secondary path filter classifies only the filtered files"
work=$(make_merged_repo infra/main.tf docs/specs/feature.md)
result=$(run_prepare "$work" --scope range --scope-value "HEAD~1..HEAD" --scope paths --scope-value infra)
assert_json_field "$result" "mode" "code" "filter to infra/ is code"
assert_captured "$result" "infra/main.tf" "the filtered file is captured"
assert_captured "$result" "docs/specs/feature.md" "the file outside the filter is not captured" absent
rm -rf "$work"

echo "Test 10: a valid empty range reports no changes, not missing specs"
work=$(make_merged_repo src/app.go)
result=$(run_prepare "$work" --scope range --scope-value "HEAD..HEAD")
assert_json_field "$result" "status" "empty" "status is empty"
message=$(jq -r '.message // ""' <<<"$result")
if grep -qF "No changes to review" <<<"$message" && ! grep -qF "spec" <<<"$message"; then
	echo "  PASS: message reports an empty range"
	PASS=$((PASS + 1))
else
	echo "  FAIL: message does not report an empty range (got: $message)"
	FAIL=$((FAIL + 1))
fi
rm -rf "$work"

echo "Test 11: an unresolvable range is refused, whatever specs are on disk"
work=$(make_merged_repo src/app.go)
result=$(run_prepare "$work" --scope range --scope-value "nosuchref..HEAD")
assert_json_field "$result" "status" "skip" "status is skip"
message=$(jq -r '.message // ""' <<<"$result")
if grep -qF "Cannot resolve ref range" <<<"$message"; then
	echo "  PASS: message names the unresolvable range"
	PASS=$((PASS + 1))
else
	echo "  FAIL: message does not name the range (got: $message)"
	FAIL=$((FAIL + 1))
fi
rm -rf "$work"

echo "Test 12: staged-only and unstaged-only code changes are a code review of those files"
for kind in staged unstaged; do
	work=$(make_merged_repo src/app.go)
	(
		cd "$work" || exit 1
		echo "more" >>src/app.go
		[[ "$kind" == staged ]] && git add src/app.go
		true
	)
	result=$(run_prepare "$work" --scope changed)
	assert_json_field "$result" "mode" "code" "$kind change is code"
	assert_captured "$result" "src/app.go" "$kind change is captured"
	rm -rf "$work"
done

echo "Test 13: a staged-only change under a named directory is captured"
work=$(make_merged_repo src/app.go)
(
	cd "$work" || exit 1
	echo "more" >>src/app.go
	git add src/app.go
)
result=$(run_prepare "$work" --scope paths --scope-value src)
assert_json_field "$result" "mode" "code" "mode is code"
assert_captured "$result" "src/app.go" "the staged file is captured"
rm -rf "$work"

echo "Test 14: a staged-only spec change is a spec review of it"
work=$(make_merged_repo src/app.go)
(
	cd "$work" || exit 1
	mkdir -p docs/specs
	echo "# New" >docs/specs/new.md
	git add docs/specs/new.md
)
result=$(run_prepare "$work" --scope changed)
assert_json_field "$result" "status" "ok" "status is ok"
assert_json_field "$result" "mode" "spec" "mode is spec"
assert_captured "$result" "docs/specs/new.md" "the staged spec is captured"
rm -rf "$work"

echo "Test 15: --scope all on a clean branch classifies the whole tree"
work=$(make_merged_repo src/app.go docs/specs/feature.md)
result=$(run_prepare "$work" --scope all)
assert_json_field "$result" "mode" "code" "mode is code"
assert_captured "$result" "src/app.go" "the code file is captured"
rm -rf "$work"

echo "Test 16: a PR with a secondary path filter classifies only the filtered files"
# The fake gh serves a PR touching one Go file and one spec. Filtered to the
# spec directory, nothing under review is code.
bindir=$(mktemp -d)
cat >"$bindir/gh" <<'GH'
#!/usr/bin/env bash
case "$1 $2" in
"pr view")
	cat <<'JSON'
{"number":7,"title":"T","body":"","baseRefName":"main","headRefName":"feature-head","url":"https://github.com/acme/widgets/pull/7","state":"OPEN","statusCheckRollup":[]}
JSON
	;;
"pr diff")
	cat <<'DIFF'
diff --git a/foo.go b/foo.go
--- a/foo.go
+++ b/foo.go
@@ -0,0 +1 @@
+package main
diff --git a/docs/specs/feature.md b/docs/specs/feature.md
--- a/docs/specs/feature.md
+++ b/docs/specs/feature.md
@@ -0,0 +1 @@
+# Feature
DIFF
	;;
"api "*) echo "[]" ;;
*) exit 0 ;;
esac
GH
chmod +x "$bindir/gh"
work=$(mktemp -d)
setup_repo "$work"
mkdir -p "$work/docs/specs" && echo "# Feature" >"$work/docs/specs/feature.md"
result=$(cd "$work" && PATH="$bindir:$PATH" AGENTS_DIR="$AGENTS" \
	bash "$SCRIPT" --scope pr --scope-value 7 --scope paths --scope-value docs/specs 2>/dev/null)
assert_json_field "$result" "mode" "spec" "filter to docs/specs is spec"
assert_captured "$result" "docs/specs/feature.md" "the filtered spec is captured"
assert_captured "$result" "foo.go" "the code file outside the filter is not captured" absent
# Filtered to a directory the PR never touched, the PR names nothing to
# review: that is an empty result, not a spec search of the disk.
result=$(cd "$work" && PATH="$bindir:$PATH" AGENTS_DIR="$AGENTS" \
	bash "$SCRIPT" --scope pr --scope-value 7 --scope paths --scope-value src 2>/dev/null)
assert_json_field "$result" "status" "empty" "a PR filtered to nothing it touched is empty"
rm -rf "$work" "$bindir"

echo "Test 17: an explicit mode is not reclassified"
work=$(make_merged_repo docs/specs/feature.md)
result=$(run_prepare "$work" --mode code --scope range --scope-value "HEAD~1..HEAD")
assert_json_field "$result" "mode" "code" "--mode code on a spec-only range stays code"
assert_captured "$result" "docs/specs/feature.md" "the spec file is captured for code review"
rm -rf "$work"

echo "Test 18: --mode specs on a code-only range says no file in it is a spec"
work=$(make_merged_repo live/dev/main.tf)
result=$(run_prepare "$work" --mode specs --scope range --scope-value "HEAD~1..HEAD")
assert_json_field "$result" "status" "empty" "status is empty"
message=$(jq -r '.message // ""' <<<"$result")
if grep -qF "HEAD~1..HEAD" <<<"$message" && grep -qF "none is a spec" <<<"$message"; then
	echo "  PASS: message names the range and says nothing in it is a spec"
	PASS=$((PASS + 1))
else
	echo "  FAIL: message does not distinguish changed-but-not-spec (got: $message)"
	FAIL=$((FAIL + 1))
fi
rm -rf "$work"

# A repo checked out on a topic branch that changed <files> relative to main,
# with the same gitignored local spec as make_merged_repo. Running with no
# --scope at all is the default invocation, which reviews this branch.
make_topic_repo() { # files...
	local work
	work=$(mktemp -d)
	(
		cd "$work" || exit 1
		git_init_sandbox
		git checkout -q -b main
		printf 'docs/superpowers/\n' >.gitignore
		echo "# readme" >README.md
		git add .gitignore README.md
		git commit -qm init
		git checkout -q -b topic
		for f in "$@"; do
			mkdir -p "$(dirname "$f")"
			echo "change" >"$f"
			git add "$f"
		done
		git commit -qm topic
		mkdir -p docs/superpowers/specs
		echo "# Local design" >docs/superpowers/specs/local-design.md
	)
	echo "$work"
}

echo "Test 19: with no --scope, a spec-only branch is a spec review of what it changed"
# Detection classified the branch's changes while spec capture, seeing no
# --scope, swept the spec directories instead: a branch changing only a root
# plan.md came back spec mode reviewing an unrelated ignored document.
work=$(make_topic_repo plan.md)
result=$(run_prepare "$work")
assert_json_field "$result" "status" "ok" "status is ok"
assert_json_field "$result" "mode" "spec" "mode is spec"
assert_captured "$result" "plan.md" "the changed plan.md is captured"
assert_captured "$result" "docs/superpowers/specs/local-design.md" "the unchanged local spec is not captured" absent
rm -rf "$work"

echo "Test 20: --mode specs with no --scope still sweeps the spec directories"
work=$(make_topic_repo plan.md)
result=$(run_prepare "$work" --mode specs)
assert_json_field "$result" "status" "ok" "status is ok"
assert_captured "$result" "docs/superpowers/specs/local-design.md" "the spec directory is swept"
rm -rf "$work"

echo "Test 21: a planning-document name is a spec only as a whole word"
# feature-spec.md and docs/tasks.md are what spec workflows write; respec.md
# and redesign.md merely end in the same letters.
for case_ in "feature-spec.md:spec" "docs/tasks.md:spec" "notes/design_plan.md:spec" \
	"src/respec.md:code" "notes/redesign.md:code" "aplan.md:code"; do
	path="${case_%:*}" want="${case_##*:}"
	work=$(make_merged_repo "$path")
	result=$(run_prepare "$work" --scope range --scope-value "HEAD~1..HEAD")
	assert_json_field "$result" "mode" "$want" "$path is $want"
	assert_captured "$result" "$path" "$path is captured"
	rm -rf "$work"
done

# A repo on main whose only tracked file is docs/specs/feature.md, so under
# --scope all the tracked tree alone is spec-only.
make_spec_only_repo() {
	local work
	work=$(mktemp -d)
	(
		cd "$work" || exit 1
		git_init_sandbox
		git checkout -q -b main
		mkdir -p docs/specs
		echo "# Feature" >docs/specs/feature.md
		git add docs/specs/feature.md
		git commit -qm init
	)
	echo "$work"
}

echo "Test 22: --scope all counts untracked files, which can make a spec tree code"
work=$(make_spec_only_repo)
result=$(run_prepare "$work" --scope all)
assert_json_field "$result" "mode" "spec" "the tracked spec-only tree is spec"
mkdir -p "$work/src" && echo "package main" >"$work/src/new.go"
result=$(run_prepare "$work" --scope all)
assert_json_field "$result" "mode" "code" "an untracked code file makes it code"
assert_captured "$result" "src/new.go" "the untracked code file is captured"
rm -rf "$work"

echo "Test 23: a configured spec directory whose name starts with '-' is found on disk"
# find(1) reads a leading '-' as an option, so both the detection fallback
# and capture's sweep prefix it with ./ before handing it over.
work=$(mktemp -d)
(
	cd "$work" || exit 1
	git_init_sandbox
	git checkout -q -b main
	mkdir -p -- -weird
	echo "# Spec" >-weird/x.md
	git add -- -weird/x.md
	git commit -qm init
)
result=$(cd "$work" && REVIEW_COUNCIL_SPEC_DIRS=-weird AGENTS_DIR="$AGENTS" bash "$SCRIPT" 2>/dev/null)
assert_json_field "$result" "status" "ok" "status is ok"
assert_json_field "$result" "mode" "spec" "the on-disk fallback finds the spec"
assert_captured "$result" "-weird/x.md" "the spec under the dash directory is captured"
rm -rf "$work"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
