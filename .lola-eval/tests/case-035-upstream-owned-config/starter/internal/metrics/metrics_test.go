package metrics

import "testing"

func TestLabel(t *testing.T) {
	if got := Label(); got != "stage:metrics" {
		t.Fatalf("Label() = %q", got)
	}
}
