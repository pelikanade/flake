// Package e2e builds the nvirellia-im binary, runs it against a stub magpie, and
// checks what visitors and the feed API see over HTTP.
package e2e

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

var (
	binPath string
	cst     = time.FixedZone("UTC+8", 8*3600)

	latestRev = "abcdef1" + strings.Repeat("0", 33)
	oldRev    = "1234567" + strings.Repeat("0", 33)
)

func TestMain(m *testing.M) {
	dir, err := os.MkdirTemp("", "nvirellia-im-e2e-")
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	binPath = filepath.Join(dir, "nvirellia-im")
	build := exec.Command("go", "build", "-o", binPath, "./cmd/nvirellia-im")
	build.Dir = ".."
	if out, err := build.CombinedOutput(); err != nil {
		fmt.Fprintf(os.Stderr, "build failed: %v\n%s", err, out)
		os.RemoveAll(dir)
		os.Exit(1)
	}
	code := m.Run()
	os.RemoveAll(dir)
	os.Exit(code)
}

type series struct {
	Time       time.Time `json:"time"`
	Input      int64     `json:"input"`
	CacheRead  int64     `json:"cache_read"`
	CacheWrite int64     `json:"cache_write"`
	Output     int64     `json:"output"`
}

type magpieStub struct {
	URL   string
	key   string
	hours []series
	days  []series
	down  atomic.Bool
	hits  atomic.Int64
}

func newMagpieStub(t *testing.T, key string, hours, days []series) *magpieStub {
	t.Helper()
	s := &magpieStub{key: key, hours: hours, days: days}
	mux := http.NewServeMux()
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		s.hits.Add(1)
		if s.down.Load() {
			http.Error(w, "down", http.StatusServiceUnavailable)
			return
		}
		if r.URL.Query().Get("k") != s.key {
			http.Error(w, "forbidden", http.StatusForbidden)
			return
		}
		http.SetCookie(w, &http.Cookie{Name: "session", Value: "ok", Path: "/"})
		http.Redirect(w, r, "/", http.StatusSeeOther)
	})
	mux.HandleFunc("/api/usage", func(w http.ResponseWriter, r *http.Request) {
		s.hits.Add(1)
		if s.down.Load() {
			http.Error(w, "down", http.StatusServiceUnavailable)
			return
		}
		if c, err := r.Cookie("session"); err != nil || c.Value != "ok" {
			http.Error(w, "no session", http.StatusUnauthorized)
			return
		}
		var body map[string]any
		switch r.URL.Query().Get("period") {
		case "today":
			body = map[string]any{"period": "today", "bucket": "hour", "series": s.hours}
		case "all":
			body = map[string]any{"period": "all", "bucket": "day", "series": s.days}
		default:
			http.Error(w, "unknown period", http.StatusBadRequest)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(body)
	})
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	s.URL = srv.URL
	return s
}

type gatusStub struct {
	URL  string
	down atomic.Bool
	hits atomic.Int64
}

func newGatusStub(t *testing.T) *gatusStub {
	t.Helper()
	s := &gatusStub{}
	type endpoint struct {
		name, group, key string
		history          []bool
	}
	gatusHistory := make([]bool, 60)
	for i := range gatusHistory {
		gatusHistory[i] = i >= 10
	}
	endpoints := []endpoint{
		{"Gatus", "Edge", "edge_gatus", gatusHistory},
		{"Paseo daemon", "Neko Sphere", "neko-sphere_paseo-daemon", []bool{true, true, false}},
		{"nuts.nvirellia.im", "Noa's IVs", "noa's-ivs_nuts-nvirellia-im", []bool{true, false, true}},
	}
	checked := time.Date(2026, 10, 23, 15, 0, 0, 0, time.UTC)
	mux := http.NewServeMux()
	mux.HandleFunc("GET /api/v1/endpoints/statuses", func(w http.ResponseWriter, r *http.Request) {
		s.hits.Add(1)
		if s.down.Load() {
			http.Error(w, "down", http.StatusServiceUnavailable)
			return
		}
		statuses := make([]map[string]any, len(endpoints))
		for i, e := range endpoints {
			results := make([]map[string]any, len(e.history))
			for j, up := range e.history {
				status := 200
				if !up {
					status = 503
				}
				results[j] = map[string]any{
					"status": status, "success": up,
					"timestamp": checked.Add(time.Duration(j) * time.Minute).Format(time.RFC3339Nano),
					"duration":  int64(12 * time.Millisecond),
				}
			}
			statuses[i] = map[string]any{
				"name": e.name, "group": e.group, "key": e.key,
				"results": results,
			}
		}
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(statuses)
	})
	mux.HandleFunc("GET /api/v1/endpoints/", func(w http.ResponseWriter, r *http.Request) {
		s.hits.Add(1)
		if s.down.Load() {
			http.Error(w, "down", http.StatusServiceUnavailable)
			return
		}
		parts := strings.Split(strings.TrimPrefix(r.URL.Path, "/api/v1/endpoints/"), "/")
		if len(parts) != 3 || parts[1] != "uptimes" {
			http.NotFound(w, r)
			return
		}
		switch parts[2] {
		case "24h":
			io.WriteString(w, "0.999900")
		case "7d":
			io.WriteString(w, "0.999000")
		default:
			http.Error(w, "unknown duration", http.StatusBadRequest)
		}
	})
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	s.URL = srv.URL
	return s
}

type prometheusStub struct {
	URL  string
	down atomic.Bool
	hits atomic.Int64
}

func newPrometheusStub(t *testing.T) *prometheusStub {
	t.Helper()
	s := &prometheusStub{}
	at := float64(time.Date(2026, 10, 23, 15, 0, 0, 0, time.UTC).Unix())
	edge := map[string]string{"host": "edge", "instance": "127.0.0.1:9100"}
	asymmetry := map[string]string{"host": "asymmetry", "instance": "asymmetry.dwelf-hoki.ts.net:9100"}
	neko := map[string]string{"host": "neko-sphere", "instance": "neko-sphere.dwelf-hoki.ts.net:9100"}
	withRevision := func(base map[string]string, revision string) map[string]string {
		out := make(map[string]string, len(base)+1)
		for k, v := range base {
			out[k] = v
		}
		out["revision"] = revision
		return out
	}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /api/v1/query", func(w http.ResponseWriter, r *http.Request) {
		s.hits.Add(1)
		if s.down.Load() {
			http.Error(w, "down", http.StatusServiceUnavailable)
			return
		}
		q := r.URL.Query().Get("query")
		if !strings.Contains(q, `job="node"`) {
			w.WriteHeader(http.StatusBadRequest)
			json.NewEncoder(w).Encode(map[string]any{"status": "error", "error": "unexpected job"})
			return
		}
		var result []map[string]any
		switch {
		case strings.HasPrefix(q, "up{"):
			result = []map[string]any{
				{"metric": edge, "value": []any{at, "1"}},
				{"metric": asymmetry, "value": []any{at, "1"}},
				{"metric": neko, "value": []any{at, "0"}},
			}
		case strings.Contains(q, "node_boot_time_seconds"):
			result = []map[string]any{
				{"metric": edge, "value": []any{at, strconv.FormatUint(12*86400+4*3600, 10)}},
				{"metric": asymmetry, "value": []any{at, strconv.FormatUint(4*3600+20*60, 10)}},
				{"metric": neko, "value": []any{at, strconv.FormatUint(3*3600, 10)}},
			}
		case strings.Contains(q, "nixos_flake_info"):
			result = []map[string]any{
				{"metric": withRevision(edge, latestRev), "value": []any{at, "1"}},
				{"metric": withRevision(asymmetry, oldRev), "value": []any{at, "1"}},
				{"metric": withRevision(neko, oldRev), "value": []any{at, "1"}},
			}
		case strings.Contains(q, "nixos_system_update_time_seconds"):
			result = []map[string]any{
				{"metric": edge, "value": []any{at, strconv.FormatInt(int64(at)-3600, 10)}},
				{"metric": asymmetry, "value": []any{at, strconv.FormatInt(int64(at)-7200, 10)}},
				{"metric": neko, "value": []any{at, strconv.FormatInt(int64(at)-86400, 10)}},
			}
		default:
			w.WriteHeader(http.StatusBadRequest)
			json.NewEncoder(w).Encode(map[string]any{"status": "error", "error": "unexpected query"})
			return
		}
		json.NewEncoder(w).Encode(map[string]any{
			"status": "success",
			"data":   map[string]any{"resultType": "vector", "result": result},
		})
	})
	mux.HandleFunc("GET /api/v1/query_range", func(w http.ResponseWriter, r *http.Request) {
		s.hits.Add(1)
		if s.down.Load() {
			http.Error(w, "down", http.StatusServiceUnavailable)
			return
		}
		q := r.URL.Query().Get("query")
		if !strings.Contains(q, `job="node"`) {
			w.WriteHeader(http.StatusBadRequest)
			json.NewEncoder(w).Encode(map[string]any{"status": "error", "error": "unexpected job"})
			return
		}
		var result []map[string]any
		switch {
		case strings.Contains(q, "node_cpu_seconds_total"):
			result = []map[string]any{
				{"metric": edge, "values": [][2]any{{at - 600, "10"}, {at - 300, "11"}, {at, "12.4"}}},
				{"metric": neko, "values": [][2]any{{at - 600, "90"}, {at - 300, "92"}, {at, "94.6"}}},
			}
		case strings.Contains(q, "node_memory_MemAvailable_bytes"):
			result = []map[string]any{
				{"metric": edge, "values": [][2]any{{at - 600, "30"}, {at - 300, "34"}, {at, "38.2"}}},
				{"metric": neko, "values": [][2]any{{at - 600, "89"}, {at - 300, "90"}, {at, "91.0"}}},
			}
		case strings.Contains(q, "node_filesystem_avail_bytes"):
			result = []map[string]any{
				{"metric": edge, "values": [][2]any{{at - 600, "60"}, {at - 300, "61"}, {at, "61.9"}}},
				{"metric": neko, "values": [][2]any{{at - 600, "87"}, {at - 300, "87.5"}, {at, "88.0"}}},
			}
		default:
			w.WriteHeader(http.StatusBadRequest)
			json.NewEncoder(w).Encode(map[string]any{"status": "error", "error": "unexpected range query"})
			return
		}
		json.NewEncoder(w).Encode(map[string]any{
			"status": "success",
			"data":   map[string]any{"resultType": "matrix", "result": result},
		})
	})
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	s.URL = srv.URL
	return s
}

type githubStub struct {
	URL  string
	sha  string
	down atomic.Bool
	hits atomic.Int64
}

func newGitHubStub(t *testing.T, sha string) *githubStub {
	t.Helper()
	s := &githubStub{sha: sha}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /repos/pelikanade/flake/commits/main", func(w http.ResponseWriter, _ *http.Request) {
		s.hits.Add(1)
		if s.down.Load() {
			http.Error(w, "down", http.StatusServiceUnavailable)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]string{"sha": s.sha})
	})
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	s.URL = srv.URL
	return s
}

type syncBuffer struct {
	mu sync.Mutex
	b  bytes.Buffer
}

func (s *syncBuffer) Write(p []byte) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.b.Write(p)
}

func (s *syncBuffer) String() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.b.String()
}

func siteEnv() []string {
	var env []string
	for _, kv := range os.Environ() {
		k, _, _ := strings.Cut(kv, "=")
		if strings.HasPrefix(k, "MAGPIE_") || strings.HasPrefix(k, "GATUS_") || strings.HasPrefix(k, "PROMETHEUS_") ||
			strings.HasPrefix(k, "GITHUB_") || k == "FLAKE_REPO" || k == "LISTEN_ADDR" || k == "FEED_TTL" {
			continue
		}
		env = append(env, kv)
	}
	return env
}

func freeAddr(t *testing.T) string {
	t.Helper()
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	addr := l.Addr().String()
	l.Close()
	return addr
}

func startSite(t *testing.T, extra ...string) string {
	t.Helper()
	addr := freeAddr(t)
	cmd := exec.Command(binPath)
	cmd.Dir = t.TempDir()
	cmd.Env = append(siteEnv(), append([]string{"LISTEN_ADDR=" + addr}, extra...)...)
	var logs syncBuffer
	cmd.Stdout, cmd.Stderr = &logs, &logs
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	done := make(chan struct{})
	go func() {
		cmd.Wait()
		close(done)
	}()
	t.Cleanup(func() {
		cmd.Process.Signal(os.Interrupt)
		<-done
	})

	base := "http://" + addr
	deadline := time.Now().Add(10 * time.Second)
	for {
		select {
		case <-done:
			t.Fatalf("server exited before becoming healthy:\n%s", logs.String())
		default:
		}
		if resp, err := http.Get(base + "/healthz"); err == nil {
			resp.Body.Close()
			if resp.StatusCode == http.StatusOK {
				return base
			}
		}
		if time.Now().After(deadline) {
			t.Fatalf("server not healthy after 10s:\n%s", logs.String())
		}
		time.Sleep(50 * time.Millisecond)
	}
}

func get(t *testing.T, url string) (int, string) {
	t.Helper()
	resp, err := http.Get(url)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, string(b)
}

type totals struct {
	Input      int64 `json:"input"`
	CacheRead  int64 `json:"cacheRead"`
	CacheWrite int64 `json:"cacheWrite"`
	Output     int64 `json:"output"`
}

type statsResp struct {
	GeneratedAt string `json:"generatedAt"`
	TZ          string `json:"tz"`
	Tokens      *struct {
		Today  totals `json:"today"`
		Hourly struct {
			Input     []int64 `json:"input"`
			CacheRead []int64 `json:"cacheRead"`
		} `json:"hourly"`
		Daily struct {
			Input []*int64 `json:"input"`
		} `json:"daily"`
	} `json:"tokens"`
	Status *struct {
		Uptime *struct {
			Endpoints []struct {
				Name      string   `json:"name"`
				Group     string   `json:"group"`
				Known     bool     `json:"known"`
				Up        bool     `json:"up"`
				Uptime24h *float64 `json:"uptime24h"`
				Uptime7d  *float64 `json:"uptime7d"`
				Results   []struct {
					Up bool   `json:"up"`
					At string `json:"at"`
				} `json:"results"`
			} `json:"endpoints"`
		} `json:"uptime"`
		Probes *struct {
			Systems []struct {
				Name       string    `json:"name"`
				Status     string    `json:"status"`
				Revision   string    `json:"revision"`
				UpdatedAt  string    `json:"updatedAt"`
				UpToDate   *bool     `json:"upToDate"`
				CPU        *float64  `json:"cpu"`
				CPUHistory []float64 `json:"cpuHistory"`
			} `json:"systems"`
		} `json:"probes"`
	} `json:"status"`
}

func fetchStats(t *testing.T, base string) statsResp {
	t.Helper()
	code, page := get(t, base+"/")
	if code != http.StatusOK {
		t.Fatalf("/ status = %d", code)
	}
	m := regexp.MustCompile(`(?s)<script type="application/json" id="cl-stats">(.*?)</script>`).FindStringSubmatch(page)
	if m == nil {
		t.Fatal("page has no #cl-stats feed")
	}
	var s statsResp
	if err := json.Unmarshal([]byte(m[1]), &s); err != nil {
		t.Fatalf("#cl-stats is not valid JSON: %v\n%s", err, m[1])
	}
	return s
}

func localMidnight() time.Time {
	now := time.Now().In(cst)
	return time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, cst)
}

func TestWithoutMagpieServesProfileOnly(t *testing.T) {
	base := startSite(t)

	code, page := get(t, base+"/")
	if code != http.StatusOK {
		t.Fatalf("/ status = %d", code)
	}
	for _, want := range []string{`id="profile"`, "i@nvirellia.im"} {
		if !strings.Contains(page, want) {
			t.Errorf("page missing %q", want)
		}
	}
	for _, banned := range []string{`id="resources"`, `href="#resources"`, `id="status"`, `href="#status"`} {
		if strings.Contains(page, banned) {
			t.Errorf("page without magpie contains %q", banned)
		}
	}

	stats := fetchStats(t, base)
	if stats.Tokens != nil {
		t.Errorf("unconfigured magpie: tokens = %+v, want null", stats.Tokens)
	}
	if stats.TZ != "Asia/Shanghai" || !strings.HasSuffix(stats.GeneratedAt, "+08:00") {
		t.Errorf("tz=%q generatedAt=%q", stats.TZ, stats.GeneratedAt)
	}
}

func TestMagpieServesTokensAndResources(t *testing.T) {
	mid := localMidnight()
	stub := newMagpieStub(t, "k-test",
		[]series{
			{Time: mid, Input: 100, CacheRead: 800, CacheWrite: 5, Output: 10},
			{Time: mid.Add(time.Hour), Input: 200, CacheWrite: 1, Output: 20},
		},
		[]series{{Time: mid, Input: 300, CacheRead: 900, CacheWrite: 6, Output: 30}},
	)
	base := startSite(t, "MAGPIE_URL="+stub.URL, "MAGPIE_WEB_KEY=k-test")

	stats := fetchStats(t, base)
	if stats.Tokens == nil {
		t.Fatal("magpie answering: tokens must be present")
	}
	if got := stats.Tokens.Today; got != (totals{Input: 300, CacheRead: 900, CacheWrite: 6, Output: 30}) {
		t.Errorf("today = %+v, want input 300 cache read 900 cache write 6 output 30", got)
	}
	if n := len(stats.Tokens.Hourly.Input); n != 24 {
		t.Errorf("hourly window = %d, want 24", n)
	}
	if n := len(stats.Tokens.Hourly.CacheRead); n != 24 {
		t.Errorf("hourly cache window = %d, want 24", n)
	}
	if got := stats.Tokens.Hourly.CacheRead[0]; got != 800 {
		t.Errorf("first hour cache read = %d, want 800", got)
	}
	if n := len(stats.Tokens.Daily.Input); n != 112 {
		t.Errorf("daily window = %d, want 112", n)
	}

	_, page := get(t, base+"/")
	for _, want := range []string{`id="resources"`, `href="#resources"`,
		"<dt>tokens today</dt><dd>1.2k</dd>", "<dt>cache read</dt><dd>900</dd>", "<dt>cache write</dt><dd>6</dd>"} {
		if !strings.Contains(page, want) {
			t.Errorf("page missing %q", want)
		}
	}
}

func TestRejectedMagpieKeyDegradesToNoTokens(t *testing.T) {
	stub := newMagpieStub(t, "right-key", nil, nil)
	base := startSite(t, "MAGPIE_URL="+stub.URL, "MAGPIE_WEB_KEY=wrong-key")

	if stats := fetchStats(t, base); stats.Tokens != nil {
		t.Errorf("rejected key: tokens = %+v, want null", stats.Tokens)
	}
	code, page := get(t, base+"/")
	if code != http.StatusOK {
		t.Fatalf("/ status = %d", code)
	}
	if strings.Contains(page, `id="resources"`) {
		t.Error("rejected key: page must not render the Resources panel")
	}
}

func TestLastGoodTokensServedDuringOutage(t *testing.T) {
	mid := localMidnight()
	stub := newMagpieStub(t, "k-test",
		[]series{{Time: mid, Input: 100, Output: 10}},
		[]series{{Time: mid, Input: 300, Output: 30}},
	)
	base := startSite(t, "MAGPIE_URL="+stub.URL, "MAGPIE_WEB_KEY=k-test", "FEED_TTL=1s")

	before := fetchStats(t, base)
	if before.Tokens == nil {
		t.Fatal("first fetch: tokens must be present")
	}

	stub.down.Store(true)
	time.Sleep(1500 * time.Millisecond)

	after := fetchStats(t, base)
	if after.Tokens == nil {
		t.Fatal("magpie down within 10 min: last good tokens must still be served")
	}
	if after.Tokens.Today != before.Tokens.Today {
		t.Errorf("stale today = %+v, want %+v", after.Tokens.Today, before.Tokens.Today)
	}
}

func TestHealthzDoesNotCallMagpie(t *testing.T) {
	stub := newMagpieStub(t, "k-test", nil, nil)
	base := startSite(t, "MAGPIE_URL="+stub.URL, "MAGPIE_WEB_KEY=k-test")

	before := stub.hits.Load()
	code, body := get(t, base+"/healthz")
	if code != http.StatusOK || body != "ok" {
		t.Errorf("healthz = %d %q", code, body)
	}
	if after := stub.hits.Load(); after != before {
		t.Errorf("healthz reached magpie %d times", after-before)
	}
}

func TestMagpieURLWithoutKeyRefusesToStart(t *testing.T) {
	cmd := exec.Command(binPath)
	cmd.Dir = t.TempDir()
	cmd.Env = append(siteEnv(), "LISTEN_ADDR="+freeAddr(t), "MAGPIE_URL=http://127.0.0.1:1")
	out, err := cmd.CombinedOutput()
	if err == nil {
		t.Fatalf("expected a non-zero exit; output:\n%s", out)
	}
	if !strings.Contains(string(out), "MAGPIE_WEB_KEY") {
		t.Errorf("error should name MAGPIE_WEB_KEY; output:\n%s", out)
	}
}

func TestGatusServesUptime(t *testing.T) {
	stub := newGatusStub(t)
	base := startSite(t, "GATUS_URL="+stub.URL)

	stats := fetchStats(t, base)
	if stats.Status == nil || stats.Status.Uptime == nil {
		t.Fatal("gatus answering: status.uptime must be present")
	}
	eps := stats.Status.Uptime.Endpoints
	if len(eps) != 3 {
		t.Fatalf("endpoints = %d, want 3", len(eps))
	}
	byName := make(map[string]int, len(eps))
	for i, e := range eps {
		byName[e.Name] = i
	}
	if i, ok := byName["Gatus"]; !ok {
		t.Fatal("Gatus endpoint missing")
	} else if e := eps[i]; !e.Known || !e.Up || e.Uptime24h == nil || e.Uptime7d == nil ||
		*e.Uptime24h < 99.989 || *e.Uptime24h > 99.991 || *e.Uptime7d < 99.899 || *e.Uptime7d > 99.901 {
		t.Errorf("Gatus = %+v, want known up with 99.99%%/99.90%%", e)
	} else if n := len(e.Results); n != 50 || !e.Results[0].Up {
		t.Errorf("Gatus history = %d results starting up=%v, want the newest 50, all up", n, n > 0 && e.Results[0].Up)
	}
	if i, ok := byName["Paseo daemon"]; !ok {
		t.Fatal("Paseo daemon endpoint missing")
	} else if e := eps[i]; !e.Known || e.Up {
		t.Errorf("Paseo daemon = %+v, want known down", e)
	} else if n := len(e.Results); n != 3 || e.Results[n-1].Up {
		t.Errorf("Paseo daemon history = %+v, want 3 results ending down", e.Results)
	}
	if stub.hits.Load() == 0 {
		t.Error("gatus was never queried")
	}

	_, page := get(t, base+"/")
	for _, want := range []string{`id="status"`, `href="#status"`, "99.99%", "Paseo daemon", "down", "12ms",
		`class="useg up"`, `class="useg down"`, `class="useg none"`, "50 of 50 checks up", "2 of 3 checks up", "HTTP 503"} {
		if !strings.Contains(page, want) {
			t.Errorf("page missing %q", want)
		}
	}
	bars := regexp.MustCompile(`(?s)<div class="ubar"[^>]*>(.*?)</div>`).FindAllStringSubmatch(page, -1)
	if len(bars) != 3 {
		t.Fatalf("uptime bars = %d, want 3", len(bars))
	}
	for _, b := range bars {
		if n := strings.Count(b[1], `class="useg `); n != 50 {
			t.Errorf("uptime bar has %d segments, want 50", n)
		}
	}
	if strings.Contains(page, "endpoint not found") {
		t.Error("page leaked a gatus error")
	}
}

func TestPrometheusServesProbes(t *testing.T) {
	stub := newPrometheusStub(t)
	github := newGitHubStub(t, latestRev)
	base := startSite(t, "PROMETHEUS_URL="+stub.URL, "GITHUB_API_URL="+github.URL)

	stats := fetchStats(t, base)
	if stats.Status == nil || stats.Status.Probes == nil {
		t.Fatal("prometheus answering: status.probes must be present")
	}
	systems := stats.Status.Probes.Systems
	if len(systems) != 3 {
		t.Fatalf("systems = %d, want 3", len(systems))
	}
	if systems[0].Name != "asymmetry" || systems[1].Name != "edge" || systems[2].Name != "neko-sphere" {
		t.Errorf("systems = %+v, want sorted asymmetry, edge, neko-sphere", systems)
	}
	byName := make(map[string]int, len(systems))
	for i, s := range systems {
		byName[s.Name] = i
	}
	edge := systems[byName["edge"]]
	if edge.Status != "up" || edge.CPU == nil || *edge.CPU < 12.39 || *edge.CPU > 12.41 {
		t.Errorf("edge = %+v, want up with 12.4%% CPU", edge)
	}
	if edge.Revision != latestRev || edge.UpdatedAt != "2026-10-23T14:00:00Z" || edge.UpToDate == nil || !*edge.UpToDate {
		t.Errorf("edge = %+v, want latest revision activated at 14:00 UTC", edge)
	}
	if n := len(edge.CPUHistory); n != 3 || edge.CPUHistory[n-1] < 12.39 {
		t.Errorf("edge CPU history = %+v, want 3 samples ending at 12.4", edge.CPUHistory)
	}
	asymmetry := systems[byName["asymmetry"]]
	if asymmetry.Status != "up" || asymmetry.CPU != nil || asymmetry.Revision != oldRev ||
		asymmetry.UpdatedAt != "2026-10-23T13:00:00Z" ||
		asymmetry.UpToDate == nil || *asymmetry.UpToDate {
		t.Errorf("asymmetry = %+v, want up on the old revision at 13:00 UTC", asymmetry)
	}
	neko := systems[byName["neko-sphere"]]
	if neko.Status != "down" || neko.CPU != nil || len(neko.CPUHistory) != 0 ||
		neko.Revision != "" || neko.UpdatedAt != "" || neko.UpToDate != nil {
		t.Errorf("neko-sphere = %+v, want down with no live or version metrics", neko)
	}
	if stub.hits.Load() == 0 {
		t.Error("prometheus was never queried")
	}
	if github.hits.Load() == 0 {
		t.Error("github was never queried")
	}

	_, page := get(t, base+"/")
	for _, want := range []string{`id="status"`, `href="#status"`, "neko-sphere", "12d 4h", "4h 20m", "12%", "38%", "62%", "down",
		"version", "last update", "abcdef1", "1234567", "2026-10-23 22:00", "2026-10-23 21:00",
		`class="vtag up-to-date"`, `class="vtag outdated"`,
		`<li class="metric cpu">`, `style="width: 12.4%"`, "no history"} {
		if !strings.Contains(page, want) {
			t.Errorf("page missing %q", want)
		}
	}
	if n := strings.Count(page, `<svg class="sparkline"`); n != 3 {
		t.Errorf("sparklines = %d, want 3 for edge and none for the others", n)
	}
	for _, banned := range []string{"95%", "91%", "88%", "3h 0m"} {
		if strings.Contains(page, banned) {
			t.Errorf("page shows stale metric %q for a down target", banned)
		}
	}
}

func TestGitHubOutageKeepsProbesWithUnknownVersion(t *testing.T) {
	stub := newPrometheusStub(t)
	github := newGitHubStub(t, latestRev)
	github.down.Store(true)
	base := startSite(t, "PROMETHEUS_URL="+stub.URL, "GITHUB_API_URL="+github.URL)

	stats := fetchStats(t, base)
	if stats.Status == nil || stats.Status.Probes == nil {
		t.Fatal("github down: probes must still be present")
	}
	byName := make(map[string]int, len(stats.Status.Probes.Systems))
	for i, s := range stats.Status.Probes.Systems {
		byName[s.Name] = i
	}
	edge := stats.Status.Probes.Systems[byName["edge"]]
	if edge.Revision != latestRev || edge.UpToDate != nil {
		t.Errorf("edge = %+v, want its revision with unknown up-to-date state", edge)
	}

	_, page := get(t, base+"/")
	if !strings.Contains(page, `class="vtag unknown"`) {
		t.Error("page missing the unknown version badge")
	}
	for _, banned := range []string{`class="vtag up-to-date"`, `class="vtag outdated"`} {
		if strings.Contains(page, banned) {
			t.Errorf("page claims %q while github is down", banned)
		}
	}
	if github.hits.Load() == 0 {
		t.Error("github was never queried")
	}
}

func TestPrometheusErrorDegradesToNoProbes(t *testing.T) {
	stub := newPrometheusStub(t)
	stub.down.Store(true)
	github := newGitHubStub(t, latestRev)
	base := startSite(t, "PROMETHEUS_URL="+stub.URL, "GITHUB_API_URL="+github.URL, "FEED_TTL=1s")

	if stats := fetchStats(t, base); stats.Status != nil {
		t.Errorf("prometheus down: status = %+v, want null", stats.Status)
	}
	_, page := get(t, base+"/")
	if strings.Contains(page, `id="status"`) {
		t.Error("prometheus down: page must not render the Status panel")
	}
}

func TestStatusLastGoodServedDuringOutage(t *testing.T) {
	gatus := newGatusStub(t)
	prometheus := newPrometheusStub(t)
	github := newGitHubStub(t, latestRev)
	base := startSite(t,
		"GATUS_URL="+gatus.URL,
		"PROMETHEUS_URL="+prometheus.URL,
		"GITHUB_API_URL="+github.URL,
		"FEED_TTL=1s")

	before := fetchStats(t, base)
	if before.Status == nil || before.Status.Uptime == nil || before.Status.Probes == nil {
		t.Fatal("first fetch: both status halves must be present")
	}

	gatus.down.Store(true)
	prometheus.down.Store(true)
	time.Sleep(1500 * time.Millisecond)

	after := fetchStats(t, base)
	if after.Status == nil || after.Status.Uptime == nil || after.Status.Probes == nil {
		t.Fatalf("upstreams down within 10 min: last good status must still be served; got %+v", after.Status)
	}
	if len(after.Status.Uptime.Endpoints) != len(before.Status.Uptime.Endpoints) ||
		len(after.Status.Probes.Systems) != len(before.Status.Probes.Systems) {
		t.Errorf("stale status changed shape: before %+v after %+v", before.Status, after.Status)
	}
}
