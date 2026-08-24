package ratelimit

import (
	"testing"
	"time"
)

func TestLimiterAllowsWithinQuota(t *testing.T) {
	l := NewLimiter(3, 10, time.Minute)

	for i := range 3 {
		if !l.Allow("alice") {
			t.Fatalf("Allow() #%d = false, want true", i+1)
		}
	}
}

func TestLimiterRefusesBeyondQuota(t *testing.T) {
	l := NewLimiter(2, 10, time.Minute)

	l.Allow("bob")
	l.Allow("bob")

	if l.Allow("bob") {
		t.Error("Allow() past the quota = true, want false")
	}
}

func TestLimiterQuotaIsPerKey(t *testing.T) {
	l := NewLimiter(1, 10, time.Minute)

	if !l.Allow("carol") {
		t.Fatal("Allow(carol) = false, want true")
	}
	if !l.Allow("dave") {
		t.Error("Allow(dave) = false, want true — quota should be per key")
	}
}

func TestLimiterRefusesWhenBucketEmpty(t *testing.T) {
	l := NewLimiter(100, 2, time.Minute)
	l.bucket.now = func() time.Time { return time.Unix(0, 0) }
	l.bucket.last = time.Unix(0, 0)

	l.Allow("erin")
	l.Allow("erin")

	if l.Allow("erin") {
		t.Error("Allow() with an empty bucket = true, want false")
	}
}

func TestLimiterRecentCountsAllowedRequests(t *testing.T) {
	l := NewLimiter(5, 10, time.Minute)

	l.Allow("frank")
	l.Allow("frank")

	if got := l.Recent(); got != 2 {
		t.Errorf("Recent() = %d, want 2", got)
	}
}
