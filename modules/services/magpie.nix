{ inputs, lib, ... }:
let
  # The CLIs Magpie drives: codex and cursor-agent refresh the logins it seeds,
  # and pi is the harness it serves to agents through the gateway.
  providerPath =
    pkgs:
    (with inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}; [
      codex
      cursor-agent
      pi
    ])
    ++ (with pkgs; [
      bubblewrap
      jq
      python3
    ]);
in
{
  flake.modules.nixos.magpie =
    {
      config,
      pkgs,
      ...
    }:
    let
      magpie = lib.getExe pkgs.selfPackages.magpie;
      install = "${pkgs.coreutils}/bin/install";
      directory = "/var/lib/magpie/.config/magpie";
      publicJSON = name: value: pkgs.writeText "magpie-${name}.json" (builtins.toJSON value);
      cursorPlugin = "@magpie-community/opencode-cursor-auth@latest";
      plugins = publicJSON "plugins" {
        plugins = [
          {
            spec = cursorPlugin;
            off = false;
          }
        ];
      };
      auth = publicJSON "plugin-auth" {
        cursor = {
          type = "oauth";
          access = "";
          refresh = "cursor-agent";
          expires = 0;
        };
      };
      migrations = publicJSON "migrations" {
        cursor = {
          state = "plugin";
          package = "@magpie-community/opencode-cursor-auth";
        };
      };
      loginRules = pkgs.writeText "magpie-login.conf" ''
        d /var/lib/magpie/.codex 0700 - - -
        d /var/lib/magpie/.config 0700 - - -
        d /var/lib/magpie/.config/cursor 0700 - - -
        f^ /var/lib/magpie/.codex/auth.json 0600 - - - codex_auth_json
        f^ /var/lib/magpie/.config/cursor/auth.json 0600 - - - cursor_auth_json
      '';
      installPlugin = pkgs.writeShellScript "magpie-install-plugin" ''
        set -euo pipefail
        if [[ ! -r "${directory}/plugins/node_modules/@magpie-community/opencode-cursor-auth/package.json" ]]; then
          ${magpie} plugin add ${cursorPlugin}
        fi
      '';
      # MAGPIE_WEB_KEY pins the browser sign-in link; without it magpie mints a
      # new key, and a new link, on every start.
      webStart = pkgs.writeShellScript "magpie-web" ''
        set -euo pipefail
        export MAGPIE_WEB_KEY="$(${pkgs.coreutils}/bin/cat "$CREDENTIALS_DIRECTORY/magpie_web_key")"
        exec ${magpie} web --addr 0.0.0.0:3430 --no-open
      '';
    in
    {
      key = "magpie";

      # The gateway and the browser UI are reachable on the tailnet and on
      # loopback only. `tailnet0` is the system interface of the sing-box
      # Tailscale endpoint, which every host running this imports.
      networking.firewall.interfaces.tailnet0.allowedTCPPorts = [
        3425
        3430
      ];

      # Magpie is the only consumer of these secrets: the four provider
      # credentials and the key that pins the browser UI's sign-in link. They
      # stay root-owned and reach the dynamic service through systemd
      # credentials; no user, Pi process or Paseo service can open them.
      sops.secrets =
        lib.genAttrs
          [
            "deepseek_api_key"
            "openrouter_api_key"
            "codex_auth_json"
            "cursor_auth_json"
            "magpie_web_key"
          ]
          (name: {
            format = "yaml";
            key = name;
            sopsFile = config.constants.resources.getSecretPath "agent-providers.yaml";
            path = "/run/secrets/${name}";
            owner = "root";
            group = "root";
            mode = "0400";
            restartUnits = [ "magpie.service" ];
          });

      sops.templates.magpie-providers = {
        mode = "0400";
        restartUnits = [ "magpie.service" ];
        content = builtins.toJSON {
          providers = [
            {
              id = "codex";
              name = "Codex";
              off = false;
              hidden = false;
            }
            {
              id = "cursor";
              name = "Cursor";
              models = [ "auto" ];
              off = false;
              hidden = false;
            }
            {
              id = "deepseek";
              name = "DeepSeek";
              key = config.sops.placeholder.deepseek_api_key;
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
              key = config.sops.placeholder.openrouter_api_key;
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
        description = "Magpie model gateway and local browser UI";
        wantedBy = [ "multi-user.target" ];
        wants = [ "network-online.target" ];
        requires = [ "sops-install-secrets.service" ];
        after = [
          "network-online.target"
          "sops-install-secrets.service"
        ];
        path = providerPath pkgs;
        environment = {
          HOME = "/var/lib/magpie";
          XDG_CONFIG_HOME = "/var/lib/magpie/.config";
          # Tailnet peers reach both listeners on this host's tailnet address,
          # so they bind every interface; this module admits 3425 and 3430 on
          # tailnet0 only, and loopback keeps working.
          MAGPIE_ADDR = "0.0.0.0:3425";
        };
        serviceConfig = {
          DynamicUser = true;
          User = "magpie";
          StateDirectory = "magpie";
          StateDirectoryMode = "0700";
          WorkingDirectory = "/var/lib/magpie";
          LoadCredential = [
            "codex_auth_json:${config.sops.secrets.codex_auth_json.path}"
            "cursor_auth_json:${config.sops.secrets.cursor_auth_json.path}"
            "providers.json:${config.sops.templates.magpie-providers.path}"
            "magpie_web_key:${config.sops.secrets.magpie_web_key.path}"
          ];
          ExecStartPre = [
            "${pkgs.systemd}/bin/systemd-tmpfiles --user --create ${loginRules}"
            "${install} -d -m 0700 ${directory}"
            "${install} -m 0600 %d/providers.json ${directory}/providers.json"
            "${install} -m 0600 ${plugins} ${directory}/plugins.json"
            "${install} -m 0600 ${auth} ${directory}/plugin-auth.json"
            "${install} -m 0600 ${migrations} ${directory}/migrations.json"
            installPlugin
          ];
          ExecStart = webStart;
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
