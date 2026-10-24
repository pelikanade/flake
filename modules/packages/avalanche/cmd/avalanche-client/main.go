package main

import (
	"flag"
	"log/slog"
	"os"

	"avalanche/internal/client"
)

func main() {
	slog.SetDefault(slog.New(slog.NewTextHandler(os.Stdout, nil)))

	target := flag.String("target", "", "machine to deploy")
	flag.Parse()
	if *target == "" {
		flag.Usage()
		os.Exit(2)
	}

	if err := client.Run(*target); err != nil {
		slog.Error("deployment failed", "target", *target, "error", err)
		os.Exit(1)
	}
}
