{
  config,
  inputs,
  lib,
  ...
}:
let
  packages = config.pi.packages;
in
{
  options.pi.packages = lib.mkOption {
    type = with lib.types; functionTo (listOf package);
    readOnly = true;
    internal = true;
    description = "Pi and the runtime tools it needs.";
  };

  config = {
    flake.modules.aspects.pi.imports = [ inputs.self.modules.aspects.agent-upstream ];

    # Pi is the only harness a gateway client runs, and its only provider is the
    # Magpie gateway, which holds every credential and reaches the vendors.
    pi.packages =
      pkgs:
      let
        llmAgents = inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system};
      in
      (with llmAgents; [ pi ])
      ++ (with pkgs; [
        bubblewrap
        jq
        python3
      ]);

    flake.modules.nixos.pi =
      { pkgs, ... }:
      {
        key = "pi";
        environment.systemPackages = packages pkgs;
      };

    flake.modules.homeManager.pi =
      {
        config,
        lib,
        pkgs,
        ...
      }:
      let
        cfg = config.programs.pi;
        defaultPackage = inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.pi;
        defaultConfigDir = "${config.home.homeDirectory}/.pi/agent";
        jsonFormat = pkgs.formats.json { };
        contentType = lib.types.either lib.types.lines lib.types.path;
        resourceType = lib.types.either (lib.types.attrsOf contentType) lib.types.path;
        isPathLike = lib.hm.strings.isPathLike;
        addSuffix =
          suffix: name:
          if lib.hasSuffix suffix name || (suffix == ".ts" && lib.hasSuffix ".js" name) then
            name
          else
            "${name}${suffix}";
        mkFile = content: if isPathLike content then { source = content; } else { text = content; };
        mkResourceEntry =
          subdir: suffix: name: content:
          let
            isDirectory = isPathLike content && lib.pathIsDirectory content;
            targetName = if isDirectory then name else addSuffix suffix name;
          in
          lib.nameValuePair "${cfg.configDir}/${subdir}/${targetName}" (
            mkFile content // lib.optionalAttrs isDirectory { recursive = true; }
          );
        mkResourceEntries =
          subdir: suffix: resources:
          if builtins.isAttrs resources then
            lib.mapAttrs' (mkResourceEntry subdir suffix) resources
          else
            {
              "${cfg.configDir}/${subdir}" = {
                source = resources;
                recursive = true;
              };
            };
        mkPromptFile = fileName: content: {
          "${cfg.configDir}/${fileName}" = mkFile content;
        };
      in
      {
        key = "pi";

        options.programs.pi = {
          enable = lib.mkEnableOption "Pi coding agent";

          package = lib.mkOption {
            type = lib.types.nullOr lib.types.package;
            default = defaultPackage;
            defaultText = lib.literalExpression "inputs.llm-agents.packages.\${pkgs.stdenv.hostPlatform.system}.pi";
            description = "The Pi package to install. Set to null to manage configuration only.";
          };

          configDir = lib.mkOption {
            type = lib.types.str;
            default = defaultConfigDir;
            defaultText = lib.literalExpression ''"''${config.home.homeDirectory}/.pi/agent"'';
            description = ''
              Directory containing Pi's global configuration. When changed from
              the upstream default, PI_CODING_AGENT_DIR is set accordingly.
            '';
          };

          settings = lib.mkOption {
            inherit (jsonFormat) type;
            default = { };
            example = {
              defaultProvider = "magpie";
              defaultModel = "cursor/auto";
              defaultThinkingLevel = "medium";
              enableInstallTelemetry = false;
            };
            description = ''
              Global Pi settings written to settings.json. See
              https://pi.dev/docs/settings for supported values. API keys should
              be supplied through environment variables, commands, or /login,
              rather than stored here.
            '';
          };

          keybindings = lib.mkOption {
            inherit (jsonFormat) type;
            default = { };
            example = {
              "tui.editor.historyPrevious" = "ctrl+p";
              "tui.editor.historyNext" = "ctrl+n";
            };
            description = "Pi keybindings written to keybindings.json.";
          };

          models = lib.mkOption {
            inherit (jsonFormat) type;
            default = { };
            example.providers.ollama = {
              baseUrl = "http://localhost:11434/v1";
              api = "openai-completions";
              apiKey = "ollama";
              models = [ { id = "qwen2.5-coder:7b"; } ];
            };
            description = ''
              Custom providers and models written to models.json. Reference
              secrets through environment variables or commands instead of
              embedding them in the Nix store.
            '';
          };

          mcpServers = lib.mkOption {
            inherit (jsonFormat) type;
            default = { };
            example.filesystem = {
              command = "npx";
              args = [
                "-y"
                "@modelcontextprotocol/server-filesystem"
                "."
              ];
            };
            description = ''
              MCP servers available in every project, written to mcp.json under
              the `mcpServers` key. Stdio servers use `command`, `args`, `env`
              and `cwd`; HTTP servers use `url`, `headers` and `oauth`.
            '';
          };

          context = lib.mkOption {
            type = contentType;
            default = "";
            description = ''
              Global agent instructions, supplied as inline text or a file path,
              and written to AGENTS.md.
            '';
          };

          systemPrompt = lib.mkOption {
            type = contentType;
            default = "";
            description = ''
              Global replacement system prompt, supplied as inline text or a
              file path, and written to SYSTEM.md.
            '';
          };

          appendSystemPrompt = lib.mkOption {
            type = contentType;
            default = "";
            description = ''
              Global system prompt addition, supplied as inline text or a file
              path, and written to APPEND_SYSTEM.md.
            '';
          };

          extensions = lib.mkOption {
            type = resourceType;
            default = { };
            description = ''
              Global Pi extensions. Use an attribute set of inline TypeScript or
              file/directory paths, or a path containing extensions. Attribute
              names receive a .ts suffix unless they already end in .ts or .js.
            '';
          };

          prompts = lib.mkOption {
            type = resourceType;
            default = { };
            description = ''
              Global prompt templates. Use an attribute set of inline Markdown
              or file paths, or a directory path. Attribute names receive a .md
              suffix unless they already end in .md.
            '';
          };

          themes = lib.mkOption {
            type = resourceType;
            default = { };
            description = ''
              Global Pi themes. Use an attribute set of inline JSON or file
              paths, or a directory path. Attribute names receive a .json suffix
              unless they already end in .json.
            '';
          };
        };

        config = {
          # Importing the aspect installs Pi, points its provider at the gateway
          # and leaves the rest of the configuration to the machine.
          programs.pi = {
            enable = lib.mkDefault true;
            package = lib.mkDefault null;
            extensions.magpie = ./magpie.ts;
            settings.defaultProvider = lib.mkDefault "magpie";
          };

          assertions = lib.mkIf cfg.enable [
            {
              assertion = !isPathLike cfg.extensions || lib.pathIsDirectory cfg.extensions;
              message = "`programs.pi.extensions` must be a directory when set to a path";
            }
            {
              assertion = !isPathLike cfg.prompts || lib.pathIsDirectory cfg.prompts;
              message = "`programs.pi.prompts` must be a directory when set to a path";
            }
            {
              assertion = !isPathLike cfg.themes || lib.pathIsDirectory cfg.themes;
              message = "`programs.pi.themes` must be a directory when set to a path";
            }
            {
              assertion =
                !builtins.isAttrs cfg.prompts
                || lib.all (content: !(isPathLike content && lib.pathIsDirectory content)) (
                  lib.attrValues cfg.prompts
                );
              message = "`programs.pi.prompts` attribute values must be files when set to paths";
            }
            {
              assertion =
                !builtins.isAttrs cfg.themes
                || lib.all (content: !(isPathLike content && lib.pathIsDirectory content)) (
                  lib.attrValues cfg.themes
                );
              message = "`programs.pi.themes` attribute values must be files when set to paths";
            }
          ];

          home = lib.mkIf cfg.enable {
            # The package list above installs Pi for the user and for a
            # co-located Paseo daemon, so the program adds only a package a
            # consumer explicitly asks for.
            packages = packages pkgs ++ lib.optional (cfg.package != null) cfg.package;

            # The gateway answers to its MagicDNS name, and the resolver does not
            # expand a bare peer name for it, so address the gateway fully
            # qualified. A host that runs its own gateway overrides this.
            sessionVariables = {
              PI_MAGPIE_URL = lib.mkDefault "http://${config.constants.getTailnetFqdn "box"}:3425";
            }
            // lib.optionalAttrs (cfg.configDir != defaultConfigDir) {
              PI_CODING_AGENT_DIR = cfg.configDir;
            };

            file = lib.mkMerge [
              (lib.mkIf (cfg.settings != { }) {
                "${cfg.configDir}/settings.json".source = jsonFormat.generate "pi-settings.json" cfg.settings;
              })
              (lib.mkIf (cfg.keybindings != { }) {
                "${cfg.configDir}/keybindings.json".source =
                  jsonFormat.generate "pi-keybindings.json" cfg.keybindings;
              })
              (lib.mkIf (cfg.mcpServers != { }) {
                "${cfg.configDir}/mcp.json".source = jsonFormat.generate "pi-mcp.json" {
                  inherit (cfg) mcpServers;
                };
              })
              (lib.mkIf (cfg.models != { }) {
                "${cfg.configDir}/models.json".source = jsonFormat.generate "pi-models.json" cfg.models;
              })
              (lib.mkIf (cfg.context != "") (mkPromptFile "AGENTS.md" cfg.context))
              (lib.mkIf (cfg.systemPrompt != "") (mkPromptFile "SYSTEM.md" cfg.systemPrompt))
              (lib.mkIf (cfg.appendSystemPrompt != "") (mkPromptFile "APPEND_SYSTEM.md" cfg.appendSystemPrompt))
              (lib.mkIf (cfg.extensions != { }) (mkResourceEntries "extensions" ".ts" cfg.extensions))
              (lib.mkIf (cfg.prompts != { }) (mkResourceEntries "prompts" ".md" cfg.prompts))
              (lib.mkIf (cfg.themes != { }) (mkResourceEntries "themes" ".json" cfg.themes))
            ];
          };
        };
      };
  };
}
