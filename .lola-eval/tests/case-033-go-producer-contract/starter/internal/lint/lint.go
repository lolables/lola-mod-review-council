// Package lint runs the lint binary the gate allows.
package lint

import (
	"fmt"
	"strings"
)

// Item is one unit of lint work.
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
	return fmt.Sprintf("lint %s x%d", i.Name, i.N)
}

// Valid reports whether the item has a name and a positive count.
func (i *Item) Valid() bool {
	return i.Name != "" && i.N > 0
}
