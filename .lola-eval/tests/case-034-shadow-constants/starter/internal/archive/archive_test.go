package archive

import "testing"

func TestLabel(t *testing.T) {
	if got := Label(); got != "stage:archive" {
		t.Fatalf("Label() = %q", got)
	}
}
