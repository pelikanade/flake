# GNOME desktop

The workstation role runs GNOME on GDM. `modules/apps/gnome/default.nix` enables
`services.desktopManager.gnome.enable` and names `gnome` as the display manager's
default session, so GDM preselects the Wayland session rather than the X one.
Enabling GNOME also turns on what it cannot run without — dconf, the GNOME and
GTK XDG portals, gnome-keyring, gcr's ssh agent, upower, udisks2, libinput,
power-profiles-daemon, NetworkManager and Bluetooth — and installs its core shell
and core apps.

The `keyring` aspect keeps `services.gnome.gnome-keyring` on. GDM's PAM session
unlocks the login keyring, so the Secret Service is up before the session's
applications read it: Obsidian's `--password-store` backend, 1Password, and the
flatpak portal's `org.freedesktop.impl.portal.Secret` mapping all point at
gnome-keyring.

## Applications

GNOME's core apps are what the desktop's tools come from. The KDE and XFCE
packages the previous session carried — Dolphin, Atril, Ristretto, xarchiver,
tumbler — are gone with it:

| Task | Application |
| --- | --- |
| Files | nautilus, which also ships the `org.freedesktop.FileManager1` service file that "reveal in file manager" activates |
| Archives | file-roller, added to `environment.systemPackages` because it is not part of the core apps |
| Documents, images | papers, loupe |
| Secrets (keyring front end) | seahorse, through `programs.seahorse.enable` |
| Terminal | GNOME Console, alongside Ghostty |
| Extensions, startup apps, titlebar buttons | gnome-tweaks |

`wl-clipboard` stays installed for command line use; the session's own clipboard
is GNOME Shell's, and clipboard history comes from the Clipboard Indicator
extension.

## Extensions

`programs.gnome-shell.extensions` installs each package into the profile, which
is what puts it on the shell's search path, and names it in
`org.gnome.shell.enabled-extensions`:

| Id | Extension | For |
| --- | --- | --- |
| 615 | AppIndicator and KStatusNotifierItem Support | tray icons from applications that only ship an AppIndicator |
| 3193 | Blur my Shell | blur for the panel, dash and overview |
| 517 | Caffeine | suspend and screensaver inhibition from the top bar |
| 307 | Dash to Dock | the dock |
| 779 | Clipboard Indicator | the session's clipboard history |
| 6807 | System Monitor | CPU, memory and network in the top bar |
| 7065 | Tiling Shell | tiling layouts and keyboard-driven window management |

Dash to Panel (1160) is installed but deliberately left out of
`enabled-extensions`: it and Dash to Dock both take over the dash, so enabling
both draws two of them. The Extensions app (`gnome-extensions-app`, or
`gnome-extensions enable dash-to-panel@jderose9.github.com`) switches between
them.

## Input method

GNOME runs IBus itself. `modules/apps/ibus.nix` enables
`i18n.inputMethod.type = "ibus"` and adds Rime as an engine built against
`rime-ice`; Home Manager then names the two input sources, the plain US layout
and Rime, in `org.gnome.desktop.input-sources.sources`. `Ctrl+Space` switches
between them and `Shift+Ctrl+Space` reverses, replacing GNOME's default
`Super+Space` chord.

The session's D-Bus activation starts `ibus-daemon --panel disable`, so GNOME
Shell draws the candidate window; no KDE kimpanel bridge or shell extension is
involved. Wayland clients reach IBus through text-input-v3, and XWayland clients
through `ibus-x11`.

`ibus-rime` keeps its user data under `~/.config/ibus/rime` (it hardcodes that
path), so `default.custom.yaml` lives there and selects the `rime_ice` schema.
The old fcitx5 tree under `~/.local/share/fcitx5` is not read.

## Theming

Stylix drives GNOME the way it drove the rest of the desktop: its GNOME target
writes the background, the interface fonts and `color-scheme` through dconf,
the user-themes extension carries the generated shell stylesheet, and the login
screen gets the cursor and icon theme from a locked dconf profile plus a replaced
`gnome-shell-theme.gresource`. The cursor is GNOME's own `Adwaita`, and the icon
theme is `Tela-dark`. `stylix.image` is not set, so the target leaves the
wallpaper alone and GNOME's own default stands.

GNOME also makes Stylix's Qt target follow the desktop, which is where two
evaluation warnings come from: it selects the `gnome` platform theme, Home
Manager reports that value as deprecated (it is called `adwaita` now), and
Stylix's own Home Manager Qt target reports the platform as unimplemented on its
side. Neither changes the result — Qt applications get the Adwaita platform theme
and the `adwaita-dark` style, which the NixOS side sets.

## After activation

- **Monitor layout.** GNOME detects the arrangement itself; the per-machine
  monitor and workspace rules that used to live in `machines/parallax.nix` and
  `machines/asymmetry.nix` are gone, so where the physical arrangement, scaling
  or rotation needs to differ from what GNOME picks, set it once in Settings and
  use "Apply" (GNOME keeps the layout in `~/.config/monitors.xml`).
- **Screenshots keep their chords**: `Super+Shift+S` opens GNOME's interactive
  screenshot UI, which starts on area selection, and `Super+Shift+P` captures the
  whole screen into `~/Pictures/Screenshots`. GNOME's own `Print`, `Shift+Print`
  and `Alt+Print` stay bound alongside them, and `Ctrl+Shift+Alt+R` opens the
  recording UI. The previous session's `Super+Shift+A` annotation has no
  counterpart here.
- **CJK input in a Tern pane** after a focus change needs checking; Tern now
  reaches IBus through GNOME Shell, see [Tern](tern.md).
- **Clawd's pet** no longer has a window rule; whether it follows every workspace
  needs checking, see [Clawd on Desk](clawd-on-desk.md).
