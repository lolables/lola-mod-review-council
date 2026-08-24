package ratelimit

import (
	"sync"
	"time"
)

// Bucket is a token bucket that refills at a fixed rate.
//
// A Bucket is safe for concurrent use.
type Bucket struct {
	mu       sync.Mutex
	capacity int
	tokens   int
	interval time.Duration
	last     time.Time
	now      func() time.Time
}

// NewBucket returns a full Bucket holding capacity tokens, gaining one
// token every interval. A capacity below one is clamped to one, and a
// non-positive interval is clamped to one second.
func NewBucket(capacity int, interval time.Duration) *Bucket {
	if capacity < 1 {
		capacity = 1
	}
	if interval <= 0 {
		interval = time.Second
	}
	return &Bucket{
		capacity: capacity,
		tokens:   capacity,
		interval: interval,
		last:     time.Now(),
		now:      time.Now,
	}
}

// refill adds any tokens earned since the last call. The caller holds mu.
func (b *Bucket) refill() {
	now := b.now()
	elapsed := now.Sub(b.last)
	if elapsed < b.interval {
		return
	}

	earned := int(elapsed / b.interval)
	b.tokens += earned
	if b.tokens > b.capacity {
		b.tokens = b.capacity
	}
	b.last = b.last.Add(time.Duration(earned) * b.interval)
}

// Take removes one token, reporting whether one was available.
func (b *Bucket) Take() bool {
	b.mu.Lock()
	defer b.mu.Unlock()

	b.refill()
	if b.tokens <= 0 {
		return false
	}
	b.tokens--
	return true
}

// Tokens reports the number of tokens currently available.
func (b *Bucket) Tokens() int {
	b.mu.Lock()
	defer b.mu.Unlock()

	b.refill()
	return b.tokens
}
