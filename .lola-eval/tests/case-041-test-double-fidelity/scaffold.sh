#!/usr/bin/env bash
# scaffold.sh — create git history for case-041-test-double-fidelity.
#
# The starter's initial code becomes the first commit (handled by reset.sh).
# This script creates a `feat` branch whose single commit adds a Registrar
# service, an in-memory fakeStore for its tests, and a contract suite that
# runs against both the fake and the production FileStore.
#
# The fake is faithful to production on every axis a test double can
# drift: it rejects a cancelled context before touching state, enforces
# email uniqueness through the same normalizeEmail key, and returns the
# same ErrDuplicate / ErrNotFound sentinels. The contract suite proves it.
#
# That is the point of this canary: it is the false-positive control for
# the testing persona's "Test Double Fidelity" criterion. A review that
# sees a fake must not invent a divergence. The correct outcome is APPROVE.
set -euo pipefail
workdir="$1"
cd "$workdir"

git -c user.name="scaffold" -c user.email="scaffold@test" branch -m main
git checkout -b feat --quiet

cat >service.go <<'GO'
package accounts

import (
	"context"
	"errors"
	"fmt"
	"strings"
)

// ErrInvalid is returned by Register for a blank email or name.
var ErrInvalid = errors.New("accounts: email and name are required")

// Registrar signs users up on top of a Store.
type Registrar struct {
	store Store
}

// NewRegistrar returns a Registrar that persists to store.
func NewRegistrar(store Store) *Registrar {
	return &Registrar{store: store}
}

// Register validates and stores a new account. Store errors, including
// ErrDuplicate and context errors, are wrapped so callers can use errors.Is.
func (r *Registrar) Register(ctx context.Context, email, name string) error {
	if strings.TrimSpace(email) == "" || strings.TrimSpace(name) == "" {
		return ErrInvalid
	}
	if err := r.store.Create(ctx, Account{Email: email, Name: name}); err != nil {
		return fmt.Errorf("register %q: %w", email, err)
	}
	return nil
}
GO

cat >fake_store_test.go <<'GO'
package accounts

import (
	"context"
	"sync"
)

// fakeStore is an in-memory Store for tests. It mirrors FileStore's
// contract (see README.md): cancelled contexts fail before any state
// change, emails are unique under normalizeEmail, and the same sentinel
// errors are returned. contract_test.go runs the same suite against both.
type fakeStore struct {
	mu       sync.Mutex
	accounts map[string]Account
}

func newFakeStore() *fakeStore {
	return &fakeStore{accounts: map[string]Account{}}
}

func (f *fakeStore) Create(ctx context.Context, a Account) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	key := normalizeEmail(a.Email)
	if _, taken := f.accounts[key]; taken {
		return ErrDuplicate
	}
	f.accounts[key] = a
	return nil
}

func (f *fakeStore) Get(ctx context.Context, email string) (Account, error) {
	if err := ctx.Err(); err != nil {
		return Account{}, err
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	a, ok := f.accounts[normalizeEmail(email)]
	if !ok {
		return Account{}, ErrNotFound
	}
	return a, nil
}
GO

cat >contract_test.go <<'GO'
package accounts

import (
	"context"
	"errors"
	"path/filepath"
	"testing"
)

// runStoreContract checks the Store contract from README.md. It runs
// against the production FileStore and the test fake so the two cannot
// drift apart unnoticed.
func runStoreContract(t *testing.T, newStore func(t *testing.T) Store) {
	t.Run("duplicate email is rejected case-insensitively", func(t *testing.T) {
		s := newStore(t)
		ctx := context.Background()
		if err := s.Create(ctx, Account{Email: "ada@example.com", Name: "Ada"}); err != nil {
			t.Fatalf("Create: %v", err)
		}
		err := s.Create(ctx, Account{Email: " ADA@example.com ", Name: "Other"})
		if !errors.Is(err, ErrDuplicate) {
			t.Fatalf("Create duplicate = %v, want ErrDuplicate", err)
		}
	})

	t.Run("unknown email is ErrNotFound", func(t *testing.T) {
		s := newStore(t)
		if _, err := s.Get(context.Background(), "nobody@example.com"); !errors.Is(err, ErrNotFound) {
			t.Fatalf("Get unknown = %v, want ErrNotFound", err)
		}
	})

	t.Run("cancelled context fails and changes nothing", func(t *testing.T) {
		s := newStore(t)
		ctx, cancel := context.WithCancel(context.Background())
		cancel()
		if err := s.Create(ctx, Account{Email: "ada@example.com"}); !errors.Is(err, context.Canceled) {
			t.Fatalf("Create on cancelled ctx = %v, want context.Canceled", err)
		}
		if _, err := s.Get(ctx, "ada@example.com"); !errors.Is(err, context.Canceled) {
			t.Fatalf("Get on cancelled ctx = %v, want context.Canceled", err)
		}
		if _, err := s.Get(context.Background(), "ada@example.com"); !errors.Is(err, ErrNotFound) {
			t.Fatalf("cancelled Create persisted an account: Get = %v", err)
		}
	})
}

func TestFileStoreContract(t *testing.T) {
	runStoreContract(t, func(t *testing.T) Store {
		return NewFileStore(filepath.Join(t.TempDir(), "accounts.json"))
	})
}

func TestFakeStoreContract(t *testing.T) {
	runStoreContract(t, func(*testing.T) Store { return newFakeStore() })
}
GO

cat >service_test.go <<'GO'
package accounts

import (
	"context"
	"errors"
	"testing"
)

func TestRegisterStoresAccount(t *testing.T) {
	store := newFakeStore()
	r := NewRegistrar(store)
	if err := r.Register(context.Background(), "ada@example.com", "Ada"); err != nil {
		t.Fatalf("Register: %v", err)
	}
	got, err := store.Get(context.Background(), "ada@example.com")
	if err != nil || got.Name != "Ada" {
		t.Fatalf("Get = %+v, %v; want Name Ada", got, err)
	}
}

func TestRegisterRejectsBlankFields(t *testing.T) {
	r := NewRegistrar(newFakeStore())
	for _, tc := range []struct{ email, name string }{
		{"", "Ada"}, {"ada@example.com", ""}, {"  ", "Ada"}, {"ada@example.com", "  "},
	} {
		if err := r.Register(context.Background(), tc.email, tc.name); !errors.Is(err, ErrInvalid) {
			t.Errorf("Register(%q, %q) = %v, want ErrInvalid", tc.email, tc.name, err)
		}
	}
}

func TestRegisterDuplicateEmail(t *testing.T) {
	r := NewRegistrar(newFakeStore())
	ctx := context.Background()
	if err := r.Register(ctx, "ada@example.com", "Ada"); err != nil {
		t.Fatalf("first Register: %v", err)
	}
	if err := r.Register(ctx, "ADA@example.com", "Impostor"); !errors.Is(err, ErrDuplicate) {
		t.Fatalf("second Register = %v, want ErrDuplicate", err)
	}
}

func TestRegisterPropagatesCancelledContext(t *testing.T) {
	store := newFakeStore()
	r := NewRegistrar(store)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if err := r.Register(ctx, "ada@example.com", "Ada"); !errors.Is(err, context.Canceled) {
		t.Fatalf("Register on cancelled ctx = %v, want context.Canceled", err)
	}
	if _, err := store.Get(context.Background(), "ada@example.com"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("cancelled Register persisted an account: Get = %v", err)
	}
}
GO

git -c user.name="scaffold" -c user.email="scaffold@test" add service.go fake_store_test.go contract_test.go service_test.go
git -c user.name="scaffold" -c user.email="scaffold@test" -c commit.gpgsign=false \
	commit --quiet -m "Add Registrar service with a contract-tested fake store"
