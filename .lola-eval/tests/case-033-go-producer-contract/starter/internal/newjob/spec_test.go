package newjob

import (
	"testing"

	"example.com/gate"
)

func TestSpecParses(t *testing.T) {
	spec, err := gate.LoadSpec(Spec("nightly"))
	if err != nil {
		t.Fatalf("LoadSpec(Spec) = %v", err)
	}
	if spec.Name != "nightly" || len(spec.Steps) != 3 {
		t.Fatalf("Spec = %+v, want name nightly with 3 steps", spec)
	}
}
