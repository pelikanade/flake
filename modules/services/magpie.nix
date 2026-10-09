_: {
  flake.modules.nixos.magpie =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      # The gateway runs the key-based providers only. Codex and Cursor sign
      # in per host through `omp /login`, so this host needs neither of
      # their CLI logins nor the community plugin that seeds them.
      magpie = lib.getExe pkgs.selfPackages.magpie;
      install = "${pkgs.coreutils}/bin/install";
      directory = "/var/lib/magpie/.config/magpie";
    in
    {
      key = "magpie";

      # The gateway is reachable on the tailnet and on loopback only.
      # `tailnet0` is the system interface of the sing-box Tailscale endpoint,
      # which this host imports.
      networking.firewall.interfaces.tailnet0.allowedTCPPorts = [ 3425 ];

      # The gateway resolves the two key-based providers from the shared
      # provider document. The copies stay root-owned and reach the dynamic
      # service through systemd credentials; no other consumer inherits them.
      # A key change restarts the unit.
      sops.secrets = {
        "magpie-deepseek-api-key" = {
          format = "yaml";
          key = "deepseek_api_key";
          sopsFile = config.constants.resources.getSecretPath "omp-providers.yaml";
          owner = "root";
          group = "root";
          mode = "0400";
        };
        "magpie-openrouter-api-key" = {
          format = "yaml";
          key = "openrouter_api_key";
          sopsFile = config.constants.resources.getSecretPath "omp-providers.yaml";
          owner = "root";
          group = "root";
          mode = "0400";
        };
      };

      # Nix declares the provider policy; sops renders the keys into this
      # template at activation and the pre-start step installs it. A restart
      # of the unit reapplies the managed list over whatever the gateway
      # itself may have edited.
      sops.templates."magpie-providers" = {
        mode = "0400";
        restartUnits = [ "magpie.service" ];
        content = builtins.toJSON {
          providers = [
            {
              id = "deepseek";
              name = "DeepSeek";
              key = config.sops.placeholder."magpie-deepseek-api-key";
              chat = "https://api.deepseek.com/v1";
              responses = "https://api.deepseek.com/v1";
              anthropic = "https://api.deepseek.com/anthropic";
              catalog = "deepseek";
              models = [
                "deepseek-flash"
                "deepseek-v4-pro"
              ];
              off = false;
              hidden = false;
            }
            {
              id = "openrouter";
              name = "OpenRouter";
              key = config.sops.placeholder."magpie-openrouter-api-key";
              chat = "https://openrouter.ai/api/v1";
              anthropic = "https://openrouter.ai/api";
              catalog = "openrouter";
              off = false;
              hidden = false;
            }
          ];
        };
      };

      systemd.services.magpie = {
        description = "Magpie model gateway";
        wantedBy = [ "multi-user.target" ];
        wants = [ "network-online.target" ];
        after = [ "network-online.target" ];

        # systemd's path option replaces the unit's PATH rather than extending
        # it, so point it at the system profile instead of listing packages
        # again.
        path = [ config.system.path ];

        environment = {
          HOME = "/var/lib/magpie";
          XDG_CONFIG_HOME = "/var/lib/magpie/.config";
          XDG_CACHE_HOME = "/var/lib/magpie/.cache";
          # The gateway binds every interface so tailnet peers reach it on this
          # host's tailnet address; this module admits 3425 on tailnet0 only,
          # and loopback keeps working. Upstream accepts only loopback callers
          # unless the socket is opened deliberately, which this variable does
          # and the sing-box endpoint's firewall bounds to the tailnet.
          MAGPIE_ADDR = "0.0.0.0:3425";
          # The banner and the CLIs advertise the gateway by its MagicDNS name;
          # the resolver does not expand a bare peer name.
          MAGPIE_PUBLIC_URL = "http://${config.constants.getTailnetFqdn config.networking.hostName}:3425";
        };

        serviceConfig = {
          DynamicUser = true;
          User = "magpie";
          StateDirectory = "magpie";
          StateDirectoryMode = "0700";
          WorkingDirectory = "/var/lib/magpie";
          LoadCredential = [ "providers.json:${config.sops.templates."magpie-providers".path}" ];
          ExecStartPre = [
            "${install} -d -m 0700 ${directory}"
            "${install} -m 0600 %d/providers.json ${directory}/providers.json"
          ];
          ExecStart = "${magpie} serve";
          Restart = "on-failure";
          RestartSec = 10;
          UMask = "0077";
          NoNewPrivileges = true;
          ProtectSystem = "strict";
          ProtectHome = true;
          PrivateTmp = true;
        };
      };
    };
}
