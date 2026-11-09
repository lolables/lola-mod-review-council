#!/usr/bin/env bash
# scaffold.sh — create git history for case-035-upstream-owned-config.
#
# The starter's initial code becomes the first commit (handled by reset.sh).
# It already has a config layer: internal/config loads config.json from
# $KEYRELAY_CONFIG or the XDG config search path, and README.md documents it.
#
# This script creates a `feat` branch whose single commit adds key injection.
# Two upstream-owned values end up compiled in, with no way to change them
# short of a rebuild:
#   - inject.Providers, a per-vendor table of API host, header and auth
#     prefix, each row citing a vendor doc and "checked live on 2026-10-26".
#     Relay applies it to every request: primary path, HIGH.
#   - doctor.statusURL, a vendor status-page endpoint read only by the
#     `keyrelay doctor` subcommand: secondary path, MEDIUM.
# Decoys: httpsPort = 443 (fixed by a standard), Placeholder (a value the
# project owns), and the made-up api.example.invalid host in the test.
set -euo pipefail
workdir="$1"
cd "${workdir}"

git -c user.name="scaffold" -c user.email="scaffold@test" branch -m main
git checkout -b feat --quiet

mkdir -p internal/inject internal/doctor
cat >internal/inject/providers.go <<'GO'
package inject

// Provider is how one vendor's API takes a static key.
type Provider struct {
	Env    string // the variable the agent reads the key from
	Host   string // the API host the key is sent to
	Header string // the request header that carries it, lowercase
	Prefix string // what goes before the key in the header
}

// Providers is every vendor whose key keyrelay injects. Each header was
// checked live on 2026-10-26: a bogus key in it gets "invalid key", not
// "missing credentials".
var Providers = []Provider{
	// Source: https://platform.claude.com/docs/en/api/overview (x-api-key)
	{Env: "ANTHROPIC_API_KEY", Host: "api.anthropic.com", Header: "x-api-key"},
	// Source: https://developers.openai.com/api/reference/overview (Authorization: Bearer)
	{Env: "OPENAI_API_KEY", Host: "api.openai.com", Header: "authorization", Prefix: "Bearer "},
	// Source: https://ai.google.dev/gemini-api/docs/api-key (x-goog-api-key)
	{Env: "GEMINI_API_KEY", Host: "generativelanguage.googleapis.com", Header: "x-goog-api-key"},
	// Source: https://console.groq.com/docs/api-reference (Authorization: Bearer)
	{Env: "GROQ_API_KEY", Host: "api.groq.com", Header: "authorization", Prefix: "Bearer "},
}
GO

cat >internal/inject/inject.go <<'GO'
// Package inject puts the real API key on requests to a known vendor host,
// so that the agent only ever holds Placeholder.
package inject

import (
	"net"
	"net/http"
	"os"
	"strconv"
)

// Placeholder is what an injected variable holds inside the sandbox.
const Placeholder = "keyrelay-placeholder"

const httpsPort = 443

// Lookup returns the provider whose API lives at hostport, if any.
func Lookup(hostport string) (Provider, bool) {
	host, port, err := net.SplitHostPort(hostport)
	if err != nil || port != strconv.Itoa(httpsPort) {
		return Provider{}, false
	}
	for _, p := range Providers {
		if p.Host == host {
			return p, true
		}
	}
	return Provider{}, false
}

// Relay replaces the placeholder key on req with the real one from the
// relay's own environment. It reports whether req went to a known vendor.
func Relay(req *http.Request) bool {
	p, ok := Lookup(req.URL.Host)
	if !ok {
		return false
	}
	key := os.Getenv(p.Env)
	if key == "" {
		return false
	}
	req.Header.Set(p.Header, p.Prefix+key)
	return true
}
GO

cat >internal/inject/inject_test.go <<'GO'
package inject

import (
	"net/http"
	"testing"
)

func TestRelaySetsVendorHeader(t *testing.T) {
	t.Setenv("OPENAI_API_KEY", "sk-real")
	req, _ := http.NewRequest(http.MethodPost, "https://api.openai.com:443/v1/responses", nil)
	req.Header.Set("authorization", "Bearer "+Placeholder)
	if !Relay(req) {
		t.Fatal("known vendor not relayed")
	}
	if got := req.Header.Get("authorization"); got != "Bearer sk-real" {
		t.Fatalf("authorization = %q", got)
	}
}

func TestRelayIgnoresUnknownHost(t *testing.T) {
	req, _ := http.NewRequest(http.MethodGet, "https://api.example.invalid:443/", nil)
	if Relay(req) {
		t.Fatal("unknown host relayed")
	}
}

func TestLookupRejectsOtherPorts(t *testing.T) {
	if _, ok := Lookup("api.anthropic.com:8080"); ok {
		t.Fatal("non-TLS port matched")
	}
}
GO

cat >internal/doctor/doctor.go <<'GO'
// Package doctor implements `keyrelay doctor`, a manual health report.
package doctor

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"time"
)

const statusURL = "https://status.anthropic.com/api/v2/status.json"

// Run prints the upstream status page's one-line summary to w.
func Run(w io.Writer) error {
	client := &http.Client{Timeout: 10 * time.Second}
	resp, err := client.Get(statusURL)
	if err != nil {
		return fmt.Errorf("upstream status: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("upstream status: HTTP %d", resp.StatusCode)
	}
	var body struct {
		Status struct {
			Description string `json:"description"`
		} `json:"status"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		return fmt.Errorf("upstream status: %w", err)
	}
	_, err = fmt.Fprintln(w, "upstream:", body.Status.Description)
	return err
}
GO

cat >cmd/keyrelay/main.go <<'GO'
// Command keyrelay is a local relay that holds API keys for sandboxed agents.
package main

import (
	"fmt"
	"os"

	"example.com/keyrelay/internal/config"
	"example.com/keyrelay/internal/doctor"
	"example.com/keyrelay/internal/inject"
)

func main() {
	if len(os.Args) > 1 && os.Args[1] == "doctor" {
		if err := doctor.Run(os.Stdout); err != nil {
			fmt.Fprintln(os.Stderr, "keyrelay:", err)
			os.Exit(1)
		}
		return
	}
	cfg, err := config.Load()
	if err != nil {
		fmt.Fprintln(os.Stderr, "keyrelay:", err)
		os.Exit(1)
	}
	fmt.Println("listening on", cfg.Listen, "for", len(inject.Providers), "vendors")
}
GO

cat >>docs/changelog.md <<'MD'
- 0.3.0: inject vendor API keys; add `keyrelay doctor`
MD

git -c user.name="scaffold" -c user.email="scaffold@test" add internal/inject internal/doctor cmd/keyrelay/main.go docs/changelog.md
git -c user.name="scaffold" -c user.email="scaffold@test" -c commit.gpgsign=false \
	commit --quiet -F - <<'MSG'
Inject vendor API keys and add a doctor subcommand

The relay now swaps the sandbox's placeholder key for the real one on
requests to each supported vendor's API host. `keyrelay doctor` prints the
upstream status page summary.
MSG
