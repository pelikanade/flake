# Strata

Strata is a keyboard-first GTK4 file manager: Miller-column, icon, and list
browsing, fuzzy search, previews rendered inside a bubblewrap sandbox, and
optional desktop integration (file chooser portal, folder handling, encrypted
volume unlock).

`modules/packages/strata/default.nix` builds upstream release `v1.0.0` from
source, and `modules/apps/strata.nix` installs it for every machine that imports
the `workstation` role.

## Desktop integration

The aspect makes Strata that workstation's file manager, in the same terms
upstream's installer uses:

- `xdg.mimeApps.defaultApplications."inode/directory"`, so folders open in Strata.
  Thunar was the previous handler and is no longer in the desktop package set.
- A per-user `io.github.lgse.Strata.FileManager1.service`, so "Reveal in file
  manager" and "Open containing folder" reach Strata. Its `Exec` is the package's
  wrapper, so the D-Bus-activated instance has the GIO and GStreamer environment a
  launched one gets.
- `services.gvfs.enable`, because SMB shares, SFTP servers, and phone storage are
  GVfs mounts.

The file chooser portal stays a separate opt-in (`strata --install-portal`, or
**Settings → General**): it replaces Open and Save dialogs for every application,
which upstream deliberately leaves to the user.

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

Every preview and thumbnail renders inside a bubblewrap namespace that runs with
a **cleared environment**, in a mount namespace containing only what the
expression binds and bakes at build time. NixOS has no `/usr`, no system profile
inside that namespace, and no way for a package to install into one, so the
defaults cannot work: with the stock `STRATA_SANDBOX_ROOT=/usr`, the helper cannot
even exec (its ELF interpreter lives in the store) and the app reports
`Preview unavailable — Connection reset by peer (os error 104)`. The expression
therefore sets upstream's documented knobs (see upstream
`docs/preview-sandbox.md`) plus one added by `nix-integration.patch`:

| Build-time variable | Value here |
| --- | --- |
| `STRATA_SANDBOX_ROOT` | `/nix/store`, replacing `/usr` as the read-only runtime tree |
| `STRATA_SANDBOX_PRLIMIT` | `util-linux`'s `prlimit`, the resource-limit launcher |
| `STRATA_SANDBOX_GDK_PIXBUF_MODULE_FILE` | `librsvg`'s `loaders.cache` (GdkPixbuf's loaders plus SVG) |
| `STRATA_SANDBOX_PATH` | `coreutils`, `ffmpeg`, `ffmpegthumbnailer`, `fontconfig`, `imagemagick`, `libraw`, `squashfs-tools`, `util-linux` |
| `STRATA_HELPER_PATH` | the closure's `bubblewrap` |

The sandboxed workers exec those helpers by name for video frames and thumbnails,
camera RAW, document text (`fc-list`), AppImage icons (`unsquashfs`), and the
`nice`/`prlimit` pair around the media decoder, so they are dependencies rather
than upstream's AUR optdepends: `/run/current-system/sw/bin` is not mounted, and
host tools cannot be reached from inside the namespace. The application process
itself is not sandboxed, so its GStreamer audio player keeps the plugin path
`wrapGAppsHook4` builds from `gst-plugins-good` and `gst-libav`.

`bwrap` is resolved from fixed trusted directories, never `PATH`, which is why
`STRATA_HELPER_PATH` exists; trust is unchanged, since a candidate still has to
canonicalize under a trust root, and `/nix/store` is one, while a host's own copy
still wins because those directories are searched first.

Without the helper, the app logs `the bubblewrap sandbox is unavailable` and
refuses the preview instead of rendering it unsandboxed.

Features that never enter the sandbox still come from the host:
`xdg-terminal-exec` for the preferred terminal launcher, and `udiskie`
(deliberately not installed here) for encrypted-volume unlock. Network shares and
phone storage need no extra package: the aspect enables GVfs, whose SMB, MTP,
AFC, and PTP backends are what GIO mounts those locations through.

The package installs the desktop entry and the scalable icon. The per-user
`FileManager1` service comes from the app aspect rather than the package, because
upstream installs it under `$XDG_DATA_HOME`; nothing is ever placed in a system
service directory, where several providers of that name would be ambiguous.

## Checks

`doCheck` is off: upstream runs its suite inside a container image with ffmpeg, a
display, and a Docker daemon. `doInstallCheck` runs the wrapped binary
(`strata --version`), which is what proves the pin still loads against this
nixpkgs. The patch also adds two `update_method_for` unit tests, which upstream CI
runs even though this package does not.

Neither addition has an in-sandbox test that exercises it end to end, so verify
them on the machine: `strata` logs `this installation is managed by Nix; in-app
updates are disabled` when it resolves its update method, and with
`RUST_LOG=strata=debug` a directory holding an image, a PDF or a video logs
`browser worker completed operation=Image|Pdf|Video` and writes
`~/.cache/thumbnails/large`. A preview that fails instead logs
`the bubblewrap sandbox is unavailable`, or surfaces the helper's
`Connection reset by peer (os error 104)` in the preview pane — the signature of a
sandbox whose helper cannot exec.
