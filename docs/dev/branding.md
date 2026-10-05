# Branding assets

The project icon and README banner live in [`docs/assets/`](../assets/). The SVGs
are the source of truth; the PNGs are rendered from them for surfaces that do
not accept SVG (GitHub avatars, social previews, chat unfurls).

| File | Size | Used by |
| --- | --- | --- |
| `icon.svg` | 256×256 | Source for the icon |
| `icon.png` | 512×512 | Avatars and other raster-only surfaces |
| `banner.svg` | 1280×320 | README header |
| `banner.png` | 1280×320 | Raster-only surfaces |
| `social-preview.svg` | 1280×640 | Source for the social preview |
| `social-preview.png` | 1280×640 | Settings → Social preview (manual upload) |

## Design constraints

- **No reviewer count.** The artwork must not encode how many personas the
  council has, so adding or removing a reviewer never invalidates it. An earlier
  draft with one seat per persona was dropped for this reason.
- **Self-contained SVGs.** GitHub renders README SVGs as `<img>`, which cannot
  load external files or web fonts. The banner therefore inlines its own copy of
  the icon, and its font stack ends in fonts that exist on common systems.
  `'Noto Sans'` sits before Helvetica so the PNG renders identically on hosts
  where Helvetica resolves to a metric clone such as Nimbus Sans.
- **Plain git, not LFS.** The six files total about 230 KB, the SVGs are text
  and diff cleanly, and LFS would bill every README view against the repository
  owner's bandwidth quota.
- **Social preview is opaque and 2:1.** GitHub recommends 1280×640 and a solid
  background, so `social-preview.svg` has square corners and no transparency,
  unlike the banner. It reuses the banner's `<defs>` and icon group scaled 1.5×;
  keep all three SVGs in sync when changing one. GitHub does not read it from
  the repository; re-upload the PNG after regenerating it.

## The magnifier rim

The rim carries yellow, white and purple bands, with the All flag colours are
mixed 20% toward white to keep the effect subtle.

The `rim` gradient uses `gradientUnits="userSpaceOnUse"` with endpoints at the
rim's outer edge (centre ± 75 px along the handle axis), so the bands run
perpendicular to the handle. Bounding-box units would ignore the stroke width
and misplace the bands on a diagonal.

Equal-width stripes do not look equal on a ring: an outer band covers a long
arc while a central band only clips the ring near the hole. The band boundaries
are instead placed so each colour covers the same arc of the rim's centre line
(radius 66). For `n` bands across the 150 px gradient axis, boundary `k` is at
offset `(75 − 66·cos(k·180°/n)) / 150`; for three bands that is `0.28` and
`0.72`.

The banner's `accent` underline repeats all four flag colours in equal
horizontal segments.

## Regenerating the PNGs

Edit the SVGs, then run:

```sh
task assets:render
```

The task needs `rsvg-convert` (`dnf install librsvg2-tools` or
`brew install librsvg`) and Noto Sans (`dnf install google-noto-sans-vf-fonts`
or `brew install --cask font-noto-sans`). It refuses to run without the font
rather than let fontconfig substitute another face. `task doctor` deliberately
does not check either: adding them there would mean adding them to the
`Brewfile`, which the macOS CI leg installs from, for a task only maintainers
run. The task's own preconditions report what is missing. It skips when no SVG has
changed since the last render; `task --force assets:render` re-renders anyway,
but `--force` also skips the font and tool checks.

Open every PNG and check it by eye before committing.
