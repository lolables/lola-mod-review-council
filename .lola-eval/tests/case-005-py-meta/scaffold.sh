#!/usr/bin/env bash
# scaffold.sh — create git history for case-005-py-meta.
# The prompt uses /review-council code HEAD, so we need at least
# two commits. This adds a second commit with an additional flaw.
set -euo pipefail
workdir="$1"
cd "$workdir"

mkdir -p src/taskq
cat > src/taskq/metrics.py <<'PY'
"""Task queue metrics — added in latest commit."""
import pickle
import os


def load_metrics(path):
    """Load metrics from a pickle file. No validation."""
    with open(path, "rb") as f:
        return pickle.loads(f.read())


def save_metrics(data, path):
    with open(path, "wb") as f:
        pickle.dump(data, f)


ADMIN_KEY = "metrics-admin-key-do-not-share"
PY

git -c user.name="scaffold" -c user.email="scaffold@test" add src/taskq/metrics.py
git -c user.name="scaffold" -c user.email="scaffold@test" -c commit.gpgsign=false \
  commit --quiet -m "Add metrics module"
