# Builder UI — DESIGN.md

Design contract for the web control plane UI in `server/frontend/`.
Visual reference: `server/origin/www/index.html` (the public tile-server
dashboard) — same charcoal/teal/serif brand, applied through Radix Themes
components instead of hand-rolled CSS. This is a refinement of an existing
brand, not a new design system.

## Tokens

| Token | Value | Used for |
|---|---|---|
| `--bg` | `#0d1117` | page background |
| `--card` | `#161b22` | card / panel background |
| `--border` | `#30363d` | hairline borders |
| `--text` | `#e6edf3` | primary text |
| `--muted` | `#8b949e` | secondary text, labels |
| `--accent` | `#2dd4bf` | brand accent: wordmark, links |
| `--ok` | `#3fb950` | success badges |
| `--warn` | `#d29922` | warnings (full-catalog, unsaved) |
| `--err` | `#f85149` | failures |

## Radix Themes configuration

One `<Theme>` wrapper in `main.tsx`, nothing per-page:

- `appearance="dark"`
- `accentColor="teal"` — interactive controls (Switch, Checkbox, primary Button)
- `grayColor="slate"` — neutrals, closest gray family to `#161b22`
- `radius="medium"`
- `panelBackground="solid"`

Component vocabulary (preexisting Radix Themes controls only — no handmade
component library): `Card`, `Flex`, `Grid`, `Text`, `Heading`, `Button`,
`Switch`, `Select`, `TextField.Root`, `Checkbox`, `Badge`, `Callout`,
`ScrollArea`, `Spinner`, `Separator`. Icons from `lucide-react` only.

## CSS overrides (styles.css — small, token-level only)

1. `body` background `#0d1117`, text `#e6edf3`, system sans stack.
2. `.radix-themes[data-appearance="dark"]` — remap Radix panel tokens to the
   brand card color: `--color-panel-solid: #161b22`,
   `--color-panel-translucent: #161b22`, `--color-background: #0d1117`.
3. `.brand-title` — serif display for the wordmark:
   `ui-serif, "New York", Georgia, "Times New Roman", serif`, weight 700,
   tracking −0.5px; the word "Flocked" in `--accent`.
4. `.log-view` — monospace 12px/1.5 `pre-wrap` for pipeline log output.
5. Links in brand accent `#2dd4bf`.

No other CSS. Spacing, radii, focus rings, and motion come from Radix
Themes defaults; motion is limited to Radix's built-in micro-transitions
(Switch thumb, Select open, Spinner) — no custom animation.

## Layout

- Single column, max width 880px, centered; 16px page padding (48px at
  ≥768px). Works from 375px up: grids collapse to one column, region list
  and log view scroll internally.
- Header: logo (`/logo.png`), serif wordmark "You're **Flocked**", subtitle
  "Tile Builder — control plane"; right side: public-site link, live
  connection dot, logout (only when the server requires auth).
- Cards: "Build settings" (regions, schedule, remote publish), "Bucket
  credentials", "Activity" (stage progress, actions, logs, job history).

## States and semantics

- Env-overridden controls: disabled + amber `env` badge next to label.
- Credential keys: badge shows source — `env` (amber), `saved` (green),
  `not set` (gray). Secret values are never rendered, never persisted in
  the browser.
- Job status badges: queued gray, running teal, succeeded green, failed
  red, interrupted amber. Local and remote publish outcomes are two
  separate badges.
- Warnings: full-catalog selection (amber Callout — national graph cost),
  unsaved-settings hint (Build uses *saved* settings).
- Errors: red Callout with the server's `detail` message; never
  `[object Object]`.

## Accessibility

Radix Themes defaults: visible focus rings, labelled form controls,
keyboard-operable Select/Checkbox/Switch, `prefers-reduced-motion`
respected by Radix's built-in transitions.
