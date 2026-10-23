# council-version.sh — the installed council's version, from the skill's
# VERSION stamp (#89).
#
# The one copy of the stamp's rules. Sourced by lib/render-provenance.sh (the
# report and PR comment header) and by the repository's scripts/lib/common.sh
# (the batch driver's plan header), so the two cannot name one install
# differently. Defines one function: sourcing it runs nothing, sets no shell
# option and needs no other file.
#
# release-bump.sh writes the stamp (docs/dev/releasing.md): "X.Y.Z" in a
# release commit, "X.Y.Z+dev" in every commit after it, "0.0.0+dev" before the
# first release. The stamp sits in an install anyone can edit, and the header
# that names it is posted to a public comment, so nothing from the file is
# printed unless all of it has one of those shapes: then it is only digits and
# dots, safe bare in markdown and on a terminal.
#
# shellcheck shell=bash
# shellcheck disable=SC2250 # Bare $var, as every other shell source here writes
# it. Enabling the braces-always style in these files would make them the only
# ones of their kind in the tree; consistency is worth more than the check.

# Print how <version_file> names its council: "vX.Y.Z", "unreleased, after
# vX.Y.Z", "unreleased, before the first release", or "unknown" for an absent
# file, one over 64 bytes, or any other content. 0.0.0 is never a release, so
# a bare 0.0.0 is unknown too. Reads at most 65 bytes: one past the cap, so a
# longer file is refused rather than truncated into a valid-looking version.
rc_council_version() { # version_file
	local file="$1" stamp="" num='(0|[1-9][0-9]*)' re
	re="^${num}\\.${num}\\.${num}(\\+dev)?$"
	if [[ -f "$file" ]]; then
		stamp=$(head -c 65 "$file" 2>/dev/null) || stamp=""
	fi
	if [[ ${#stamp} -gt 64 || ! "$stamp" =~ $re || "$stamp" == "0.0.0" ]]; then
		printf '%s' "unknown"
	elif [[ "$stamp" == "0.0.0+dev" ]]; then
		printf '%s' "unreleased, before the first release"
	elif [[ "$stamp" == *+dev ]]; then
		printf '%s' "unreleased, after v${stamp%+dev}"
	else
		printf '%s' "v${stamp}"
	fi
}
