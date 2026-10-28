# Clawd on Desk

[Clawd](https://github.com/rullerzhou-afk/clawd-on-desk) is a pixel desktop pet
that follows AI coding agents: it animates while a session works, shows a card
when a tool needs permission, and keeps a HUD and a dashboard of live sessions.
It is an Electron application, and it ships installers for Windows, macOS,
AppImage and deb; here it is built from the release tag.

`modules/packages/clawd-on-desk/default.nix` pins one release. `agent-desktops`
installs it, with the Node runtime its agent hooks need, through
`pkgs.selfPackages.clawd-on-desk`.

## Layout

Upstream's release keeps the application in `resources/app.asar` and the parts
that cannot live in an archive — the hook scripts, the theme assets, the koffi
addon — beside it in `resources/app.asar.unpacked`. This package ships no
archive, so the application directory *is* `resources/app.asar.unpacked`, and
both layouts' path assumptions resolve to the same tree:

- `hooks/auto-start.js`, the SessionStart hook that starts the pet when an agent
  starts, decides between "release" and "source checkout" by looking for
  `app.asar` in its own directory name, and the release branch is the one that
  can spawn `<install>/clawd-on-desk`; the wrapper is there for it.
- The app's other release-shaped paths (`process.resourcesPath/app.asar.unpacked/…`)
  are behind `app.isPackaged`, which stays false: the wrapper runs the Electron
  binary under its own name with the application directory as its argument, the
  layout `npm start` uses. That keeps the application's own tree — `src/`,
  `agents/`, `hooks/`, `themes/`, `assets/`, `pwa/` — as the single source of
  those paths, disables the in-app updater, and leaves the Linux "start at
  login" writer as the only place that assumed the `electron` npm package is
  installed. A patch makes that writer store the executable it is running from
  with the application directory as its argument, which is what the app already
  writes on macOS.

The koffi addon is the one native dependency. Its package ships a prebuilt
binary for every platform, and the package keeps only the one this host loads.
That binary needs `libstdc++`, which nothing else in the tree links (Chromium
and Electron carry their own C++ runtime), and the process that resolves the
dependency is the `dlopen()` of the addon itself — which consults the addon's
own RPATH and the loader cache, never the RPATH of the Electron process. The
package therefore points the addon at the C++ runtime instead of exporting
`LD_LIBRARY_PATH` for every launch path. Without it, every koffi caller in the
app silently falls back, starting with the X11 input hint that keeps the pet's
window from taking keyboard focus.

## Wayland and X11

Upstream runs the pet as an XWayland client by default: native Wayland forbids
client-side window positioning and global cursor queries, so the pet could
neither be dragged nor follow the cursor. The app relaunches itself with
`--ozone-platform=x11` on a Wayland session with an X server, and honors
`CLAWD_OZONE_PLATFORM=wayland|x11|auto` to override that decision.

The wrapper connects that switch to the NixOS convention: when
`NIXOS_OZONE_WL` is set — this repository's Hyprland session sets it, as
NixOS users expect Electron applications to honour — and a Wayland display is
present, the wrapper sets `CLAWD_OZONE_PLATFORM=wayland`, which leaves the app
on Chromium's own Ozone default instead of relaunching it under XWayland. So on
such a session the pet is a native Wayland client and cannot be dragged or
placed by the app; `CLAWD_OZONE_PLATFORM=x11 clawd-on-desk` restores the
XWayland behaviour the app is designed around, which is also what happens on a
session that does not set `NIXOS_OZONE_WL`.

## Hyprland

`modules/apps/hyprland/default.nix` carries a `clawd-overlays` window rule for
the pet and its overlay windows (the session HUD, the quota ring, the
permission bubbles, the click surface and the roam-fence picker). They are
frameless windows that draw their own pixels on a transparent surface, so the
compositor's border, rounding, shadow and blur draw a rectangle around a sprite
that is neither rectangular nor decorated, and the configured move animation
makes a pet that writes its own position every frame trail behind it. The rule
matches those windows by title — every frameless page in the app falls back to
the application name for a title it does not set, and the framed dialogs
(settings, dashboard, welcome) are localized and keep their decorations.

## Agent integrations

Clawd watches agents through hooks it installs into their configuration files,
and every hook it writes is a Node script: `node <app>/hooks/clawd-hook.js
<event>`. It resolves the interpreter from paths a NixOS machine does not have
and falls back to the bare name, so `agent-desktops` installs `pkgs.nodejs`
with it — otherwise the hooks it registers cannot run at all, and the app's own
doctor can only report that. The app writes the hook commands into
`~/.claude/settings.json`, `~/.codex/…` and the other agents' configuration
when they are installed, and keeps them in sync on every launch.
