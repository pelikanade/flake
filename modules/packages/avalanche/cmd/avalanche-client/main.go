package main

import (
	"log/slog"
	"os"

	"avalanche/internal/client"
)

func main() {
	slog.SetDefault(slog.New(slog.NewTextHandler(os.Stdout, nil)))
	if err := client.Run(); err != nil {
		slog.Error("deployment failed", "error", err)
		os.Exit(1)
	}
}
