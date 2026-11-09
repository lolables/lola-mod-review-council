package config

import (
	"os"
	"path/filepath"
	"testing"
)

func TestLoadPrefersConfigHome(t *testing.T) {
	home, sys := t.TempDir(), t.TempDir()
	t.Setenv("KEYRELAY_CONFIG", "")
	t.Setenv("XDG_CONFIG_HOME", home)
	t.Setenv("XDG_CONFIG_DIRS", sys)
	write(t, filepath.Join(sys, appName, "config.json"), `{"listen":"0.0.0.0:1"}`)
	write(t, filepath.Join(home, appName, "config.json"), `{"listen":"127.0.0.1:2"}`)
	c, err := Load()
	if err != nil || c.Listen != "127.0.0.1:2" {
		t.Fatalf("Load() = %+v, %v", c, err)
	}
}

func TestLoadDefaultsWhenNoFile(t *testing.T) {
	t.Setenv("KEYRELAY_CONFIG", "")
	t.Setenv("XDG_CONFIG_HOME", t.TempDir())
	t.Setenv("XDG_CONFIG_DIRS", t.TempDir())
	c, err := Load()
	if err != nil || c != Default() {
		t.Fatalf("Load() = %+v, %v", c, err)
	}
}

func TestLoadExplicitFileMustExist(t *testing.T) {
	t.Setenv("KEYRELAY_CONFIG", filepath.Join(t.TempDir(), "missing.json"))
	if _, err := Load(); err == nil {
		t.Fatal("missing $KEYRELAY_CONFIG accepted")
	}
}

func TestLoadRejectsBadJSON(t *testing.T) {
	p := filepath.Join(t.TempDir(), "config.json")
	write(t, p, `{"listen":`)
	t.Setenv("KEYRELAY_CONFIG", p)
	if _, err := Load(); err == nil {
		t.Fatal("malformed config accepted")
	}
}

func write(t *testing.T, path, body string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
}
