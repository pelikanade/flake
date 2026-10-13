# Strata

Strata is a keyboard-first GTK4 file manager: Miller-column, icon, and list
browsing, fuzzy search, previews rendered inside a bubblewrap sandbox, and
optional desktop integration (file chooser portal, folder handling, encrypted
volume unlock).

`modules/packages/strata/default.nix` builds upstream release `v1.0.0` from
source. Nothing installs it by default; add `pkgs.selfPackages.strata` where a
machine wants it.

## Why the unstable set

The dependency tree requires Rust 1.96 (`kstring 2.0.4`), and nixos-26.05 ships
1.95, so the package takes `pkgsUnstable`: its 1.98 toolchain is the release line
upstream builds with. The native libraries (GTK 4, GtkSourceView 5, GStreamer,
poppler GLib) would build against the stable set.

## Updates belong to Nix

Upstream versions its releases through an in-app updater that downloads a
verified archive and replaces the installed binary. A store path cannot be
replaced, and upstream reserves its `share/strata/install-source.toml` marker for
the AUR packages ([distribution packaging](https://github.com/lgse/strata/blob/main/docs/packaging.md)),
so `nix-integration.patch` adds a fifth update method instead: an executable
under `/nix/store` is reported as Nix-managed.

- The updater refuses to install anything (`perform_install`), so the app can
  never write over its own store path.
- Update checks keep querying GitHub, so **Settings → Updates** still reports a
  newer release, with the instruction to update the package in the Nix
  configuration.
- The status row reads `Version 1.0.0 · Managed by Nix`.

Set `STRATA_BUILD_COMMIT` from the pinned revision (as the expression does),
because build.rs finds no git checkout in the sandbox and would otherwise report
`unknown` in About.

## Runtime

Every preview and thumbnail renders inside a bubblewrap sandbox, and the app
resolves `bwrap` only from fixed trusted directories (`/usr/bin`, `/sbin`,
`/run/wrappers/bin`, `/run/current-system/sw/bin`, …) — never from `PATH`. A
package cannot install into the system profile, and `nixos-26.05` does not carry
`bubblewrap` there by default, so `nix-integration.patch` adds
`STRATA_HELPER_PATH`: a colon-separated list baked at build time that contributes
directories to that lookup. The expression sets it to the closure's `bubblewrap`.
Trust is unchanged, because a candidate still has to canonicalize under a trust
root, and `/nix/store` is one; a host's own copy still wins, since the fixed
directories are searched first.

Without that helper the app logs `the bubblewrap sandbox is unavailable` and
refuses those previews rather than rendering them unsandboxed.

The desktop entry and the scalable icon are installed for launchers; the D-Bus
`FileManager1` service stays an explicit per-user opt-in (`strata
--install-file-manager`, or **Settings → General**), which is why no system
service directory gets it.

Optional capabilities follow upstream's AUR packaging: `ffmpeg` and
`ffmpegthumbnailer` for video previews, `imagemagick` or `libraw` for camera RAW,
`gvfs` plus a backend (`gvfs-smb`, `gvfs-mtp`, `gvfs-afc`, `gvfs-gphoto2`) for
network shares and phones, and `xdg-terminal-exec` for the preferred terminal
launcher. None are dependencies of this package.

## Checks

`doCheck` is off: upstream runs its suite inside a container image with ffmpeg, a
display, and a Docker daemon. `doInstallCheck` runs the wrapped binary
(`strata --version`), which is what proves the pin still loads against this
nixpkgs. The patch also adds two `update_method_for` unit tests, which upstream CI
runs even though this package does not.

Neither addition has an in-sandbox test that exercises it end to end, so verify
them on the machine: `strata` logs `this installation is managed by Nix; in-app
updates are disabled` when it resolves its update method, and a rendered preview
logs `browser sandbox started` (or a media worker starting) instead of
`the bubblewrap sandbox is unavailable`.
