# Brewfile — the macOS prerequisite contract for Review Council.
#
# This file is the single source of truth. The macOS leg of
# .github/workflows/test.yml installs from it, so `brew bundle` on a laptop and
# a CI run get the identical formula set. Add a macOS prerequisite here, not in
# the workflow.
#
#   brew bundle    # install everything below
#   task doctor    # confirm each one is what PATH actually resolves to
#
# Why each formula:
#
#   bash       macOS ships 3.2 and will not move off it. The scripts need 4+
#              for `mapfile` and `${var,,}`.
#   jq         Every artifact the pipeline reads or writes is JSON.
#   coreutils  macOS has no `timeout` at all. GNU timeout bounds every forge
#              call so a hung `gh` or `git` cannot stall a review.
#   uv         Builds the .venv that `task lola-eval:*` runs the eval harness
#              from. It is the only prerequisite here that a plain `task test`
#              never touches — nothing in the module or its unit suites is
#              Python — but the eval harness cannot bootstrap itself without
#              it, and uv also supplies the interpreter when the host's own
#              python3 is older than the 3.11 lola-eval requires (a stock Mac
#              ships 3.9).
#
# DO NOT add $(brew --prefix coreutils)/libexec/gnubin to PATH.
#
# Homebrew installs the coreutils tools g-prefixed — `gtimeout`, `gsed`,
# `ggrep` — and does not shadow the BSD ones. That is deliberate, and this
# project depends on it. The scripts accept `timeout` or `gtimeout`, so nothing
# here needs PATH surgery to work.
#
# Putting gnubin on PATH replaces BSD sed/grep/awk with the GNU versions. The
# macOS CI leg then stops being a macOS test and becomes a second Linux one,
# which defeats the only reason that leg exists: catching GNU-only constructs
# before an end user on a stock Mac does. `task doctor` warns when it finds
# gnubin on PATH for exactly this reason.

brew "bash"
brew "jq"
brew "coreutils"
brew "uv"
