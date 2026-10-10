#!/usr/bin/env bash
# lib/symlinks.sh judges a symlink by its path and target text alone. These pin
# what "leaves the repository" means, including through a chain of links.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB="$SCRIPT_DIR/../skills/review-council/scripts/lib/symlinks.sh"
# shellcheck source=module/tests/helpers.sh
source "$SCRIPT_DIR/helpers.sh"
# shellcheck source=module/skills/review-council/scripts/lib/symlinks.sh
source "$LIB"

judge() { # expected link target label
	local got=inside
	# shellcheck disable=SC2310 # rc_symlink_escapes is a predicate.
	rc_symlink_escapes "$2" "$3" && got=escapes
	assert_equals "$got" "$1" "$4"
}

echo "Test 1: single links (RC-076)"
judge escapes leak /etc/passwd "an absolute target escapes"
judge escapes leak ../x "climbing above the root escapes"
judge inside docs/l ../x "climbing to the root stays inside"
judge escapes docs/l ../../x "climbing past the root from a subdirectory escapes"
judge escapes l .git/config "a target in .git escapes"
judge escapes l docs/../.git/hooks "a target reaching .git through .. escapes"
judge escapes l .GIT/config ".git is matched without regard to case"
judge inside l a/./b//c "redundant separators and dots stay inside"
# shellcheck disable=SC2088 # the unexpanded ~ is the case under test.
judge inside l "~/secrets" "~ is a literal directory name"
judge inside l "" "an empty target names the link's own directory"
judge escapes l $'a\nb' "a target holding a newline is refused"

echo "Test 2: chains through other links (RC-076)"
rc_symlink_map_reset
rc_symlink_map_add a /etc
judge escapes b a/passwd "a link through an escaping link escapes"
rc_symlink_map_reset
rc_symlink_map_add a b
rc_symlink_map_add b a
judge escapes a b "a cycle is reported as escaping"
rc_symlink_map_reset
rc_symlink_map_add d sub
judge escapes e d/../.. ".. after a link resolves from the link's target"
judge inside e d/.. ".. after a link to a subdirectory returns to the root"
rc_symlink_map_reset
rc_symlink_map_add a docs
judge inside c a/readme "a link through an inside link stays inside"
rc_symlink_map_reset
rc_symlink_map_add "@" /etc
judge escapes x "@/passwd" "a link named @ is a map key like any other"
rc_symlink_map_reset
judge inside x "@/passwd" "an emptied map follows nothing"

echo "Test 3: a target thousands of components long is judged in well under a second"
# The walk once rebuilt its position in a subshell per component: 3,000
# components took 5.5 s, so a pull request could stall preparation at will.
# Fork-free it takes 0.2 s; the bound leaves room for a slow runner. LC_ALL=C
# as rc-check-symlinks.sh runs it.
long=$(printf 'a/%.0s' {1..3000})$(printf '../%.0s' {1..3000})
got=$(
	export LC_ALL=C
	start=$SECONDS
	verdict=inside
	# shellcheck disable=SC2310 # rc_symlink_escapes is a predicate.
	if rc_symlink_escapes l "${long}../x"; then
		verdict=escapes
	fi
	echo "$verdict $((SECONDS - start))"
)
assert_equals "${got% *}" escapes "one .. past the long climb still escapes"
if ((${got#* } < 3)); then
	echo "  PASS: judged in ${got#* } s"
	PASS=$((PASS + 1))
else
	echo "  FAIL: judging took ${got#* } s"
	FAIL=$((FAIL + 1))
fi

echo "Test 4: a link with an unknown target escapes wherever a chain reaches it (RC-078)"
rc_symlink_map_reset
rc_symlink_map_add_unknown n
judge escapes y n/x "a chain through the unknown link escapes"
judge escapes y n/.. "climbing straight back out of it still escapes"
judge inside y nx/.. "a sibling name is not the unknown link"

echo "Test 5: the walk names the first changed link it follows (RC-078)"
followed_by() { # path target
	# shellcheck disable=SC2310 # rc_symlink_escapes is a predicate.
	rc_symlink_escapes "$1" "$2" || true
	printf '%s' "$_rc_symlink_followed_changed"
}
rc_symlink_map_reset
rc_symlink_map_add b sub
rc_symlink_map_add c sub
rc_symlink_map_add d b
rc_symlink_mark_changed b
got=$(followed_by a b/../..)
assert_equals "$got" "b" "a walk through a changed link names it"
got=$(followed_by a d/../..)
assert_equals "$got" "b" "so does a walk reaching it through another link"
got=$(followed_by a c/../..)
assert_equals "$got" "" "a walk through an unchanged link names none"
# shellcheck disable=SC2310 # rc_symlink_escapes is a predicate.
rc_symlink_escapes a b/x || true
# shellcheck disable=SC2310 # rc_symlink_escapes is a predicate.
rc_symlink_escapes a /etc || true
assert_equals "$_rc_symlink_followed_changed" "" "each judgement starts unset"
rc_symlink_map_reset
rc_symlink_map_add b sub
got=$(followed_by a b/../..)
assert_equals "$got" "" "a reset clears the changed set"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
