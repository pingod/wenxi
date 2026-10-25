package http

import (
	"context"
	"sync"
	"time"
)

type adaptiveHost struct {
	active, users int
	busyUntil     time.Time
	changed       chan struct{}
}

type adaptiveHostLimiter struct {
	sync.Mutex
	entries         map[string]*adaptiveHost
	busyConnections int
	busyPeriod      time.Duration
}

func newAdaptiveHostLimiter(connections int, period time.Duration) *adaptiveHostLimiter {
	return &adaptiveHostLimiter{
		entries: make(map[string]*adaptiveHost), busyConnections: connections, busyPeriod: period,
	}
}

func (limiter *adaptiveHostLimiter) hostLocked(host string) *adaptiveHost {
	now := time.Now()
	for key, entry := range limiter.entries {
		if entry.users == 0 && !entry.busyUntil.After(now) {
			delete(limiter.entries, key)
		}
	}
	entry := limiter.entries[host]
	if entry == nil {
		entry = &adaptiveHost{changed: make(chan struct{})}
		limiter.entries[host] = entry
	}
	return entry
}

// Healthy nodes retain the user's requested parallelism. An overloaded node
// gets a smaller shared window for retries and subsequent files on that host.
// In-flight requests keep their slots, so a retry cannot pile onto that burst.
func (limiter *adaptiveHostLimiter) limit(host string) {
	limiter.Lock()
	defer limiter.Unlock()
	limiter.hostLocked(host).busyUntil = time.Now().Add(limiter.busyPeriod)
}

func (limiter *adaptiveHostLimiter) acquire(ctx context.Context, host string) (func(), error) {
	limiter.Lock()
	entry := limiter.hostLocked(host)
	entry.users++
	for {
		if err := ctx.Err(); err != nil {
			entry.users--
			if entry.users == 0 && !entry.busyUntil.After(time.Now()) {
				delete(limiter.entries, host)
			}
			limiter.Unlock()
			return nil, err
		}
		limit := 512
		if entry.busyUntil.After(time.Now()) {
			limit = limiter.busyConnections
		}
		if entry.active < limit {
			entry.active++
			limiter.Unlock()
			break
		}
		changed := entry.changed
		var timer *time.Timer
		var expired <-chan time.Time
		if remaining := time.Until(entry.busyUntil); remaining > 0 {
			timer = time.NewTimer(remaining)
			expired = timer.C
		}
		limiter.Unlock()
		select {
		case <-ctx.Done():
		case <-changed:
		case <-expired:
		}
		if timer != nil {
			timer.Stop()
		}
		limiter.Lock()
	}
	freeHost := func() {
		limiter.Lock()
		entry.active--
		entry.users--
		close(entry.changed)
		entry.changed = make(chan struct{})
		if entry.users == 0 && !entry.busyUntil.After(time.Now()) {
			delete(limiter.entries, host)
		}
		limiter.Unlock()
	}
	freeBudget, err := acquireConnection(ctx, host)
	if err != nil {
		freeHost()
		return nil, err
	}
	return func() {
		freeBudget()
		freeHost()
	}, nil
}
