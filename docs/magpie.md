# Magpie

Magpie ([yetone/magpie](https://github.com/yetone/magpie)) is a desktop and
terminal interface for managing an AI agent's models and providers: a GTK3
window over a WebKitGTK view, with its own provider list, model picker and plugin
host. `modules/packages/magpie.nix` builds it, and the workstation desktops
install it through the `agent-desktops` aspect, so Asymmetry and Parallax carry
`magpie` on `PATH` and a desktop entry. The same package runs the model gateway
and its browser page on neko-sphere
through the `magpie` aspect ([the service](#the-gateway-service)).

## The gateway service

`modules/services/magpie.nix` runs `magpie web --gateway` — the browser page on
`0.0.0.0:3430` with the gateway beside it on `0.0.0.0:3425`, one process, no
desktop needed. Gateway mode is what a headless host wants: no Agents,
Sessions or Library surface.

Tailnet peers reach the OpenAI, OpenAI-Responses and Anthropic routes on
`neko-sphere.leaffish-halfmoon.ts.net:3425`. Upstream accepts anything the
gateway's loopback callers present and requires a key only when sharing is
enabled, so the firewall is the boundary: `networking.firewall.interfaces.tailnet0`
admits 3425 and 3430 and loopback keeps working. The endpoint's MagicDNS name
is handed to the gateway in `MAGPIE_PUBLIC_URL`.

The page signs in through the link the service prints into its journal on
every start, which carries the sign-in key as `?k=`. `MAGPIE_WEB_KEY` pins
that key across restarts, from the shared encrypted document
[modules/secrets/magpie.yaml](../modules/secrets/magpie.yaml): the browser
stays signed in for 400 days instead of dying with a run's own key, and
replacing the value in the document (edit with `sops`) revokes every link.
Anyone with the link reaches the daemon — keep the journal line out of logs
you share, and treat 3430 as tailnet-grant material.

Configuration is entirely by hand in the web UI: providers, their keys, model
lists, routing groups and plugins are whatever it saves into
`/var/lib/magpie/.config/magpie/providers.json` and the settings beside it.
Nothing is rendered into the service home from Nix, and a restart or a reboot
keeps every change: the state lives under the persistent `StateDirectory`,
which the unit re-chowns to itself on each start. The keys typed into the UI
therefore sit on the server's disk, protected by the `0700` state directory
tree, the dynamic user and `ProtectSystem=strict` — not by this repository's
sops documents. This service receives only `magpie_web_key` through a systemd
credential. The same [encrypted document](../modules/secrets/magpie.yaml) holds
the endpoint and gateway API key for [omp clients](omp.md#credentials), and its
recipients include Asymmetry, Parallax, neko-sphere and the maintainer. Each host
recipient can decrypt the whole document; client runtime files omit the UI key.

The service runs as `DynamicUser` with a private persistent
`StateDirectory=magpie` and `HOME=/var/lib/magpie`, hardened with
`ProtectSystem=strict`, `ProtectHome` and `PrivateTmp`, and restarts on
failure. The UI's Providers page adds keyed vendors (`magpie provider add
deepseek sk-…` is the same thing from a shell) and accounts; whatever it lists,
the gateway serves, and `/v1/models` shows served providers' models. Upstream
rotates the model catalog on its own.

A second gateway must not listen on 3425 anywhere on the tailnet; peers cannot
tell them apart.

### Verifying the gateway

After separately authorized deployment, from a tailnet peer:

```sh
systemctl status magpie.service          # on neko-sphere
curl --fail --silent http://neko-sphere.leaffish-halfmoon.ts.net:3425/v1/models | head
curl --silent http://neko-sphere.leaffish-halfmoon.ts.net:3430/ -o /dev/null -w '%{http_code}\n'  # 401: the key guards every page
```

`/v1/models` is the catalog the UI has configured — empty until the first
provider is added there. A real chat round-trip against one of its models
proves the key resolves and the upstream still answers:

```sh
curl --fail --silent -X POST -H 'Authorization: Bearer magpie' \
  -H 'content-type: application/json' \
  http://neko-sphere.leaffish-halfmoon.ts.net:3425/v1/chat/completions \
  -d '{"model":"<provider>/<model>","max_tokens":8,"messages":[{"role":"user","content":"ping"}]}'
```

`journalctl -u magpie.service` holds the sign-in link and any startup
failures; keep the link and any credential output out of shared logs. The
link arrives once per start and stays valid while `magpie_web_key` is
unchanged. Evaluation and package builds alone cannot prove these behaviors.

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
this repository provisions the desktop app's state; the app is not configured
declaratively. The gateway service's home is the same shape: every provider,
key, model list and setting it is given is claimed through the web UI and
stored under the service home, and nothing here renders into that home.

## Moving to a newer version

Bump `version` together with the `hash` of the new tag, and `vendorHash` when
`go.mod` changes. The in-app updater cannot help and neither can `magpie update`:
the store is read-only and the terminal path refuses on purpose.
