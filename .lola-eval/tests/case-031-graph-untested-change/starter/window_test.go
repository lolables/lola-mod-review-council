package ratelimit

import (
	"testing"
	"time"
)

func TestNewWindowClampsSize(t *testing.T) {
	w := NewWindow(0)
	if w.size != time.Second {
		t.Errorf("size = %v, want 1s", w.size)
	}
}

func TestWindowCountsRecordedEvents(t *testing.T) {
	w := NewWindow(time.Minute)
	now := time.Unix(0, 0)
	w.now = func() time.Time { return now }

	w.Record()
	w.Record()
	w.Record()

	if got := w.Count(); got != 3 {
		t.Errorf("Count() = %d, want 3", got)
	}
}

func TestWindowEvictsExpiredEvents(t *testing.T) {
	w := NewWindow(10 * time.Second)
	now := time.Unix(0, 0)
	w.now = func() time.Time { return now }

	w.Record()
	w.Record()

	now = now.Add(11 * time.Second)
	if got := w.Count(); got != 0 {
		t.Errorf("Count() after the window passed = %d, want 0", got)
	}
}

func TestWindowKeepsPartiallyExpiredEvents(t *testing.T) {
	w := NewWindow(10 * time.Second)
	now := time.Unix(0, 0)
	w.now = func() time.Time { return now }

	w.Record()
	now = now.Add(6 * time.Second)
	w.Record()

	now = now.Add(5 * time.Second)
	if got := w.Count(); got != 1 {
		t.Errorf("Count() = %d, want 1 (only the older event expired)", got)
	}
}

func TestWindowEmptyCount(t *testing.T) {
	w := NewWindow(time.Second)
	if got := w.Count(); got != 0 {
		t.Errorf("Count() on a fresh window = %d, want 0", got)
	}
}
