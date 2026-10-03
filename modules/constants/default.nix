{ inputs, ... }:
{
  flake.modules.generic.constants = { lib, ... }: {
    options.constants = lib.mkOption {
      type = lib.types.submodule {
        freeformType = lib.types.attrsOf lib.types.unspecified;
      };
      default = { };
    };

    imports = with inputs.self.modules.generic; [
      nvirellia
      resources
      tailnet
    ];
  };
}
