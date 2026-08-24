#!/usr/bin/env bash
set -euo pipefail

cd "$1"

# Five cohesive subsystems, each carrying exactly ONE planted defect, and each
# defect belonging to the lens a naive triage is MOST likely to route away from
# that subsystem. That placement is the whole point of the case: a triage pass
# that keeps the Adversary on `pkg/auth` and drops it from `web/templates`
# looks sensible and loses the XSS.
#
# | Subsystem       | Looks like        | Planted defect belongs to |
# |-----------------|-------------------|---------------------------|
# | web/templates   | presentation      | Adversary (unescaped input)|
# | deploy          | CI plumbing       | Tester (tests cannot fail) |
# | pkg/store       | internal data     | Curator (README now false) |
# | pkg/metrics     | instrumentation   | Operator (unbounded growth)|
# | pkg/legacy      | dead-ish code     | Guard (duplicated logic)   |

git -c user.name="scaffold" -c user.email="scaffold@test" branch -m main
git checkout -b feat -q

mkdir -p web/templates deploy pkg/store pkg/metrics pkg/legacy

# --- web/templates: ADVERSARY ------------------------------------------------
# Renders a user-supplied note into HTML through template.HTML, which tells
# html/template the value is already safe and disables escaping. Stored XSS.
cat >web/templates/render.go <<'EOF'
package templates

import (
	"html/template"
	"io"
)

var noteTmpl = template.Must(template.New("note").Parse(
	`<div class="note">{{.Body}}</div>`))

type Note struct {
	Body template.HTML
}

// RenderNote writes a single note as HTML.
func RenderNote(w io.Writer, userSuppliedBody string) error {
	return noteTmpl.Execute(w, Note{Body: template.HTML(userSuppliedBody)})
}
EOF

cat >web/templates/layout.go <<'EOF'
package templates

import (
	"html/template"
	"io"
)

var pageTmpl = template.Must(template.New("page").Parse(
	`<!doctype html><html><head><title>{{.Title}}</title></head><body>{{.Body}}</body></html>`))

type Page struct {
	Title string
	Body  template.HTML
}

// RenderPage writes a full page around already-rendered body HTML.
func RenderPage(w io.Writer, title string, body template.HTML) error {
	return pageTmpl.Execute(w, Page{Title: title, Body: body})
}
EOF

# --- deploy: TESTER ----------------------------------------------------------
# The test step cannot fail the build: `|| true` swallows a non-zero go test.
# Every subsequent red test is invisible, and the badge stays green.
cat >deploy/ci.yml <<'EOF'
name: build
on: [push]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-go@v5
        with:
          go-version: "1.22"
      - name: build
        run: go build ./...
      - name: test
        run: go test ./... || true
EOF

cat >deploy/Dockerfile <<'EOF'
FROM golang:1.22-alpine AS build
WORKDIR /src
COPY . .
RUN go build -o /out/ledger .

FROM alpine:3.20
COPY --from=build /out/ledger /usr/local/bin/ledger
USER 65532:65532
ENTRYPOINT ["/usr/local/bin/ledger"]
EOF

# --- pkg/store: CURATOR ------------------------------------------------------
# Purge permanently removes records. The README still promises, in as many
# words, that a record is never removed. The code is correct; the documentation
# is now false, and only the Curator is looking for that.
cat >pkg/store/store.go <<'EOF'
package store

import "sync"

type Record struct {
	ID   string
	Body string
}

type Store struct {
	mu      sync.Mutex
	records map[string]Record
}

func New() *Store {
	return &Store{records: make(map[string]Record)}
}

func (s *Store) Append(r Record) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.records[r.ID] = r
}

func (s *Store) Get(id string) (Record, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	r, ok := s.records[id]
	return r, ok
}

// Purge permanently removes every record older than the retention window.
// Removed records cannot be recovered.
func (s *Store) Purge(keep []string) int {
	s.mu.Lock()
	defer s.mu.Unlock()
	kept := make(map[string]struct{}, len(keep))
	for _, id := range keep {
		kept[id] = struct{}{}
	}
	removed := 0
	for id := range s.records {
		if _, ok := kept[id]; !ok {
			delete(s.records, id)
			removed++
		}
	}
	return removed
}
EOF

cat >pkg/store/store_test.go <<'EOF'
package store

import "testing"

func TestAppendAndGet(t *testing.T) {
	s := New()
	s.Append(Record{ID: "a", Body: "one"})
	got, ok := s.Get("a")
	if !ok {
		t.Fatal("record a not found after Append")
	}
	if got.Body != "one" {
		t.Fatalf("body = %q, want %q", got.Body, "one")
	}
}

func TestPurgeKeepsListed(t *testing.T) {
	s := New()
	s.Append(Record{ID: "a"})
	s.Append(Record{ID: "b"})
	if n := s.Purge([]string{"a"}); n != 1 {
		t.Fatalf("purged %d, want 1", n)
	}
	if _, ok := s.Get("a"); !ok {
		t.Fatal("kept record was purged")
	}
}
EOF

# --- pkg/metrics: OPERATOR ---------------------------------------------------
# One map entry per distinct request path, never evicted. Any client can mint
# unlimited paths, so this grows without bound until the process is OOM-killed.
cat >pkg/metrics/counter.go <<'EOF'
package metrics

import "sync"

var (
	mu     sync.Mutex
	byPath = map[string]int64{}
)

// Observe records one request against the exact path it arrived on.
func Observe(path string) {
	mu.Lock()
	defer mu.Unlock()
	byPath[path]++
}

// Snapshot returns the current counts.
func Snapshot() map[string]int64 {
	mu.Lock()
	defer mu.Unlock()
	out := make(map[string]int64, len(byPath))
	for k, v := range byPath {
		out[k] = v
	}
	return out
}
EOF

cat >pkg/metrics/counter_test.go <<'EOF'
package metrics

import "testing"

func TestObserveCounts(t *testing.T) {
	Observe("/health")
	Observe("/health")
	if got := Snapshot()["/health"]; got != 2 {
		t.Fatalf("count = %d, want 2", got)
	}
}
EOF

# --- pkg/legacy: GUARD -------------------------------------------------------
# A byte-for-byte reimplementation of store.Store, reachable from nothing. The
# change claims to add a ledger; this is a second one nobody asked for.
cat >pkg/legacy/oldstore.go <<'EOF'
package legacy

import "sync"

type Record struct {
	ID   string
	Body string
}

type OldStore struct {
	mu      sync.Mutex
	records map[string]Record
}

func NewOldStore() *OldStore {
	return &OldStore{records: make(map[string]Record)}
}

func (s *OldStore) Append(r Record) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.records[r.ID] = r
}

func (s *OldStore) Get(id string) (Record, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	r, ok := s.records[id]
	return r, ok
}
EOF

cat >pkg/legacy/doc.go <<'EOF'
// Package legacy holds the pre-1.0 storage implementation.
package legacy
EOF

git -c user.name="scaffold" -c user.email="scaffold@test" add -A
git -c user.name="scaffold" -c user.email="scaffold@test" \
	commit -m "feat: add rendering, storage, metrics and deploy config" -q

git checkout main -q
