package cache

import "testing"

func TestLabel(t *testing.T) {
	if got := Label(); got != "stage:cache" {
		t.Fatalf("Label() = %q", got)
	}
}
