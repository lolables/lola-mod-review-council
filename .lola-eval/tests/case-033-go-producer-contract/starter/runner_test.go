package gate

import "testing"

func TestRun(t *testing.T) {
	spec, err := LoadSpec("name: tidy\nsteps:\n  - lint ./...\n  - notify --channel ops\n")
	if err != nil {
		t.Fatal(err)
	}
	cleared, err := Run(spec)
	if err != nil || len(cleared) != 2 {
		t.Fatalf("Run = %v, %v, want 2 cleared steps", cleared, err)
	}
}

func TestRunStopsAtDeniedStep(t *testing.T) {
	spec, err := LoadSpec("name: bad\nsteps:\n  - lint ./...\n  - rm -rf /\n  - notify --channel ops\n")
	if err != nil {
		t.Fatal(err)
	}
	if cleared, err := Run(spec); err == nil || cleared != nil {
		t.Fatalf("Run = %v, %v, want an error and no cleared steps", cleared, err)
	}
}

func TestLoadSpecRejectsEmpty(t *testing.T) {
	if _, err := LoadSpec("name: x\n"); err == nil {
		t.Fatal("LoadSpec with no steps: want error, got nil")
	}
}
