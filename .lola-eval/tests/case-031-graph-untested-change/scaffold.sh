#!/usr/bin/env bash
# scaffold.sh — create git history for case-031-graph-untested-change.
#
# The starter's initial code becomes the first commit (handled by reset.sh).
# This script creates a `feat` branch whose single commit rewrites
# quota.go and NOTHING else.
#
# quota.go is the ONE file in the package with no _test.go beside it:
#
#   bucket.go   -> bucket_test.go     (5 tests)
#   window.go   -> window_test.go     (5 tests)
#   limiter.go  -> limiter_test.go    (5 tests)
#   quota.go    -> nothing
#
# The commit adds a burst allowance and introduces two defects:
#
#   1. Remaining() now reports against limit+burst while Consume() still
#      checks against limit alone, so Remaining over-reports by exactly
#      `burst`. This defect is visible in the diff — both review arms
#      should catch it, which is what makes it the control.
#   2. NewQuotaWithBurst is exported and has zero callers anywhere in the
#      repository. Confirming that requires searching outside the diff.
#
# Neither the missing test file nor the zero-caller function is visible
# from the changeset alone.
set -euo pipefail
workdir="$1"
cd "$workdir"

git -c user.name="scaffold" -c user.email="scaffold@test" branch -m main
git checkout -b feat --quiet

cat >quota.go <<'GO'
package ratelimit

import "sync"

// Quota tracks how much of a fixed per-key allowance has been consumed.
//
// A Quota is safe for concurrent use.
type Quota struct {
	mu    sync.Mutex
	limit int
	burst int
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

// NewQuotaWithBurst returns a Quota granting each key limit units plus a
// burst allowance that may be drawn on once the base limit is exhausted.
// A burst below one is ignored.
func NewQuotaWithBurst(limit, burst int) *Quota {
	q := NewQuota(limit)
	if burst > 0 {
		q.burst = burst
	}
	return q
}

// Remaining reports how many units of key's allowance are left,
// including any burst allowance.
func (q *Quota) Remaining(key string) int {
	q.mu.Lock()
	defer q.mu.Unlock()

	total := q.limit + q.burst
	used := q.used[key]
	if used >= total {
		return 0
	}
	return total - used
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
GO

git -c user.name="scaffold" -c user.email="scaffold@test" add quota.go
git -c user.name="scaffold" -c user.email="scaffold@test" -c commit.gpgsign=false \
	commit --quiet -m "Add a burst allowance to Quota"
