#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=module/skills/review-council/scripts/rc-lib.sh
source "$(dirname "$0")/rc-lib.sh"
rc_trap_errors

# rc-resolve-packs.sh --refs DIR --project-packs DIR|none --user-packs DIR
#                     --changeset FILE --review-root DIR --out DIR
# Decides which convention packs a review loads, from the packs themselves.
#
# A language or framework pack declares what it covers in its own frontmatter,
# so supporting a new language is a file, not an edit to a detection table:
#
#   contract: 1                     required on lang-* and fw-*; exact match
#   extensions: [tf, hcl]           lang-*: lowercase, no dot, at least one
#   framework: react                fw-*: the slug recorded as the framework
#   probe: package.json '"react"'   fw-*: a file at the tree root and the text
#                                   it must contain (one quote pair is peeled)
#
# Three directories are searched, in fixed precedence: the project's packs
# (preparation's copy of the base revision's, never the reviewed tree), the
# user's, then the shipped references. A pack name found in several is
# resolved to the highest-precedence copy that loads: whole file, no merging.
# A copy that does not load (unknown contract, bad frontmatter) is reported on
# stderr and in the output, and the next location's copy is tried. Shipped
# files other than lang-*/fw-* (base.md, severity.md, schemas) are not packs
# here; severity.md stays with prepare-config.sh. A pack in the project or
# user directory that is neither lang-* nor fw-* is additive and loads as is.
#
# Only regular files directly in those directories, named
# ^[A-Za-z0-9][A-Za-z0-9._-]*\.md$, are read; symlinks and other names are
# ignored. Nothing here executes pack text, and probes only read.
#
# Language: each lang-* pack claims its extensions; where two claim one the
# higher-precedence pack wins, then the name sorts first. The pack that claims
# the most changed files is the language (ties: name ascending). Framework:
# the first fw-* pack, by name, whose probe file is among the changed files and
# contains the probe text in the review root.
#
# Writes <out>/packs.tsv, one row per pack considered:
#   kind  name  path  source  status  reason
#   kind    language | framework | additional
#   source  project | user | shipped
#   status  selected | available (valid, not chosen) | skipped (reason given)
# A copy shadowed by a higher-precedence one has no row.

usage() {
	echo "usage: rc-resolve-packs.sh --refs DIR --project-packs DIR|none --user-packs DIR --changeset FILE --review-root DIR --out DIR" >&2
	exit 2
}

refs="" project_dir="" user_dir="" changeset="" review_root="" out=""
while (($# > 0)); do
	(($# >= 2)) || usage
	case "$1" in
	--refs) refs="$2" ;;
	--project-packs) project_dir="$2" ;;
	--user-packs) user_dir="$2" ;;
	--changeset) changeset="$2" ;;
	--review-root) review_root="$2" ;;
	--out) out="$2" ;;
	*) usage ;;
	esac
	shift 2
done
[[ -n "$refs" && -n "$project_dir" && -n "$user_dir" && -n "$changeset" && -n "$review_root" && -n "$out" ]] || usage
[[ -d "$refs" ]] || {
	echo "rc-resolve-packs: --refs '${refs}' is not a directory" >&2
	exit 2
}
[[ -f "$changeset" ]] || {
	echo "rc-resolve-packs: --changeset '${changeset}' is not a file" >&2
	exit 2
}
mkdir -p -- "$out"

name_re='^[A-Za-z0-9][A-Za-z0-9._-]*\.md$'

# Locations in precedence order, as "source:dir". A directory that is absent
# (the user never made one) simply holds no packs.
locations=()
[[ "$project_dir" == "none" ]] || locations+=("project:${project_dir}")
locations+=("user:${user_dir}" "shipped:${refs}")

# fm_values <file>: "key<TAB>value" for each top-level key of the FIRST
# frontmatter block, first occurrence of a key wins. The block must open on
# line 1 and is read to its closing `---` or 40 lines, whichever comes first,
# so a pack with no frontmatter yields nothing and a long body is never scanned.
fm_values() {
	awk '
		NR == 1 { if ($0 != "---") exit; next }
		NR > 41 || $0 == "---" { exit }
		{ sub(/\r$/, "") }
		match($0, /^[A-Za-z_][A-Za-z0-9_]*:/) {
			key = substr($0, 1, RLENGTH - 1)
			if (key in seen) next
			seen[key] = 1
			val = substr($0, RLENGTH + 1)
			sub(/^[ \t]+/, "", val)
			sub(/[ \t]+$/, "", val)
			printf "%s\t%s\n", key, val
		}' "$1"
}

# clean <text>: printable ASCII only, at most 60 bytes — pack text is untrusted
# and ends up in a TSV, a tracking.md line and stderr.
clean() {
	local t
	t=$(printf '%s' "$1" | LC_ALL=C tr -cd '[:print:]')
	printf '%s' "${t:0:60}"
}

rows=()  # kind\tname\tpath\tsource\tstatus\treason
skip() { # name path source reason
	local reason
	reason=$(clean "$4")
	# shellcheck disable=SC2312 # rc_pack_kind ends in a case with a default arm: it cannot fail.
	rows+=("$(printf '%s\t%s\t%s\t%s\tskipped\t%s' "$(rc_pack_kind "$1")" "$1" "$2" "$3" "$reason")")
	echo "rc-resolve-packs: ${3} pack '${1}' skipped: ${reason}" >&2
}
rc_pack_kind() {
	case "$1" in
	lang-*) echo language ;;
	fw-*) echo framework ;;
	*) echo additional ;;
	esac
}

# validate <name> <file>: sets VAL_REASON (empty when the pack loads) and, for a
# loading pack, VAL_EXTS (space-separated) or VAL_FRAMEWORK / VAL_PROBE_FILE /
# VAL_PROBE_TEXT.
validate() {
	local name="$1" file="$2" key val kv contract="" pack_id="" exts="" framework="" probe=""
	VAL_REASON="" VAL_EXTS="" VAL_FRAMEWORK="" VAL_PROBE_FILE="" VAL_PROBE_TEXT=""
	# shellcheck disable=SC2312 # an unreadable pack yields no keys and is skipped below for its missing contract.
	while IFS=$'\t' read -r key val; do
		case "$key" in
		contract) contract="$val" ;;
		pack_id) pack_id="$val" ;;
		extensions) exts="$val" ;;
		framework) framework="$val" ;;
		probe) probe="$val" ;;
		*) ;;
		esac
	done < <(fm_values "$file")
	if [[ -z "$contract" ]]; then
		VAL_REASON="contract missing (this resolver reads contract: 1)"
		return 0
	fi
	if [[ "$contract" != "1" ]]; then
		VAL_REASON="unsupported contract '${contract}' (this resolver reads contract: 1)"
		return 0
	fi
	if [[ -n "$pack_id" && "$pack_id" != "${name}" ]]; then
		VAL_REASON="pack_id '${pack_id}' does not match the file name"
		return 0
	fi
	# rc-build-context.sh aborts the whole review on a pack without this heading,
	# so a pack lacking it must lose to the next copy here, not at context build.
	if [[ "$name" == lang-* || "$name" == fw-* ]] && ! grep -qx '## Calibration Notes' "$file"; then
		VAL_REASON="no '## Calibration Notes' section"
		return 0
	fi
	case "$name" in
	lang-*)
		if [[ ! "$exts" =~ ^\[[a-z0-9,\ ]+\]$ ]]; then
			VAL_REASON="extensions missing or not a lowercase list like [tf, hcl]"
			return 0
		fi
		exts="${exts#\[}"
		exts="${exts%\]}"
		for kv in ${exts//,/ }; do
			VAL_EXTS+="${VAL_EXTS:+ }${kv}"
		done
		[[ -n "$VAL_EXTS" ]] || VAL_REASON="extensions is empty"
		;;
	fw-*)
		if [[ ! "$framework" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
			VAL_REASON="framework missing or not a lowercase slug"
			return 0
		fi
		# The slug is what tracking.md records and rc-build-context.sh turns back
		# into fw-<slug>.md, so it has to be the file's own name.
		if [[ "fw-${framework}" != "$name" ]]; then
			VAL_REASON="framework '${framework}' does not match the file name"
			return 0
		fi
		local pfile="${probe%%[[:space:]]*}" ptext=""
		[[ "$probe" == *[[:space:]]* ]] && ptext="${probe#"$pfile"}"
		ptext="${ptext#"${ptext%%[![:space:]]*}"}"
		case "$ptext" in
		\"*\") ptext="${ptext:1:${#ptext}-2}" ;;
		\'*\') ptext="${ptext:1:${#ptext}-2}" ;;
		*) ;;
		esac
		if [[ ! "$pfile" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ || -z "$ptext" ]]; then
			VAL_REASON="probe must be a plain file name and the text to find"
			return 0
		fi
		VAL_FRAMEWORK="$framework" VAL_PROBE_FILE="$pfile" VAL_PROBE_TEXT="$ptext"
		;;
	*) ;;
	esac
}

# Names across all locations, then the highest-precedence loading copy of each.
all_names=$(
	for loc in "${locations[@]}"; do
		source="${loc%%:*}" dir="${loc#*:}"
		for f in "$dir"/*.md; do
			[[ -e "$f" || -L "$f" ]] || continue
			base="${f##*/}"
			if [[ ! "$base" =~ $name_re ]]; then
				# shellcheck disable=SC2312 # clean ends in printf: it cannot fail.
				echo "rc-resolve-packs: ignored '$(clean "$base")' in ${source} packs: unsafe file name" >&2
				continue
			fi
			if [[ ! -f "$f" || -L "$f" ]]; then
				echo "rc-resolve-packs: ignored '${base}' in ${source} packs: not a regular file" >&2
				continue
			fi
			[[ "$base" == "severity.md" ]] && continue
			[[ "$source" == "shipped" && ! "$base" =~ ^(lang|fw)- ]] && continue
			echo "${base%.md}"
		done
	done | LC_ALL=C sort -u
)

lang_names=() lang_paths=() lang_srcs=() lang_exts=()
fw_names=() fw_paths=() fw_srcs=() fw_frameworks=() fw_pfiles=() fw_ptexts=()
extra_rows=()
while IFS= read -r name; do
	[[ -n "$name" ]] || continue
	for loc in "${locations[@]}"; do
		source="${loc%%:*}" dir="${loc#*:}"
		file="${dir}/${name}.md"
		[[ -f "$file" && ! -L "$file" ]] || continue
		[[ "$source" == "shipped" && ! "$name" =~ ^(lang|fw)- ]] && continue
		case "$name" in
		lang-* | fw-*)
			validate "$name" "$file"
			if [[ -n "$VAL_REASON" ]]; then
				skip "$name" "$file" "$source" "$VAL_REASON"
				continue
			fi
			if [[ "$name" == lang-* ]]; then
				lang_names+=("$name") lang_paths+=("$file") lang_srcs+=("$source") lang_exts+=("$VAL_EXTS")
			else
				fw_names+=("$name") fw_paths+=("$file") fw_srcs+=("$source")
				fw_frameworks+=("$VAL_FRAMEWORK") fw_pfiles+=("$VAL_PROBE_FILE") fw_ptexts+=("$VAL_PROBE_TEXT")
			fi
			;;
		*)
			extra_rows+=("$(printf 'additional\t%s\t%s\t%s\tselected\t' "$name" "$file" "$source")")
			;;
		esac
		break
	done
done <<<"$all_names"

# --- Language: extension ownership, then the most-claimed pack ---
rank() { # source
	case "$1" in project) echo 0 ;; user) echo 1 ;; *) echo 2 ;; esac
}
declare -A ext_owner=() pack_count=()
# Owners are assigned in (precedence, name) order so the first claim stands.
order=$(
	for i in "${!lang_names[@]}"; do
		# shellcheck disable=SC2312 # rank ends in a case with a default arm: it cannot fail.
		printf '%s\t%s\t%s\n' "$(rank "${lang_srcs[$i]}")" "${lang_names[$i]}" "$i"
	done | LC_ALL=C sort -t$'\t' -k1,1n -k2,2
)
while IFS=$'\t' read -r _ _ i; do
	[[ -n "$i" ]] || continue
	for e in ${lang_exts[$i]}; do
		[[ -n "${ext_owner[$e]:-}" ]] || ext_owner[$e]="${lang_names[$i]}"
	done
done <<<"$order"

while IFS= read -r file; do
	[[ -n "$file" ]] || continue
	e="${file##*.}"
	[[ "$e" == "$file" ]] && continue
	e="${e,,}"
	owner="${ext_owner[$e]:-}"
	[[ -n "$owner" ]] && pack_count[$owner]=$((${pack_count[$owner]:-0} + 1))
done <"$changeset"

chosen_lang=""
if ((${#pack_count[@]} > 0)); then
	chosen_lang=$(for k in "${!pack_count[@]}"; do printf '%s\t%s\n' "${pack_count[$k]}" "$k"; done |
		LC_ALL=C sort -t$'\t' -k1,1rn -k2,2 | head -n 1 | cut -f2)
fi
for i in "${!lang_names[@]}"; do
	if [[ "${lang_names[$i]}" == "$chosen_lang" ]]; then
		rows+=("$(printf 'language\t%s\t%s\t%s\tselected\t' "${lang_names[$i]}" "${lang_paths[$i]}" "${lang_srcs[$i]}")")
	else
		rows+=("$(printf 'language\t%s\t%s\t%s\tavailable\tnot the language of this change' "${lang_names[$i]}" "${lang_paths[$i]}" "${lang_srcs[$i]}")")
	fi
done

# --- Framework: first probe that matches, by pack name ---
chosen_fw=""
for i in "${!fw_names[@]}"; do
	pfile="${fw_pfiles[$i]}"
	# The probe file must be part of the change (as before: a repository's
	# dependency manifest says nothing about a change that never touched it),
	# and is read from the review root, never the launch directory.
	grep -qxE -- ".*(^|/)${pfile//./\\.}" "$changeset" || continue
	[[ -f "${review_root}/${pfile}" && ! -L "${review_root}/${pfile}" ]] || continue
	if grep -qF -- "${fw_ptexts[$i]}" "${review_root}/${pfile}"; then
		chosen_fw="${fw_names[$i]}"
		break
	fi
done
for i in "${!fw_names[@]}"; do
	if [[ "${fw_names[$i]}" == "$chosen_fw" ]]; then
		rows+=("$(printf 'framework\t%s\t%s\t%s\tselected\t' "${fw_names[$i]}" "${fw_paths[$i]}" "${fw_srcs[$i]}")")
	else
		rows+=("$(printf 'framework\t%s\t%s\t%s\tavailable\tprobe did not match this change' "${fw_names[$i]}" "${fw_paths[$i]}" "${fw_srcs[$i]}")")
	fi
done

{
	((${#rows[@]} == 0)) || printf '%s\n' "${rows[@]}"
	((${#extra_rows[@]} == 0)) || printf '%s\n' "${extra_rows[@]}"
} >"${out}/packs.tsv"
