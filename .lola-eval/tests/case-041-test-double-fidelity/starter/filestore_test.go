package accounts

import (
	"context"
	"errors"
	"path/filepath"
	"testing"
)

func TestFileStoreRoundTrip(t *testing.T) {
	s := NewFileStore(filepath.Join(t.TempDir(), "accounts.json"))
	want := Account{Email: "ada@example.com", Name: "Ada"}
	if err := s.Create(context.Background(), want); err != nil {
		t.Fatalf("Create: %v", err)
	}
	got, err := s.Get(context.Background(), "ada@example.com")
	if err != nil || got != want {
		t.Fatalf("Get = %+v, %v; want %+v", got, err, want)
	}
}

func TestFileStoreDuplicateIsCaseInsensitive(t *testing.T) {
	s := NewFileStore(filepath.Join(t.TempDir(), "accounts.json"))
	ctx := context.Background()
	if err := s.Create(ctx, Account{Email: "ada@example.com", Name: "Ada"}); err != nil {
		t.Fatalf("Create: %v", err)
	}
	err := s.Create(ctx, Account{Email: " ADA@example.com ", Name: "Other"})
	if !errors.Is(err, ErrDuplicate) {
		t.Fatalf("Create duplicate = %v, want ErrDuplicate", err)
	}
}

func TestFileStoreGetUnknown(t *testing.T) {
	s := NewFileStore(filepath.Join(t.TempDir(), "accounts.json"))
	if _, err := s.Get(context.Background(), "nobody@example.com"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("Get unknown = %v, want ErrNotFound", err)
	}
}

func TestFileStoreCancelledContext(t *testing.T) {
	s := NewFileStore(filepath.Join(t.TempDir(), "accounts.json"))
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if err := s.Create(ctx, Account{Email: "ada@example.com"}); !errors.Is(err, context.Canceled) {
		t.Fatalf("Create on cancelled ctx = %v, want context.Canceled", err)
	}
	if _, err := s.Get(context.Background(), "ada@example.com"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("cancelled Create persisted an account: Get = %v", err)
	}
}
