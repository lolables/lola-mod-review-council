package pins

import (
	"os"
	"path/filepath"
	"testing"
)

func TestRead(t *testing.T) {
	path := filepath.Join(t.TempDir(), "x.lock")
	if err := os.WriteFile(path, []byte("# c\n\nalpha 0.0.1\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	got, err := Read(path)
	if err != nil || got["alpha"] != "0.0.1" {
		t.Fatalf("Read = %v, %v", got, err)
	}
}

func TestReadRejectsBareKey(t *testing.T) {
	path := filepath.Join(t.TempDir(), "x.lock")
	if err := os.WriteFile(path, []byte("lonely\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := Read(path); err == nil {
		t.Fatal("want error for a line with no value")
	}
}
