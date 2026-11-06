package envx

import "testing"

func TestLabel(t *testing.T) {
	if got := Label(); got != "stage:envx" {
		t.Fatalf("Label() = %q", got)
	}
}
