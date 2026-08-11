# Verity Images Catalog Design System

## 1. Atmosphere & Identity

The catalog is a quiet security console: exact, transparent, and operational. It inherits the
dark mono visual language from `verity.supply`, measured from the live site at 375px and 1280px.
The signature is an evidence rail that makes policy, provenance, and freshness visible before a
visitor chooses an image.

The primary visitor is a platform engineer choosing a trusted image. Their path is: understand the
publication policy, find an image, inspect its evidence, copy an immutable pull reference. A
keyboard-only visitor and a visitor using reduced motion must complete the same path without loss.

## 2. Color

| Role | Token | Value | Usage |
|---|---|---|---|
| Void | `--void` | `#060d12` | Page background |
| Void raised | `--void-raised` | `#0b1419` | Sticky navigation |
| Surface | `--surface` | `#0a1720` | Controls and cards |
| Surface raised | `--surface-raised` | `#111b22` | Evidence panels |
| Border | `--border` | `#152230` | Default separation |
| Border strong | `--border-strong` | `#1f2b35` | Hover and emphasis |
| Text | `--text` | `#e8edf2` | Titles and high emphasis |
| Text primary | `--text-primary` | `#c5d5dd` | Body copy |
| Text secondary | `--text-secondary` | `#95a8b8` | Labels and metadata |
| Text muted | `--text-muted` | `#7a8e9c` | Quiet metadata |
| Nucleus | `--nucleus` | `#00f0cc` | Focus, success, primary action |
| Nucleus dim | `--nucleus-dim` | `#00d4b8` | Hover state |
| Orbit | `--orbit` | `#0099a8` | Patched track and links |
| Warning | `--warning` | `#fbbf24` | Advisory status |
| Error | `--error` | `#f87171` | Load and validation failures |
| Ink on accent | `--accent-ink` | `#002820` | Text on nucleus |

Atmosphere tokens: `--grid-dot` is `rgba(0, 240, 204, 0.035)`, `--glow` is
`rgba(0, 240, 204, 0.16)`, and `--overlay` is `rgba(6, 13, 18, 0.88)`. Accent is reserved for
interactive state, verified status, and the evidence rail.

## 3. Typography

The live reference renders Share Tech Mono for prose and JetBrains Mono for commands. Both are
loaded from Google Fonts with resilient local mono fallbacks.

| Level | Token | Size | Line height | Tracking | Usage |
|---|---|---:|---:|---:|---|
| Display | `--type-display` | `clamp(1.75rem, 4.5vw, 2.5rem)` | 1.15 | 0.10em | Hero thesis |
| H1 | `--type-h1` | `1.75rem` | 1.25 | 0.08em | Page title |
| H2 | `--type-h2` | `1.25rem` | 1.35 | 0.06em | Section title |
| H3 | `--type-h3` | `1rem` | 1.4 | 0.04em | Image title |
| Body | `--type-body` | `0.9375rem` | 1.7 | 0 | Prose |
| Small | `--type-small` | `0.8125rem` | 1.55 | 0.02em | Metadata |
| Label | `--type-label` | `0.75rem` | 1.35 | 0.12em | Controls and overlines |

Body text never falls below 13px. Labels may use 12px because their tracked mono forms are short,
high contrast, and supplementary. Command text uses JetBrains Mono.

## 4. Spacing & Layout

The base unit is 4px. Tokens are `--space-1` 4px, `--space-2` 8px, `--space-3` 12px,
`--space-4` 16px, `--space-5` 24px, `--space-6` 32px, `--space-7` 48px, `--space-8` 64px,
and `--space-9` 96px.

- Maximum content width: 1152px, matching the live reference.
- Page gutters: 16px through tablet, 24px above 768px.
- Breakpoints: 640px, 768px, 960px, and 1024px.
- Hero: single column on narrow screens, asymmetric 7/5 split above 960px.
- Catalog: a single-column row list. Rows hide digests below 1024px and reflow below 640px.
- Long references wrap inside their card. The page must never gain horizontal overflow at 375px.

## 5. Components

### Navigation

- **Structure**: skip link, brand anchor, repository and raw-data links.
- **States**: default, hover, focus, active.
- **Accessibility**: landmark label, visible focus, 44px minimum touch targets.
- **Motion**: color and glow only, 150ms.

### Evidence rail

- **Structure**: policy status, publication timestamp, source revision.
- **Variants**: loading, ready, error.
- **Accessibility**: status text does not rely on color; timestamp uses `<time>`.
- **Motion**: the ready indicator fades in; reduced motion removes the fade.

### Filter controls

- **Structure**: labelled search input, track button group, sort select, result status.
- **States**: default, hover, focus, pressed, disabled, empty, error.
- **Accessibility**: `aria-pressed` expresses filter state; results announce through a polite live region.
- **Motion**: the pressed fill changes over 180ms. No decorative movement.

### Image row

- **Structure**: a native details row with a summary for name, track, version, digest, freshness,
  findings, and copy action; expanded variants contain descriptions, tags, immutable pull commands,
  and verification disclosures.
- **Variants**: Wolfi and patched.
- **States**: default, hover, focus-within, row open, verification commands open.
- **Accessibility**: an article heading names each record; disclosure uses native `<details>`.
- **Motion**: border and glow only, 180ms.

### Copy action

- **Structure**: command text and adjacent text button.
- **States**: copy, copied, failure.
- **Accessibility**: the changed label is announced; the command remains selectable.
- **Motion**: adapted from beui.dev `action-swap`: opacity and blur swap over 200ms, with an
  immediate reduced-motion path.

## 6. Motion & Interaction

| Token | Value | Usage |
|---|---|---|
| `--duration-fast` | 120ms | Press and focus feedback |
| `--duration-standard` | 180ms | Filter and card state |
| `--duration-swap` | 200ms | Copy label swap |
| `--ease-out` | `cubic-bezier(0.2, 0.7, 0.2, 1)` | Enter and emphasis |
| `--ease-standard` | `cubic-bezier(0.4, 0, 0.2, 1)` | Color and border |

The filter mechanism is adapted from beui.dev `tabs`, but uses `aria-pressed` buttons because it
filters one result set rather than switching tab panels. Copy feedback follows `action-swap`.
Only opacity, transform, and filter may animate. `prefers-reduced-motion: reduce` makes every state
change immediate. The `/` key focuses search and Escape clears it when search owns focus.

## 7. Depth & Surface

The strategy is mixed tonal shift and borders. Cards use `--surface` over `--void`, a one-pixel
border, and a two-layer shadow declared as `--shadow-card`: a faint top rim plus deep ambient
separation. Interactive focus uses `--shadow-focus`; the hero evidence rail uses a radial accent
glow. Radii remain tight: 2px, 4px, and 6px. Pills are reserved for status and filters.

## 8. Accessibility Constraints & Accepted Debt

### Constraints

- WCAG 2.2 AA minimum, with 4.5:1 body contrast and 3:1 large-text contrast.
- Full keyboard reachability, persistent visible focus, semantic landmarks, and a skip link.
- Search, filter, sort, copy, and disclosure flows work without a pointer.
- Reduced motion is respected. Content reflows at 200% zoom and 375px without primary overflow.
- Status language says `0 fixable`, never `0 CVE`, because non-fixable findings may remain.

### Accepted Debt

| Item | Location | Why accepted | Owner / Exit |
|---|---|---|---|
| Client-rendered catalog records | `site/app.js` | Pages publishes the catalog after site assembly, so a zero-build static client keeps the image pipeline isolated. Core policy and navigation remain in HTML. | Replace with build-time rendering only if deep image SEO becomes a product requirement. |
| External web fonts | `site/styles.css` | Matches the existing Verity identity with resilient local fallbacks. | Vendor OFL font subsets if availability or privacy requirements change. |
