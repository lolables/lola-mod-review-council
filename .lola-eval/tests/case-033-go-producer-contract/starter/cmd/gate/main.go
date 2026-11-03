// Command gate runs job specs and writes starter specs.
package main

import (
	"fmt"
	"os"

	"example.com/gate"
	"example.com/gate/internal/newjob"
)

func main() {
	if len(os.Args) != 3 {
		fmt.Fprintln(os.Stderr, "usage: gate run FILE | gate new NAME")
		os.Exit(2)
	}
	switch os.Args[1] {
	case "run":
		text, err := os.ReadFile(os.Args[2])
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		spec, err := gate.LoadSpec(string(text))
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		cleared, err := gate.Run(spec)
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		for _, step := range cleared {
			fmt.Println(step)
		}
	case "new":
		fmt.Print(newjob.Spec(os.Args[2]))
	default:
		fmt.Fprintln(os.Stderr, "usage: gate run FILE | gate new NAME")
		os.Exit(2)
	}
}
