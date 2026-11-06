package tenant

import "testing"

func TestLabel(t *testing.T) {
	if got := Label(); got != "stage:tenant" {
		t.Fatalf("Label() = %q", got)
	}
}
