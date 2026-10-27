package web

import (
	"testing"

	"github.com/pelikanade/nvirellia.im/internal/feed"
)

func TestVersionInfo(t *testing.T) {
	yes, no := true, false
	tests := []struct {
		name              string
		probe             feed.Probe
		short, state, tag string
	}{
		{"no revision", feed.Probe{}, "—", "", ""},
		{"unknown revision", feed.Probe{Revision: "unknown"}, "unknown", "unknown", "unknown"},
		{"up to date", feed.Probe{Revision: "abcdef1234567890", UpToDate: &yes}, "abcdef1", "up-to-date", "up-to-date"},
		{"outdated", feed.Probe{Revision: "1234567890abcdef", UpToDate: &no}, "1234567", "outdated", "outdated"},
		{"dirty", feed.Probe{Revision: "abcdef1234567890-dirty", UpToDate: &no}, "abcdef1-dirty", "modified", "modified"},
		{"upstream unknown", feed.Probe{Revision: "abcdef1234567890"}, "abcdef1", "unknown", "unknown"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			short, _, state, tag := versionInfo(tt.probe)
			if short != tt.short || state != tt.state || tag != tt.tag {
				t.Errorf("versionInfo(%+v) = %q, %q, %q; want %q, %q, %q",
					tt.probe, short, state, tag, tt.short, tt.state, tt.tag)
			}
		})
	}
}
