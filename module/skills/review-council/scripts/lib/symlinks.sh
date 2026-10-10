#!/usr/bin/env bash
# Lexical judgement of a symlink: does following it leave the repository?
#
# Sourced by rc-check-symlinks.sh (links a change touches, judged against every
# link in the head tree) and rc-clone-target.sh (links the operator's checkout
# tracks). Nothing here touches the filesystem. A link is judged by its
# repository path and target text alone, so where a target happens to point on
# the machine running the review cannot change the answer, and no link is ever
# followed to find out.
#
# The caller fills the link map with every link it knows about
# (rc_symlink_map_add); a path that reaches one of those links is followed
# through the map, the way the kernel would follow it on disk. Keys carry a
# "p:" prefix so that a link named `@` or `*` is an ordinary key.
#
# A link whose target could not be read is added with rc_symlink_map_add_unknown
# and counts as escaping, both when it is judged and when a chain reaches it.
# Links marked with rc_symlink_mark_changed are the ones a change touched; after
# rc_symlink_escapes, _rc_symlink_followed_changed names the first of them the
# walk went through (empty when none), so a caller can tell a link the change
# made escape from one that already escaped.
#
# The rule is POSIX path semantics only: `/` is the sole separator and `.git`
# is matched by name in any case. Aliases another platform would honour, such
# as `C:/`, backslash separators or a trailing-dot `.git.`, are not modelled.
# A link missing from the map is not followed, so a chain through a link the
# caller does not know about is judged lexically at that point.

declare -gA _RC_SYMLINK_MAP=()
declare -gA _RC_SYMLINK_CHANGED=()

# Links followed while judging one target. Linux gives up at 40 (MAXSYMLINKS);
# a chain that long, or a cycle, is reported as escaping.
RC_SYMLINK_MAX_HOPS=40

_rc_symlink_hops=0
_rc_symlink_path=""
_rc_symlink_followed_changed=""

rc_symlink_map_reset() {
	_RC_SYMLINK_MAP=()
	_RC_SYMLINK_CHANGED=()
}

rc_symlink_map_add() { # path target
	_RC_SYMLINK_MAP["p:$1"]="$2"
}

# An absolute target is what the walk already refuses, so storing one makes a
# chain through this link escape with no special case in the walk; "/" escapes
# under every reading, so no real target is misjudged by sharing it.
rc_symlink_map_add_unknown() { # path
	_RC_SYMLINK_MAP["p:$1"]=/
}

rc_symlink_mark_changed() { # path
	_RC_SYMLINK_CHANGED["p:$1"]=1
}

# Resolve <target> as written in a link inside repository directory <dir> (""
# for the root). Sets _rc_symlink_path to the repository-relative result.
# Returns 1 when the walk leaves the repository or enters .git: an absolute
# target, a `..` above the root, a first component of .git in any case (a
# case-insensitive filesystem serves .GIT as .git), a target holding a newline
# (nothing renders it faithfully, so it is refused rather than judged), or a
# chain past RC_SYMLINK_MAX_HOPS. A component that names a mapped link is
# followed before the next one is read, so `link/..` is judged from where the
# link points, not lexically from the link itself.
_rc_symlink_walk() { # dir target
	local cur="$1" target="$2" c first link_dir
	local -a parts=()
	[[ "$target" == /* || "$target" == *$'\n'* ]] && return 1
	IFS=/ read -r -a parts <<<"$target"
	# The walk position is kept as one string and edited at its tail, never
	# rebuilt from an array: a rebuild per component costs a subshell or a full
	# join each time, and a target thousands of components long then takes
	# seconds. Components never hold a slash, so the tail edit is exact.
	for c in "${parts[@]}"; do
		case "$c" in
		"" | .) continue ;;
		..)
			[[ -n "$cur" ]] || return 1
			if [[ "$cur" == */* ]]; then
				cur="${cur%/*}"
			else
				cur=""
			fi
			;;
		*)
			cur="${cur:+$cur/}$c"
			first="${cur%%/*}"
			[[ "${first,,}" == ".git" ]] && return 1
			if [[ -n "${_RC_SYMLINK_MAP["p:$cur"]+set}" ]]; then
				((++_rc_symlink_hops <= RC_SYMLINK_MAX_HOPS)) || return 1
				if [[ -z "$_rc_symlink_followed_changed" && -n "${_RC_SYMLINK_CHANGED["p:$cur"]+set}" ]]; then
					_rc_symlink_followed_changed="$cur"
				fi
				link_dir=""
				[[ "$cur" == */* ]] && link_dir="${cur%/*}"
				_rc_symlink_walk "$link_dir" "${_RC_SYMLINK_MAP["p:$cur"]}" || return 1
				cur="$_rc_symlink_path"
			fi
			;;
		esac
	done
	_rc_symlink_path="$cur"
	return 0
}

# 0 when the link at repository path <path>, holding <target>, leads out of the
# repository (see _rc_symlink_walk); 1 when it stays inside. Either way sets
# _rc_symlink_followed_changed.
rc_symlink_escapes() { # path target
	local dir=""
	[[ "$1" == */* ]] && dir="${1%/*}"
	_rc_symlink_hops=0
	_rc_symlink_followed_changed=""
	_rc_symlink_walk "$dir" "$2" && return 1
	return 0
}
