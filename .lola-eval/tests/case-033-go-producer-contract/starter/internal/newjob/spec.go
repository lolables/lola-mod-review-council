// Package newjob renders the starter spec that `gate new` writes.
package newjob

import (
	"fmt"
	"strings"
)

// Spec renders the starter spec for a new job called name. The steps lint the
// tree, archive the result into the job's output directory, and tell the ops
// channel.
func Spec(name string) string {
	var b strings.Builder
	fmt.Fprintf(&b, "name: %s\n", name)
	b.WriteString("steps:\n")
	b.WriteString("  - lint ./...\n")
	b.WriteString("  - archive \"$OUT_DIR/result.json\"\n")
	b.WriteString("  - notify --channel ops\n")
	return b.String()
}
