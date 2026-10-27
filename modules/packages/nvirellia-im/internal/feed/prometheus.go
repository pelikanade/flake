package feed

import (
	"context"
	"fmt"
	"math"
	"net/http"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"time"
)

// ProbeHistoryWindow is how much history the Status tab draws for each host
// metric. The range queries use probeHistoryStep.
const (
	ProbeHistoryWindow = 6 * time.Hour
	probeHistoryStep   = 5 * time.Minute
)

// Prometheus reads host probes from a Prometheus instance's HTTP API. The
// scrape configuration is the source of truth: targets are node_exporter jobs
// labelled with host, and this client only queries:
//
//	up{job=<job>}                                      -> target state
//	time() - node_boot_time_seconds{job=<job>}         -> host uptime
//	100 * (1 - rate(node_cpu_seconds_total{mode="idle"}[5m])) -> CPU %
//	100 * (1 - MemAvailable / MemTotal)                -> memory %
//	100 * (1 - filesystem avail / size)                -> root disk %
//	nixos_flake_info{job=<job>}                        -> flake revision
//	nixos_system_update_time_seconds{job=<job>}        -> activation time
//
// The metric queries use /api/v1/query_range so the same pass supplies the
// current value and the sparkline history. The API is read-only and
// unauthenticated; the deployment binds it to loopback.
type Prometheus struct {
	baseURL string
	job     string
	client  *http.Client
}

// NewPrometheus returns a client for baseURL. An empty job defaults to "node".
func NewPrometheus(baseURL, job string) (*Prometheus, error) {
	if _, err := url.Parse(baseURL); err != nil {
		return nil, fmt.Errorf("PROMETHEUS_URL: %w", err)
	}
	if job == "" {
		job = "node"
	}
	return &Prometheus{
		baseURL: strings.TrimRight(baseURL, "/"),
		job:     job,
		client:  &http.Client{},
	}, nil
}

// Probes implements ProbeSource.
func (p *Prometheus) Probes(ctx context.Context) (Probes, error) {
	now := time.Now()
	start := now.Add(-ProbeHistoryWindow)

	queries := []struct {
		key    string
		expr   string
		ranged bool
	}{
		{"up", fmt.Sprintf(`up{job=%q}`, p.job), false},
		{"uptime", fmt.Sprintf(`time() - node_boot_time_seconds{job=%q}`, p.job), false},
		{"cpu", fmt.Sprintf(`100 * (1 - avg by (host, instance) (rate(node_cpu_seconds_total{job=%q,mode="idle"}[5m])))`, p.job), true},
		{"mem", fmt.Sprintf(`max by (host, instance) (100 * (1 - node_memory_MemAvailable_bytes{job=%q} / node_memory_MemTotal_bytes{job=%q}))`, p.job, p.job), true},
		{"disk", fmt.Sprintf(`max by (host, instance) (100 * (1 - node_filesystem_avail_bytes{job=%q,mountpoint="/",fstype!~"tmpfs|overlay"} / node_filesystem_size_bytes{job=%q,mountpoint="/",fstype!~"tmpfs|overlay"}))`, p.job, p.job), true},
		{"revision", fmt.Sprintf(`nixos_flake_info{job=%q}`, p.job), false},
		{"activated", fmt.Sprintf(`nixos_system_update_time_seconds{job=%q}`, p.job), false},
	}

	type queryResult struct {
		key     string
		samples []promSample
		series  []promSeries
		err     error
	}
	results := make(chan queryResult, len(queries))
	for _, q := range queries {
		go func(key, expr string, ranged bool) {
			if ranged {
				series, err := p.queryRange(ctx, expr, start, now, probeHistoryStep)
				results <- queryResult{key: key, series: series, err: err}
				return
			}
			samples, err := p.query(ctx, expr)
			results <- queryResult{key: key, samples: samples, err: err}
		}(q.key, q.expr, q.ranged)
	}

	var (
		upSamples        []promSample
		uptimeSamples    []promSample
		revisionSamples  []promSample
		activatedSamples []promSample
		cpuSeries        []promSeries
		memSeries        []promSeries
		diskSeries       []promSeries
		firstErr         error
	)
	for range queries {
		r := <-results
		if r.err != nil {
			if firstErr == nil {
				firstErr = r.err
			}
			continue
		}
		switch r.key {
		case "up":
			upSamples = r.samples
		case "uptime":
			uptimeSamples = r.samples
		case "revision":
			revisionSamples = r.samples
		case "activated":
			activatedSamples = r.samples
		case "cpu":
			cpuSeries = r.series
		case "mem":
			memSeries = r.series
		case "disk":
			diskSeries = r.series
		}
	}
	if firstErr != nil {
		return Probes{}, firstErr
	}

	type builder struct {
		probe   Probe
		updated time.Time
	}
	builders := make(map[string]*builder)
	for _, s := range upSamples {
		name := sampleHost(s.metric)
		if name == "" {
			continue
		}
		b := &builder{probe: Probe{Name: name, Status: "unknown"}}
		if s.metric["host"] != "" {
			b.probe.Host = s.metric["instance"]
		}
		switch s.value {
		case 1:
			b.probe.Status = "up"
		case 0:
			b.probe.Status = "down"
		}
		if !s.at.IsZero() {
			b.probe.Updated = s.at.UTC().Format(time.RFC3339)
			b.updated = s.at
		}
		builders[name] = b
	}

	for _, s := range uptimeSamples {
		b := builders[sampleHost(s.metric)]
		if b == nil || b.probe.Status != "up" {
			continue
		}
		if v, ok := nonNegative(s.value); ok {
			sec := uint64(math.Round(v))
			b.probe.UptimeSeconds = &sec
			if s.at.After(b.updated) {
				b.updated = s.at
				b.probe.Updated = s.at.UTC().Format(time.RFC3339)
			}
		}
	}

	// The textfile metrics describe the running system, not a live resource
	// sample, but they go stale the same way when the target stops answering.
	// Suppress them for a down target like the resource metrics below.
	for _, s := range revisionSamples {
		b := builders[sampleHost(s.metric)]
		if b == nil || b.probe.Status != "up" {
			continue
		}
		if rev := strings.TrimSpace(s.metric["revision"]); rev != "" {
			b.probe.Revision = rev
		}
	}

	for _, s := range activatedSamples {
		b := builders[sampleHost(s.metric)]
		if b == nil || b.probe.Status != "up" {
			continue
		}
		if v, ok := nonNegative(s.value); ok {
			at := time.Unix(int64(math.Round(v)), 0).UTC().Format(time.RFC3339)
			b.probe.UpdatedAt = at
		}
	}

	for _, m := range []struct {
		key    string
		series []promSeries
	}{
		{"cpu", cpuSeries},
		{"mem", memSeries},
		{"disk", diskSeries},
	} {
		for _, s := range m.series {
			b := builders[sampleHost(s.metric)]
			if b == nil || b.probe.Status != "up" || len(s.points) == 0 {
				continue // metrics for a down target are stale; leave them blank
			}
			history := make([]float64, len(s.points))
			for i, pt := range s.points {
				history[i] = clampPercent(pt.value)
			}
			current := history[len(history)-1]
			switch m.key {
			case "cpu":
				b.probe.CPU, b.probe.CPUHistory = &current, history
			case "mem":
				b.probe.Mem, b.probe.MemHistory = &current, history
			case "disk":
				b.probe.Disk, b.probe.DiskHistory = &current, history
			}
			if last := s.points[len(s.points)-1].at; last.After(b.updated) {
				b.updated = last
				b.probe.Updated = last.UTC().Format(time.RFC3339)
			}
		}
	}

	out := make([]Probe, 0, len(builders))
	for _, b := range builders {
		out = append(out, b.probe)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return Probes{Systems: out}, nil
}

// promResponse is the part of /api/v1/query the feed reads.
type promResponse struct {
	Status string `json:"status"`
	Error  string `json:"error,omitempty"`
	Data   struct {
		ResultType string `json:"resultType"`
		Result     []struct {
			Metric map[string]string `json:"metric"`
			Value  [2]any            `json:"value"`
		} `json:"result"`
	} `json:"data"`
}

// promRangeResponse is the part of /api/v1/query_range the feed reads.
type promRangeResponse struct {
	Status string `json:"status"`
	Error  string `json:"error,omitempty"`
	Data   struct {
		ResultType string `json:"resultType"`
		Result     []struct {
			Metric map[string]string `json:"metric"`
			Values [][2]any          `json:"values"`
		} `json:"result"`
	} `json:"data"`
}

// promSample is one instant vector element, with its timestamp decoded.
type promSample struct {
	metric map[string]string
	value  float64
	at     time.Time
}

// promSeries is one range vector element.
type promSeries struct {
	metric map[string]string
	points []promPoint
}

type promPoint struct {
	at    time.Time
	value float64
}

// query runs one PromQL expression and returns its instant vector.
func (p *Prometheus) query(ctx context.Context, expr string) ([]promSample, error) {
	var body promResponse
	target := joinURL(p.baseURL, "/api/v1/query", url.Values{"query": {expr}})
	if err := getJSON(ctx, p.client, target, "prometheus", &body); err != nil {
		return nil, err
	}
	if body.Status != "success" {
		return nil, promStatusError(body.Status, body.Error)
	}
	if body.Data.ResultType != "vector" {
		return nil, fmt.Errorf("prometheus: result type %q", body.Data.ResultType)
	}
	out := make([]promSample, 0, len(body.Data.Result))
	for _, r := range body.Data.Result {
		ts, ok := r.Value[0].(float64)
		text, okText := r.Value[1].(string)
		if !ok || !okText {
			continue
		}
		v, err := strconv.ParseFloat(text, 64)
		if err != nil {
			continue
		}
		out = append(out, promSample{metric: r.Metric, value: v, at: promTime(ts)})
	}
	return out, nil
}

// queryRange runs one PromQL expression over [start, end] at step.
func (p *Prometheus) queryRange(ctx context.Context, expr string, start, end time.Time, step time.Duration) ([]promSeries, error) {
	q := url.Values{
		"query": {expr},
		"start": {strconv.FormatInt(start.Unix(), 10)},
		"end":   {strconv.FormatInt(end.Unix(), 10)},
		"step":  {strconv.FormatInt(int64(step/time.Second), 10)},
	}
	var body promRangeResponse
	target := joinURL(p.baseURL, "/api/v1/query_range", q)
	if err := getJSON(ctx, p.client, target, "prometheus", &body); err != nil {
		return nil, err
	}
	if body.Status != "success" {
		return nil, promStatusError(body.Status, body.Error)
	}
	if body.Data.ResultType != "matrix" {
		return nil, fmt.Errorf("prometheus: result type %q", body.Data.ResultType)
	}
	out := make([]promSeries, 0, len(body.Data.Result))
	for _, r := range body.Data.Result {
		points := make([]promPoint, 0, len(r.Values))
		for _, v := range r.Values {
			ts, ok := v[0].(float64)
			text, okText := v[1].(string)
			if !ok || !okText {
				continue
			}
			f, err := strconv.ParseFloat(text, 64)
			if err != nil || math.IsNaN(f) || math.IsInf(f, 0) {
				continue
			}
			points = append(points, promPoint{at: promTime(ts), value: f})
		}
		if len(points) > 0 {
			out = append(out, promSeries{metric: r.Metric, points: points})
		}
	}
	return out, nil
}

// promStatusError turns a successful HTTP response carrying an error status
// into an error.
func promStatusError(status, msg string) error {
	if msg != "" {
		return fmt.Errorf("prometheus: %s", msg)
	}
	return fmt.Errorf("prometheus: status %q", status)
}

// promTime converts the API's float seconds to a time.
func promTime(ts float64) time.Time {
	sec, frac := math.Modf(ts)
	return time.Unix(int64(sec), int64(frac*1e9))
}

// sampleHost prefers the host label the deployment adds, then falls back to
// the scrape instance.
func sampleHost(metric map[string]string) string {
	if h := metric["host"]; h != "" {
		return h
	}
	return metric["instance"]
}

// nonNegative reports v when it is a finite, non-negative number.
func nonNegative(v float64) (float64, bool) {
	if math.IsNaN(v) || math.IsInf(v, 0) || v < 0 {
		return 0, false
	}
	return v, true
}

// clampPercent keeps a history sample inside the 0..100 display range.
func clampPercent(v float64) float64 {
	if math.IsNaN(v) || math.IsInf(v, 0) {
		return 0
	}
	return min(max(v, 0), 100)
}
