#!/usr/bin/env bash
# Check that this host has everything the scripts and quality gates need, and
# print an actionable remedy for whatever is missing.
#
# The macOS prerequisite set lives in the repo-root Brewfile, which CI installs
# from too. This script checks the *result* rather than the install, because a
# formula being installed is not the same as its binary being the one PATH
# resolves to. On macOS that gap is real: /bin/bash is 3.2 and Homebrew's bash 5
# lands somewhere else entirely, so PATH order decides which one the scripts
# actually get.
#
# Deliberately written to bash 3.2 — no mapfile, no `${var,,}`, no associative
# arrays. This script has to run on the very host it is diagnosing, and a stock
# Mac cannot execute the bash 4 constructs the rest of the codebase uses.
set -uo pipefail

failed=0

# Report one required command by name. Three callers need the same found/missing
# formatting plus the shared failure flag.
require_command() {
	local name="$1" remedy="$2" path
	path="$(command -v "$name" || true)"
	if [[ -n "$path" ]]; then
		printf 'ok    %-10s %s\n' "$name" "$path"
		return
	fi
	printf 'FAIL  %-10s not found on PATH\n' "$name"
	printf '      remedy: %s\n' "$remedy"
	failed=1
}

echo "Review Council prerequisites"
echo

# Bash 4+. Interrogate the bash that PATH resolves to, not the one running this
# script: `task` and every suite invoke `bash`/`env bash`, so PATH is what
# decides, and on macOS the 3.2 in /bin frequently wins.
bash_bin="$(command -v bash || true)"
if [[ -z "$bash_bin" ]]; then
	printf 'FAIL  %-10s not found on PATH\n' bash
	printf '      remedy: %s\n' "macOS: brew bundle (see the repo-root Brewfile)"
	failed=1
else
	# Single quotes are the point: these must expand in the child bash being
	# probed, not in this one, or every host reports its own version.
	# shellcheck disable=SC2016
	bash_major="$("$bash_bin" -c 'echo "${BASH_VERSINFO[0]}"' 2>/dev/null || true)"
	# shellcheck disable=SC2016
	bash_full="$("$bash_bin" -c 'echo "$BASH_VERSION"' 2>/dev/null || true)"
	if [[ -z "$bash_major" ]] || [[ "$bash_major" -lt 4 ]]; then
		printf "FAIL  %-10s %s at %s — 4+ required for mapfile and \${var,,}\n" \
			bash "${bash_full:-unknown}" "$bash_bin"
		printf '      remedy: %s\n' "macOS: brew bundle, then put Homebrew's bin ahead of /bin on PATH"
		failed=1
	else
		printf 'ok    %-10s %s at %s\n' bash "$bash_full" "$bash_bin"
	fi
fi

require_command jq "macOS: brew bundle | Debian: apt-get install jq | Fedora: dnf install jq"

# GNU timeout bounds every forge call so a hung `gh` or `git` cannot stall a
# review. Homebrew's coreutils installs it as `gtimeout`; the scripts accept
# either name, so either one satisfies this check.
timeout_bin="$(command -v timeout || command -v gtimeout || true)"
if [[ -n "$timeout_bin" ]]; then
	printf 'ok    %-10s %s\n' timeout "$timeout_bin"
else
	printf 'FAIL  %-10s neither timeout nor gtimeout found on PATH\n' timeout
	printf '      remedy: %s\n' "macOS: brew bundle | Debian/Fedora: install coreutils"
	failed=1
fi

require_command shellcheck "needed by 'task lint' — macOS: brew install shellcheck | Fedora: dnf install ShellCheck"
require_command shfmt "needed by 'task lint' — macOS: brew install shfmt | any: go install mvdan.cc/sh/v3/cmd/shfmt@latest"

# uv builds the .venv that `task lola-eval:*` installs the eval harness into,
# and supplies a 3.11+ interpreter when the host's python3 is older. Checked
# here rather than left to fail at eval time so that one `task doctor` still
# answers "is this checkout ready to work in" for every entry point, not just
# the ones a given contributor happens to use first.
require_command uv "needed by 'task lola-eval:*' — macOS: brew bundle | any: curl -LsSf https://astral.sh/uv/install.sh | sh"

# Advisory only: coreutils' unprefixed GNU tools on PATH. This never fails the
# task — a contributor may want gnubin for unrelated work — but it silently
# changes what a local run proves, so it is worth saying out loud.
IFS=':' read -r -a path_entries <<<"$PATH"
gnubin_hits=()
for entry in "${path_entries[@]}"; do
	if [[ "$entry" == *libexec/gnubin* ]]; then
		gnubin_hits+=("$entry")
	fi
done

if [[ "${#gnubin_hits[@]}" -gt 0 ]]; then
	echo
	echo "WARN  coreutils' libexec/gnubin is on your PATH:"
	for entry in "${gnubin_hits[@]}"; do
		printf '        %s\n' "$entry"
	done
	echo "      That directory holds GNU sed/grep/awk/timeout under their plain,"
	echo "      unprefixed names, so they shadow the BSD tools macOS ships."
	echo "      Homebrew leaves them g-prefixed on purpose. With gnubin on PATH"
	echo "      your local run exercises GNU behaviour on every platform, so a"
	echo "      GNU-only construct passes here and then breaks for an end user"
	echo "      on a stock Mac and on the macOS CI leg. Drop gnubin from PATH"
	echo "      before trusting a green local run to mean the code is portable."
fi

echo
if [[ "$failed" -eq 0 ]]; then
	echo "All prerequisites satisfied."
else
	echo "Missing prerequisites above. On macOS, 'brew bundle' from the repo root installs the set."
fi
exit "$failed"
