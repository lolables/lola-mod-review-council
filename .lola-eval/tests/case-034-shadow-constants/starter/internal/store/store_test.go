package store

import "testing"

func TestLabel(t *testing.T) {
	if got := Label(); got != "stage:store" {
		t.Fatalf("Label() = %q", got)
	}
}
