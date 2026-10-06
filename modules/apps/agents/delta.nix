{ inputs, ... }:
{
  flake-file.inputs.delta = {
    url = "github:zed-industries/delta-nix";

    # That flake packages Delta's release binaries against its own nixpkgs. The
    # package keeps Nix's glibc and runtime libraries on its RUNPATH and loads
    # the host drivers from /run/opengl-driver at startup, so building it
    # against this system's nixpkgs is what keeps the two in step; Delta's README
    # names a mismatched graphics stack as the cause of a `GLIBC_... not found`
    # or "No GPU adapters found" startup failure.
    inputs.nixpkgs.follows = "nixpkgs";
  };

  # Delta is Zed's agent desktop: one window over the agent's chat, edits and
  # terminal, with its CLI as the entry point that also opens it. The vendor
  # ships the binary and its packaging flake, so this composes that package
  # instead of building one; see docs/delta.md.
  flake.modules.homeManager.delta =
    { pkgs, ... }:
    {
      home.packages = [ inputs.delta.packages.${pkgs.stdenv.hostPlatform.system}.delta ];
    };
}
