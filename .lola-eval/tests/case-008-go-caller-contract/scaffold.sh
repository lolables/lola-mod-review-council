#!/usr/bin/env bash
# scaffold.sh — create git history for case-008-go-caller-contract.
#
# The starter's initial code becomes the first commit (handled by reset.sh).
# In it Lookup in quota.go returns the default quota for a tenant that has
# none configured, and Allow, near the bottom of the same file, dereferences
# Lookup's result unconditionally.
#
# This script creates a `feat` branch whose single commit changes Lookup's
# contract: it now returns nil for an unconfigured tenant, defaultQuota is
# deleted, and the Lookup(unknown) test expects nil, so the change looks
# complete and `go test` passes. Allow is untouched and sits outside every
# diff hunk, context lines included, yet it now panics with a nil
# dereference on any request from an unconfigured tenant: a crash that any
# caller can trigger.
#
# The defect is in unchanged lines of a changed file. A reviewer working from
# the diff alone sees a tidy contract change; it finds the panic only by
# reading the rest of quota.go for Lookup's callers.
set -euo pipefail
workdir="$1"
cd "$workdir"

git -c user.name="scaffold" -c user.email="scaffold@test" branch -m main
git checkout -b feat --quiet

cat >quota.go <<'GO'
// Package quota tracks how many requests each tenant may make per window.
package quota

import (
	"fmt"
	"regexp"
	"sort"
	"strconv"
	"strings"
)

// Quota is the number of requests a tenant may make per window.
type Quota struct {
	Tenant string
	Limit  int
}

var quotas = map[string]Quota{
	"acme":    {Tenant: "acme", Limit: 1000},
	"globex":  {Tenant: "globex", Limit: 250},
	"initech": {Tenant: "initech", Limit: 50},
}

// Lookup returns the quota for tenant. It returns nil when the tenant has no
// quota configured, so callers can tell an unconfigured tenant from one on
// the default quota.
func Lookup(tenant string) *Quota {
	if q, ok := quotas[tenant]; ok {
		return &q
	}
	return nil
}

var tenantName = regexp.MustCompile(`^[a-z][a-z0-9-]{1,31}$`)

// validTenant reports whether name is a well-formed tenant identifier.
func validTenant(name string) bool {
	return tenantName.MatchString(name)
}

// formatLimit renders a limit for the admin listing, e.g. "1.5k/window".
func formatLimit(limit int) string {
	if limit >= 1000 {
		return strconv.FormatFloat(float64(limit)/1000, 'f', -1, 64) + "k/window"
	}
	return strconv.Itoa(limit) + "/window"
}

// ParseUsage parses one "tenant=used" line from the gateway's usage report.
func ParseUsage(line string) (string, int, error) {
	tenant, count, ok := strings.Cut(strings.TrimSpace(line), "=")
	if !ok {
		return "", 0, fmt.Errorf("usage line %q: missing '='", line)
	}
	if !validTenant(tenant) {
		return "", 0, fmt.Errorf("usage line %q: invalid tenant %q", line, tenant)
	}
	used, err := strconv.Atoi(count)
	if err != nil || used < 0 {
		return "", 0, fmt.Errorf("usage line %q: invalid count %q", line, count)
	}
	return tenant, used, nil
}

// Summary renders one line per configured tenant, sorted by name.
func Summary() string {
	names := make([]string, 0, len(quotas))
	for name := range quotas {
		names = append(names, name)
	}
	sort.Strings(names)

	var b strings.Builder
	for _, name := range names {
		fmt.Fprintf(&b, "%-12s %s\n", name, formatLimit(quotas[name].Limit))
	}
	return b.String()
}

// Allow reports whether tenant may make another request, given how many
// requests it has already made in the current window.
func Allow(tenant string, used int) bool {
	q := Lookup(tenant)
	return used < q.Limit
}
GO

cat >quota_test.go <<'GO'
package quota

import "testing"

func TestAllow(t *testing.T) {
	cases := []struct {
		tenant string
		used   int
		want   bool
	}{
		{"acme", 0, true},
		{"acme", 999, true},
		{"acme", 1000, false},
		{"initech", 49, true},
		{"initech", 50, false},
	}
	for _, c := range cases {
		if got := Allow(c.tenant, c.used); got != c.want {
			t.Errorf("Allow(%q, %d) = %v, want %v", c.tenant, c.used, got, c.want)
		}
	}
}

func TestParseUsage(t *testing.T) {
	tenant, used, err := ParseUsage("globex=42\n")
	if err != nil || tenant != "globex" || used != 42 {
		t.Fatalf("ParseUsage(globex=42) = %q, %d, %v", tenant, used, err)
	}

	for _, line := range []string{"globex", "Globex=1", "globex=-1", "globex=x"} {
		if _, _, err := ParseUsage(line); err == nil {
			t.Errorf("ParseUsage(%q): want error, got nil", line)
		}
	}
}

func TestSummary(t *testing.T) {
	want := "acme         1k/window\n" +
		"globex       250/window\n" +
		"initech      50/window\n"
	if got := Summary(); got != want {
		t.Errorf("Summary() =\n%s\nwant\n%s", got, want)
	}
}

func TestLookupKnown(t *testing.T) {
	q := Lookup("globex")
	if q == nil || q.Limit != 250 {
		t.Fatalf("Lookup(globex) = %+v, want limit 250", q)
	}
}

func TestLookupUnknown(t *testing.T) {
	if q := Lookup("hooli"); q != nil {
		t.Fatalf("Lookup(hooli) = %+v, want nil", q)
	}
}
GO

git -c user.name="scaffold" -c user.email="scaffold@test" add quota.go quota_test.go
git -c user.name="scaffold" -c user.email="scaffold@test" -c commit.gpgsign=false \
	commit --quiet -F - <<'MSG'
Return nil from Lookup for unconfigured tenants

Billing needs to distinguish tenants that have no quota configured from
tenants that are deliberately on the default quota; both used to come
back as the same 100-request default. Lookup now returns nil for an
unconfigured tenant and leaves the fallback decision to the caller.
MSG
