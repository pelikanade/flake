# Tern

Tern is Stencil's closed-beta terminal workspace: one native window holding
panes, files and remote sessions. It is closed source and, in beta, published
only through Stencil's build service, so it cannot be fetched by a Nix build and
cannot be redistributed here.

`modules/packages/tern.nix` pins one build of it. Nothing installs it by default;
add `pkgs.selfPackages.tern` where a machine wants it.

## The artifact

| Artifact | Use |
| --- | --- |
| `Tern-<version>-linux-x86_64.tar.gz` | glibc, the one NixOS runs; pinned here |
| `Tern-<version>-linux-musl-x86_64.tar.gz` | musl loader and libstdc++; saves nothing on NixOS |

Both hold a single `tern/tern`; the version is `0.6.0`, whose build service id is
`20261007-073820-0e39682` (the trailing commit is what `tern --version` prints).

`https://tern.sh/releases/...` also serves a binary called `tern`, and it is a
different product: the hosted tour and hook tool documented at `tern.sh`. Do not
package the terminal from it.

## Why requireFile

An unauthenticated request for a `build.stencil.so/d/tern/...` artifact is a 302
to `auth.stencil.so/login`, so `fetchurl` receives a login page and no hash can
match. The expression therefore uses `requireFile`: it records the URL, the
artifact name and its hash, and the build succeeds only once that exact tarball
is in the store. Download it while signed in; the first command prints the SRI to
put in `hash`, and the second is what makes the build's output path exist:

```sh
nix hash file --type sha256 --sri ~/Downloads/Tern-0.6.0-linux-x86_64.tar.gz
nix-store --add-fixed sha256 ~/Downloads/Tern-0.6.0-linux-x86_64.tar.gz
nix build .#tern
```

`requireFile` compares by output path, which is the content hash plus the
artifact's own file name: add the tarball under the name the expression expects,
and neither rename it (`Tern-0.6.0-linux-x86_64(1).tar.gz` will not do) nor edit
it. Keep the artifact out of the repository and out of any public cache.

## The build

The artifact is a glibc binary that links nothing beyond glibc, libstdc++ and
libgcc_s; `autoPatchelfHook` supplies the last two. It needs more than that.
Tern draws through wgpu, which dlopens Vulkan, EGL and the Wayland client, so
those directories and the host's GPU driver directory are appended to its
RUNPATH; 0.6.0's windowing also dlopens `libxcb.so.1` for the X11 backend, so
`libxcb` joins them, and `libxkbcommon` carries the `libxkbcommon-x11.so.0` that
pairs with it. `tern register` shells out to `git` and the desktop and icon
caches, so the wrapper prepends them to `PATH`. `versionCheckHook` runs the
finished binary, which is what proves the pin still loads against this nixpkgs.

The browser pane is the other runtime gap. Tern dlopens its web engine, taking
WPE WebKit if it is present and WebKitGTK otherwise, so `webkitgtk_4_1` joins
those libraries on the RUNPATH: no other package on NixOS answers to
`libwebkit2gtk-4.1.so.0`, and the dlopen happens from the executable, which is
where RUNPATH is read.

WebKitGTK's network process then takes its TLS backend from a GIO module, which
no RUNPATH can supply, because GIO finds those through `GIO_EXTRA_MODULES`.
`agent-desktops` enables `services.gnome.glib-networking` for that. It cannot be
the package's own wrapper environment: Tern registers itself with the path of the
binary it runs from — the wrapped executable, not the wrapper — so the desktop
entry and the profile's links launch it without that environment, while the
session variable reaches every launch. The engine alone works without it; pages
over HTTPS report `TLS support is not available`.

## Moving to a newer build

Take the new link, and update `build`, `version` and `hash` in the expression
together. The in-app "Check for updates" and "Restart to update" cannot help: the
store binary is read-only, and an update would land outside Nix's control.
Runtime state — sign-in against `auth.stencil.so`, linked repositories, plugins
and logs — lives in `~/.config/tern`, or wherever `TERN_CONFIG_DIR` points, and
survives a package bump.
