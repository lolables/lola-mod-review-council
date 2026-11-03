package gate

import "testing"

func TestValidate(t *testing.T) {
	ok := []string{
		"lint ./...",
		"notify --channel ops",
		"archive result.json",
	}
	for _, cmd := range ok {
		if err := Validate(cmd); err != nil {
			t.Errorf("Validate(%q) = %v, want nil", cmd, err)
		}
	}

	denied := []string{
		"",
		"rm -rf /",
		"lint $(whoami)",
		"notify `id`",
	}
	for _, cmd := range denied {
		if err := Validate(cmd); err == nil {
			t.Errorf("Validate(%q): want error, got nil", cmd)
		}
	}
}
