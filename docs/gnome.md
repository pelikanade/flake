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
is GNOME Shell's, and clipboard history comes from Vicinae, which the extension
feeds copy events.

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
| 6807 | System Monitor | CPU, memory and network in the top bar |
| 8594 | Vicinae | the launcher's clipboard and window-management APIs |

Dash to Panel (1160) is installed but deliberately left out of
`enabled-extensions`: it and Dash to Dock both take over the dash, so enabling
both draws two of them. The Extensions app (`gnome-extensions-app`, or
`gnome-extensions enable dash-to-panel@jderose9.github.com`) switches between
them.

## Vicinae

`modules/apps/vicinae.nix` runs the daemon as a user service for the whole
graphical session, so the launcher is up before any hotkey fires.
`Super+Space` toggles it: GNOME's own `switch-input-source` binding holds that
chord by default, and the aspect clears both it and its `Shift` counterpart,
which is free here because fcitx5, not GNOME, owns input methods in this session.
The keybinding is a GNOME custom keybinding running `vicinae toggle`, the same
mechanism the desktop's own settings use, so it also shows up in the GNOME
keyboard panel.

## Theming

Stylix drives GNOME the way it drove the rest of the desktop: its GNOME target
writes the background, the interface fonts and `color-scheme` through dconf,
the user-themes extension carries the generated shell stylesheet, and the login
screen gets the cursor and icon theme from a locked dconf profile plus a replaced
`gnome-shell-theme.gresource`. `stylix.image` is not set, so the target leaves
the wallpaper alone and GNOME's own default stands.

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
- **CJK input in a Tern pane** after a focus change needs checking; see
  [Tern](tern.md), whose input-method workaround was removed with the previous
  session.
- **Clawd's pet** no longer has a window rule; whether it follows every workspace
  needs checking, see [Clawd on Desk](clawd-on-desk.md).
