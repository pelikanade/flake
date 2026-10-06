# Magpie

Magpie ([yetone/magpie](https://github.com/yetone/magpie)) is a desktop and
terminal interface for managing an AI agent's models and providers: a GTK3
window over a WebKitGTK view, with its own provider list, model picker and plugin
host. `modules/packages/magpie.nix` builds it, and the workstation desktops
install it through the `agent-desktops` aspect, so Asymmetry and Parallax carry
`magpie` on `PATH` and a desktop entry.

This is the application alone. The `magpie` gateway service that box ran, the
`agent-providers.yaml` credentials it decrypted and omp's `magpie` extension were
removed in the same commit as the package; omp's providers are declared in
`models.yml` instead ([omp](omp.md)).

## The package

`buildGoModule` builds the vendored tree with the `production` and `gtk3` tags.
The binary links GTK3, WebKitGTK and the GStreamer plugins the view plays media
with; `wrapGAppsHook3` supplies the GTK environment; `ldflags` stamps the version
the CLI reports. `copyDesktopItems` installs a `Development` entry claiming
`x-scheme-handler/magpie`, which is how the app is handed its own links, and the
icon is installed into hicolor at 1024x1024.

Three patches keep a Nix-managed copy from fighting its store path:

- `internal/gui/update.go` drops the `update.CanElevate()` arm, so the in-app
  updater never asks polkit to replace the store binary.
- `update_cli.go` refuses every `magpie update` except `update check` and tells
  the user to update the Nix package instead.
- `internal/gui/scheme_linux.go` and `internal/autostart/autostart.go` rewrite an
  `os.Executable()` path ending in `.magpie-wrapped` back to `magpie`, because
  the desktop entry and the login autostart entry are launched outside the
  wrapper's environment and must still reach it.

A fourth patch fixes an upstream race the suite already covers. The plugin
host's `init` call writes to the host's stdin, and that write hits `EPIPE` as
soon as the host is gone — before the reader goroutine has seen the end of the
pipe — so a Bun that cannot start the host was counted as healthy and left in
use instead of the previous Bun being tried. Counting a broken stdin pipe as the
host's death is what makes that fallback work;
`TestHostFallsBackWhenTheNewBunDies` fails without it.

Magpie installs its plugins as Bun packages and would otherwise download a Bun
runtime of its own. `MAGPIE_BUN` points at the Nix-managed Bun taken from the
unstable set — Magpie's floor is newer than the Bun in nixos-26.05 — and the
wrapper prepends `xdg-utils` and `desktop-file-utils` to `PATH` and unsets
`APPIMAGE`.

`preCheck` rewrites the test suite's absolute `/bin/cat`, `/bin/mkdir`,
`/usr/bin:/bin` and `--session` references to store paths, and widens the
source-policy test to accept the vendored tree, before
`go test -tags=production,gtk3 ./...` runs. The install check runs the finished
`magpie --version` and, without network or sign-in, adds a test plugin through
the installed wrapper and lists it, asserting that no Bun landed in
`$XDG_CACHE_HOME`.

## State

Runtime state belongs to the user: providers, plugins and settings under
`~/.config/magpie`, plugin and runtime data under `~/.cache/magpie`. Nothing in
this repository provisions either; the app is not configured declaratively.

## Moving to a newer version

Bump `version` together with the `hash` of the new tag, and `vendorHash` when
`go.mod` changes. The in-app updater cannot help and neither can `magpie update`:
the store is read-only and the terminal path refuses on purpose.
