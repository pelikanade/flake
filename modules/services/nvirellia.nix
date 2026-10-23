{ inputs, ... }:
{
  # The personal site is its own flake: a Go service whose templates and static
  # assets are embedded in the binary. The input carries the package and the
  # upstream NixOS module, which owns the unit, hardening and its options.
  flake-file.inputs.nvirellia = {
    url = "github:pelikanade/nvirellia.im";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  flake.modules.nixos.nvirellia =
    { config, ... }:
    {
      imports = [ inputs.nvirellia.nixosModules.default ];

      services.nvirellia = {
        enable = true;

        # The Resources panel asks Magpie's web API through its tailnet Service.
        magpie.url = "http://${config.constants.getTailnetFqdn "nsphere-magpie"}";
        magpie.keyFile = config.sops.templates.nvirellia-environment.path;
      };

      # The upstream unit loads the key through `EnvironmentFile`, which systemd
      # reads before it drops to the dynamic user, so root-only is enough.
      sops.secrets.magpie_web_key = {
        format = "yaml";
        key = "magpie_web_key";
        sopsFile = config.constants.resources.getSecretPath "nvirellia.yaml";
        restartUnits = [ "nvirellia.service" ];
      };

      sops.templates.nvirellia-environment = {
        content = "MAGPIE_WEB_KEY=${config.sops.placeholder.magpie_web_key}";
        restartUnits = [ "nvirellia.service" ];
      };
    };
}
