# Verity Images Catalog Design System

## 1. Identity

The catalog reads as a component datasheet: the image name is the part number, the publication
policy is the absolute-maximum-ratings table, and the revision block states when and from what the
catalog was published. It is a public record, evidence first. Verity is a free public good with no
account, no paid tier, and no sign-up or demo path; the primary action is copying a pull command.
Tektum appears only as a quiet footer line.

The primary visitor is a platform engineer choosing a trusted image. Their path is: understand the
chain of custody and publication policy, find an image, inspect its evidence, copy an immutable pull
reference and the verification commands. A keyboard-only visitor and a visitor using reduced motion
must complete the same path without loss.

Personality comes from boxed tables, section numbering, and monospace data, not from tracking,
glow, or accent color. Wording rules: say `0 fixable at publish time`, never `0 CVE`; say
`SLSA Build L3 provenance` (a deliberate owner decision; the pipeline change that makes it true is tracked separately); FIPS flavors are `not CMVP validated`; no competitor mentions.

## 2. Color

Tokens live on `:root` in `site/styles.css`. Light is the default; dark applies through
`prefers-color-scheme: dark` unless `<html data-theme="light">` is set, and `data-theme="dark"`
forces dark. Changing the token set themes every surface; no component uses a literal color.

| Role | Token | Light | Dark | Usage |
|---|---|---|---|---|
| Background | `--bg` | `#ffffff` | `#0e1114` | Page and controls |
| Tint | `--tint` | `#eef2f7` | `#161a1e` | Section headings, open rows, pressed filters |
| Ink | `--ink` | `#111111` | `#e9edf0` | Text and structural 1px box lines |
| Muted | `--muted` | `#595f66` | `#9ba5ae` | Labels, metadata, section numbers |
| Pass | `--pass` | `#0a6b3d` | `#5fcf94` | Gate states and copied feedback only |
| Rule | `--rule` | `#cfd4da` | `#2b3239` | Decorative inner separators only |
| Box | `--box` | `#6b727a` | `#7b858e` | Form control and chip borders |
| Error | `--err` | `#a3241a` | `#ff8a80` | Copy failure |
| Hover | `--hover` | `#f7f9fb` | `#12161a` | Row hover background |
| On ink | `--on-ink` | `var(--bg)` | `var(--bg)` | Text on ink-filled surfaces |

Measured contrast (WCAG 2.x), against `--bg` / `--tint`:

| Token | Light | Dark |
|---|---|---|
| `--ink` | 18.88 / 16.80 | 16.08 / 14.86 |
| `--muted` | 6.45 / 5.74 | 7.56 / 6.99 |
| `--pass` | 6.60 / 5.87 | 9.77 / 9.03 |
| `--err` | 7.43 / 6.61 | 8.30 / 7.66 |
| `--box` | 4.87 / 4.33 | 5.04 / 4.65 |
| `--rule` | 1.49 / 1.33 | 1.46 / 1.35 |

`--rule` is below 3:1 and must never carry text or bound a control. Status never relies on color
alone: every green state also has text (`0 FIXABLE`, `GATE`, `COPIED`).

## 3. Typography

System stacks only; the site makes no font requests.

- Data: `ui-monospace, "SF Mono", Menlo, Consolas, "Liberation Mono", monospace` at 13 to 14px for
  digests, commands, tables, controls, and labels.
- Headings: `system-ui` weight 700 with `font-variant-caps: all-small-caps`, prefixed by a mono
  section number (`1.0`, `2.0`, `3.0`, and `1.1`, `3.12` for items).
- Body: `system-ui` 15px / 1.55.
- Hero thesis 44px, 32px below 760px. No letter-spacing anywhere. Body text never falls below 13px;
  12px is used only for short column labels.

## 4. Layout

- One full-width boxed sheet, maximum 1240px, 20px gutters (10px below 760px). Stacked boxes share
  a single 1px ink border.
- Index order: header bar, title bar (thesis left, revision block right), `1.0 Chain of custody`,
  `2.0 Publication policy`, `3.0 Catalog`, document footer. Trust uses the same header and footer
  with numbered prose sections.
- Breakpoints: 1000px (revision block and policy notes stack, controls wrap), 860px (custody rail
  turns vertical), 760px (rows become stacked cards, tables become label/value blocks).
- Long digests, identities, and commands wrap with `overflow-wrap: anywhere`. The page must never
  gain horizontal overflow at 375px and must reflow at 200% zoom.

## 5. Components

### Header and theme toggle

- **Structure**: skip link, `VERITY/IMAGES` brand, primary nav (Trust, Raw JSON, Schema, GitHub),
  theme toggle button.
- **Toggle**: cycles `Theme: Auto`, `Theme: Light`, `Theme: Dark`. Auto removes `data-theme`.
  `site/theme.js` persists the choice in `localStorage` inside try/catch; a short inline head script
  applies it before first paint.
- **Accessibility**: nav landmark, 44px targets, the button label itself announces the mode.

### Revision block

- **Structure**: a real `<table>` with an ink caption: REV (publish time, `<time>`), SRC (main plus
  commit linking to the catalog run), CATALOG (record counts by track), COSIGN (minimum version).
- **Data**: filled from `catalog.json` by `site/app.js`.

### Custody rail

- **Structure**: ordered list SOURCE, BUILD, SIGN, ATTEST, PUBLISH with real identifiers. BUILD
  links to the catalog run, SIGN shows the certificate identity and issuer from `catalog.json`,
  ATTEST names the SBOM format and `actions/attest-build-provenance`.
- **Visual**: 10px square ink nodes and a 1px ink connector; gate notes in pass-green boxes, the
  FIPS note in a box-border box. Five columns above 860px, vertical below.

### Policy table

- **Structure**: numbered leader rows (`2.1` to `2.8`) built with flex and a dotted `::after`
  leader, plus a short notes column.

### Filter controls

- **Structure**: labelled search, track buttons with square check cells and counts, sort select,
  polite live result status.
- **Accessibility**: `aria-pressed` expresses filter state; `/` focuses search, Escape clears it.

### Record row

- **Structure**: native `<details>`; the summary shows number, name, variant count, track,
  version with FIPS marker, short digest, freshness, `0 FIXABLE`, and copy action. The expanded
  panel is a boxed table: description, KNOWN UNFIXABLE severity breakdown, tags, pull command,
  verification commands, and a per-digest custody trace ending at that image's digest.
- **States**: default, hover, open, focus-visible.
- **FIPS marker**: `title` and visually hidden text read "FIPS flavor. Not CMVP validated."

### Copy action

- **Structure**: text button; labels `COPY`, `COPIED`, `SELECT` with brackets added in CSS.
- **States**: copied uses `--pass`, failure uses `--err`, both with a label change.
- **Motion**: a 200ms opacity and blur swap, skipped under reduced motion.

## 6. Motion

Two motions exist: the custody connector draws in once with `scaleX` (`scaleY` when vertical),
staggered 120ms per segment, and the copy label swap. Smooth scroll is used only for the hero
action. `prefers-reduced-motion: reduce` disables all animation and smooth scrolling.

## 7. Accessibility Constraints & Accepted Debt

### Constraints

- WCAG 2.2 AA: 4.5:1 text contrast, 3:1 for control borders and focus indicators.
- Full keyboard reachability, persistent visible `:focus-visible` outline, landmarks, skip link.
- 44px minimum targets on buttons, nav links, and controls.
- Search, filter, sort, copy, and disclosure flows work without a pointer.
- No horizontal overflow at 375px; content reflows at 200% zoom.

### Accepted Debt

| Item | Location | Why accepted | Owner / Exit |
|---|---|---|---|
| Client-rendered catalog records | `site/app.js` | Pages publishes the catalog after site assembly, so a zero-build static client keeps the image pipeline isolated. Core policy and navigation remain in HTML. | Replace with build-time rendering only if deep image SEO becomes a product requirement. |
| Theme preference stored client-side | `site/theme.js`, inline head scripts | Static hosting has no server preference; `localStorage` plus a pre-paint inline script avoids a theme flash. The inline script would need a hash if a Content-Security-Policy is added. | Move to a CSP hash or drop persistence if a strict CSP is introduced. |
