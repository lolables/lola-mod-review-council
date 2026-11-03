// Package report supports the runner's report bookkeeping.
package report

import (
	"fmt"
	"strings"
)

// Item is one unit of report work.
type Item struct {
	Name string
	N    int
}

// New returns an Item for name, trimmed of surrounding space.
func New(name string, n int) *Item {
	return &Item{Name: strings.TrimSpace(name), N: n}
}

// Describe renders the item for the runner's log.
func (i *Item) Describe() string {
	return fmt.Sprintf("report %s x%d", i.Name, i.N)
}

// Valid reports whether the item has a name and a positive count.
func (i *Item) Valid() bool {
	return i.Name != "" && i.N > 0
}
