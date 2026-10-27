package feed

import "time"

// aggregate turns magpie usage into the feed's UTC+8 windows as of now. "Today"
// is the local day's total; hourly is today's 24 local hours from midnight, with
// hours after now zero; daily is the 16-week Monday-first grid, with days after
// today left null.
func aggregate(u Usage, now time.Time, loc *time.Location) Tokens {
	local := now.In(loc)
	y, m, d := local.Date()
	todayMidnight := time.Date(y, m, d, 0, 0, 0, 0, loc)
	hourly := sumByKey(u.Hours, loc, hourLayout)
	daily := sumByKey(u.Days, loc, dayLayout)
	start := dailyStart(local)

	t := Tokens{Today: daily[local.Format(dayLayout)]}
	hw := fillSeries(hourlyWindow, func(i int) (Totals, bool) {
		return hourly[time.Date(y, m, d, i, 0, 0, 0, loc).Format(hourLayout)], true
	}, func(v int64) int64 { return v })
	t.Hourly = Hourly{Start: todayMidnight.Format(time.RFC3339),
		Input: hw.Input, CacheRead: hw.CacheRead, CacheWrite: hw.CacheWrite, Output: hw.Output}
	dw := fillSeries(dailyDays, func(i int) (Totals, bool) {
		day := time.Date(start.Year(), start.Month(), start.Day()+i, 0, 0, 0, 0, loc)
		if day.After(todayMidnight) {
			return Totals{}, false
		}
		return daily[day.Format(dayLayout)], true
	}, func(v int64) *int64 { return &v })
	t.Daily = Daily{Start: start.Format(dayLayout),
		Input: dw.Input, CacheRead: dw.CacheRead, CacheWrite: dw.CacheWrite, Output: dw.Output}
	return t
}

// sumByKey totals each bucket's tokens under its start instant formatted in loc with layout.
func sumByKey(buckets []Bucket, loc *time.Location, layout string) map[string]Totals {
	sums := make(map[string]Totals)
	for _, b := range buckets {
		k := b.Start.In(loc).Format(layout)
		t := sums[k]
		t.Input += b.Input
		t.CacheRead += b.CacheRead
		t.CacheWrite += b.CacheWrite
		t.Output += b.Output
		sums[k] = t
	}
	return sums
}

// series is one window's four token series.
type series[T any] struct {
	Input, CacheRead, CacheWrite, Output []T
}

// fillSeries builds the four series of length n. Index i takes the wrapped totals
// from at when at reports ok; otherwise it stays the zero value.
func fillSeries[T any](n int, at func(i int) (Totals, bool), wrap func(int64) T) series[T] {
	s := series[T]{Input: make([]T, n), CacheRead: make([]T, n), CacheWrite: make([]T, n), Output: make([]T, n)}
	for i := range n {
		t, ok := at(i)
		if !ok {
			continue
		}
		s.Input[i], s.CacheRead[i], s.CacheWrite[i], s.Output[i] = wrap(t.Input), wrap(t.CacheRead), wrap(t.CacheWrite), wrap(t.Output)
	}
	return s
}
