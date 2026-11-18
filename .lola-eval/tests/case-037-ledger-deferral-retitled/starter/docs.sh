#!/usr/bin/env bash
# docs.sh - build the docs site.
set -euo pipefail
mkdocs build --strict
