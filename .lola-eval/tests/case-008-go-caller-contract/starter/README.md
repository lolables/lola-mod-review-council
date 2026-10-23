# quota

A per-tenant request quota service. Each tenant may make up to `Limit`
requests per window; the gateway calls `Allow` before forwarding a
request and rejects it once the tenant has used its quota.

`Lookup` returns a tenant's quota. `ParseUsage` reads the
`tenant=used` lines the gateway reports at the end of each window, and
`Summary` renders the configured quotas for the admin listing.
