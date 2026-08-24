package textutil

import "testing"

func TestTruncateShorterThanLimit(t *testing.T) {
	if got := Truncate("short", 10); got != "short" {
		t.Errorf("Truncate() = %q, want %q", got, "short")
	}
}

func TestTruncateExactlyAtLimit(t *testing.T) {
	if got := Truncate("exact", 5); got != "exact" {
		t.Errorf("Truncate() = %q, want %q", got, "exact")
	}
}

func TestTruncateAppendsEllipsis(t *testing.T) {
	if got := Truncate("truncate me", 5); got != "trun…" {
		t.Errorf("Truncate() = %q, want %q", got, "trun…")
	}
}

func TestTruncateCountsRunesNotBytes(t *testing.T) {
	// Five runes, ten bytes. Nothing should be removed.
	if got := Truncate("héllö", 5); got != "héllö" {
		t.Errorf("Truncate() = %q, want %q", got, "héllö")
	}
	if got := Truncate("héllö", 3); got != "hé…" {
		t.Errorf("Truncate() = %q, want %q", got, "hé…")
	}
}

func TestTruncateLimitBoundaries(t *testing.T) {
	if got := Truncate("anything", 0); got != "" {
		t.Errorf("Truncate(limit 0) = %q, want empty", got)
	}
	if got := Truncate("anything", 1); got != "…" {
		t.Errorf("Truncate(limit 1) = %q, want ellipsis", got)
	}
}
