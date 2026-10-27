package feed

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Gatus reads a gatus instance's status API:
//
//	GET <base>/api/v1/endpoints/statuses            -> every monitor and its last result
//	GET <base>/api/v1/endpoints/<key>/uptimes/24h   -> uptime percentage as text
//	GET <base>/api/v1/endpoints/<key>/uptimes/7d
//
// The routes are unprotected unless the instance configures security, which the
// nvirellia-im deployment does not. Uptime calls are best effort: a failed window
// leaves that percentage nil while the monitor itself still renders.
type Gatus struct {
	baseURL string
	client  *http.Client
}

// NewGatus returns a client for baseURL.
func NewGatus(baseURL string) (*Gatus, error) {
	if _, err := url.Parse(baseURL); err != nil {
		return nil, fmt.Errorf("GATUS_URL: %w", err)
	}
	return &Gatus{baseURL: strings.TrimRight(baseURL, "/"), client: &http.Client{}}, nil
}

// Uptime implements UptimeSource.
func (g *Gatus) Uptime(ctx context.Context) (Uptime, error) {
	// Ask for the history Gatus' own cards draw: one segment per result.
	q := url.Values{"page": {"1"}, "pageSize": {"50"}}
	var statuses []gatusStatus
	if err := getJSON(ctx, g.client, g.endpoint("/api/v1/endpoints/statuses", q), "gatus", &statuses); err != nil {
		return Uptime{}, err
	}

	endpoints := make([]Endpoint, len(statuses))
	var wg sync.WaitGroup
	sem := make(chan struct{}, 8) // the instance is local; cap bursty fan-out anyway
	for i, s := range statuses {
		endpoints[i] = Endpoint{Name: s.Name, Group: s.Group, Key: s.Key}
		if n := len(s.Results); n > 0 {
			last := s.Results[n-1]
			endpoints[i].Known = true
			endpoints[i].Up = last.Success
			endpoints[i].Status = last.Status
			endpoints[i].LatencyMS = last.Duration / int64(time.Millisecond)
			if !last.Timestamp.IsZero() {
				endpoints[i].CheckedAt = last.Timestamp.UTC().Format(time.RFC3339)
			}
			results := s.Results
			if len(results) > 50 {
				results = results[len(results)-50:]
			}
			endpoints[i].Results = make([]Check, len(results))
			for j, r := range results {
				c := Check{Up: r.Success, Status: r.Status, LatencyMS: r.Duration / int64(time.Millisecond)}
				if !r.Timestamp.IsZero() {
					c.At = r.Timestamp.UTC().Format(time.RFC3339)
				}
				endpoints[i].Results[j] = c
			}
		}
		wg.Add(2)
		go func(i int, key string) {
			defer wg.Done()
			sem <- struct{}{}
			defer func() { <-sem }()
			endpoints[i].Uptime24h = g.uptime(ctx, key, "24h")
		}(i, s.Key)
		go func(i int, key string) {
			defer wg.Done()
			sem <- struct{}{}
			defer func() { <-sem }()
			endpoints[i].Uptime7d = g.uptime(ctx, key, "7d")
		}(i, s.Key)
	}
	wg.Wait()
	sort.Slice(endpoints, func(i, j int) bool {
		if endpoints[i].Group != endpoints[j].Group {
			return endpoints[i].Group < endpoints[j].Group
		}
		return endpoints[i].Name < endpoints[j].Name
	})
	return Uptime{Endpoints: endpoints}, nil
}

// gatusStatus is the part of /api/v1/endpoints/statuses the feed reads.
type gatusStatus struct {
	Name    string `json:"name"`
	Group   string `json:"group"`
	Key     string `json:"key"`
	Results []struct {
		Status    int       `json:"status"`
		Duration  int64     `json:"duration"` // nanoseconds
		Success   bool      `json:"success"`
		Timestamp time.Time `json:"timestamp"`
	} `json:"results"`
}

// uptime fetches one window and converts gatus' 0..1 fraction to a percentage.
// A missing endpoint or malformed body yields nil, never an error for the whole
// status fetch.
func (g *Gatus) uptime(ctx context.Context, key, window string) *float64 {
	target := g.endpoint("/api/v1/endpoints/"+url.PathEscape(key)+"/uptimes/"+window, nil)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, target, nil)
	if err != nil {
		return nil
	}
	resp, err := g.client.Do(req)
	if err != nil {
		return nil
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		drainBody(resp)
		return nil
	}
	b, err := io.ReadAll(io.LimitReader(resp.Body, 64))
	if err != nil {
		return nil
	}
	v, err := strconv.ParseFloat(strings.TrimSpace(string(b)), 64)
	if err != nil || v < 0 || v > 1 {
		return nil
	}
	pct := v * 100
	return &pct
}

// endpoint joins a path and query onto the base URL.
func (g *Gatus) endpoint(path string, q url.Values) string {
	return joinURL(g.baseURL, path, q)
}
