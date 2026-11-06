package report

import "testing"

func TestLabel(t *testing.T) {
	if got := Label(); got != "stage:report" {
		t.Fatalf("Label() = %q", got)
	}
}
