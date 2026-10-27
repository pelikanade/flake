package feed

import (
	"context"
	"sync"
	"time"
)

// TokenSource fetches magpie's token usage.
type TokenSource interface {
	Usage(ctx context.Context) (Usage, error)
}

// UptimeSource fetches gatus' monitor statuses.
type UptimeSource interface {
	Uptime(ctx context.Context) (Uptime, error)
}

// ProbeSource fetches host probes from Prometheus.
type ProbeSource interface {
	Probes(ctx context.Context) (Probes, error)
}

// RevisionSource fetches the published flake's current main revision.
type RevisionSource interface {
	Revision(ctx context.Context) (string, error)
}

// Config holds the feed's day zone and how long a fetched value stays fresh.
type Config struct {
	Location *time.Location // day zone for the feed; required
	TTL      time.Duration  // how long a fetched value is fresh (FEED_TTL); required
}

// Sources are the upstreams behind each feed section. A nil source leaves that
// section nil; a nil Revision leaves every UpToDate unknown.
type Sources struct {
	Tokens   TokenSource
	Uptime   UptimeSource
	Probes   ProbeSource
	Revision RevisionSource
}

const (
	upstreamTimeout = 3 * time.Second  // per magpie request timeout
	statusTimeout   = 5 * time.Second  // per gatus/prometheus fetch timeout
	revisionTTL     = 5 * time.Minute  // upstream main moves at most daily; stay under GitHub's rate limit
	maxStale        = 10 * time.Minute // oldest last-good value served on error
)

// Service builds Feed snapshots. It is safe for concurrent use.
type Service struct {
	loc      *time.Location
	tokens   *cached[Usage]
	uptime   *cached[Uptime]
	probes   *cached[Probes]
	revision *cached[string]
}

// New wires the service. cfg.Location must be set. A nil source leaves its
// section nil in every snapshot; a nil Revision leaves UpToDate nil.
func New(cfg Config, src Sources) *Service {
	s := &Service{loc: cfg.Location}

	var fetchTokens func(context.Context) (Usage, error)
	if src.Tokens != nil {
		fetchTokens = src.Tokens.Usage
	}
	s.tokens = &cached[Usage]{name: "magpie", fetch: fetchTokens, now: time.Now,
		ttl: cfg.TTL, timeout: upstreamTimeout, maxStale: maxStale}

	var fetchUptime func(context.Context) (Uptime, error)
	if src.Uptime != nil {
		fetchUptime = src.Uptime.Uptime
	}
	s.uptime = &cached[Uptime]{name: "gatus", fetch: fetchUptime, now: time.Now,
		ttl: cfg.TTL, timeout: statusTimeout, maxStale: maxStale}

	var fetchProbes func(context.Context) (Probes, error)
	if src.Probes != nil {
		fetchProbes = src.Probes.Probes
	}
	s.probes = &cached[Probes]{name: "prometheus", fetch: fetchProbes, now: time.Now,
		ttl: cfg.TTL, timeout: statusTimeout, maxStale: maxStale}

	var fetchRevision func(context.Context) (string, error)
	if src.Revision != nil {
		fetchRevision = src.Revision.Revision
	}
	s.revision = &cached[string]{name: "github", fetch: fetchRevision, now: time.Now,
		ttl: revisionTTL, timeout: statusTimeout, maxStale: maxStale}
	return s
}

// Feed returns the current snapshot. Each section is nil while its upstream is
// unconfigured, unreachable with no last-good value within maxStale, or empty.
func (s *Service) Feed() Feed {
	now := time.Now()
	f := Feed{
		GeneratedAt: now.In(s.loc).Format(time.RFC3339),
		TZ:          s.loc.String(),
	}

	// Each cache serializes its own upstream, but the four are independent;
	// fetching them together keeps a cold page at the slowest timeout instead
	// of the sum of all four.
	var (
		wg           sync.WaitGroup
		usage        Usage
		haveUsage    bool
		up           Uptime
		haveUptime   bool
		probes       Probes
		haveProbes   bool
		revision     string
		haveRevision bool
		freshRev     bool
	)
	wg.Add(4)
	go func() {
		defer wg.Done()
		usage, haveUsage, _ = s.tokens.get()
	}()
	go func() {
		defer wg.Done()
		up, haveUptime, _ = s.uptime.get()
	}()
	go func() {
		defer wg.Done()
		probes, haveProbes, _ = s.probes.get()
	}()
	go func() {
		defer wg.Done()
		revision, haveRevision, freshRev = s.revision.get()
	}()
	wg.Wait()

	if haveUsage && (len(usage.Hours) > 0 || len(usage.Days) > 0) {
		t := aggregate(usage, now, s.loc)
		f.Tokens = &t
	}
	if haveUptime && len(up.Endpoints) > 0 {
		if f.Status == nil {
			f.Status = &Status{}
		}
		f.Status.Uptime = &up
	}
	if haveProbes && len(probes.Systems) > 0 {
		// Probe values are cached and shared between snapshots. Copy the slice
		// before attaching the comparison so concurrent Feed calls never write
		// through the cache.
		systems := make([]Probe, len(probes.Systems))
		copy(systems, probes.Systems)
		compare := haveRevision && freshRev && revision != ""
		for i := range systems {
			p := &systems[i]
			p.UpToDate = nil
			if !compare || p.Revision == "" || p.Revision == "unknown" {
				continue
			}
			upToDate := p.Revision == revision
			p.UpToDate = &upToDate
		}
		probes.Systems = systems
		if f.Status == nil {
			f.Status = &Status{}
		}
		f.Status.Probes = &probes
	}
	return f
}
