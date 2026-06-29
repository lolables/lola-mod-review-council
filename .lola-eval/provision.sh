#!/usr/bin/env bash
# provision.sh — copy the current module/ into each starter repo
# so the agent under test runs /review-council with THIS commit's
# version of Review Council.
#
# Usage: provision.sh [module_dir]
#   module_dir defaults to ../module (relative to this script).
#
# For each starter/ under .lola-eval/tests/:
#   1. Remove any prior .lola/ and CLI integration dirs inside the starter
#   2. Copy module/ into starter/.lola/modules/review-council/module/
#   3. Write starter/.lola/modules/review-council/.lola/source.yml
#   4. Copy top-level AGENTS.md, README.md, LICENSE, CHANGELOG.md
#      into starter/.lola/modules/review-council/ (lola expects these
#      at the module root alongside module/)
#   5. Copy CLI integration files directly (.claude/, .opencode/)
#      instead of calling `lola install` (which is too slow for batch use)
#   6. Write a clean .gitconfig for eval isolation
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_DIR="${1:-$(cd "$SCRIPT_DIR/../module" && pwd)}"
TESTS_DIR="$SCRIPT_DIR/tests"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [[ ! -d "$MODULE_DIR" ]]; then
  echo "provision.sh: module dir not found: $MODULE_DIR" >&2
  exit 1
fi

if [[ ! -d "$TESTS_DIR" ]]; then
  echo "provision.sh: tests dir not found: $TESTS_DIR" >&2
  exit 1
fi

provisioned=0

for starter in "$TESTS_DIR"/*/starter; do
  [[ -d "$starter" ]] || continue
  case_name="$(basename "$(dirname "$starter")")"

  # Clean prior provisioning (module files + CLI integration dirs)
  rm -rf "$starter/.lola" "$starter/.claude" "$starter/.opencode"

  # Create lola module structure
  mod_dest="$starter/.lola/modules/review-council"
  mkdir -p "$mod_dest/module"
  mkdir -p "$mod_dest/.lola"

  # Copy the module contents (exclude .git to avoid embedded repo warnings)
  cp -a "$MODULE_DIR/." "$mod_dest/module/"
  find "$mod_dest" -name .git -type d -exec rm -rf {} + 2>/dev/null || true

  # Copy top-level files that lola expects at the module root
  for f in AGENTS.md README.md LICENSE CHANGELOG.md; do
    if [[ -f "$PROJECT_ROOT/$f" ]]; then
      cp "$PROJECT_ROOT/$f" "$mod_dest/$f"
    fi
  done

  # Write lola source metadata
  cat > "$mod_dest/.lola/source.yml" <<'YAML'
source: local://provision
type: local
YAML

  # Install CLI integration files directly by copying from module/.
  # This replaces `lola install` which takes 15-30s per invocation
  # due to Python startup + module resolution overhead.
  # The output is deterministic: agents/, commands/, skills/ are
  # straight copies of the module source files.
  for target_dir in .claude .opencode; do
    mkdir -p "$starter/$target_dir/agents"

    # Copy agents
    if [[ -d "$MODULE_DIR/agents" ]]; then
      cp "$MODULE_DIR/agents/"*.md "$starter/$target_dir/agents/" 2>/dev/null || true
    fi

    # Copy skills (recursive — includes scripts/, phases/ subdirectories)
    if [[ -d "$MODULE_DIR/skills" ]]; then
      cp -a "$MODULE_DIR/skills/." "$starter/$target_dir/skills/"
    fi

    # Copy references (convention packs, model guidance)
    if [[ -d "$MODULE_DIR/references" ]]; then
      cp -a "$MODULE_DIR/references/." "$starter/$target_dir/references/"
    fi
  done

  # Write clean git config for eval isolation
  cat > "$starter/.gitconfig" <<'GIT'
[user]
    name = lola-eval
    email = eval@localhost
[commit]
    gpgsign = false
[init]
    defaultBranch = main
GIT

  # Create starter-clean/ — same source code, no module artifacts.
  # Used by pack_id=none baseline runs for genuine bare-model comparison.
  clean="$TESTS_DIR/$case_name/starter-clean"
  rm -rf "$clean"
  cp -a "$starter" "$clean"
  # Strip all module artifacts from the clean starter
  rm -rf "$clean/.lola"
  rm -rf "$clean/.claude"
  rm -rf "$clean/.opencode"
  # Strip all lola-injected blocks from system context files
  for f in AGENTS.md CLAUDE.md; do
    if [[ -f "$clean/$f" ]]; then
      sed -i '/<!-- lola:module:.*:start -->/,/<!-- lola:module:.*:end -->/d' "$clean/$f"
      sed -i '/<!-- lola:skills:start -->/,/<!-- lola:skills:end -->/d' "$clean/$f"
      sed -i '/<!-- lola:instructions:start -->/d; /<!-- lola:instructions:end -->/d' "$clean/$f"
      # Remove the "Lola Skills" preamble section if present
      sed -i '/^## Lola Skills$/,/^<!-- lola:skills:start -->/d' "$clean/$f" 2>/dev/null || true
      # Remove file if now empty (only whitespace)
      if [[ ! -s "$clean/$f" ]] || ! grep -q '[^[:space:]]' "$clean/$f" 2>/dev/null; then
        rm -f "$clean/$f"
      fi
    fi
  done

  provisioned=$((provisioned + 1))
  echo "provision.sh: provisioned $case_name (+ starter-clean)"
done

if [[ $provisioned -eq 0 ]]; then
  echo "provision.sh: no starter dirs found under $TESTS_DIR" >&2
  exit 1
fi

echo "provision.sh: $provisioned case(s) provisioned"
