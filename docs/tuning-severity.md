# Tuning severity for your project

Every reviewer finding has a severity: CRITICAL, HIGH, MEDIUM or LOW. CRITICAL
and HIGH block the change (REQUEST CHANGES). MEDIUM and LOW are advisories
(APPROVE WITH ADVISORIES). If the council blocks on things your team treats as
advice, or waves through things you always want fixed, there are two ways to
change that.

| You want to… | Use | How sure is it? |
|---|---|---|
| Make one reviewer advisory, or make one always block | The `Severity override` setting | Deterministic: a script enforces it after review |
| Change what each level *means* for your codebase | Your own `severity.md` pack | Guidance: reviewers and the arbiter read it and rate accordingly |

Both can be used together. The pack shapes how severity is assigned, and the
setting then bounds the result. When they disagree, the setting wins.

## Recipe 1: make Guard advisory

Guard checks that a change does what was asked and nothing more. Some teams
want to hear about drift without being blocked by it. Add this to the
`## Review Council Configuration` section of `AGENTS.md` or `CLAUDE.md`, and
commit it to your base branch:

```text
## Review Council Configuration

- Severity override: guard<=LOW
```

`<=` is a cap: Guard findings are never above LOW. Use `guard<=MEDIUM` to keep
Guard's MEDIUM/LOW distinction while still never blocking.

## Recipe 2: make a reviewer always block

If every operations finding must be fixed before merge:

```text
- Severity override: sre>=HIGH
```

`>=` is a floor: SRE findings are never below HIGH. A finding raised to HIGH
this way, and left without an `impact` line, gets one saying the project
configuration raised it.

Use `=` to pin a level exactly (`testing=MEDIUM`). Combine terms with commas,
one per reviewer:

```text
- Severity override: guard<=LOW, sre>=HIGH
```

The reviewers are `adversary`, `curator`, `guard`, `sre` and `testing`. Each
term covers that reviewer in both code and spec reviews. Reviewer names must be
lower case; levels are case-insensitive.

## Recipe 3: write your own `severity.md`

The shipped pack defines each level, with examples per reviewer. To redefine
them, start from a copy. Find `references/severity.md` in your installed
skill: a user-scope install (`lola install ... -s user`) puts it at
`~/.claude/skills/review-council/references/severity.md`; a project-scope or
manual install puts it at `.claude/skills/review-council/references/severity.md`
in your project. The paths are Claude Code's; other hosts use their own config
directory, as in the README's Install section.

```bash
mkdir -p .review-council/packs
cp ~/.claude/skills/review-council/references/severity.md .review-council/packs/severity.md
```

Edit the copy, then commit it to your base branch. Two locations are read,
and the first one found wins:

1. **Project:** `.review-council/packs/severity.md`, as committed on the base
   branch. Use this for team policy.
2. **User:** `$XDG_CONFIG_HOME/review-council/packs/severity.md` (by default
   `~/.config/review-council/packs/severity.md`). Use this for your own
   reviews across projects. It must be a regular file, not a symlink; a
   symlink is skipped with a warning when the review starts. A relative
   `XDG_CONFIG_HOME` is ignored (with a note), since it would resolve inside
   the reviewed tree.

If neither exists, the shipped pack is used. Whichever wins is used for the
whole run, by every reviewer and by the arbiter that calibrates severities.

## Where it must live: the base branch

The change under review never configures its own review. Both the setting and
the project pack are read from the base revision (for a PR, the merge-base
with its target branch), never from the branch being reviewed. A pull request
that adds `guard<=LOW` or an easier `severity.md` is reviewed under the
existing rules. The setting takes effect once it is merged.

When a change does edit these files, the run's `tracking.md` lists them under
`Config changed by changeset:`, and the report says the change's version was
not obeyed.

## Checking it worked

Each run writes a session directory. In it:

- `tracking.md` names what was used:
  ```text
  - Severity pack: project
  - Severity override: guard<=LOW, sre>=HIGH
  ```
  `Severity pack` is `project`, `user` or `module` (the shipped one).
- `verdicts/_meta/verification.txt`, under `=== SEVERITY CALIBRATION ===`,
  lists every finding the setting moved, with its old and new level.
- `verdicts/findings.json` records each move on the finding itself, in
  `provenance.calibrated_from`:
  ```json
  {"from": "HIGH", "to": "LOW", "reason": "config: Severity override guard<=LOW"}
  ```

## Troubleshooting

A term that can't be used is dropped and the others still apply. Each dropped
term is printed when the review starts (`rc-prepare: Severity override term
'…' rejected (…)`) and recorded in `tracking.md`:

```text
- Severity override rejected: wizard<=LOW (unknown persona)
```

| Reason | Meaning | Fix |
|---|---|---|
| `unknown persona` | The name isn't one of the five reviewers | Use `adversary`, `curator`, `guard`, `sre` or `testing`, lower case |
| `unknown level` | The level isn't CRITICAL, HIGH, MEDIUM or LOW | Check the spelling |
| `malformed term` | No `<=`, `>=` or `=` between name and level | Write it as `guard<=LOW` |
| `persona already set` | A second term for the same reviewer | Keep one term per reviewer; the first one is used |

If `Severity override` shows `none` although you configured it, the setting is
probably not on the base branch yet, or every term was rejected. Check the
`Severity override rejected` lines, then compare `Config source:` in
`tracking.md` with the commit you expect.
