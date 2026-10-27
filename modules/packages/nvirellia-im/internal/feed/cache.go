package feed

import (
	"context"
	"log"
	"sync"
	"time"
)

// cached holds one upstream's last good value. At most one fetch runs at a time
// (the mutex is held across it), and a failed fetch is not retried until ttl has passed.
type cached[T any] struct {
	name     string
	fetch    func(context.Context) (T, error) // nil when the upstream is unconfigured
	now      func() time.Time
	ttl      time.Duration
	timeout  time.Duration
	maxStale time.Duration

	mu        sync.Mutex
	val       T
	have      bool
	fetchedAt time.Time
	retryAt   time.Time
}

// get returns the value to serve, whether any value exists, and whether it is
// fresh (fetched successfully within ttl). A stale value is served only while it
// is younger than maxStale; otherwise get reports no value.
func (c *cached[T]) get() (val T, have, fresh bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.fetch == nil {
		return val, false, false
	}
	now := c.now()
	if c.have && now.Sub(c.fetchedAt) < c.ttl {
		return c.val, true, true
	}
	if now.Before(c.retryAt) {
		return c.stale(now)
	}
	// Detached from the request context: one caller's cancellation must not poison the cache.
	ctx, cancel := context.WithTimeout(context.Background(), c.timeout)
	defer cancel()
	v, err := c.fetch(ctx)
	if err != nil {
		c.retryAt = now.Add(c.ttl)
		log.Printf("feed: %s unavailable, serving fallback: %v", c.name, err)
		return c.stale(now)
	}
	c.val, c.have, c.fetchedAt = v, true, now
	return v, true, true
}

func (c *cached[T]) stale(now time.Time) (val T, have, fresh bool) {
	if c.have && now.Sub(c.fetchedAt) < c.maxStale {
		return c.val, true, false
	}
	return val, false, false
}
