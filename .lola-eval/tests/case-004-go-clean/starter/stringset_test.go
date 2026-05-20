package stringset

import (
	"testing"
)

func TestNew(t *testing.T) {
	tests := []struct {
		name  string
		input []string
		want  int
	}{
		{"empty", nil, 0},
		{"one element", []string{"a"}, 1},
		{"duplicates collapsed", []string{"a", "b", "a"}, 2},
		{"multiple unique", []string{"x", "y", "z"}, 3},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			s := New(tc.input...)
			if got := s.Len(); got != tc.want {
				t.Errorf("New(%v).Len() = %d, want %d", tc.input, got, tc.want)
			}
		})
	}
}

func TestAddAndContains(t *testing.T) {
	s := New()
	if s.Contains("a") {
		t.Error("empty set should not contain 'a'")
	}
	s.Add("a")
	if !s.Contains("a") {
		t.Error("set should contain 'a' after Add")
	}
	s.Add("a")
	if s.Len() != 1 {
		t.Errorf("duplicate Add should not increase Len; got %d", s.Len())
	}
}

func TestRemove(t *testing.T) {
	s := New("a", "b", "c")
	s.Remove("b")
	if s.Contains("b") {
		t.Error("set should not contain 'b' after Remove")
	}
	if s.Len() != 2 {
		t.Errorf("Len after Remove = %d, want 2", s.Len())
	}
	s.Remove("nonexistent")
	if s.Len() != 2 {
		t.Error("removing nonexistent element should not change Len")
	}
}

func TestElements(t *testing.T) {
	s := New("c", "a", "b")
	got := s.Elements()
	want := []string{"a", "b", "c"}
	if len(got) != len(want) {
		t.Fatalf("Elements() length = %d, want %d", len(got), len(want))
	}
	for i, v := range got {
		if v != want[i] {
			t.Errorf("Elements()[%d] = %q, want %q", i, v, want[i])
		}
	}
}

func TestUnion(t *testing.T) {
	a := New("x", "y")
	b := New("y", "z")
	u := a.Union(b)
	if u.Len() != 3 {
		t.Errorf("Union Len = %d, want 3", u.Len())
	}
	for _, e := range []string{"x", "y", "z"} {
		if !u.Contains(e) {
			t.Errorf("Union should contain %q", e)
		}
	}
}

func TestIntersect(t *testing.T) {
	a := New("x", "y", "z")
	b := New("y", "z", "w")
	inter := a.Intersect(b)
	if inter.Len() != 2 {
		t.Errorf("Intersect Len = %d, want 2", inter.Len())
	}
	if !inter.Contains("y") || !inter.Contains("z") {
		t.Error("Intersect should contain y and z")
	}
	if inter.Contains("x") || inter.Contains("w") {
		t.Error("Intersect should not contain x or w")
	}
}

func TestDifference(t *testing.T) {
	a := New("x", "y", "z")
	b := New("y", "z", "w")
	diff := a.Difference(b)
	if diff.Len() != 1 {
		t.Errorf("Difference Len = %d, want 1", diff.Len())
	}
	if !diff.Contains("x") {
		t.Error("Difference should contain x")
	}
}

func TestString(t *testing.T) {
	s := New("b", "a")
	got := s.String()
	want := "{a, b}"
	if got != want {
		t.Errorf("String() = %q, want %q", got, want)
	}
}
