{
  inputs,
  ...
}:
let
  ompPackages =
    pkgs:
    (with pkgs; [
      bashInteractive
      chromium
      git
      jq
      nix
      openssh
      python3
      ripgrep
    ])
    ++ [ inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.agent-browser ];
in
{
  config = {
    perSystem =
      { system, ... }:
      {
        packages.omp = inputs.omp.packages.${system}.omp;
      };

    flake-file.inputs.omp = {
      url = "github:can1357/oh-my-pi";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    flake.modules.nixos.omp =
      {
        config,
        lib,
        pkgs,
        ...
      }:
      let
        username = config.constants.nvirellia.username;
        user = config.users.users.${username};
        hasDesktopUser = lib.hasAttr username config.users.users;
      in
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

        sops.templates.omp-magpie = lib.mkIf hasDesktopUser {
          content = builtins.toJSON {
            endpoint = config.sops.placeholder.omp-magpie-endpoint;
            api_key = config.sops.placeholder.omp-magpie-api-key;
          };
          path = "${user.home}/.omp/agent/magpie.yaml";
          owner = username;
          mode = "0400";
        };

        systemd.tmpfiles.rules = lib.mkIf hasDesktopUser [
          "d ${user.home}/.omp 0700 ${username} ${user.group} -"
          "d ${user.home}/.omp/agent 0700 ${username} ${user.group} -"
        ];
        systemd.services.sops-install-secrets.after = [
          "systemd-tmpfiles-setup.service"
          "systemd-tmpfiles-resetup.service"
        ];
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
        # next switch. These selectors require `omp /login cursor` and
        # `omp /login openai-codex`. setupVersion is the onboarding wizard's
        # completion marker (omp's CURRENT_SETUP_VERSION); raise it when omp
        # raises that constant, or the wizard reappears.
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
