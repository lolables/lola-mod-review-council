package ratelimit

import "time"

// Limiter combines a per-key quota with a shared token bucket and a
// sliding-window counter used for reporting.
type Limiter struct {
	quota  *Quota
	bucket *Bucket
	window *Window
}

// NewLimiter builds a Limiter from the three primitives in this package.
func NewLimiter(perKeyLimit, burstCapacity int, window time.Duration) *Limiter {
	return &Limiter{
		quota:  NewQuota(perKeyLimit),
		bucket: NewBucket(burstCapacity, time.Second),
		window: NewWindow(window),
	}
}

// Allow reports whether one request from key may proceed. A request must
// satisfy the key's quota and the shared bucket; every allowed request is
// recorded in the window.
func (l *Limiter) Allow(key string) bool {
	if !l.quota.Consume(key, 1) {
		return false
	}
	if !l.bucket.Take() {
		return false
	}

	l.window.Record()
	return true
}

// Recent reports how many requests were allowed inside the window.
func (l *Limiter) Recent() int {
	return l.window.Count()
}

// Budget reports how much of key's quota is left.
func (l *Limiter) Budget(key string) int {
	return l.quota.Remaining(key)
}
