// Command keyrelay is a local relay that holds API keys for sandboxed agents.
package main

import (
	"fmt"
	"os"

	"example.com/keyrelay/internal/config"
)

func main() {
	cfg, err := config.Load()
	if err != nil {
		fmt.Fprintln(os.Stderr, "keyrelay:", err)
		os.Exit(1)
	}
	fmt.Println("listening on", cfg.Listen)
}
