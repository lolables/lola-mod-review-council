package schedule

import "testing"

func TestLabel(t *testing.T) {
	if got := Label(); got != "stage:schedule" {
		t.Fatalf("Label() = %q", got)
	}
}
