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

var defaultQuota = Quota{Tenant: "default", Limit: 100}

// Lookup returns the quota for tenant, or the default quota when the tenant
// has none.
func Lookup(tenant string) *Quota {
	if q, ok := quotas[tenant]; ok {
		return &q
	}
	return &defaultQuota
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
