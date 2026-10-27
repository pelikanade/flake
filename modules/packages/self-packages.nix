{ inputs, ... }:
{
  # Keyed on the machine doing the building, not the machine the system is for:
  # a cross-compiled system may only import store paths its builder can actually
  # produce, which is what `buildPlatform` names.
  flake.overlays.selfPackages = final: _prev: {
    selfPackages = inputs.self.packages.${final.stdenv.buildPlatform.system};
  };

  flake.modules.nixos.base.nixpkgs.overlays = [ inputs.self.overlays.selfPackages ];
}
