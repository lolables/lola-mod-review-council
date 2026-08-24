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
