{
  config,
  inputs,
  lib,
  ...
}:
let
  aspectModule = {
    options = {
      nixosModule = lib.mkOption {
        type = lib.types.nullOr lib.types.deferredModule;
        default = null;
        description = "The NixOS contribution of this aspect.";
      };

      homeModule = lib.mkOption {
        type = lib.types.nullOr lib.types.deferredModule;
        default = null;
        description = "The Home Manager contribution of this aspect.";
      };
    };
  };

  machineModule = {
    options = {
      system = lib.mkOption {
        type = lib.types.str;
        description = "The Nix system for this machine.";
      };

      diskoConfig = lib.mkOption {
        type = lib.types.nullOr lib.types.deferredModule;
        default = null;
        description = "The disk layout assigned to this machine.";
      };

      hardware = lib.mkOption {
        type = lib.types.nullOr lib.types.deferredModule;
        default = null;
        description = "The hardware facts for this machine.";
      };
    };
  };

  nativeModuleNames = lib.unique (
    builtins.attrNames config.flake.modules.nixos ++ builtins.attrNames config.flake.modules.homeManager
  );

  generatedAspects = lib.genAttrs nativeModuleNames (name: {
    config =
      lib.optionalAttrs (builtins.hasAttr name config.flake.modules.nixos) {
        nixosModule = config.flake.modules.nixos.${name};
      }
      // lib.optionalAttrs (builtins.hasAttr name config.flake.modules.homeManager) {
        homeModule = config.flake.modules.homeManager.${name};
      };
  });

  materializeMachine =
    _name: machine:
    inputs.nixpkgs.lib.nixosSystem {
      inherit (machine) system;
      modules =
        lib.optional (machine.nixosModule != null) machine.nixosModule
        ++ lib.optional (machine.diskoConfig != null) machine.diskoConfig
        ++ lib.optional (machine.hardware != null) machine.hardware
        ++ lib.optional (machine.homeModule != null) {
          home-manager.sharedModules = [ machine.homeModule ];
        };
    };
in
{
  options.machines = lib.mkOption {
    type = lib.types.lazyAttrsOf (
      lib.types.submoduleWith {
        class = "aspects";
        modules = [
          aspectModule
          machineModule
        ];
      }
    );
    default = { };
    description = "Machines materialized as NixOS configurations.";
  };

  config = {
    flake.modules.aspects = generatedAspects;
    flake.nixosConfigurations = lib.mapAttrs materializeMachine config.machines;
  };
}
