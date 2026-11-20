package accounts

import (
	"context"
	"errors"
	"strings"
)

// Account is a registered user.
type Account struct {
	Email string
	Name  string
}

var (
	// ErrDuplicate is returned by Create when the email is already taken.
	ErrDuplicate = errors.New("accounts: email already registered")
	// ErrNotFound is returned by Get when no account has the email.
	ErrNotFound = errors.New("accounts: account not found")
)

// Store persists accounts. See README.md for the contract.
type Store interface {
	Create(ctx context.Context, a Account) error
	Get(ctx context.Context, email string) (Account, error)
}

// normalizeEmail is the uniqueness key shared by every Store.
func normalizeEmail(email string) string {
	return strings.ToLower(strings.TrimSpace(email))
}
