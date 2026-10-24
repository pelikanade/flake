package main

import (
	"fmt"
	"log/slog"
	"os"

	"avalanche/internal/server"
)

func usage() {
	fmt.Fprintln(os.Stderr, "usage: avalanche-server serve|request|activate")
}

func main() {
	slog.SetDefault(slog.New(slog.NewTextHandler(os.Stdout, nil)))
	if len(os.Args) != 2 {
		usage()
		os.Exit(2)
	}

	var err error
	switch os.Args[1] {
	case "serve":
		err = server.Serve()
	case "request":
		err = server.Request()
	case "activate":
		err = server.Activate()
	default:
		usage()
		os.Exit(2)
	}

	if err != nil {
		slog.Error("avalanche-server", "error", err)
		os.Exit(1)
	}
}
