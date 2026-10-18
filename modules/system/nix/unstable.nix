{ inputs, ... }:
{
  flake-file.inputs.nixpkgs-unstable.url = "https://channels.nixos.org/nixos-unstable/nixexprs.tar.zst";

  flake.modules.nixos.nix = {
    nixpkgs.overlays = [
      (_final: prev: {
        unstable = import inputs.nixpkgs-unstable {
          system = prev.stdenv.hostPlatform.system;
          inherit (prev) config;
        };
      })
    ];
  };

  perSystem =
    { system, ... }:
    {
      _module.args.pkgsUnstable = import inputs.nixpkgs-unstable {
        inherit system;
        config.allowUnfree = true;
      };
    };
}
