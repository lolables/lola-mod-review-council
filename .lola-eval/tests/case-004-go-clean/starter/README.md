# stringset

An unordered set of strings backed by a map.

## Usage

```go
s := stringset.New("a", "b", "c")
s.Add("d")
s.Remove("a")
fmt.Println(s.Contains("b")) // true
fmt.Println(s)                // {b, c, d}
```

## API

- `New(elems ...string) *Set` — create a set with initial elements
- `Add(elem string)` — add an element
- `Remove(elem string)` — remove an element
- `Contains(elem string) bool` — membership test
- `Len() int` — cardinality
- `Elements() []string` — sorted slice of elements
- `Union(other *Set) *Set` — set union
- `Intersect(other *Set) *Set` — set intersection
- `Difference(other *Set) *Set` — set difference
- `String() string` — human-readable representation
