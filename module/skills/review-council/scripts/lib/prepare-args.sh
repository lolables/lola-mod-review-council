# prepare-args.sh — flag parsing and scope resolution.
#
# Sections 0 of the preparation pipeline, sourced by rc-prepare.sh in order.
# Not executable on its own: these are straight-line statements over the
# globals the caller and the earlier fragments set, exactly as they were
# when this was one 1,400-line file. An `exit` on a skip path still ends
# the whole program, because `source` runs in the same shell.
#
# Sourced with no arguments, so $@ here is still rc-prepare.sh's own: the
# parse loop consumes the caller's positional parameters and `shift`
# shifts them there. Sourcing this WITH arguments would break that.
#
# shellcheck shell=bash
# shellcheck disable=SC2154,SC2034 # A fragment reads globals its
# predecessors set (SC2154) and sets globals its successors read (SC2034);
# standalone both look like mistakes. `shellcheck -x` resolves them through
# rc-prepare.sh but reports nothing from a sourced file, so each fragment is
# linted standalone too — these two codes are the price, and every other
# check still runs over this file.

# Restating the caller's options: a no-op at runtime, since rc-prepare.sh
# sets them before sourcing anything. It is here so this file is analysed
# under the options it actually runs with — without it shellcheck assumes
# defaults and reports 22 SC2312 command-substitution warnings that do not
# apply. `-e` stays off deliberately; see the note in rc-prepare.sh.
set -uo pipefail

# ============================================================================
# SECTION 0: Parse Input Arguments
# ============================================================================

mode_override=""
review_instructions=""
scope_type=""
scope_value=""
scope_filters=() # Secondary --scope paths filters
base_override=""
effort="standard"
post_comment="no"
post_auto_send="no"
# Empty means "the caller said nothing": prepare-changes.sh resolves these
# across CLI > env > config > default, and only a non-empty value here wins.
persona_selection_cli=""
triage_cli=""

while [[ $# -gt 0 ]]; do
	case "$1" in
	--mode)
		[[ $# -lt 2 ]] && {
			json_output "skip" "--mode requires a value (code, specs, or auto)"
			exit 0
		}
		# Validated here, like --effort. Without this the value fell through to
		# a `code` default, so any typo silently ran a CODE review: wrong
		# personas, wrong scope default, and a report naming a mode the caller
		# never asked for. `spec` is the typo that matters — the accepted token
		# is `specs`, but the mode is called `spec` in the JSON `mode` field and
		# in every divisor-*-spec.md filename, so the singular is the natural
		# guess. It is refused rather than aliased: one clear rejection naming
		# the three valid values costs a retry, while an alias grows a second
		# spelling that every future reader has to know about.
		case "$2" in
		code | specs | auto) mode_override="$2" ;;
		*)
			json_output "skip" "Invalid --mode value: $2. Valid values: code, specs, auto"
			exit 0
			;;
		esac
		shift 2
		;;
	--scope)
		[[ $# -lt 2 ]] && {
			json_output "skip" "--scope requires a value (changed, all, range, paths, pr, or url)"
			exit 0
		}
		if [[ -z "$scope_type" ]]; then
			scope_type="$2"
		elif [[ "$2" == "paths" ]]; then
			# Secondary scope: filter
			scope_filters+=("paths")
		else
			json_output "skip" "Cannot combine two base scopes: --scope $scope_type and --scope $2. Only 'paths' is valid as a secondary scope."
			exit 0
		fi
		shift 2
		;;
	--scope-value)
		[[ $# -lt 2 ]] && {
			json_output "skip" "--scope-value requires a value"
			exit 0
		}
		if [[ ${#scope_filters[@]} -gt 0 ]] && [[ "${scope_filters[-1]}" == "paths" ]]; then
			# Bind to the secondary paths filter
			scope_filters[-1]="paths:$2"
		else
			scope_value="$2"
		fi
		shift 2
		;;
	--review-instructions)
		[[ $# -lt 2 ]] && {
			json_output "skip" "--review-instructions requires a value"
			exit 0
		}
		review_instructions="$2"
		shift 2
		;;
	--base)
		[[ $# -lt 2 ]] && {
			json_output "skip" "--base requires a value"
			exit 0
		}
		base_override="$2"
		shift 2
		;;
	--effort)
		[[ $# -lt 2 ]] && {
			json_output "skip" "--effort requires a value (quick, standard, or deep)"
			exit 0
		}
		case "$2" in
		quick | standard | deep) effort="$2" ;;
		*)
			json_output "skip" "Invalid --effort value: $2. Valid values: quick, standard, deep"
			exit 0
			;;
		esac
		shift 2
		;;
	--post-comment)
		post_comment="yes"
		shift
		;;
	--post-auto-send)
		post_comment="yes"
		post_auto_send="yes"
		shift
		;;
	# Council-shaping switches. Both are tri-state here — unset means "the
	# caller said nothing", which is what lets the env var and the project's
	# configuration block have their turn in prepare-changes.sh. A `--flag`
	# that defaulted to "off" when absent would make the CLI layer win every
	# run, silently overriding a project that had configured the opposite.
	--persona-selection)
		persona_selection_cli="on"
		shift
		;;
	--no-persona-selection)
		persona_selection_cli="off"
		shift
		;;
	--triage)
		triage_cli="on"
		shift
		;;
	--no-triage)
		triage_cli="off"
		shift
		;;
	--help)
		cat <<-'HELP'
			Usage: rc-prepare.sh [flags]

			Flags:
			  --mode <code|specs|auto>         Review mode (default: auto-detect)
			  --scope <type>                   Scope type: changed, all, range, paths, pr, url
			  --scope-value <value>            Value for the preceding --scope
			  --review-instructions <text>     Freeform review guidance for agents
			  --base <branch>                  Override base branch (default: main or master)
			  --effort <quick|standard|deep>   Review depth (default: standard)
			  --post-comment                   Post the verdict as a PR comment (opt-in; confirmed at Step 7)
			  --post-auto-send                 Post without a per-run confirmation prompt
			  --persona-selection              Let change shape narrow the council (default: on)
			  --no-persona-selection           Always dispatch every discovered reviewer
			  --triage                         Let a triage pass narrow deep-mode subsystem councils (default: off)
			  --no-triage                      Dispatch every council against every subsystem

			Both council switches also read REVIEW_COUNCIL_PERSONA_SELECTION and
			REVIEW_COUNCIL_TRIAGE, and a "Persona selection:" / "Subsystem triage:"
			line in the project's Review Council Configuration block. Precedence is
			flag, then environment, then configuration, then the default above.

			Scope types:
			  changed     base...HEAD + uncommitted changes (code default)
			  all         All non-ignored project files (specs default)
			  range       git diff on --scope-value ref range (e.g., "HEAD~1..HEAD")
			  paths       Comma-separated paths in --scope-value. A file is reviewed
			              on its own, whatever git makes of it (untracked, ignored,
			              or committed and unmodified); a directory filters the
			              changeset to what changed under it.
			  pr          Fetch PR by number in --scope-value
			  url         Fetch PR by URL in --scope-value

			Multiple --scope flags are processed left-to-right. First sets base
			changeset, subsequent filter. Only 'paths' is valid as secondary.
		HELP
		exit 0
		;;
	*)
		json_output "skip" "Unknown flag: $1. Run with --help for usage."
		exit 0
		;;
	esac
done

# Resolve input_type and input_value from scope flags for downstream compatibility
input_type=""
input_value=""
scope_dir=""

case "${scope_type}" in
changed | "")
	input_type="auto"
	;;
all)
	input_type="all"
	;;
range)
	if [[ -z "$scope_value" ]]; then
		json_output "skip" "--scope range requires --scope-value with a ref range (e.g., HEAD~1..HEAD)"
		exit 0
	fi
	input_type="ref_range"
	input_value="$scope_value"
	;;
paths)
	if [[ -z "$scope_value" ]]; then
		json_output "skip" "--scope paths requires --scope-value with directory paths"
		exit 0
	fi
	input_type="dir_scope"
	input_value="$scope_value"
	scope_dir="$scope_value"
	;;
pr)
	if [[ -z "$scope_value" ]]; then
		json_output "skip" "--scope pr requires --scope-value with a PR number"
		exit 0
	fi
	input_type="pr_number"
	input_value="$scope_value"
	;;
url)
	if [[ -z "$scope_value" ]]; then
		json_output "skip" "--scope url requires --scope-value with a PR URL"
		exit 0
	fi
	input_type="url"
	input_value="$scope_value"
	;;
*)
	json_output "skip" "Unknown scope type: ${scope_type}. Valid: changed, all, range, paths, pr, url"
	exit 0
	;;
esac

# Apply secondary path filter
for filter in "${scope_filters[@]}"; do
	if [[ "$filter" == paths:* ]]; then
		scope_dir="${filter#paths:}"
	fi
done

# Normalise the path list once, here, where it is resolved — not in each of the
# four places that read it. Every consumer (both changeset builders, mode
# detection, the secondary filter) then sees the same entries, which is what
# stops two stages disagreeing about what was named: normalising inside the
# changeset builder alone left mode detection reading `src/app.go/` as a path
# that is not a file, falling through to its no-changes branch, and dispatching
# the spec council over a Go file the builder had resolved perfectly well.
#
# Trailing slashes go because `-e`/`-f` are false for a regular file named with
# one, so `src/auth.go/` was refused as "Target not found: src/auth.go" — naming
# as missing a path that is plainly there. They are stripped in a loop rather
# than with one `%/` because `src/auth.go//` is the same path again.
#
# Empty entries go because `read -ra` keeps an interior empty field, so a
# doubled comma in a generated flag string became an entry matching nothing and
# took the whole run down with a refusal that named nothing at all.
if [[ -n "$scope_dir" ]]; then
	scope_dir_given="$scope_dir"
	IFS=',' read -ra scope_entries <<<"$scope_dir"
	scope_dir=""
	for scope_entry in "${scope_entries[@]}"; do
		while [[ "$scope_entry" == */ ]]; do
			scope_entry="${scope_entry%/}"
		done
		[[ -z "$scope_entry" ]] && continue
		scope_dir="${scope_dir:+${scope_dir},}${scope_entry}"
	done
	if [[ -z "$scope_dir" ]]; then
		json_output "skip" "--scope paths was given no usable path in --scope-value '${scope_dir_given}'."
		exit 0
	fi
	# input_value carries the same list on `--scope paths`, and spec-mode
	# discovery falls back to it. Left unnormalised it is the raw string again,
	# by a different route.
	[[ "$input_type" == "dir_scope" ]] && input_value="$scope_dir"
fi
