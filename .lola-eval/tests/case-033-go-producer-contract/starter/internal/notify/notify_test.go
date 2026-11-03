package notify

import "testing"

func TestDescribe(t *testing.T) {
	if got := New("  job ", 2).Describe(); got != "notify job x2" {
		t.Errorf("Describe() = %q", got)
	}
}

func TestValid(t *testing.T) {
	if New("", 1).Valid() || New("job", 0).Valid() {
		t.Error("Valid() accepted an empty name or a zero count")
	}
	if !New("job", 1).Valid() {
		t.Error("Valid() rejected a good item")
	}
}
