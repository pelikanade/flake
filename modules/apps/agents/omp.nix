{
  inputs,
  ...
}:
let
  # omp brings its own tools, shell and native code; add the interpreter its
  # eval cells use and the system tools its calls reach for.
  ompPackages =
    pkgs:
    (with pkgs; [
      bashInteractive
      git
      jq
      nix
      openssh
      python3
      ripgrep
    ]);
in
{
  config = {
    flake-file.inputs.omp = {
      url = "github:can1357/oh-my-pi";
      # oh-my-pi has no dedicated binary cache, so it follows the shared root.
      inputs.nixpkgs.follows = "nixpkgs";
    };

    flake.modules.aspects.omp.imports = [ inputs.self.modules.aspects.agent-upstream ];

    flake.modules.nixos.omp =
      {
        config,
        lib,
        pkgs,
        ...
      }:
      {
        key = "omp";

        # Upstream owns the agent directory: it installs omp, takes the package
        # option and writes config.yml as a writable copy, because omp flocks and
        # atomically rewrites its configuration.
        imports = [ inputs.omp.nixosModules.default ];

        programs.omp.enable = lib.mkDefault true;
        environment.systemPackages = ompPackages pkgs;

        sops.secrets = {
          omp-magpie-endpoint = {
            format = "yaml";
            key = "endpoint";
            sopsFile = config.constants.resources.getSecretPath "magpie.yaml";
          };
          omp-magpie-api-key = {
            format = "yaml";
            key = "api_key";
            sopsFile = config.constants.resources.getSecretPath "magpie.yaml";
          };
        };

        sops.templates.omp-magpie =
          lib.mkIf (lib.hasAttr config.constants.nvirellia.username config.users.users)
            {
              content = builtins.toJSON {
                endpoint = config.sops.placeholder.omp-magpie-endpoint;
                api_key = config.sops.placeholder.omp-magpie-api-key;
              };
              path = config.constants.resources.userSecretPaths.ompMagpie;
              owner = config.constants.nvirellia.username;
              mode = "0400";
            };
      };

    flake.modules.homeManager.omp =
      {
        config,
        lib,
        pkgs,
        ...
      }:
      {
        key = "omp";

        imports = [ inputs.omp.homeManagerModules.default ];

        # Upstream owns the agent directory and installs config.yml as a
        # writable copy overwritten on every switch, so every setting worth
        # keeping is declared here; a runtime /settings change is lost at the
        # next switch. These are the role assignments and interface settings the
        # desktop user runs today. Cursor's OAuth Sonnet plans and advises, and
        # Codex's gpt-6-astra:xhigh runs the slow role. These selectors require
        # `omp /login cursor` and `omp /login openai-codex`. setupVersion is the
        # onboarding wizard's completion marker (omp's CURRENT_SETUP_VERSION);
        # raise it when omp raises that constant, or the wizard reappears.
        programs.omp = {
          enable = lib.mkDefault true;
          settings = {
            modelRoles = {
              plan = "cursor/claude-sonnet-5-5:high";
              advisor = "cursor/claude-sonnet-5-5:high";
              slow = "openai-codex/gpt-6-astra:xhigh";
            };
            composer.shape = "claude";
            setupVersion = 2;
            symbolPreset = "nerd";
            theme.dark = "dark-nord";
            hideThinkingBlock = true;
            github.enabled = true;
            task.isolation.enabled = true;
          };
        };

        home = lib.mkIf config.programs.omp.enable {
          packages = ompPackages pkgs;

          sessionVariables = {
            OMP_MAGPIE_CONFIG = config.constants.resources.userSecretPaths.ompMagpie;
            PI_CONFIG_FILES = toString (
              (pkgs.formats.yaml { }).generate "omp-magpie-config.yml" {
                extensions = [ "${pkgs.selfPackages.omp-magpie}/share/omp/extensions/magpie" ];
              }
            );
          };
        };
      };
  };
}
