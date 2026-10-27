# shellcheck shell=bash
# eval-env.sh — the environment every lola-eval task runs under. Sourced, not
# executed, at the head of each command in .taskfiles/lola-eval.yml:
#
#   . "{{.EVAL_ENV}}" && {{.LOLA_EVAL}} test
#
# This cannot be a top-level `env:` in lola-eval.yml: Task merges an included
# file's top-level env into every task in the project. It once was one, and
# `task release:bump` committed and tagged v0.1.0 as "Lola Eval" with the
# operator's git config ignored.
#
# XDG_CACHE_HOME must be set so the eval provider and reset.sh resolve the
# same cache root — when unset, reset.sh derives it from an overridden sandbox
# HOME and aborts with exit 2. The git variables isolate the eval's git
# operations from the caller's global and system config.

export XDG_CACHE_HOME="${XDG_CACHE_HOME:-${HOME}/.cache}"
export XDG_STATE_HOME="${XDG_STATE_HOME:-${HOME}/.local/state}"
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME="Lola Eval"
export GIT_AUTHOR_EMAIL="lola-eval@invalid"
export GIT_COMMITTER_NAME="Lola Eval"
export GIT_COMMITTER_EMAIL="lola-eval@invalid"
