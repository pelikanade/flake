package server

import (
	"bytes"
	"crypto/subtle"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/google/uuid"

	"avalanche/internal/deploy"
	"avalanche/internal/protocol"
)

// Serve runs the non-root HTTP trigger on loopback.
func Serve() error {
	cfg, err := LoadConfig()
	if err != nil {
		return err
	}
	token, err := deploy.ReadToken(cfg.TokenFile)
	if err != nil {
		return err
	}

	gin.SetMode(gin.ReleaseMode)
	router := gin.New()
	router.Use(gin.Recovery())
	router.POST("/deploy", requireToken(token), deployHandler(cfg))

	addr := fmt.Sprintf("127.0.0.1:%d", cfg.Port)
	slog.Info("deployment server listening", "addr", addr)
	httpServer := &http.Server{
		Addr:              addr,
		Handler:           router,
		ReadHeaderTimeout: 10 * time.Second,
		IdleTimeout:       2 * time.Minute,
	}
	return httpServer.ListenAndServe()
}

func requireToken(token string) gin.HandlerFunc {
	expected := "Bearer " + token
	return func(c *gin.Context) {
		if subtle.ConstantTimeCompare([]byte(c.GetHeader("Authorization")), []byte(expected)) != 1 {
			c.AbortWithStatusJSON(http.StatusForbidden, gin.H{"error": "forbidden"})
			return
		}
		c.Next()
	}
}

func deployHandler(cfg *Config) gin.HandlerFunc {
	return func(c *gin.Context) {
		c.Request.Body = http.MaxBytesReader(c.Writer, c.Request.Body, 4096)
		body, err := c.GetRawData()
		if err != nil {
			c.String(http.StatusBadRequest, "invalid body")
			return
		}

		storePath := strings.TrimSpace(string(body))
		if !deploy.ValidStorePath(cfg.Hostname, storePath) {
			c.String(http.StatusBadRequest, "invalid store path")
			return
		}

		nonce := uuid.NewString()
		if err := deploy.WriteRequest(cfg.Dir, nonce, storePath); err != nil {
			c.String(http.StatusInternalServerError, "cannot write request")
			return
		}

		slog.Info("deployment requested", "nonce", nonce, "store_path", storePath)
		streamDeploy(c.Writer, cfg, nonce)
	}
}

// streamDeploy follows the activation log and status files and relays them as
// NDJSON events until the transient unit publishes its result.
func streamDeploy(w http.ResponseWriter, cfg *Config, nonce string) {
	flusher, ok := w.(http.Flusher)
	if !ok {
		http.Error(w, "streaming unsupported", http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "application/x-ndjson")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(http.StatusOK)

	encoder := json.NewEncoder(w)
	send := func(event protocol.Event) bool {
		if err := encoder.Encode(event); err != nil {
			return false
		}
		flusher.Flush()
		return true
	}

	logPath := filepath.Join(cfg.Dir, "log-"+nonce)
	statusPath := filepath.Join(cfg.Dir, "status-"+nonce)
	resultPath := filepath.Join(cfg.Dir, "result-"+nonce)
	defer func() {
		_ = os.Remove(logPath)
		_ = os.Remove(statusPath)
		_ = os.Remove(resultPath)
	}()

	if !send(protocol.Event{Type: "phase", Phase: "queued"}) {
		return
	}

	var logFile *os.File
	var pending []byte
	readLog := func() bool {
		if logFile == nil {
			file, err := os.Open(logPath)
			if err != nil {
				return true
			}
			logFile = file
		}

		buffer := make([]byte, 4096)
		for {
			n, err := logFile.Read(buffer)
			if n > 0 {
				pending = append(pending, buffer[:n]...)
				for {
					index := bytes.IndexByte(pending, '\n')
					if index < 0 {
						break
					}
					line := string(pending[:index])
					pending = pending[index+1:]
					if !send(protocol.Event{Type: "log", Line: line}) {
						return false
					}
				}
			}
			if err != nil {
				break
			}
		}
		return true
	}
	defer func() {
		if logFile != nil {
			_ = logFile.Close()
		}
	}()

	lastPhase := ""
	deadline := time.Now().Add(cfg.Timeout)
	for {
		if !readLog() {
			return
		}

		if data, err := os.ReadFile(statusPath); err == nil {
			phase := strings.TrimSpace(string(data))
			if phase != "" && phase != lastPhase {
				lastPhase = phase
				if !send(protocol.Event{Type: "phase", Phase: phase}) {
					return
				}
			}
		}

		if data, err := os.ReadFile(resultPath); err == nil {
			if !readLog() {
				return
			}
			if len(pending) > 0 {
				if !send(protocol.Event{Type: "log", Line: string(pending)}) {
					return
				}
				pending = nil
			}
			if strings.TrimSpace(string(data)) == "ok" {
				send(protocol.Event{Type: "done", OK: true})
			} else {
				send(protocol.Event{Type: "done", Error: "deployment failed"})
			}
			return
		}

		if time.Now().After(deadline) {
			send(protocol.Event{Type: "done", Error: "deployment timed out"})
			return
		}
		time.Sleep(200 * time.Millisecond)
	}
}
