// Package feed builds the nvirellia.im feed: token windows from magpie (cache
// tokens included), uptime from gatus, and host probes from prometheus. Each
// section is nil while its upstream has no data (unconfigured, unreachable, or
// empty).
package feed

import (
	"time"
	_ "time/tzdata" // the day zone must resolve in minimal containers
)

const zoneName = "Asia/Shanghai"

// Layouts for the daily and hourly keys. Both are read in the feed zone (UTC+8).
const (
	dayLayout  = "2006-01-02"
	hourLayout = "2006-01-02T15"
)

// Location returns the feed's day zone, UTC+8.
func Location() (*time.Location, error) {
	return time.LoadLocation(zoneName)
}

// Feed is the nvirellia.im profile feed: generation time, day zone, token
// windows, and the status tab's uptime checks and host probes.
type Feed struct {
	GeneratedAt string  `json:"generatedAt"`
	TZ          string  `json:"tz"`
	Tokens      *Tokens `json:"tokens"`
	Status      *Status `json:"status"`
}

// Status is the status tab: gatus checks and prometheus probes. Either half is
// nil when its upstream has no data.
type Status struct {
	Uptime *Uptime `json:"uptime"`
	Probes *Probes `json:"probes"`
}

// Uptime is gatus' view of the checks it runs, one row per monitor.
type Uptime struct {
	Endpoints []Endpoint `json:"endpoints"`
}

// Endpoint is one gatus monitor. Uptime24h and Uptime7d are percentages in
// [0, 100]; nil means gatus had no uptime data for that window.
type Endpoint struct {
	Name      string   `json:"name"`
	Group     string   `json:"group"`
	Key       string   `json:"key"`
	Known     bool     `json:"known"` // a result has been recorded
	Up        bool     `json:"up"`
	Status    int      `json:"status,omitempty"` // HTTP status of the last result
	LatencyMS int64    `json:"latencyMs,omitempty"`
	CheckedAt string   `json:"checkedAt,omitempty"` // RFC 3339
	Uptime24h *float64 `json:"uptime24h"`
	Uptime7d  *float64 `json:"uptime7d"`

	// Results is the recent check history, oldest first, from gatus' status
	// API. The Status tab draws one bar segment per result.
	Results []Check `json:"results,omitempty"`
}

// Check is one gatus result.
type Check struct {
	Up        bool   `json:"up"`
	Status    int    `json:"status,omitempty"`
	LatencyMS int64  `json:"latencyMs,omitempty"`
	At        string `json:"at,omitempty"` // RFC 3339
}

// Probes is Prometheus' view of the hosts it scrapes.
type Probes struct {
	Systems []Probe `json:"systems"`
}

// Probe is one Prometheus target. UptimeSeconds, CPU, Mem and Disk are nil
// when the target is down or the metric is missing; Status is up, down, or
// unknown. Revision and UpdatedAt come from the host's textfile metrics and are
// empty on a target that has not published them. UpToDate is nil when the
// upstream revision is unknown or the host has no revision to compare.
type Probe struct {
	Name          string   `json:"name"`
	Host          string   `json:"host,omitempty"`
	Status        string   `json:"status"`
	UptimeSeconds *uint64  `json:"uptimeSeconds,omitempty"`
	CPU           *float64 `json:"cpu,omitempty"`
	Mem           *float64 `json:"mem,omitempty"`
	Disk          *float64 `json:"disk,omitempty"`
	Updated       string   `json:"updated,omitempty"` // RFC 3339

	// Revision is the flake revision that built the running system, possibly
	// suffixed "-dirty" or the literal "unknown". UpdatedAt is when that
	// generation was activated.
	Revision  string `json:"revision,omitempty"`
	UpdatedAt string `json:"updatedAt,omitempty"` // RFC 3339
	UpToDate  *bool  `json:"upToDate,omitempty"`

	// Histories are percentage samples, oldest first, over the last
	// ProbeHistoryWindow.
	CPUHistory  []float64 `json:"cpuHistory,omitempty"`
	MemHistory  []float64 `json:"memHistory,omitempty"`
	DiskHistory []float64 `json:"diskHistory,omitempty"`
}

// Tokens is the magpie-derived part of the feed.
type Tokens struct {
	Today  Totals `json:"today"`
	Hourly Hourly `json:"hourly"`
	Daily  Daily  `json:"daily"`
}

// Totals is a window's token counts: the prompt's uncached input, its cache
// reads and writes, and the output. Magpie counts reasoning tokens inside
// output, and nothing of the prompt is counted twice.
type Totals struct {
	Input      int64 `json:"input"`
	CacheRead  int64 `json:"cacheRead"`
	CacheWrite int64 `json:"cacheWrite"`
	Output     int64 `json:"output"`
}

// All is every token the totals count, cache included.
func (t Totals) All() int64 { return t.Input + t.CacheRead + t.CacheWrite + t.Output }

// Hourly is today's 24 local hours, oldest first; hours after now are zero.
type Hourly struct {
	Start      string  `json:"start"`
	Input      []int64 `json:"input"`
	CacheRead  []int64 `json:"cacheRead"`
	CacheWrite []int64 `json:"cacheWrite"`
	Output     []int64 `json:"output"`
}

// At is the totals of the hour at index i.
func (h Hourly) At(i int) Totals {
	return Totals{Input: h.Input[i], CacheRead: h.CacheRead[i], CacheWrite: h.CacheWrite[i], Output: h.Output[i]}
}

// Daily is 16 Monday-first weeks; nil entries are days after today, and days before magpie's first record are zero.
type Daily struct {
	Start      string   `json:"start"`
	Input      []*int64 `json:"input"`
	CacheRead  []*int64 `json:"cacheRead"`
	CacheWrite []*int64 `json:"cacheWrite"`
	Output     []*int64 `json:"output"`
}

// At is the totals of the day at index i, nil for a day after today.
func (d Daily) At(i int) *Totals {
	if d.Input[i] == nil {
		return nil
	}
	return &Totals{Input: *d.Input[i], CacheRead: *d.CacheRead[i], CacheWrite: *d.CacheWrite[i], Output: *d.Output[i]}
}

// Bucket is magpie usage for one local hour or day, keyed by its start instant.
type Bucket struct {
	Start      time.Time `json:"start"`
	Input      int64     `json:"input"`
	CacheRead  int64     `json:"cacheRead"`
	CacheWrite int64     `json:"cacheWrite"`
	Output     int64     `json:"output"`
}

// Usage is magpie's token usage as the feed reads it: today's hourly buckets and
// the per-day buckets from magpie's first usage record.
type Usage struct {
	Hours []Bucket
	Days  []Bucket
}

// Window sizes shared by aggregation and the daily layout.
const (
	hourlyWindow = 24
	dailyWeeks   = 16
	dailyDays    = 7 * dailyWeeks
)

// weekdayIndex maps a time to its Monday-first index: Mon=0 … Sun=6.
func weekdayIndex(t time.Time) int {
	return (int(t.Weekday()) + 6) % 7
}

// dailyStart is local midnight of the Monday that opens the 16-week window.
func dailyStart(local time.Time) time.Time {
	y, m, d := local.Date()
	return time.Date(y, m, d-weekdayIndex(local)-7*(dailyWeeks-1), 0, 0, 0, 0, local.Location())
}
