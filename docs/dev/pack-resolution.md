# Pack resolution

How a review decides which convention packs it loads. For writing a pack, see
README "Convention Packs".

## Flow

1. `rc-prepare.sh` copies the project's `.review-council/packs/` from the base
   revision into `review-config/packs/` (`lib/prepare-config.sh`). The reviewed
   tree is never read for packs.
2. In the same fragment it runs `scripts/rc-resolve-packs.sh` over three
   directories, highest precedence first: that project copy, the user's
   `$XDG_CONFIG_HOME/review-council/packs/`, the shipped `references/`.
3. The resolver writes `review-config/resolved/packs.tsv`, one row per pack
   considered: `kind name path source status reason`. Status is `selected`,
   `available` (valid, not chosen) or `skipped` (reason given). A copy shadowed
   by a higher-precedence one has no row.
4. Preparation turns the rows into the `Language`, `Framework`, `Language pack`,
   `Framework pack`, `Additional packs` and `Skipped packs` lines of
   `tracking.md`. `Language` and
   `Framework` are labels (the pack name without its prefix); nothing derives a
   path from them. They are `unknown` / `none` when no pack was selected, so a
   language or framework without a pack (`js`, `vue`, `gin`, ...) is no longer
   named; the labels used to come from a hard-coded extension and manifest table.
5. Dispatch-time scripts read `packs.tsv` through `rc_selected_packs`
   (`rc-lib.sh`): `rc-build-context.sh` puts each selected language and
   framework pack's Calibration Notes in the preamble, and
   `rc-assemble-prompts.sh` writes the `Packs:` line and the persona's
   `## Reviewer hints` rows into every prompt. A missing `packs.tsv` is an error
   in both: preparation did not finish. This includes a session prepared by an
   older version of the module, which has to be prepared again; there is no
   fallback to the old label lookup.

## Rules the resolver enforces

- Only regular files directly in a packs directory, named
  `^[A-Za-z0-9][A-Za-z0-9._-]*\.md$`. Symlinks and other names are ignored with
  a stderr line. Pack text is never executed; probes only read.
- A pack name found in several directories resolves to the highest-precedence
  copy that loads. A copy that fails validation is reported and the next is
  tried. Whole file, no merging.
- `lang-*` and `fw-*` need `contract: 1`; anything else is skipped with a reason.
  Language packs need `extensions`, framework packs a `framework` slug equal to
  the file name minus `fw-` and a `probe`.
- Language: each pack claims its extensions (higher precedence, then name, wins
  a clash); the pack covering the most changed files is the language. No pack
  claims the changeset: language `unknown`, no language pack. Several languages
  in one change load only the plurality's pack.
- Framework: the first `fw-*` pack by name whose probe file is among the changed
  files and contains the probe text in the review root.
- `severity.md` is not a pack here; `prepare-config.sh` resolves it separately.
  Shipped files that are not `lang-*`/`fw-*` are infrastructure.
- Project and user files that are neither `lang-*` nor `fw-*` are additive and
  load as given.

## Reviewer hints

The `## Reviewer hints` table replaced the table that lived in
`references/dispatch-prompt.md`. Because external packs author the rows,
`hints_for` in `rc-assemble-prompts.sh` keeps a row only when it begins
`Check for `, is one line, and is at most 400 characters, with at most five rows
per pack and persona. Dropped rows are reported on stderr.

## Tests

`test-rc-resolve-packs.sh` drives the resolver directly,
`test-rc-prepare-packs.sh` through `rc-prepare.sh`, and
`test-rc-build-context.sh` / `test-rc-assemble-prompts.sh` cover the consumers.
