// Package gate decides which job steps the runner may execute.
package gate

import (
	"fmt"
	"strings"
)

// allowed is the set of binaries a job step may invoke.
var allowed = map[string]bool{
	"archive": true,
	"lint":    true,
	"notify":  true,
}

// Validate reports whether the runner may execute cmd. The first word must be
// an allowed binary, and command substitution is refused.
func Validate(cmd string) error {
	fields := strings.Fields(cmd)
	if len(fields) == 0 {
		return fmt.Errorf("empty command")
	}
	if !allowed[fields[0]] {
		return fmt.Errorf("command %q: %s is not an allowed binary", cmd, fields[0])
	}
	if strings.Contains(cmd, "$(") || strings.Contains(cmd, "`") {
		return fmt.Errorf("command %q: command substitution is not allowed", cmd)
	}
	return nil
}
