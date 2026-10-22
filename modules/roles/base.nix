{ inputs, lib, ... }:
{
  flake.modules.aspects.base = {
    imports = with inputs.self.modules.aspects; [
      nix
      auto-upgrade
      secrets
      disko
    ];
    nixosModule = inputs.self.modules.generic.constants;
    homeModule = inputs.self.modules.generic.constants;
  };

  flake.modules.nixos.base = {
    options.roles.base.imported = lib.mkOption {
      type = lib.types.bool;
      default = true;
      readOnly = true;
      internal = true;
      description = "Whether the base role module was imported.";
    };

    imports = [
      inputs.home-manager.nixosModules.home-manager
    ];

    config = {
      documentation.man.cache.enable = false;
    };
  };
}
