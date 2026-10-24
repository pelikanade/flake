package protocol

// Event is one line of the deployment stream. The server sends log and phase
// events while the activation runs, then exactly one done event.
type Event struct {
	Type  string `json:"type"`
	Line  string `json:"line,omitempty"`
	Phase string `json:"phase,omitempty"`
	OK    bool   `json:"ok,omitempty"`
	Error string `json:"error,omitempty"`
}
