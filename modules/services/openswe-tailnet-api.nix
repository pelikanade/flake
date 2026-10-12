{ inputs, ... }:
{
  flake.modules.aspects.openswe-tailnet-api.imports = with inputs.self.modules.aspects; [
    sing-box
  ];

  flake.modules.nixos.openswe-tailnet-api =
    { config, ... }:
    {
      # Paseo exports certificates through the existing tailnet endpoint. The
      # root pre-start renderer reads this same file into sing-box's runtime
      # configuration; the sing-box user does not need direct file access.
      sops.secrets.openswe-tailnet-api-key = {
        format = "yaml";
        key = "api_key";
        sopsFile = config.constants.resources.getSecretPath "sing-box-api.yaml";
        path = "/run/secrets/openswe-tailnet-api-key";
        owner = "paseo";
        group = "paseo";
        mode = "0400";
        restartUnits = [ "sing-box.service" ];
      };

      services.sing-box.settings.services = [
        {
          type = "api";
          tag = "openswe-tailnet-api";
          listen = "127.0.0.1";
          listen_port = 9090;
          # The userspace tailnet can forward local ports, so loopback alone
          # is not an authentication boundary. This API controls all sing-box.
          secret._secret = config.sops.secrets.openswe-tailnet-api-key.path;
        }
      ];
    };
}
