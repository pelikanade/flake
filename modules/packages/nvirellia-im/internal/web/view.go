package web

import (
	"encoding/json"
	"fmt"
	"html/template"
	"math"
	"slices"
	"strconv"
	"strings"
	"time"

	"github.com/pelikanade/nvirellia.im/internal/feed"
)

// page is the template data for the sheet. Field names are used by templates/*.html.
type page struct {
	Resources bool // magpie has data: the Resources tab, its panel, and the status readouts render
	Status    *statusView
	FeedJSON  template.JS
	Updated   string
	Readouts  readouts
	Legend    legend
}

type readouts struct {
	Today, Input, CacheRead, CacheWrite, Output, ThisHour, Peak, Last7d, Note string
}

type legend struct {
	In, Cache, Out string
}

// statusView is the Status panel, already formatted for the template.
type statusView struct {
	Uptime *uptimeView
	Probes *probeView
}

// uptimeSlots is the segment count of every uptime bar, matching the history
// gatus returns. Short histories are padded on the oldest side, so bars line up
// and a three-check monitor never stretches three segments across the row.
const uptimeSlots = 50

type uptimeView struct {
	Summary   string // "3 monitors · 2 up · 1 down"
	Endpoints []uptimeRow
}

type uptimeRow struct {
	Name, Group, State  string
	Uptime24h, Uptime7d string
	Last, Latency       string // time and latency of the newest check
	Oldest              string // time of the oldest check in the bar
	Tally               string // "2 of 3 checks up"
	BarLabel            string // the bar's accessible name
	Slots               []checkSlot
}

// checkSlot is one bar segment: up, down, or none for padding before the
// first recorded check. Title is its native tooltip.
type checkSlot struct {
	State, Title string
}

type probeView struct {
	Summary string // "2 hosts · 1 up · 1 down"
	Window  string // history span, "6h"
	Systems []probeRow
}

type probeRow struct {
	Name, Host, State, Uptime, Seen string
	Version, VersionFull            string // short hash shown, full hash in the tooltip
	VersionState, VersionLabel      string // "up-to-date", "outdated", "modified", "unknown"
	Updated                         string // last generation activation in the feed zone
	Metrics                         []metricView
}

// metricView is one host metric: its reading, a meter, and a sparkline. Fill,
// Line and Area are empty when the target has no live value or history.
type metricView struct {
	Key, Label, Value string
	Fill              string // meter width as a CSS percentage
	Level             string // "", "warn" or "crit"
	Line, Area        string // sparkline points in a sparkW x sparkH box
	GraphLabel        string
}

// newPage derives everything the templates show from one feed snapshot.
func newPage(f feed.Feed) (page, error) {
	generated, err := time.Parse(time.RFC3339, f.GeneratedAt)
	if err != nil {
		return page{}, fmt.Errorf("generatedAt: %w", err)
	}
	feedJSON, err := json.Marshal(f)
	if err != nil {
		return page{}, err
	}
	p := page{FeedJSON: template.JS(feedJSON), Updated: generated.Format("2006-01-02")}
	loc, err := time.LoadLocation(f.TZ)
	if err != nil {
		loc = generated.Location()
	}
	p.Status = newStatusView(f.Status, loc)
	if f.Tokens == nil {
		return p, nil
	}
	hourStart, err := time.Parse(time.RFC3339, f.Tokens.Hourly.Start)
	if err != nil {
		return page{}, fmt.Errorf("hourly start: %w", err)
	}

	t := *f.Tokens
	hourTot := make([]int64, len(t.Hourly.Input))
	for i := range hourTot {
		hourTot[i] = t.Hourly.At(i).All()
	}
	dayTot := make([]*int64, len(t.Daily.Input))
	last := 0
	for i := range dayTot {
		d := t.Daily.At(i)
		if d == nil {
			continue
		}
		v := d.All()
		dayTot[i] = &v
		last = i
	}

	nowH := generated.Hour() // hourly starts at local midnight, so the index is the hour
	peak := slices.Index(hourTot, slices.Max(hourTot))
	var last7 int64
	for i := max(0, last-6); i <= last; i++ {
		if dayTot[i] != nil {
			last7 += *dayTot[i]
		}
	}
	todayTot := t.Today.All()
	todayCache := t.Today.CacheRead + t.Today.CacheWrite
	hourCache := t.Hourly.CacheRead[nowH] + t.Hourly.CacheWrite[nowH]

	snapshotLabel := generated.Format("2006-01-02 15:04") + " (UTC+8)"
	p.Resources = true
	p.Readouts = readouts{
		Today:      fmtTokens(todayTot),
		Input:      fmtTokens(t.Today.Input),
		CacheRead:  fmtTokens(t.Today.CacheRead),
		CacheWrite: fmtTokens(t.Today.CacheWrite),
		Output:     fmtTokens(t.Today.Output),
		ThisHour:   fmtTokens(hourTot[nowH]),
		Peak:       fmt.Sprintf("%s · %s", hourLabel(hourStart, peak), fmtTokens(hourTot[peak])),
		Last7d:     fmtTokens(last7),
		Note:       fmt.Sprintf("magpie snapshot: %s", snapshotLabel),
	}
	p.Legend = legend{
		In:    fmt.Sprintf("today %s · this hour %s", fmtTokens(t.Today.Input), fmtTokens(t.Hourly.Input[nowH])),
		Cache: fmt.Sprintf("today %s · this hour %s", fmtTokens(todayCache), fmtTokens(hourCache)),
		Out:   fmt.Sprintf("today %s · this hour %s", fmtTokens(t.Today.Output), fmtTokens(t.Hourly.Output[nowH])),
	}
	return p, nil
}

// hourLabel is the "HH:00" label of the hour at index i past the window start.
func hourLabel(start time.Time, i int) string {
	return fmt.Sprintf("%02d:00", (start.Hour()+i)%24)
}

// newStatusView formats gatus and Prometheus data for the Status panel. It
// returns nil when neither source has anything to show, so the tab stays out of
// the page.
func newStatusView(s *feed.Status, loc *time.Location) *statusView {
	if s == nil {
		return nil
	}
	v := &statusView{}
	if s.Uptime != nil {
		v.Uptime = &uptimeView{}
		states := make([]string, 0, len(s.Uptime.Endpoints))
		for _, e := range s.Uptime.Endpoints {
			row := uptimeRow{
				Name:      e.Name,
				Group:     e.Group,
				State:     endpointState(e),
				Uptime24h: fmtPercent(e.Uptime24h),
				Uptime7d:  fmtPercent(e.Uptime7d),
				Last:      fmtClock(e.CheckedAt, loc),
			}
			if e.LatencyMS > 0 {
				row.Latency = fmt.Sprintf("%dms", e.LatencyMS)
			}
			row.Slots, row.Tally, row.Oldest = uptimeBar(e.Results, loc)
			row.BarLabel = row.Name + ", last checks: " + row.Tally
			if row.Oldest != "—" {
				row.BarLabel += ", " + row.Oldest + " to " + row.Last
			}
			states = append(states, row.State)
			v.Uptime.Endpoints = append(v.Uptime.Endpoints, row)
		}
		v.Uptime.Summary = stateSummary(states, "monitor", "monitors")
	}
	if s.Probes != nil {
		v.Probes = &probeView{Window: fmt.Sprintf("%.0fh", feed.ProbeHistoryWindow.Hours())}
		states := make([]string, 0, len(s.Probes.Systems))
		for _, p := range s.Probes.Systems {
			row := probeRow{
				Name:   p.Name,
				Host:   p.Host,
				State:  probeState(p.Status),
				Uptime: "—",
				Seen:   fmtClock(p.Updated, loc),
				Metrics: []metricView{
					newMetric("cpu", "cpu", p.CPU, p.CPUHistory, v.Probes.Window),
					newMetric("mem", "memory", p.Mem, p.MemHistory, v.Probes.Window),
					newMetric("disk", "disk", p.Disk, p.DiskHistory, v.Probes.Window),
				},
			}
			row.Version, row.VersionFull, row.VersionState, row.VersionLabel = versionInfo(p)
			row.Updated = fmtMoment(p.UpdatedAt, loc)
			if p.UptimeSeconds != nil {
				row.Uptime = fmtDuration(*p.UptimeSeconds)
			}
			states = append(states, row.State)
			v.Probes.Systems = append(v.Probes.Systems, row)
		}
		v.Probes.Summary = stateSummary(states, "host", "hosts")
	}
	if v.Uptime == nil && v.Probes == nil {
		return nil
	}
	return v
}

// stateSummary counts states for a frame caption: "3 monitors · 2 up · 1 down".
func stateSummary(states []string, one, many string) string {
	noun := many
	if len(states) == 1 {
		noun = one
	}
	parts := []string{fmt.Sprintf("%d %s", len(states), noun)}
	for _, st := range []string{"up", "down", "unknown"} {
		if n := countOf(states, st); n > 0 {
			parts = append(parts, fmt.Sprintf("%d %s", n, st))
		}
	}
	return strings.Join(parts, " · ")
}

func countOf(states []string, want string) int {
	n := 0
	for _, s := range states {
		if s == want {
			n++
		}
	}
	return n
}

// uptimeBar lays the newest uptimeSlots checks into a fixed-width bar, oldest
// first, padding the oldest side with empty slots. It also returns the visible
// tally and the oldest check's time.
func uptimeBar(results []feed.Check, loc *time.Location) (slots []checkSlot, tally, oldest string) {
	if len(results) > uptimeSlots {
		results = results[len(results)-uptimeSlots:]
	}
	slots = make([]checkSlot, 0, uptimeSlots)
	for range uptimeSlots - len(results) {
		slots = append(slots, checkSlot{State: "none", Title: "no check recorded"})
	}
	up := 0
	for _, c := range results {
		st := "down"
		if c.Up {
			st = "up"
			up++
		}
		slots = append(slots, checkSlot{State: st, Title: checkTitle(c, st, loc)})
	}
	if len(results) == 0 {
		return slots, "no checks yet", "—"
	}
	return slots, fmt.Sprintf("%d of %d checks up", up, len(results)), fmtClock(results[0].At, loc)
}

// checkTitle is one segment's tooltip: "Oct 23 23:01 · down · HTTP 503 · 12ms".
func checkTitle(c feed.Check, state string, loc *time.Location) string {
	parts := []string{"time unknown", state}
	if t, err := time.Parse(time.RFC3339, c.At); err == nil {
		parts[0] = t.In(loc).Format("Jan 2 15:04:05")
	}
	if c.Status > 0 {
		parts = append(parts, fmt.Sprintf("HTTP %d", c.Status))
	}
	if c.LatencyMS > 0 {
		parts = append(parts, fmt.Sprintf("%dms", c.LatencyMS))
	}
	return strings.Join(parts, " · ")
}

// Sparkline box: the viewBox of every metric graph. The vertical scale is a
// fixed 0..100%, like a load applet, so hosts and metrics compare at a glance.
const sparkW, sparkH = 120, 30

// newMetric formats one host metric. A nil value or empty history renders as
// a dash and an empty graph, never as stale numbers.
func newMetric(key, label string, v *float64, history []float64, window string) metricView {
	m := metricView{Key: key, Label: label, Value: "—"}
	if v != nil {
		pct := min(max(*v, 0), 100)
		m.Value = fmtPercentValue(pct)
		m.Fill = strconv.FormatFloat(pct, 'f', 1, 64) + "%"
		switch {
		case pct >= 90:
			m.Level = "crit"
		case pct >= 75:
			m.Level = "warn"
		}
	}
	if len(history) == 0 {
		m.GraphLabel = label + ": no history"
		return m
	}
	m.Line, m.Area = sparkline(history)
	m.GraphLabel = fmt.Sprintf("%s, last %s: now %s, low %s, high %s", label, window,
		m.Value, fmtPercentValue(slices.Min(history)), fmtPercentValue(slices.Max(history)))
	return m
}

// sparkline maps percentage samples, oldest first, to a polyline and its
// filled area. A single sample draws a flat line.
func sparkline(values []float64) (line, area string) {
	if len(values) == 1 {
		values = []float64{values[0], values[0]}
	}
	var b strings.Builder
	for i, v := range values {
		x := float64(i) / float64(len(values)-1) * sparkW
		y := sparkH - 1 - min(max(v, 0), 100)/100*(sparkH-2)
		if i > 0 {
			b.WriteByte(' ')
		}
		fmt.Fprintf(&b, "%.1f,%.1f", x, y)
	}
	line = b.String()
	return line, fmt.Sprintf("0,%d %s %d,%d", sparkH, line, sparkW, sparkH)
}

// endpointState is the gatus monitor state shown on the Status row.
func endpointState(e feed.Endpoint) string {
	switch {
	case !e.Known:
		return "unknown"
	case e.Up:
		return "up"
	default:
		return "down"
	}
}

// probeState keeps Prometheus' states and maps anything else to unknown.
func probeState(s string) string {
	switch s {
	case "up", "down":
		return s
	default:
		return "unknown"
	}
}

// fmtPercent renders gatus' 0..1-derived percentage; nil means no data for the window.
func fmtPercent(p *float64) string {
	if p == nil {
		return "—"
	}
	return fmt.Sprintf("%.2f%%", *p)
}

// fmtPercentValue renders a Prometheus percentage.
func fmtPercentValue(v float64) string {
	return fmt.Sprintf("%.0f%%", v)
}

// fmtDuration renders a host uptime in the largest two units that fit.
func fmtDuration(sec uint64) string {
	if sec == 0 {
		return "—"
	}
	d, h, m := sec/86400, (sec%86400)/3600, (sec%3600)/60
	switch {
	case d > 0:
		return fmt.Sprintf("%dd %dh", d, h)
	case h > 0:
		return fmt.Sprintf("%dh %dm", h, m)
	default:
		return fmt.Sprintf("%dm", m)
	}
}

// fmtClock is an RFC 3339 instant as "15:04" in the feed zone.
func fmtClock(s string, loc *time.Location) string {
	if s == "" {
		return "—"
	}
	t, err := time.Parse(time.RFC3339, s)
	if err != nil {
		return "—"
	}
	return t.In(loc).Format("15:04")
}

// fmtMoment is an RFC 3339 instant as "2006-01-02 15:04" in the feed zone. The
// last update can be days old, so it carries the date that fmtClock omits.
func fmtMoment(s string, loc *time.Location) string {
	if s == "" {
		return "—"
	}
	t, err := time.Parse(time.RFC3339, s)
	if err != nil {
		return "—"
	}
	return t.In(loc).Format("2006-01-02 15:04")
}

// versionInfo formats a host's flake revision and its relation to upstream
// main. A dirty tree based on main is "modified", not "outdated"; a nil
// comparison means the upstream revision is unavailable.
func versionInfo(p feed.Probe) (short, full, state, label string) {
	if p.Revision == "" {
		return "—", "", "", ""
	}
	short, full = shortRevision(p.Revision), p.Revision
	switch {
	case p.Revision == "unknown", p.UpToDate == nil:
		return short, full, "unknown", "unknown"
	case *p.UpToDate:
		return short, full, "up-to-date", "up-to-date"
	case strings.HasSuffix(p.Revision, "-dirty"):
		return short, full, "modified", "modified"
	default:
		return short, full, "outdated", "outdated"
	}
}

// shortRevision keeps the first seven hex characters of a git revision, and
// any suffix such as "-dirty".
func shortRevision(rev string) string {
	base, suffix, _ := strings.Cut(rev, "-")
	if len(base) > 7 {
		base = base[:7]
	}
	if suffix != "" {
		return base + "-" + suffix
	}
	return base
}

// fmtTokens matches the page script's readout format: 4477200 -> "4.5M", 182300 -> "182k", 4710 -> "4.7k".
func fmtTokens(n int64) string {
	switch {
	case n >= 1e6:
		return fmt.Sprintf("%.1fM", float64(n)/1e6)
	case n >= 1e4:
		return fmt.Sprintf("%dk", int64(math.Round(float64(n)/1e3)))
	case n >= 1e3:
		return fmt.Sprintf("%.1fk", float64(n)/1e3)
	default:
		return strconv.FormatInt(n, 10)
	}
}

// icon is the sprite reference for id, a fixed literal from the templates.
func icon(id string) template.HTML {
	return template.HTML(`<svg class="ic" aria-hidden="true"><use href="#` + id + `"/></svg>`)
}
