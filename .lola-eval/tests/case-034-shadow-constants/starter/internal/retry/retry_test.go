package retry

import "testing"

func TestLabel(t *testing.T) {
	if got := Label(); got != "stage:retry" {
		t.Fatalf("Label() = %q", got)
	}
}
