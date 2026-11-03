package envx

import "os"

// Expand resolves $VAR and ${VAR} references in the runner's own config text
// from the process environment. It is not applied to job steps.
func Expand(text string) string {
	return os.ExpandEnv(text)
}
