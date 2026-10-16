# OpenDesign

OpenDesign is a local-first design-agent workspace: it runs design skills against
a coding agent and renders the resulting prototypes, dashboards, decks, images
and motion graphics in a sandboxed preview.

Upstream ships desktop installers for macOS and Windows only, and its Linux
answer is "run from source". That source run is the whole product on Linux: the
`od` daemon serves the statically exported web workspace itself, so the browser
is the workspace, and every capability is reachable from the `od` CLI as well.

`modules/packages/open-design/default.nix` builds release `open-design-v0.25.0`
from source; `modules/apps/agents/agent-desktops.nix` installs it for every
machine that imports the `workstation` role.

## Running it

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

## What the store path holds

The daemon resolves its workspace root from its own location, and reaches every
dependency through the relative links pnpm creates, so the package keeps parts of
upstream's shape instead of flattening it:

| Path | What reads it |
| --- | --- |
| `apps/daemon/{bin,dist}` | The `od` CLI entry and the daemon |
| `apps/web/out` | The static export served at `/` (`STATIC_DIR`, `apps/daemon/src/server.ts`) |
| `resources/` | `OD_RESOURCE_ROOT`: skills, design systems, design templates, craft rules, prompt templates, bundled plugins (`_official`, `registry`), frames, community pets, the plugin-preview manifest, and the DeepSeek Harness connection tarball |
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

## Build notes

- **Only the daemon's closure ships.** The workspace install happens in a
  trimmed copy that holds `packages/*` and `apps/daemon` but not the web app, the
  Electron shells, `tools/` or the test suite; pnpm installs the projects a
  workspace contains, which is also how upstream's container build keeps the
  Electron toolchain out. The exported web UI is copied in separately. (946 MB
  installed, against 2.8 GB for the whole workspace — the web app's runtime
  dependencies, Playwright, TypeScript and the packaging tooling are the
  difference.)
- **`better-sqlite3` and `node-pty` are compiled here.** `iplConfigHook` installs
  with `--ignore-scripts`, and neither package ships a linux prebuild in its
  tarball, so `node-gyp` builds them against nixpkgs' Node. The install phase
  asserts both `.node` files exist, because a silent skip is what the first
  attempt at this did.
- **sharp cannot use the libvips it ships.** The prebuilt `libvips-cpp` statically
  embeds its own glib, so the addon's `g_*` references bind to a different copy
  and the first raster operation dies with SIGSEGV — the failure
  `deepseek-harness-desktop` documents at length for Electron, reproduced here in
  plain Node. The package symlinks nixpkgs' dynamically linked `vips` under the
  name the addon's `DT_NEEDED` uses, puts it on `LD_LIBRARY_PATH`, and builds the
  link only when the versions agree. `installCheckPhase` then rasterizes a 4×4 PNG
  through the addon, which is the probe that fails with 139 on the prebuilt
  library. Re-check it after a sharp, vips or Node bump.
- **One upstream patch.** The daemon anchors the design-system importers' scratch
  space at `<PROJECT_ROOT>/.tmp`, which upstream's container image makes writable
  and a store path is not; `postPatch` points it at the runtime data directory
  instead, so importing a design system from GitHub or a shadcn registry works.
- **The DeepSeek Harness bridge is baked, not built on demand.** `OD_RESOURCE_ROOT`
  carries `agent-runtimes/deepseek-harness/` — the `@open-design/dsh-runtime`
  tarball plus an integrity manifest — exactly as `tools/pack` bakes it for the
  packaged builds. Without it the daemon's fallback tries to `pnpm pack` out of a
  read-only workspace.

## Updating

`default.nix` pins the release tag, its revision, the source hash and the pnpm
version upstream's `packageManager` field pins; `importPnpmLock` reads the
integrity hashes out of the fetched `pnpm-lock.yaml`, so no lockfile copy and no
`pnpmDepsHash` are kept here. A bump is: new `version`, `rev`, source hash, and —
only when upstream moves `packageManager` — a new `pnpmVersion` with its tarball
hash.

## Checks

`doInstallCheck` runs the wrapped `od --help` and the sharp probe above.
Verification on the built package, not covered by the build:

- `od` starts the daemon, serves the workspace at `/`, and answers
  `/api/health`, `/api/skills`, `/api/design-templates`, `/api/plugins`,
  `/api/craft` and `/api/projects`; `od status` reads that daemon back.
- A SQLite round-trip through the compiled `better-sqlite3`, and the bundled
  `ffmpeg` binary executing.
- `POST /api/agents/deepseek-harness/companion/install` verifies the baked bridge
  bundle and then reports `AGENT_NOT_INSTALLED` when no `dsh` is on `PATH`, which
  is the expected outcome on a machine that has not installed it.
- A real agent run — choosing a runtime, sending a prompt, and watching files
  land in the project — needs a coding-agent CLI on the machine and is the one
  path the package cannot exercise by itself. The same goes for a browser session
  that renders the workspace: the packaging environment had no reachable browser,
  so the export is verified as served markup plus every asset it references
  answering 200, not as hydrated UI.
