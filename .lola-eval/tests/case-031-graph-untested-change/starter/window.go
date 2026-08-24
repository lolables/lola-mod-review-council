package ratelimit

import (
	"sync"
	"time"
)

// Window counts events inside a sliding time window.
//
// A Window is safe for concurrent use.
type Window struct {
	mu     sync.Mutex
	size   time.Duration
	events []time.Time
	now    func() time.Time
}

// NewWindow returns a Window covering the given size.
// A non-positive size is clamped to one second.
func NewWindow(size time.Duration) *Window {
	if size <= 0 {
		size = time.Second
	}
	return &Window{
		size: size,
		now:  time.Now,
	}
}

// evict drops events that have fallen out of the window.
// The caller holds mu.
func (w *Window) evict(now time.Time) {
	cutoff := now.Add(-w.size)
	keep := w.events[:0]
	for _, at := range w.events {
		if at.After(cutoff) {
			keep = append(keep, at)
		}
	}
	w.events = keep
}

// Record adds one event at the current time.
func (w *Window) Record() {
	w.mu.Lock()
	defer w.mu.Unlock()

	now := w.now()
	w.evict(now)
	w.events = append(w.events, now)
}

// Count reports how many events fall inside the window.
func (w *Window) Count() int {
	w.mu.Lock()
	defer w.mu.Unlock()

	w.evict(w.now())
	return len(w.events)
}
