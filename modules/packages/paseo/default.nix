{ inputs, ... }:
{
  # Upstream packages both halves: the daemon (`paseo`) and the Electron
  # desktop application, whose transparent Linux window and glass surfaces are
  # part of the same source tree rather than a local patch.
  flake-file.inputs.paseo = {
    url = "github:pelikanade/paseo";

    # The package expressions use this nixpkgs' Electron and native build
    # inputs. Upstream's npm dependency hash is derived from the lockfile and
    # the fetcher, not from the source revision, so the same packages build
    # against a followed nixpkgs.
    inputs.nixpkgs.follows = "nixpkgs";
  };

  perSystem =
    { system, ... }:
    let
      upstream = inputs.paseo.packages.${system};

      # Paseo 0.12 bundles the browser app into the daemon's web UI. Metro's
      # worker transforming the generated ws-outbound validator needs more than
      # the 2 GiB heap Node selects for hosts under 15 GiB, and upstream's
      # daemon build does not set the limit its desktop build does.
      paseoDaemon = upstream.paseo.overrideAttrs (_: {
        NODE_OPTIONS = "--max-old-space-size=4096";
      });
    in
    {
      packages.paseo-daemon = paseoDaemon;
      packages.paseo-desktop = upstream.desktop;
    };
}
