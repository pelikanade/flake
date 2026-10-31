{ inputs, ... }:
{
  # Upstream packages both halves: the daemon (`paseo`) and the Electron
  # desktop application. Pinned to the release tag matching the version this
  # repository already composed, so changing the source repository does not
  # also move the package version.
  flake-file.inputs.paseo = {
    url = "github:getpaseo/paseo/v0.13.0";

    inputs.nixpkgs.follows = "nixpkgs";
  };

  perSystem =
    { system, ... }:
    let
      upstream = inputs.paseo.packages.${system};

      # Upstream derives this fixed-output hash from the lockfile with the
      # fetchNpmDeps implementation of the nixpkgs it is built with, so
      # following our nixpkgs changes it. Upstream exposes it as an argument
      # for exactly this case.
      npmDepsHash = "sha256-DZOPOf81PkUxdD65BrfkTZhs6/DkfDWCFZ/SU+QrZbg=";

      # The desktop derivation reuses the daemon's npm dependency closure
      # instead of refetching the registry, so it must receive the daemon with
      # the overridden hash.
      fromUpstream = upstream.paseo.override { inherit npmDepsHash; };
      fromUpstreamDesktop = upstream.desktop.override { paseo = fromUpstream; };

      # Upstream's build phases replace buildNpmPackage's default build and
      # install with `npm ci --ignore-scripts`, which skips the root postinstall
      # that applies `patches/`. The bundled web UI and the desktop renderer
      # import exports those patches add (for example @gorhom's
      # BottomSheetModalInternalProvider), so an unpatched install renders
      # `undefined` as a component and dies with React error #130. The server
      # patch (@opencode-ai/sdk) needs it too.
      withPatches =
        drv:
        drv.overrideAttrs (old: {
          preBuild = ''
            ${old.preBuild or ""}
            export PATH="$PWD/node_modules/.bin:$PATH"
            if ! command -v patch-package > /dev/null; then
              echo "patch-package is missing; the build would ship unpatched dependencies" >&2
              exit 1
            fi
            node scripts/postinstall-patches.mjs
          '';
        });

      # Paseo bundles the browser app into the daemon's web UI. Metro's worker
      # transforming the generated ws-outbound validator needs more than the
      # 2 GiB heap Node selects for hosts under 15 GiB, and upstream's daemon
      # build does not set the limit its desktop build does.
      paseoDaemon = withPatches fromUpstream;
    in
    {
      packages.paseo-daemon = paseoDaemon.overrideAttrs (_: {
        NODE_OPTIONS = "--max-old-space-size=4096";
      });
      packages.paseo-desktop = withPatches fromUpstreamDesktop;
    };
}
