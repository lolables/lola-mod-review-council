// Package stringset provides an unordered set of strings backed by a map.
//
// A Set is safe for concurrent reads but not concurrent writes.
// For concurrent access, the caller must synchronize externally.
package stringset

import (
	"fmt"
	"sort"
	"strings"
)

// Set is an unordered collection of unique strings.
type Set struct {
	m map[string]struct{}
}

// New returns a Set containing the given elements.
func New(elems ...string) *Set {
	s := &Set{m: make(map[string]struct{}, len(elems))}
	for _, e := range elems {
		s.m[e] = struct{}{}
	}
	return s
}

// Add inserts elem into the set. If elem is already present, Add is a no-op.
func (s *Set) Add(elem string) {
	s.m[elem] = struct{}{}
}

// Remove deletes elem from the set. If elem is not present, Remove is a no-op.
func (s *Set) Remove(elem string) {
	delete(s.m, elem)
}

// Contains reports whether elem is in the set.
func (s *Set) Contains(elem string) bool {
	_, ok := s.m[elem]
	return ok
}

// Len returns the number of elements in the set.
func (s *Set) Len() int {
	return len(s.m)
}

// Elements returns the set's elements in sorted order.
func (s *Set) Elements() []string {
	elems := make([]string, 0, len(s.m))
	for e := range s.m {
		elems = append(elems, e)
	}
	sort.Strings(elems)
	return elems
}

// Union returns a new set containing all elements from both s and other.
func (s *Set) Union(other *Set) *Set {
	result := New(s.Elements()...)
	for e := range other.m {
		result.Add(e)
	}
	return result
}

// Intersect returns a new set containing only elements present in both s and other.
func (s *Set) Intersect(other *Set) *Set {
	result := New()
	for e := range s.m {
		if other.Contains(e) {
			result.Add(e)
		}
	}
	return result
}

// Difference returns a new set containing elements in s that are not in other.
func (s *Set) Difference(other *Set) *Set {
	result := New()
	for e := range s.m {
		if !other.Contains(e) {
			result.Add(e)
		}
	}
	return result
}

// String returns a human-readable representation like {a, b, c}.
func (s *Set) String() string {
	elems := s.Elements()
	return fmt.Sprintf("{%s}", strings.Join(elems, ", "))
}
