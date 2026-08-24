package ratelimit

import "sync"

// Quota tracks how much of a fixed per-key allowance has been consumed.
//
// A Quota is safe for concurrent use.
type Quota struct {
	mu    sync.Mutex
	limit int
	used  map[string]int
}

// NewQuota returns a Quota granting each key limit units.
// A limit below zero is clamped to zero.
func NewQuota(limit int) *Quota {
	if limit < 0 {
		limit = 0
	}
	return &Quota{
		limit: limit,
		used:  make(map[string]int),
	}
}

// Remaining reports how many units of key's allowance are left.
func (q *Quota) Remaining(key string) int {
	q.mu.Lock()
	defer q.mu.Unlock()

	used := q.used[key]
	if used >= q.limit {
		return 0
	}
	return q.limit - used
}

// Consume takes n units from key's allowance, reporting whether it fit.
// A negative n is rejected rather than treated as a refund.
func (q *Quota) Consume(key string, n int) bool {
	if n < 0 {
		return false
	}

	q.mu.Lock()
	defer q.mu.Unlock()

	used := q.used[key]
	if used+n > q.limit {
		return false
	}
	q.used[key] = used + n
	return true
}

// Reset clears key's usage, restoring its full allowance.
func (q *Quota) Reset(key string) {
	q.mu.Lock()
	defer q.mu.Unlock()

	delete(q.used, key)
}
