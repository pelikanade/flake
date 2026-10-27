package main

import (
	"context"
	"errors"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"
)

func main() {
	if err := serve(); err != nil {
		log.Print(err)
		os.Exit(1)
	}
}

func serve() error {
	if len(os.Args) != 2 {
		return fmt.Errorf("usage: freezer <config.yaml>")
	}
	cfg, err := LoadConfig(os.Args[1])
	if err != nil {
		return err
	}
	if len(cfg.Repositories) == 0 {
		return fmt.Errorf("at least one public repository must be registered")
	}
	if cfg.GitHubToken == "" {
		return fmt.Errorf("github_token or GITHUB_TOKEN is required for commit statuses")
	}
	app, err := NewServer(cfg)
	if err != nil {
		return err
	}
	defer app.Close()
	server := &http.Server{Addr: cfg.Listen, Handler: app.Handler(), ReadHeaderTimeout: 10 * time.Second, IdleTimeout: time.Minute}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	finished := make(chan error, 1)
	go func() { log.Printf("freezer listening on %s", cfg.Listen); finished <- server.ListenAndServe() }()
	select {
	case err := <-finished:
		if errors.Is(err, http.ErrServerClosed) {
			return nil
		}
		return err
	case <-ctx.Done():
		app.cancel()
		shutdown, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if err := server.Shutdown(shutdown); err != nil {
			server.Close()
			return err
		}
		return nil
	}
}
