package ratelimit

import (
	"testing"
	"time"
)

// fixedClock returns a clock the test drives by hand, so the bucket's
// refill behaviour is asserted without sleeping.
func fixedClock(start time.Time) (func() time.Time, func(time.Duration)) {
	now := start
	return func() time.Time { return now }, func(d time.Duration) { now = now.Add(d) }
}

func TestNewBucketClampsArguments(t *testing.T) {
	b := NewBucket(0, 0)
	if b.capacity != 1 {
		t.Errorf("capacity = %d, want 1", b.capacity)
	}
	if b.interval != time.Second {
		t.Errorf("interval = %v, want 1s", b.interval)
	}
}

func TestBucketStartsFull(t *testing.T) {
	b := NewBucket(3, time.Second)
	if got := b.Tokens(); got != 3 {
		t.Errorf("Tokens() = %d, want 3", got)
	}
}

func TestBucketTakeDrainsThenRefuses(t *testing.T) {
	b := NewBucket(2, time.Second)
	clock, _ := fixedClock(time.Unix(0, 0))
	b.now = clock
	b.last = time.Unix(0, 0)

	for i := range 2 {
		if !b.Take() {
			t.Fatalf("Take() #%d = false, want true", i+1)
		}
	}
	if b.Take() {
		t.Error("Take() on an empty bucket = true, want false")
	}
}

func TestBucketRefillsOverTime(t *testing.T) {
	b := NewBucket(3, time.Second)
	clock, advance := fixedClock(time.Unix(0, 0))
	b.now = clock
	b.last = time.Unix(0, 0)

	for range 3 {
		b.Take()
	}
	if got := b.Tokens(); got != 0 {
		t.Fatalf("Tokens() after draining = %d, want 0", got)
	}

	advance(2 * time.Second)
	if got := b.Tokens(); got != 2 {
		t.Errorf("Tokens() after 2s = %d, want 2", got)
	}
}

func TestBucketRefillCapsAtCapacity(t *testing.T) {
	b := NewBucket(2, time.Second)
	clock, advance := fixedClock(time.Unix(0, 0))
	b.now = clock
	b.last = time.Unix(0, 0)

	b.Take()
	advance(time.Hour)
	if got := b.Tokens(); got != 2 {
		t.Errorf("Tokens() after an hour = %d, want 2 (capacity)", got)
	}
}
