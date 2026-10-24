{
  flake.modules.nixos.deploy-client =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      clientYaml = (pkgs.formats.yaml { }).generate "client.yaml" {
        client = {
          local = config.networking.hostName;
          tailnet = config.constants.tailnetDnsName;
          token_file = "/run/secrets/deploy_trigger_token";
          port = 8080;
          flake = ".";
          timeout = "2h";
        };
      };
    in
    {
      assertions = [
        {
          assertion = config.users.users ? github-runner;
          message = "deploy-client: the github-runner user is not defined";
        }
      ];

      environment.etc."avalanche/client.yaml".source = clientYaml;
      environment.systemPackages = [ pkgs.selfPackages.avalanche ];

      users.users.github-runner.extraGroups = [ "deploy" ];

      # Every runner service uses PrivateUsers, so name the supplementary group
      # explicitly instead of relying on the user's group list.
      systemd.services = lib.mapAttrs' (
        runnerName: _:
        lib.nameValuePair "github-runner-${runnerName}" {
          serviceConfig.SupplementaryGroups = [ "deploy" ];
        }
      ) config.services.github-runners;
    };
}
