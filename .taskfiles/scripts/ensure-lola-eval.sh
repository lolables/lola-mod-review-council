#!/usr/bin/env bash
# Bring the lola-eval harness into a managed virtualenv, or confirm the one
# already there is the one the Taskfile asks for.
#
# Usage: ensure-lola-eval.sh [--force] <binary> <venv-dir> <spec>
#
#   binary    the lola-eval path the Taskfile resolved. When it is not the one
#             inside <venv-dir>, the host already has lola-eval installed and
#             this script keeps its hands off.
#   venv-dir  the virtualenv this script owns outright. It is cleared and
#             rebuilt, never patched, so nothing else may live in it.
#   spec      a PEP 508 direct reference, e.g.
#             'lola-eval @ git+https://host/lola-eval.git@main'
#   --force   rebuild even when the venv already matches <spec>. With a
#             floating ref the spec string never changes, so this is the only
#             way to pick up new upstream commits.
#
# Why a script rather than a `status:` block on the task: Task resolves a
# global `sh:` var when it parses the file, before any dep can run, so the
# Taskfile cannot both discover lola-eval and install it in one invocation.
# The var therefore names a fixed path and this script makes that path real.
# Keeping the create/install/skip/fail decision here also puts it somewhere
# that shellcheck lints and module/tests/test-ensure-lola-eval.sh can drive.
set -euo pipefail

force=0
if [[ "${1:-}" == "--force" ]]; then
	force=1
	shift
fi

if [[ $# -ne 3 ]]; then
	echo "Usage: ensure-lola-eval.sh [--force] <binary> <venv-dir> <spec>" >&2
	exit 2
fi

binary="$1"
venv="$2"
spec="$3"
managed="$venv/bin/lola-eval"
# Inside the venv on purpose: the stamp describes that specific tree, so
# clearing the venv must take the stamp with it. Kept out of git by the
# existing .venv/ entry in .gitignore.
stamp="$venv/.lola-eval-spec"

# A lola-eval the host installed itself — an RPM, pipx, a system package — wins
# over anything this script would build, and the Taskfile has already applied
# that precedence by the time we get here. Building a venv anyway would review
# with a different harness than the operator chose, so the only thing left to
# check is that the path actually works.
if [[ "$binary" != "$managed" ]]; then
	if [[ -x "$binary" ]]; then
		exit 0
	fi
	echo "ERROR: lola-eval resolved to '$binary', which is not executable." >&2
	echo "       Remove that entry from PATH to let this project manage its own" >&2
	echo "       virtualenv, or repair the installation it points at." >&2
	exit 1
fi

# The hot path: this runs ahead of every eval task, so an up-to-date venv must
# cost two stat calls and a read, with no subprocess and nothing on the network.
if [[ "$force" -eq 0 && -x "$managed" && -f "$stamp" ]]; then
	installed="$(cat "$stamp")"
	if [[ "$installed" == "$spec" ]]; then
		exit 0
	fi
fi

if ! command -v uv >/dev/null 2>&1; then
	cat >&2 <<-'MISSING_UV'
		ERROR: uv not found on PATH — cannot install the lola-eval harness.

		Install it:
		  macOS:  brew bundle          (from the repo root; uv is in the Brewfile)
		  any:    curl -LsSf https://astral.sh/uv/install.sh | sh

		Then re-run this task. To use a lola-eval you installed yourself instead,
		put it on PATH and this project will defer to it.
	MISSING_UV
	exit 1
fi

echo "Installing the lola-eval harness into $venv"
echo "  spec: $spec"

# Dropped before the first thing that can fail, so that a half-built venv is
# never left carrying a stamp that says it is current. The next run then
# rebuilds instead of trusting the wreckage.
rm -f "$stamp"

# --clear rebuilds from scratch: a respec is a version change, and layering a
# second install over the first leaves whichever files the new one does not
# overwrite. --no-project stops uv walking up to any pyproject.toml above the
# repo. The floor is lola-eval's own Requires-Python; naming a single version
# instead would reject the perfectly good interpreter most hosts already have.
uv venv --clear --no-project --python '>=3.11' "$venv"
uv pip install --quiet --python "$venv/bin/python" "$spec"

# A resolution that succeeds without producing the console script is possible —
# a renamed entry point, a wheel built without one — and reporting success here
# would hand the caller a path that does not exist, surfacing later as a bare
# "no such file" from inside whichever eval task ran next.
if [[ ! -x "$managed" ]]; then
	echo "ERROR: the install reported success but produced no executable at" >&2
	echo "       $managed" >&2
	exit 1
fi

printf '%s\n' "$spec" >"$stamp"
"$managed" --version
