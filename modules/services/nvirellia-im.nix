{ inputs, ... }:
{
  flake-file.inputs.nvirellia-im = {
    url = "github:pelikanade/nvirellia.im";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  flake.modules.nixos.nvirellia-im =
    { config, ... }:
    {
      imports = [ inputs.nvirellia-im.nixosModules.default ];

      services.nvirellia-im = {
        enable = true;

        magpie.url = "http://${config.constants.getTailnetFqdn "nsphere-magpie"}";
        magpie.keyFile = config.sops.templates.nvirellia-im-environment.path;

        gatus.url = "http://127.0.0.1:3001";
        prometheus.url = "http://127.0.0.1:9090";
      };

      # The key lives in Magpie's own document; enrollment is per document, so
      # edge can unwrap all of it even though only the web key is read here.
      # The upstream unit loads the key through `EnvironmentFile`, which systemd
      # reads before it drops to the dynamic user, so root-only is enough.
      sops.secrets."magpie-web-key" = {
        format = "yaml";
        key = "magpie_web_key";
        sopsFile = config.constants.resources.getSecretPath "magpie.yaml";
        restartUnits = [ "nvirellia-im.service" ];
      };

      sops.templates.nvirellia-im-environment = {
        content = "MAGPIE_WEB_KEY=${config.sops.placeholder."magpie-web-key"}";
        restartUnits = [ "nvirellia-im.service" ];
      };
    };
}
