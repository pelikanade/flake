{ inputs, ... }: {
  flake.modules.nixos.magpie =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      magpie = lib.getExe pkgs.selfPackages.magpie;
      grok = inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.grok;
      webStart = pkgs.writeShellScript "magpie-web" ''
        set -euo pipefail
        # magpie installs its own grok under $HOME/.grok/bin and never searches PATH; link that path to the Nix build.
        mkdir -p "$HOME/.grok/bin"
        ln -sfn ${grok}/bin/grok "$HOME/.grok/bin/grok"
        export MAGPIE_WEB_KEY="$(${pkgs.coreutils}/bin/cat "$CREDENTIALS_DIRECTORY/magpie-web-key")"
        exec ${magpie} web --gateway --addr 0.0.0.0:3430 --no-open
      '';
    in
    {
      key = "magpie";

      sops.secrets."magpie-web-key" = {
        format = "yaml";
        key = "magpie_web_key";
        sopsFile = config.constants.resources.getSecretPath "magpie.yaml";
        owner = "root";
        group = "root";
        mode = "0400";
        restartUnits = [ "magpie.service" ];
      };

      systemd.services.magpie = {
        description = "Magpie model gateway and browser UI";
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
          MAGPIE_ADDR = "0.0.0.0:3425";
          MAGPIE_PUBLIC_URL = "http://${config.constants.getTailnetFqdn config.networking.hostName}:3425";
        };

        serviceConfig = {
          DynamicUser = true;
          User = "magpie";
          StateDirectory = "magpie";
          StateDirectoryMode = "0700";
          WorkingDirectory = "/var/lib/magpie";
          LoadCredential = [ "magpie-web-key:${config.sops.secrets."magpie-web-key".path}" ];
          ExecStart = "${webStart}";
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
