# Releasing

`CHANGELOG.md` is generated from the commit history by
[git-cliff](https://git-cliff.org). Do not edit it by hand: the next release
regenerates the whole file and discards any manual change.

## Prerequisites

- git-cliff 2.14.2. Take the prebuilt binary for your platform from
  <https://github.com/orhun/git-cliff/releases/tag/v2.14.2> and check it against
  the `.sha512` file published beside it, or build it with
  `cargo install git-cliff --version 2.14.2`. CI pins the same version in
  `.github/workflows/test.yml`.
- A clean working tree on the commit you want to release (normally `main`).

`task doctor` reports whether git-cliff is on `PATH`.

## Cutting a release

```console
$ task release:bump
Current version: 0.1.0
New version [0.1.1]:
✅ Released v0.1.1 — run 'git push --follow-tags' when ready
```

Press Enter to accept the suggestion, or type a version. To skip the prompt,
pass the version: `task release:bump -- 0.2.0`. With stdin closed and no
version argument the task fails rather than choosing for you.

The task:

1. Refuses uncommitted changes to tracked files (untracked files are ignored),
   a release with nothing releasable since the last tag (see below), a version that is not `MAJOR.MINOR.PATCH`
   (no leading zeros, so `0.6.00` is rejected), a version not greater than
   `VERSION`, and a version whose tag already exists.
2. Writes the new version to `VERSION`.
3. Regenerates `CHANGELOG.md` with the new version as its newest section, and
   checks that the section exists.
4. Commits both files as `chore(release): vX.Y.Z` and creates the annotated tag
   `vX.Y.Z`.

Nothing is pushed. `git push --follow-tags` publishes: the tag triggers
`.github/workflows/release.yml`, which checks the tag matches `VERSION` and
creates the GitHub release with that version's changelog section as its
notes.

`task release:current` prints the current version.

git-cliff prints its own `INFO` and `WARN` log lines while it runs. A `WARN`
that N commits "were skipped due to parse error(s)" is expected: those are merge
commits and commits that do not follow Conventional Commits.

### If it fails

- **Nothing is releasable**: when no commit since the last tag lands in the
  changelog (only `chore(deps)` or `chore(release)` commits, say), the task
  refuses with `nothing releasable since vX.Y.Z`, with or without a version
  argument. The publish workflow extracts the tag's section from `CHANGELOG.md`
  and fails when there is none, so a release without one would only break after
  the push. With no release tag, or a tag that does not match `VERSION`, the
  task cannot tell in advance; it regenerates `CHANGELOG.md`, finds no section
  for the new version, restores `VERSION` and `CHANGELOG.md` to their committed
  state and exits with `CHANGELOG.md has no section for X.Y.Z`.
- **The release commit is rejected** (a hook, for example): `VERSION` and
  `CHANGELOG.md` are restored to their committed state (a `CHANGELOG.md` that
  was not tracked is removed) and the task exits with an error. Fix the cause
  and run the task again.
- **Only the tag fails**: the release commit stays. The error names the command
  that finishes the job: `git tag -a vX.Y.Z -m vX.Y.Z`.

## How the next version is suggested

git-cliff reads the commits since the last release tag. Only tags of exactly
the form `vMAJOR.MINOR.PATCH` count as releases (`tag_pattern` in
`cliff.toml`); other tags, such as `backup/*`, are ignored. While the major
version is 0:

| Commits since the last release include | Suggested bump |
|---|---|
| A breaking change (`feat!:` or a `BREAKING CHANGE:` footer) | minor (0.5.0 → 0.6.0) |
| Anything else releasable (`feat:`, `fix:`, …) | patch (0.5.0 → 0.5.1) |

Nothing suggests 1.0.0; type it when you mean it. The task suggests a patch bump
and says why when there is no release tag yet, or when the highest release tag
(`vMAJOR.MINOR.PATCH` only, as in `cliff.toml`; pre-release tags such as
`v0.6.0-rc1` are ignored) is not exactly `v<VERSION>` (`VERSION` drifted). If no commit since the tag is releasable, it refuses
instead of suggesting.

## What appears in the changelog

Only commits whose subject follows
[Conventional Commits](https://www.conventionalcommits.org) appear; others,
including merge commits, are left out. They are grouped by type:

| Type | Section |
|---|---|
| `feat` | Features |
| `fix` | Bug Fixes |
| `refactor` | Refactor |
| `doc`/`docs` | Documentation |
| `perf` | Performance |
| `style` | Styling |
| `test` | Testing |
| `chore`, `ci`, `build` | Miscellaneous Tasks |
| `revert` | Revert |

A commit whose body mentions "security" and that no earlier rule matched goes
under Security; any other conventional commit lands in Other.

`chore(release)`, `chore(deps…)`, `chore(pr)` and `chore(pull)` commits are
skipped. A commit's subject becomes its changelog line, so write subjects for a
reader of the release notes. The configuration is `cliff.toml`.

## Tests

`task test:release` runs `.taskfiles/tests/release.venom.yml` against
throw-away repositories. It needs venom and git-cliff. CI runs it on pushes to
and pull requests against `main`.
