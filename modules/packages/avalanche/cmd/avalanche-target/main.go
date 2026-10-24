package main

import (
	"fmt"
	"os"

	"avalanche/internal/avalanche"
)

func usage() {
	fmt.Fprintln(os.Stderr, "usage: avalanche-target serve|request|activate <nonce> <store-path> <dir> <hostname>")
}

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(2)
	}

	var err error
	switch os.Args[1] {
	case "serve":
		err = avalanche.Serve()
	case "request":
		err = avalanche.Request()
	case "activate":
		if len(os.Args) != 6 {
			usage()
			os.Exit(2)
		}
		err = avalanche.Activate(os.Args[2], os.Args[3], os.Args[4], os.Args[5])
	default:
		usage()
		os.Exit(2)
	}

	if err != nil {
		fmt.Fprintln(os.Stderr, "avalanche-target:", err)
		os.Exit(1)
	}
}
