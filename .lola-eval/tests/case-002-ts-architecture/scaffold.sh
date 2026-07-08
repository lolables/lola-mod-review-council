#!/usr/bin/env bash
# scaffold.sh — create git history for case-002-ts-architecture.
# The prompt uses /review-council code HEAD, so we need at least
# two commits. The starter's initial code becomes the first commit
# (handled by reset.sh). This script adds a second commit that
# introduces an additional architectural flaw.
set -euo pipefail
workdir="$1"
cd "$workdir"

# Add a file with a new architectural concern in the latest commit
mkdir -p src
cat >src/GlobalState.tsx <<'TSX'
// Global mutable state — anti-pattern in React
export const globalState: Record<string, any> = {};

export function setGlobal(key: string, value: any): void {
  globalState[key] = value;
}

export function getGlobal(key: string): any {
  return globalState[key];
}
TSX

git -c user.name="scaffold" -c user.email="scaffold@test" add src/GlobalState.tsx
git -c user.name="scaffold" -c user.email="scaffold@test" -c commit.gpgsign=false \
	commit --quiet -m "Add global state module"
