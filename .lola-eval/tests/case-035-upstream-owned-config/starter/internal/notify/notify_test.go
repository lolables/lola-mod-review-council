package notify

import "testing"

func TestLabel(t *testing.T) {
	if got := Label(); got != "stage:notify" {
		t.Fatalf("Label() = %q", got)
	}
}
