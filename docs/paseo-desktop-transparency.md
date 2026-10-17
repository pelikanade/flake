# Paseo desktop transparency

The Linux Paseo Desktop window is transparent and paints a single translucent
glass tint over Hyprland's blurred wallpaper. Cards, tabs, pills, buttons,
popovers and menus are tinted with low-alpha overlays instead of opaque
surfaces, so they keep a visible base colour while the wallpaper still shows
through.

This is a local patch, not an upstream feature. It targets the pinned Paseo
release and is expected to need attention whenever that release moves.

- Package: `modules/packages/paseo-desktop.nix`
- Patch: `modules/packages/paseo-desktop-transparency.patch`
- Current target: Paseo `v0.11.4` (tag commit `dc5b02f`), applied with `-p1`
  during `patchPhase`.

## How the layer works

1. The Electron main process creates the Linux window with `transparent: true`
   and `backgroundColor: "rgba(0, 0, 0, 0)"`.
2. The renderer's chrome sync sends an opaque theme colour to the main process.
   `window-manager.ts` ignores that colour on Linux, because applying it would
   paint over the transparent surface again.
3. The renderer paints **one** tint at the root:
   `windowFill` uses `theme.colors.surfaceGlass`, which is
   `rgba(24, 27, 26, 0.85)` for the default dark theme. Every structural
   surface below it is transparent; painting another translucent layer would
   multiply the alpha and turn the window opaque.
4. React Navigation normally paints each screen with `rgb(242, 242, 242)` from
   its default theme. `_layout.tsx` wraps the app in a `ThemeProvider` whose
   navigation background is transparent.
5. Cards, row states, tabs, pills and popovers use low-alpha overlays on top of
   the glass. The result is a visible base tint with the wallpaper still
   visible through it.
6. Popovers float over the app, not over the desktop, so the compositor cannot
   blur what is behind them. Web builds use `backdrop-filter: blur(20px)` and
   `index.html` also applies it to `[data-menu-surface="true"]`. Native builds
   keep the translucent fill without the CSS blur.

Light themes deliberately stay visually opaque: `surfaceGlass` is the theme's
opaque `surface0`, matching MonoCode's dark-only glass behaviour. The window is
still transparent at the Electron level, but the renderer covers it.

Non-Linux Electron targets are untouched by the window options. The renderer
glass tokens still fall back to opaque colours where `GLASS_ENABLED` is false.

## Renderer tokens

Defined in `packages/app/src/styles/theme.ts`:

| Token | Dark glass (Electron/Linux) | Light theme | Dark non-glass |
| --- | --- | --- | --- |
| `surfaceGlass` | `rgba(surface0, 0.85)` | opaque `surface0` | opaque `surface0` |
| `surfaceCard` | `rgba(255, 255, 255, 0.06)` | `rgba(0, 0, 0, 0.035)` | opaque `surface1` |
| `surfaceRowHover` | `rgba(255, 255, 255, 0.04)` | `rgba(0, 0, 0, 0.035)` | opaque `surface1` |
| `surfaceRowSelected` | `rgba(255, 255, 255, 0.07)` | `rgba(0, 0, 0, 0.06)` | opaque `surface2` |
| `surfaceRowPressed` | `rgba(255, 255, 255, 0.09)` | `rgba(0, 0, 0, 0.09)` | opaque `surface2` |
| `surfaceCode` | `rgba(255, 255, 255, 0.07)` | `rgba(0, 0, 0, 0.045)` | opaque `surface2` |
| `surfaceMenu` | `rgba(surface1, 0.55)` | `rgba(255, 255, 255, 0.9)` | opaque `surface1` |

`glassBackdropFilter` is the web-only blur object used by menus, dropdowns and
hover cards. `react-native-web.d.ts` declares the two CSS properties for
TypeScript; React Native Web passes them through to CSS.

Tune the effect in `theme.ts`. `GLASS_ALPHA` controls the root tint; the
`surface*` entries control cards, rows and popovers. If a surface looks too
opaque, lower its alpha rather than adding a second tint layer.

## What the patch touches

The patch is organised by intent, not by file count:

- **Window and chrome**: `packages/desktop/src/main.ts`,
  `packages/desktop/src/window/window-manager.ts`.
- **Root and navigation**: `packages/app/public/index.html`,
  `packages/app/react-native-web.d.ts`, `packages/app/src/app/_layout.tsx`,
  `packages/app/src/navigation/themed-stack.tsx`.
- **Structural surfaces**: workspace, tabs, headers, sidebar, splits, screen
  roots, splash and error screens, setup/plugin screens, `page-layout`.
- **Rows and selection**: agent list, sidebar workspace/status renderers,
  explorer tree, settings sidebar, collapsible rows, segmented controls.
- **Cards and pills**: composer input, composer pills, `DiffStat` pill, thinking
  / tool-call expansion, settings cards, open-project tiles.
- **Popovers**: shared menu surface and menu items, combobox, autocomplete,
  select/button hovers, hover cards. Context menus and plugin popovers use the
  shared `MenuSurface`, so they are covered by the same change.
- **Diff views**: file header, diff header/context lines, tool-call diff and
  scroll areas, diff-pane callouts.
- **Markdown and code**: inline code, fenced code, tables, blockquotes, details
  summaries, code surfaces, front matter cells, startup logs.
- **Floating UI**: toasts, download progress, pane find, command center,
  workspace/plugin hover cards, zoom controls, dialogs and sheets.
- **Workspace gate**: the loading/unavailable/recovery shell uses
  `containerWorkspaceBackground`, not the opaque `container`, so a freshly
  created or temporarily unavailable workspace stays glass.

## Updating the patch for a new Paseo release

1. Bump `version` in `modules/packages/paseo-desktop.nix`, update `src.hash`
   with `nix-prefetch-url --unpack` or from the build error, then update
   `npmDepsHash` the same way. `paseo-daemon.nix` inherits the version, source
   and dependency hashes, so it follows automatically; it does not apply this
   patch because it builds the headless server rather than the renderer.
2. Fetch the matching tag into a scratch checkout, for example:
   `git clone --depth 1 --branch vX.Y.Z https://github.com/getpaseo/paseo`.
3. Check that the patch still applies:
   `git apply --check modules/packages/paseo-desktop-transparency.patch`.
   If it applies, run the build. If it does not, apply with
   `git apply --3way` and resolve by intent using the categories above.
4. Re-apply rejected hunks in the new source rather than editing the built
   `app.asar`. Upstream regularly moves styles between files; keep the
   **transparent structural layer + one tint layer** model instead of copying
   old line numbers.
5. Regenerate the patch from the scratch checkout:
   `git diff > modules/packages/paseo-desktop-transparency.patch`.
6. `git add` the patch before building. Nix only sees staged files, and an
   unstaged patch silently leaves the previous derivation cached.
7. Build with `nix build .#paseo-desktop`. The patch phase fails loudly when a
   hunk no longer matches; that is the signal to repeat step 4.
8. Deploy separately after review (`just deploy` requires explicit
   authorization), then check both themes in the live Hyprland session.

## Adding a newly found opaque surface

When a new card, tab, or popover still reads as a flat plate, do not change
`surface0` or `surface1`. Choose the token by role:

- a card or panel -> `surfaceCard`
- a code block, inline code, log, or diff context -> `surfaceCode`
- a hovered row, tab, or button -> `surfaceRowHover`
- a selected row or active tab -> `surfaceRowSelected`
- a pressed row -> `surfaceRowPressed`
- a popover, dropdown, context menu, or plugin popover -> `surfaceMenu`
  plus `glassBackdropFilter`

If the surface is a structural container that spans a whole region, make it
transparent instead and let the single root glass layer show through. If it is
a popover, it needs `surfaceMenu` and the web backdrop blur, because the
compositor cannot blur the app content behind it.

## Surfaces intentionally left opaque

Not every `surface*` background is a plate. These stay opaque on purpose:

- Terminal emulator body, browser webview, and file editor body: long-form
  reading and terminal contrast win over wallpaper bleed.
- Skeleton placeholders (`sidebar-agent-list-skeleton`, PR/commit skeletons).
- Status-ring and sidebar status backdrops used to knock holes out of icons;
  they must match an opaque paint to cut the icon cleanly.
- Small badges, shortcut chips, usage meters, and diff add/remove tints: their
  colour is the signal, and they are already translucent where appropriate.
- Modal scrims and image/video previews, where dimming is the point.

If one of these reads as a plate in the live UI, convert it with the role
table above rather than making `surface0` translucent.

## Verification

- Patch applies cleanly to a clean checkout of the pinned tag.
- `nix build .#paseo-desktop` completes, including the desktop `tsc` step and
  the Expo web export.
- Extract the packaged main process and confirm `transparent: true`,
  `rgba(0, 0, 0, 0)` and the Linux guard around `setBackgroundColor`:
  `asar extract-file .../app.asar dist/main.js`.
- In a headless browser loading the exported renderer with a
  `window.paseoDesktop` stub, the computed root background is
  `rgba(24, 27, 26, 0.85)`, the navigation background is not
  `rgb(242, 242, 242)`, and a corner pixel over white is about
  `rgb(58, 61, 60)` (the expected alpha composite).
- In the live app, check dark mode: root glass and wallpaper blur; composer,
  sidebar selection, tabs, pills, thinking/tool blocks, settings cards, diff
  panel, context menus, dropdowns and plugin popovers should read as tinted
  glass, not flat plates. Toggle light mode: it should remain opaque and
  readable.

## Pitfalls

- **Do not make `surface0` translucent.** It is also used as a text/icon colour
  and in string concatenations such as `${surface0}cc`; changing the token
  breaks both. Add or use the dedicated glass tokens instead.
- **One paint layer per region.** Stacking two 85% layers reaches roughly 98%
  opacity. Keep section containers transparent and paint the tint once at the
  root (`windowFill`) or once per floating surface.
- **Keep `html` and `body` transparent.** The original dark
  `background-color: #181b1a` sits behind the glass and makes it opaque.
- **Keep the navigation theme background transparent.** Otherwise every
  screen paints an opaque `#f2f2f2` layer over the glass.
- **Menus need their own blur.** The Hyprland compositor only blurs the desktop
  behind the window. Use `surfaceMenu` plus `backdrop-filter` (web) so app
  content behind a popover is blurred rather than sharp; do not lower the menu
  alpha without that blur.
- **Linux-only window changes.** Transparent windows on other platforms have
  different resize/shadow limitations. This package is Linux-only; keep the
  `process.platform === "linux"` guards if the source is reused elsewhere.
- **Hyprland must blur.** `decoration.blur.enabled` is already set in this
  repository. Without compositor blur the glass shows the raw wallpaper.
- **Do not use `sed` or hand-edited line numbers.** The patch is the contract;
  a failed hunk should stop the build, not silently ship a half-transparent
  app.
- **Do not apply the patch to the installed store path.** Rebuild the package;
  the deployed application is an immutable Nix store output.
