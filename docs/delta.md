# Delta

Delta ([delta.dev](https://delta.dev)) is Zed's agent desktop: one window over a
coding agent's chat, edits and terminal, with the vendor's own models and
sign-in. It is proprietary and unfree, and its Linux builds are published only as
binaries, which
[zed-industries/delta-nix](https://github.com/zed-industries/delta-nix) packages
in an official flake. This repository consumes that flake as the `delta` input
(`modules/apps/agents/delta.nix`) instead of building a package of its own: the
vendor's expression is the one that tracks the release layout, and upstream is
what validates it against each release.

The workstation desktops install it through the `delta` aspect, so Asymmetry and
Parallax carry `delta` on `PATH` and a desktop entry that runs `delta open %U`.
Nothing installs it on a server and nothing configures it here: this repository
provisions none of its settings or state, and credentials for its accounts go
through the Secret Service API that `modules/services/keyring.nix` provides.

## Why the input follows nixpkgs

`flake-file.inputs.delta` declares `inputs.nixpkgs.follows = "nixpkgs"`. The
package keeps the release's own libraries ahead of Nix's on the RUNPATH of every
ELF file it ships, and its wrapper adds `LD_LIBRARY_PATH` for the `dlopen` calls
behind the Vulkan ICD chain, so the libraries it carries are its own. What it
cannot carry is the host graphics stack: Delta loads the drivers from
`/run/opengl-driver` at startup, and a package built against an older glibc fails
to load newer Mesa or LLVM libraries there — `GLIBC_... not found` followed by
`No GPU adapters found`. Upstream's README names that as the cost of building the
package against a different nixpkgs, so following this system's is a runtime
requirement, not only repository policy.

## Verification

Upstream's install check is what keeps a build honest: it validates the desktop
entries, runs `ldd` over every executable and library in the tree, and fails the
build while any dependency is unresolved. A successful build therefore proves the
pinned release still loads against this nixpkgs, which evaluation and a
configuration build alone would not.

When checking a build by hand, the application binary prints the release version
(`delta-app --version`); the CLI in the same release artifact carries its own
version string, which lags the application's, so `delta --version` disagrees with
the package version on purpose.

## Moving to a newer version

`nix flake update delta` moves the packaging and the binary version together,
because the flake takes the `stable` entry of its own `releases.json`. To hold a
release instead, pin the input to its tag —
`github:zed-industries/delta-nix/v0.18.2` — which pins the package definition and
the binary. Delta's built-in updater is disabled in the package
(`DELTA_UPDATE_EXPLANATION`), so it cannot replace the store path behind the
configuration's back; the update path is the input.
