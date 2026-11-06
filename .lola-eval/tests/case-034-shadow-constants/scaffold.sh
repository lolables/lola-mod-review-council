#!/usr/bin/env bash
# scaffold.sh — create git history for case-034-shadow-constants.
#
# The starter's initial code becomes the first commit (handled by reset.sh).
# Owners: pins/tools.lock (lintkit version) and pins/fixtures.lock (fixture
# SHA). README.md and docs/changelog.md mention lintkit 1.62.2.
#
# This script creates a `feat` branch whose single commit bumps lintkit to
# 1.64.0 and adds ci/setup.go. Two shadow copies result:
#   - fixtureSHA restates fixtures.lock (unchanged, outside the diff) and is
#     the value VerifyFixture compares against: an integrity gate, HIGH.
#   - lintkitVersion restates tools.lock (bumped in the same diff): MEDIUM.
# README.md, outside every hunk, still tells users to install lintkit 1.62.2:
# stale install steps, HIGH for the Curator.
# Decoys: the new changelog line cites 1.62.2 on purpose (history), and the
# new test feeds ParseVersion a made-up "v9.9.9".
set -euo pipefail
workdir="$1"
cd "$workdir"

git -c user.name="scaffold" -c user.email="scaffold@test" branch -m main
git checkout -b feat --quiet

printf '# Pinned toolchain.\nlintkit 1.64.0\n' >pins/tools.lock

mkdir -p ci
cat >ci/setup.go <<'GO'
// Package ci prepares the lint toolchain and the fixture checkout.
package ci

import (
	"fmt"
	"strings"
)

const (
	lintkitVersion = "1.64.0"
	fixtureSHA     = "4f1c9b7e2a6d8035e1b94c7a0d2f6e83a5b1c970"
)

// LintkitURL returns the download URL for the pinned lintkit release.
func LintkitURL() string {
	return fmt.Sprintf("https://example.com/lintkit/releases/v%s/lintkit.tar.gz", lintkitVersion)
}

// VerifyFixture refuses a fixture checkout whose head is not the pinned commit.
func VerifyFixture(head string) error {
	if head != fixtureSHA {
		return fmt.Errorf("fixture head %s, want %s", head, fixtureSHA)
	}
	return nil
}

// ParseVersion strips a leading "v" from a release tag.
func ParseVersion(tag string) string {
	return strings.TrimPrefix(tag, "v")
}
GO

cat >ci/setup_test.go <<'GO'
package ci

import "testing"

func TestParseVersion(t *testing.T) {
	if got := ParseVersion("v9.9.9"); got != "9.9.9" {
		t.Fatalf("ParseVersion = %q", got)
	}
}

func TestVerifyFixture(t *testing.T) {
	if err := VerifyFixture(fixtureSHA); err != nil {
		t.Fatalf("pinned head refused: %v", err)
	}
	if err := VerifyFixture("0000000000000000000000000000000000000000"); err == nil {
		t.Fatal("unpinned head accepted")
	}
}

func TestLintkitURL(t *testing.T) {
	want := "https://example.com/lintkit/releases/v1.64.0/lintkit.tar.gz"
	if got := LintkitURL(); got != want {
		t.Fatalf("LintkitURL = %q", got)
	}
}
GO

printf -- '- 0.4.0: bump lintkit from 1.62.2 to 1.64.0\n' >>docs/changelog.md

git -c user.name="scaffold" -c user.email="scaffold@test" add pins/tools.lock ci docs/changelog.md
git -c user.name="scaffold" -c user.email="scaffold@test" -c commit.gpgsign=false \
	commit --quiet -F - <<'MSG'
Bump lintkit to 1.64.0 and add CI setup helpers

pins/tools.lock moves to lintkit 1.64.0. The new ci package builds the
download URL and refuses a fixture checkout that is not the pinned commit.
MSG
