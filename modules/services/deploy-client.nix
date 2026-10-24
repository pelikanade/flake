{ inputs, ... }:
{
  flake.modules.nixos.deploy-client =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      configurations = inputs.self.nixosConfigurations;
      targetNames = lib.filter (
        name:
        if name == config.networking.hostName then
          config.services.deploy-target.enable or false
        else
          configurations.${name}.config.services.deploy-target.enable or false
      ) (builtins.attrNames configurations);

      clientYaml = (pkgs.formats.yaml { }).generate "client.yaml" {
        client = {
          local = config.networking.hostName;
          tailnet = config.constants.tailnetDnsName;
          token_file = "/run/secrets/deploy_trigger_token";
          port = 8080;
          targets = targetNames;
          flake = ".";
          timeout = "2h";
        };
      };
    in
    {
      assertions = [
        {
          assertion = targetNames != [ ];
          message = "deploy-client: no machine imports deploy-target";
        }
        {
          assertion = config.users.users ? github-runner;
          message = "deploy-client: the github-runner user is not defined";
        }
      ];

      environment.etc."avalanche/client.yaml".source = clientYaml;
      environment.systemPackages = [ pkgs.selfPackages.avalanche ];

      users.users.github-runner.extraGroups = [ "deploy" ];

      # The runner service uses PrivateUsers, so name the supplementary group
      # explicitly instead of relying on the user's group list.
      systemd.services."github-runner-${config.networking.hostName}".serviceConfig.SupplementaryGroups = [
        "deploy"
      ];
    };
}
