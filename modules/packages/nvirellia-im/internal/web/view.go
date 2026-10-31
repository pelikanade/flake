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

type page struct {
	Resources bool
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
	Total string
}

type statusView struct {
	Uptime *uptimeView
	Probes *probeView
}

const uptimeSlots = 50

type uptimeView struct {
	Summary   string
	Endpoints []uptimeRow
}

type uptimeRow struct {
	Name, Group, State  string
	Uptime24h, Uptime7d string
	Last, Latency       string
	Oldest              string
	Tally               string
	BarLabel            string
	Slots               []checkSlot
}

type checkSlot struct {
	State, Title string
}

type probeView struct {
	Summary string
	Window  string
	Systems []probeRow
}

type probeRow struct {
	Name, Host, State, Uptime, Seen string
	Version, VersionFull            string
	VersionState, VersionLabel      string
	Updated                         string
	Metrics                         []metricView
}

type metricView struct {
	Key, Label, Value string
	Fill              string
	Level             string
	Line, Area        string
	GraphLabel        string
}

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

	nowH := generated.Hour()
	peak := slices.Index(hourTot, slices.Max(hourTot))
	var last7 int64
	for i := max(0, last-6); i <= last; i++ {
		if dayTot[i] != nil {
			last7 += *dayTot[i]
		}
	}
	todayTot := t.Today.All()

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
		Total: fmt.Sprintf("today %s · this hour %s", fmtTokens(todayTot), fmtTokens(hourTot[nowH])),
	}
	return p, nil
}

func hourLabel(start time.Time, i int) string {
	return fmt.Sprintf("%02d:00", (start.Hour()+i)%24)
}

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

const sparkW, sparkH = 120, 30

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

func probeState(s string) string {
	switch s {
	case "up", "down":
		return s
	default:
		return "unknown"
	}
}

func fmtPercent(p *float64) string {
	if p == nil {
		return "—"
	}
	return fmt.Sprintf("%.2f%%", *p)
}

func fmtPercentValue(v float64) string {
	return fmt.Sprintf("%.0f%%", v)
}

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

func icon(id string) template.HTML {
	return template.HTML(`<svg class="ic" aria-hidden="true"><use href="#` + id + `"/></svg>`)
}
