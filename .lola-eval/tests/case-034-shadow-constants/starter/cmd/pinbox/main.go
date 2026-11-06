// Command pinbox prints the pinned lintkit version for CI.
package main

import (
	"fmt"
	"os"

	"example.com/pinbox/pins"
)

func main() {
	tools, err := pins.Read("pins/tools.lock")
	if err != nil {
		fmt.Fprintln(os.Stderr, "pinbox:", err)
		os.Exit(1)
	}
	fmt.Println("lintkit", tools["lintkit"])
}
