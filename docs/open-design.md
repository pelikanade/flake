# OpenDesign

OpenDesign is a local-first design-agent workspace: it runs design skills against
a coding agent and renders the resulting prototypes, dashboards, decks, images
and motion graphics in a sandboxed preview.

Upstream publishes desktop installers for macOS and Windows only; its Linux lane
builds an AppImage behind CI's `ENABLE_STABLE_LINUX` and publishes nothing. Both
shapes of the product are built here from release `open-design-v0.25.0`, and they
are the same application underneath — one local daemon owns projects, skills,
design systems and agent runs, and one web workspace talks to it:

| Package | What it is |
| --- | --- |
| `open-design` (`od`) | The daemon, serving the statically exported web workspace itself. Upstream's Linux and container answer: the browser is the workspace, and every capability is also an `od` subcommand. |
| `open-design-desktop` | The Electron application upstream ships on macOS and Windows: it starts a daemon sidecar and a Next.js server web sidecar and loads the workspace in a window. |

`modules/apps/agents/agent-desktops.nix` installs the desktop application for
every machine that imports the `workstation` role. `pkgs.selfPackages.open-design`
is the daemon, for a browser session, a service or a container.

## Running the daemon

```sh
od                # start the daemon on 127.0.0.1:7456 and open the browser
od --no-open      # start it without opening a browser
od status         # health, version and plugin count from the running daemon
od --help         # every UI feature also has a subcommand
```

The daemon scans `PATH` for the coding-agent CLIs it can drive (Claude Code,
Codex, `dsh`, and the rest of upstream's registry) and offers BYOK providers for
everything else, so the agents themselves stay other packages' business.
`od agent setup deepseek-harness` installs the connection component this package
ships into the user's own `dsh` profile.

## What the daemon package holds

The daemon resolves its workspace root from its own location, and reaches every
dependency through the relative links pnpm creates, so the package keeps parts of
upstream's shape instead of flattening it:

| Path | What reads it |
| --- | --- |
| `apps/daemon/{bin,dist}` | The `od` CLI entry and the daemon |
| `apps/web/out` | The static export served at `/` (`STATIC_DIR`, `apps/daemon/src/server.ts`) |
| `resources/` | `OD_RESOURCE_ROOT`: skills, design systems, design templates, craft rules, prompt templates, bundled plugins (`_official`, `registry`), frames, community pets, the plugin-preview manifest, and the DeepSeek Harness connection tarball |
| `resources/bin/vela`, `resources/bin/libexec/opencode/opencode` | The Vela CLI and the OpenCode companion its release pins, spawned for Cloud sign-in, team projects, billing and every other AMR-backed call |
| `node_modules/.pnpm`, `packages/` | The daemon's production dependency closure, plus the workspace packages its `@open-design/*` links point at |
| `sharp-libvips/lib` | The `LD_LIBRARY_PATH` entry sharp needs (below) |

The wrapper pins five values: `OD_RESOURCE_ROOT` (above), `OD_DATA_DIR`, `OD_BIN`
(so a spawned agent finds the CLI back), `OD_NODE_BIN`, and `LD_LIBRARY_PATH`.
Its `PATH` gains `bash`, `git`, `poppler-utils` and `xdg-utils` — the same
external tools upstream's container image installs, `xdg-utils` because `od` opens
the browser through `xdg-open`.

Runtime state lives outside the store: `$XDG_DATA_HOME/open-design` unless
`OD_DATA_DIR` says otherwise, holding SQLite, projects, artifacts, user skills and
design systems, plugin state, diagnostics, media credentials (they follow
`OD_DATA_DIR`, per upstream's own precedence) and the scratch directory the
design-system importers clone into.

## The packaged desktop application

Inside `$out/lib/open-design-desktop/linux-unpacked`:

| Path | What it is |
| --- | --- |
| `Open Design` | nixpkgs' Electron dist, renamed — Electron treats an executable named `electron` as its default app and reports `app.isPackaged === false` |
| `resources/app` | The bundle: upstream's one-line `main.cjs` entry, the preload, the packaged manifest, and a production-only workspace tree whose `node_modules/@open-design/*` links let the shell resolve `@open-design/packaged` and both `…/sidecar` entries |
| `resources/open-design` | The resource root the packaged config points at: the content trees, plus the Node the sidecars run on (`bin/node`) and the Vela CLI with its OpenCode companion (`bin/vela`, `bin/libexec/opencode/opencode`) |
| `resources/open-design-config.json` | Read from `resourcesPath/open-design-config.json` (`apps/packaged/src/config.ts`); portable, so no build-machine path is baked |
| `resources/dom-to-pptx.bundle.js.gz` | The editable-PPTX export bundle, read from `resourcesPath` |

The window loads `od://app/`, which the shell proxies to the web sidecar
(`apps/packaged/src/protocol.ts`), so the packaged runtime always carries the web
app's **server** build and its runtime dependencies — where the daemon package
ships the static `out/` export instead.

Four details are load-bearing, three of them found by running the thing:

- **The wrapper sets none of the daemon package's environment.** The packaged
  runtime owns `OD_RESOURCE_ROOT`, `OD_DATA_DIR` and `OD_NODE_BIN` for the
  sidecars it starts, and a wrapper value wins over all three. `OD_RESOURCE_ROOT`
  especially: the daemon refuses a resource root that is not under its workspace
  root, `process.resourcesPath` or `OD_INSTALLATION_DIR`, and the first smoke run
  died exactly there — the wrapper inherited the daemon package's value, which
  points outside the app.
- **The bundled Node is a copy, not a symlink.** Node reports `process.execPath`
  from `/proc/self/exe`, and the daemon accepts its resource root only when that
  path carries a `resources/open-design/bin/` marker
  (`apps/daemon/src/daemon-paths.ts`). Through a symlink it becomes the store path,
  the marker is gone, and the daemon exits 1 at startup — which is why upstream
  copies the binary rather than linking it.
- **The native modules are built for Node, not for Electron.** They belong to the
  daemon sidecar, which the runtime starts on `resources/open-design/bin/node`.
  This is the same reason upstream's electron-builder config turns `npmRebuild`
  and `nodeGypRebuild` off, and why sharp's libvips substitution from the daemon
  package is repeated here.
- **The copied Electron dist keeps its dlopen RPATHs.** The fixup phase's
  `patchelf` hook shrinks RPATHs to the directories that satisfy `DT_NEEDED`;
  ANGLE opens `libGL` and `libvulkan` by name and Chromium opens `libpci` for
  GPU discovery, so those are invisible to it. The desktop package adds the
  three back to `libGLESv2.so` and the `Open Design` binary after
  `autoPatchelf`, and `installCheck` asserts they stayed. Without them the GPU
  process logs `Could not dlopen libGL.so.1` and falls back to
  `gpu_compositing: disabled_software`: the welcome screen still looks fine,
  but the blur-and-liquid-glass workspace after sign-in runs at software frame
  rates and burns CPU. Re-check this after an Electron bump.
- **Electron 42, not upstream's 41.** nixpkgs marks `electron_41` insecure; 42 is
  the nearest line its build accepts. The shell uses only stable Electron APIs
  (`app`, `BrowserWindow`, `protocol`, `dialog`, `shell`), and does not run the
  sidecars on Electron at all.
- **Wayland follows nixpkgs' `NIXOS_OZONE_WL` convention.** When that and
  `WAYLAND_DISPLAY` are both set, the wrapper appends `--ozone-platform=wayland`
  with the decoration, IME and text-input features. It is the explicit platform
  switch rather than the `--ozone-platform-hint=auto` nixpkgs hands other Chromium
  applications: this Electron does not carry that switch, and passing it leaves the
  application on X11 — seen by running it against a headless Weston, where only the
  explicit form comes up with `DISPLAY` unset. Chromium reads its switches out of
  argv, which the packaged launcher ignores: it parses only its own flags.

electron-builder is not run. For a directory target its Linux configuration
(`asar: false`, those two rebuild flags off, `tools/pack/src/linux.ts`) leaves
exactly the pieces the install phase places, and copying them needs neither
electron-builder's Electron download nor a cache the sandbox cannot fill. There is
no AppImage and no updater: the store is read-only and the app is updated by
rebuilding the package, so the packaged config carries no `updateMetadataUrl`.

## Build notes

- **One source, two packages.** `default.nix` pins the release tag, its revision,
  the source hash and the pnpm version upstream's `packageManager` field pins once,
  and both packages share that plus a single `mitmCache`, so the two never fetch
  or resolve the same tree twice.
- **The daemon package ships only the daemon's closure.** Its install happens in a
  trimmed workspace copy that holds `packages/*` and `apps/daemon`; pnpm installs
  the projects a workspace contains, which is also how upstream's container build
  keeps the Electron toolchain out. Only the paths the daemon's own `files` field
  declares travel, so its sources and tests stay behind. (616 MB installed, against
  2.8 GB for the whole workspace.)
- **The desktop package builds upstream's packaged stages** in order
  (`tools/pack/src/workspace-build.ts`): `dsh-runtime`, then everything
  `@open-design/packaged` depends on with `OD_WEB_OUTPUT_MODE=server` and a 4 GB
  heap ceiling for Next's in-process type check, then the web sidecar's `tsc`
  output, then the packaged entry. Its own runtime tree is a second trimmed
  install, over the four projects the packaged runtime loads
  (`daemon`, `web`, `desktop`, `packaged`), with the workspace's own packages
  linked in where upstream installs packed tarballs.
- **The rest of the tree is pruned the way upstream prunes it.** Type
  declarations, source maps, docs, test folders and build-only sources go from the
  installed modules and workspace packages, exactly as upstream's container image
  deletes them from its own installed tree — never from the resource root, whose
  `docs` and `examples` directories are product content. Three vendor trees get the
  same treatment: `node-pty`'s `prebuilds` (paseo deletes them so the addon it
  compiled is the one that loads; here they only hold darwin and win32 binaries),
  its `deps`/`third_party` build sources, and `onnxruntime-node`'s other-platform
  binaries, which its loader never selects.
- **`better-sqlite3` and `node-pty` are compiled here.** `iplConfigHook` installs
  with `--ignore-scripts`, and neither package ships a linux prebuild in its
  tarball, so `node-gyp` builds them against nixpkgs' Node — in both packages,
  before the pass that deletes the sources they build from. The install phase
  asserts both `.node` files exist, because a silent skip is what the first attempt
  at this did.
- **sharp cannot use the libvips it ships.** The prebuilt `libvips-cpp` statically
  embeds its own glib, so the addon's `g_*` references bind to a different copy
  and the first raster operation dies with SIGSEGV — the failure
  `deepseek-harness-desktop` documents at length for Electron, reproduced here in
  plain Node. Both packages symlink nixpkgs' dynamically linked `vips` under the
  name the addon's `DT_NEEDED` uses, put it on `LD_LIBRARY_PATH`, and build the
  link only when the versions agree; `installCheckPhase` then rasterizes a 4×4 PNG,
  which is the probe that fails with 139 on the prebuilt library. Re-check it after
  a sharp, vips or Node bump.
- **One upstream patch, shared by both.** The daemon anchors the design-system
  importers' scratch space at `<PROJECT_ROOT>/.tmp`, which upstream's container
  image makes writable and a store path is not; `postPatch` points it at the
  runtime data directory instead, so importing a design system from GitHub or a
  shadcn registry works.
- **The DeepSeek Harness bridge is baked, not built on demand.**
  `OD_RESOURCE_ROOT` carries `agent-runtimes/deepseek-harness/` — the
  `@open-design/dsh-runtime` tarball plus an integrity manifest — exactly as
  `tools/pack` bakes it for the packaged builds. Without it the daemon's fallback
  tries to `pnpm pack` out of a read-only workspace.
- **The Vela CLI is bundled, not looked up.** Cloud sign-in and every AMR-backed
  call spawn `vela` (`apps/daemon/src/integrations/vela.ts` wraps
  `vela collab …`), and the daemon accepts a packaged installation only as the
  pair upstream ships: `packagedBuiltInExecutable`
  (`apps/daemon/src/runtimes/executables.ts`) takes `$OD_RESOURCE_ROOT/bin/vela`
  when the OpenCode companion sits in `bin/libexec/opencode/` beside it, and
  falls back to PATH otherwise — where the wrapper puts no `vela`. Upstream's
  packaging step copies both into the resource root, so this package copies them
  too, from the `@powerformer/vela-cli-linux-x64` tarball at the version
  `tools/pack/package.json` pins. Without them `/api/integrations/vela/login`
  answers "vela binary not found; install vela or configure VELA_BIN",
  `/api/integrations/vela/status` answers 503 `amr-runtime-unavailable`, the AMR
  runtime is reported unavailable, and every cloud-transport call the collab
  layer classifies as infrastructure reaches the web client as 502 — the state
  the packaged desktop application cannot sign in from.

## Updating

`default.nix` pins the release tag, its revision, the source hash and the pnpm
version upstream's `packageManager` field pins; `importPnpmLock` reads the
integrity hashes out of the fetched `pnpm-lock.yaml`, so no lockfile copy and no
`pnpmDepsHash` are kept here. A bump is: new `version`, `rev`, source hash, and —
only when upstream moves `packageManager` — a new `pnpmVersion` with its tarball
hash. Both packages follow the one pin; the desktop package additionally follows
whatever `electron_42` nixpkgs carries.

## Checks

`doInstallCheck` runs the wrapped `od --help`, the sharp probe and the bundled
Vela CLI's `--version` in the daemon package, and in the desktop package resolves
the four entry points the packaged runtime asks Node for
(`@open-design/packaged`, `@open-design/desktop/main`, `@open-design/daemon/sidecar`,
`@open-design/web/sidecar`) and asserts the bundled Node, Vela CLI, companion,
config and executable are where the runtime looks for them.

Verified on the built packages, not by the build:

- The daemon starts, serves the workspace and every asset it references, and
  answers `/api/health`, `/api/skills`, `/api/design-templates`, `/api/plugins`,
  `/api/craft` and `/api/projects`; `od status` reads it back. A SQLite round-trip
  through the compiled `better-sqlite3`, `node-pty` spawning a real pty, the
  bundled `ffmpeg` executing, and `POST /api/agents/deepseek-harness/companion/install`
  verifying the baked bridge before reporting `AGENT_NOT_INSTALLED`.
- The desktop application, launched headless under Xvfb: both sidecars come up
  (their logs, IPC sockets and the daemon's SQLite appear under
  `$XDG_CONFIG_HOME/Open Design/namespaces/default/`), the web sidecar serves the
  workspace (`<title>OpenDesign</title>`) and the daemon answers `/api/health` on
  its own port. Launched windowed on the same display, it draws upstream's welcome
  screen — "Welcome to OpenDesign" with Sign in, Local AI and API Key — which is
  the packaged shell loading `od://app/` through the web sidecar.
- The Wayland path, on a headless Weston rather than an X server: with
  `NIXOS_OZONE_WL=1`, `WAYLAND_DISPLAY` set and no `DISPLAY`, the wrapped binary
  starts on the Wayland platform — every sidecar comes up and nothing logs the X11
  failure that appears when the platform cannot initialize. The same run without
  `WAYLAND_DISPLAY` keeps working on X11, which is the point of the convention.
- The bundled Vela CLI: the daemon reports the AMR runtime available, answers
  `GET /api/integrations/vela/status` with the signed-out profile, and
  `POST /api/integrations/vela/login` with 202 whose stages read
  `spawn_result: success` and `device_auth_create_result: success` — the bundled
  binary reaches the cloud and starts device authorization. The same daemon built
  without `resources/bin/vela` answers "vela binary not found; install vela or
  configure VELA_BIN" there, and 503 `amr-runtime-unavailable` on status.
- A real agent run — choosing a runtime, sending a prompt, and watching files land
  in the project — needs a coding-agent CLI on the machine and is the one path the
  packages cannot exercise by themselves. The desktop application's native folder
  picker and tray behaviour still want a real desktop session.

