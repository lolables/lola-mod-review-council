package audit

import "testing"

func TestLabel(t *testing.T) {
	if got := Label(); got != "stage:audit" {
		t.Fatalf("Label() = %q", got)
	}
}
