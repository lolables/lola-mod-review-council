package accounts

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"sync"
)

// FileStore is the production Store: all accounts live in one JSON file.
type FileStore struct {
	mu   sync.Mutex
	path string
}

// NewFileStore returns a FileStore backed by path. The file is created on
// the first successful Create.
func NewFileStore(path string) *FileStore {
	return &FileStore{path: path}
}

func (s *FileStore) load() (map[string]Account, error) {
	data, err := os.ReadFile(s.path)
	if errors.Is(err, os.ErrNotExist) {
		return map[string]Account{}, nil
	}
	if err != nil {
		return nil, fmt.Errorf("accounts: read %s: %w", s.path, err)
	}
	accounts := map[string]Account{}
	if err := json.Unmarshal(data, &accounts); err != nil {
		return nil, fmt.Errorf("accounts: decode %s: %w", s.path, err)
	}
	return accounts, nil
}

// Create stores a. It returns ErrDuplicate if the normalized email exists.
func (s *FileStore) Create(ctx context.Context, a Account) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	accounts, err := s.load()
	if err != nil {
		return err
	}
	key := normalizeEmail(a.Email)
	if _, taken := accounts[key]; taken {
		return ErrDuplicate
	}
	accounts[key] = a
	data, err := json.Marshal(accounts)
	if err != nil {
		return fmt.Errorf("accounts: encode: %w", err)
	}
	if err := os.WriteFile(s.path, data, 0o600); err != nil {
		return fmt.Errorf("accounts: write %s: %w", s.path, err)
	}
	return nil
}

// Get returns the account with the given email, or ErrNotFound.
func (s *FileStore) Get(ctx context.Context, email string) (Account, error) {
	if err := ctx.Err(); err != nil {
		return Account{}, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	accounts, err := s.load()
	if err != nil {
		return Account{}, err
	}
	a, ok := accounts[normalizeEmail(email)]
	if !ok {
		return Account{}, ErrNotFound
	}
	return a, nil
}
