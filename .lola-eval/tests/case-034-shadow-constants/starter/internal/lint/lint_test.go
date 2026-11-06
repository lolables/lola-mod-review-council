package lint

import "testing"

func TestLabel(t *testing.T) {
	if got := Label(); got != "stage:lint" {
		t.Fatalf("Label() = %q", got)
	}
}
