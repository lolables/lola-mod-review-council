package textutil

import (
	"slices"
	"testing"
)

func TestWrapBreaksAtWidth(t *testing.T) {
	got := Wrap("the quick brown fox jumps", 10)
	want := []string{"the quick", "brown fox", "jumps"}
	if !slices.Equal(got, want) {
		t.Errorf("Wrap() = %q, want %q", got, want)
	}
}

func TestWrapKeepsLongWordsIntact(t *testing.T) {
	got := Wrap("a supercalifragilistic b", 5)
	want := []string{"a", "supercalifragilistic", "b"}
	if !slices.Equal(got, want) {
		t.Errorf("Wrap() = %q, want %q", got, want)
	}
}

func TestWrapNormalizesInputSpacing(t *testing.T) {
	got := Wrap("  one   two  ", 20)
	want := []string{"one two"}
	if !slices.Equal(got, want) {
		t.Errorf("Wrap() = %q, want %q", got, want)
	}
}

func TestWrapEmptyInput(t *testing.T) {
	if got := Wrap("   ", 10); got != nil {
		t.Errorf("Wrap(blank) = %q, want nil", got)
	}
}

func TestWrapClampsWidth(t *testing.T) {
	got := Wrap("a b", 0)
	want := []string{"a", "b"}
	if !slices.Equal(got, want) {
		t.Errorf("Wrap() = %q, want %q", got, want)
	}
}
