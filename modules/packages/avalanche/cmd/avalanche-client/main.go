package main

import (
	"flag"
	"fmt"
	"os"

	"avalanche/internal/avalanche"
)

func main() {
	flake := flag.String("flake", ".", "flake path")
	config := flag.String("config", "/etc/avalanche/client.conf", "client configuration")
	dryRun := flag.Bool("dry-run", false, "print targets without building or triggering")
	flag.Parse()

	if err := avalanche.RunClient(*config, *flake, *dryRun); err != nil {
		fmt.Fprintln(os.Stderr, "avalanche-client:", err)
		os.Exit(1)
	}
}
