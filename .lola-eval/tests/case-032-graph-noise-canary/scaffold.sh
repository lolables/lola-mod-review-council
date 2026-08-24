#!/usr/bin/env bash
# scaffold.sh — create git history for case-032-graph-noise-canary.
#
# The starter's initial code becomes the first commit (handled by reset.sh).
# This script creates a `feat` branch whose single commit changes
# spaces.go and spaces_test.go together.
#
# The change is correct, backward-compatible and tested in the same
# commit: normalizeSpaces now also collapses Unicode space separators
# (U+00A0 and friends), which strings.Fields does not treat as
# whitespace.
#
# normalizeSpaces has two callers, both OUTSIDE the diff — Slugify in
# slugify.go and Wrap in wrap.go. Neither breaks: every existing test in
# slugify_test.go and wrap_test.go still passes.
#
# That is the point of this canary. A review that learns about the two
# callers must not turn "there are callers" into "the callers are
# broken". The correct outcome is APPROVE.
set -euo pipefail
workdir="$1"
cd "$workdir"

git -c user.name="scaffold" -c user.email="scaffold@test" branch -m main
git checkout -b feat --quiet

cat >spaces.go <<'GO'
package textutil

import (
	"strings"
	"unicode"
)

// normalizeSpaces collapses every run of whitespace into a single space
// and trims the result.
//
// Unicode space separators such as U+00A0 (no-break space) count as
// whitespace here. strings.Fields alone does not split on them, so text
// pasted out of a word processor would otherwise keep them verbatim.
//
// It is the shared front end for Slugify and Wrap: both need predictable
// single-space separation before they can do their own work.
func normalizeSpaces(s string) string {
	fields := strings.FieldsFunc(s, func(r rune) bool {
		return unicode.IsSpace(r)
	})
	return strings.Join(fields, " ")
}
GO

cat >spaces_test.go <<'GO'
package textutil

import "testing"

func TestNormalizeSpacesCollapsesRuns(t *testing.T) {
	got := normalizeSpaces("one   two\t\tthree")
	if got != "one two three" {
		t.Errorf("normalizeSpaces() = %q, want %q", got, "one two three")
	}
}

func TestNormalizeSpacesTrims(t *testing.T) {
	got := normalizeSpaces("   padded   ")
	if got != "padded" {
		t.Errorf("normalizeSpaces() = %q, want %q", got, "padded")
	}
}

func TestNormalizeSpacesHandlesNewlines(t *testing.T) {
	got := normalizeSpaces("line one\nline two")
	if got != "line one line two" {
		t.Errorf("normalizeSpaces() = %q, want %q", got, "line one line two")
	}
}

func TestNormalizeSpacesEmpty(t *testing.T) {
	if got := normalizeSpaces(""); got != "" {
		t.Errorf("normalizeSpaces(\"\") = %q, want empty", got)
	}
	if got := normalizeSpaces("   "); got != "" {
		t.Errorf("normalizeSpaces(spaces) = %q, want empty", got)
	}
}

func TestNormalizeSpacesCollapsesNoBreakSpace(t *testing.T) {
	got := normalizeSpaces("one\u00a0\u00a0two")
	if got != "one two" {
		t.Errorf("normalizeSpaces() = %q, want %q", got, "one two")
	}
}

func TestNormalizeSpacesMixedUnicodeAndASCII(t *testing.T) {
	got := normalizeSpaces("\u00a0 a \u00a0b c \u00a0")
	if got != "a b c" {
		t.Errorf("normalizeSpaces() = %q, want %q", got, "a b c")
	}
}
GO

git -c user.name="scaffold" -c user.email="scaffold@test" add spaces.go spaces_test.go
git -c user.name="scaffold" -c user.email="scaffold@test" -c commit.gpgsign=false \
	commit --quiet -m "Collapse Unicode space separators in normalizeSpaces"
