{
  inputs,
  ...
}:
{
  flake.modules.homeManager.herdr =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      cfg = config.programs.herdr;
      defaultPackage = inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.herdr;
      tomlFormat = pkgs.formats.toml { };
      pluginType = lib.types.path;
      pluginEntries = lib.mapAttrs' (name: source: {
        name = "herdr/plugins/${name}";
        value = {
          inherit source;
          recursive = true;
        };
      }) cfg.plugins;
      pluginPaths = lib.mapAttrsToList (
        name: _: "${config.xdg.configHome}/herdr/plugins/${name}"
      ) cfg.plugins;
      herdrCommand = if cfg.package == null then "herdr" else lib.escapeShellArg (lib.getExe cfg.package);

      settings = lib.foldl' (
        collected: contribute: lib.recursiveUpdate collected (contribute collected)
      ) cfg.settings cfg.pluginSettings;
    in
    {
      options.programs.herdr = {
        enable = lib.mkEnableOption "Herdr terminal workspace manager";

        package = lib.mkOption {
          type = lib.types.nullOr lib.types.package;
          default = defaultPackage;
          defaultText = lib.literalExpression "inputs.llm-agents.packages.\${pkgs.stdenv.hostPlatform.system}.herdr";
          description = "The Herdr package to install. Set to null to manage configuration only.";
        };

        settings = lib.mkOption {
          inherit (tomlFormat) type;
          default = {
            onboarding = false;
            session.resume_agents_on_restore = true;
            theme.name = "gruvbox";
            ui.toast.delivery = "system";
          };
          example = {
            keys.prefix = "ctrl+b";
            theme.name = "gruvbox";
            ui.toast.delivery = "herdr";
          };
          description = ''
            Herdr configuration written to
            $XDG_CONFIG_HOME/herdr/config.toml. See
            https://herdr.dev/docs/configuration/ for supported settings.

            The plugin modules beside this file append their sidebar rows,
            keys and tab-bar entry to these settings.
          '';
        };

        plugins = lib.mkOption {
          type = lib.types.attrsOf pluginType;
          default = { };
          example = lib.literalExpression ''
            {
              workspace-tools = ./herdr-plugins/workspace-tools;
            }
          '';
          description = ''
            Local Herdr plugin directories to link declaratively. Each value
            must be a directory containing a herdr-plugin.toml manifest. The
            directory is copied into $XDG_CONFIG_HOME/herdr/plugins/<name> and
            linked with `herdr plugin link --enabled` during activation.
          '';
        };

        pluginSettings = lib.mkOption {
          type = lib.types.listOf (lib.types.functionTo tomlFormat.type);
          default = [ ];
          internal = true;
          description = ''
            Herdr settings contributed by the plugin modules beside this file.
            Each function receives the settings collected so far and returns
            the part it owns, which is merged into them.
          '';
        };
      };

      config = lib.mkIf cfg.enable {
        assertions = [
          {
            assertion = lib.all lib.pathIsDirectory (lib.attrValues cfg.plugins);
            message = "`programs.herdr.plugins` values must be plugin directories";
          }
          {
            assertion = lib.all (path: builtins.pathExists (path + "/herdr-plugin.toml")) (
              lib.attrValues cfg.plugins
            );
            message = "`programs.herdr.plugins` values must contain herdr-plugin.toml";
          }
        ];

        home.packages = lib.mkIf (cfg.package != null) [ cfg.package ];

        xdg.configFile = {
          "herdr/config.toml".source = tomlFormat.generate "herdr-config.toml" settings;
        }
        // pluginEntries;

        home.activation.linkHerdrPlugins = lib.mkIf (cfg.plugins != { }) (
          lib.hm.dag.entryAfter [ "writeBoundary" ] ''
            if command -v ${herdrCommand} >/dev/null 2>&1 || [ -x ${herdrCommand} ]; then
              ${lib.concatMapStringsSep "\n                " (
                path: "$DRY_RUN_CMD ${herdrCommand} plugin link ${lib.escapeShellArg path} --enabled"
              ) pluginPaths}
            else
              echo "Herdr executable not found; skipping Herdr plugin linking" >&2
            fi
          ''
        );
      };
    };
}
