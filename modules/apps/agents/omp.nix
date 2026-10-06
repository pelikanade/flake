{
  inputs,
  ...
}:
let
  # omp is the harness the agent hosts run; its providers are declared in
  # models.yml rather than discovered from a gateway. omp brings its own tools,
  # shell and native code, so this adds what an agent host expects from the
  # system anyway: the interpreter its eval cells use, jq for ad-hoc shell work,
  # and the shell, git, ssh, nix and ripgrep its tool calls reach for.
  ompPackages =
    pkgs:
    [ inputs.omp.packages.${pkgs.stdenv.hostPlatform.system}.omp ]
    ++ (with pkgs; [
      bashInteractive
      git
      jq
      nix
      openssh
      python3
      ripgrep
    ]);

  # DeepSeek and OpenRouter are key-based, so a client host authenticates them
  # from a runtime secret. Codex and Cursor are OAuth providers omp owns through
  # `omp /login`; their credentials stay in omp's own auth store per host and
  # never enter Nix. The keys resolve lazily, so models.yml names a command
  # instead of embedding a value: no key reaches Nix evaluation, the store or
  # the environment.
  providersYaml = keyPaths: ''
    providers:
      deepseek:
        apiKey: "!cat ${keyPaths.ompDeepseekApiKey}"
      openrouter:
        apiKey: "!cat ${keyPaths.ompOpenrouterApiKey}"
  '';
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

        # Decrypt the provider keys for the desktop user, who reads them by path
        # from models.yml. A server host has no such user and provisions its own
        # copy where its omp runs instead.
        sops.secrets = lib.mkIf (lib.hasAttr config.constants.nvirellia.username config.users.users) {
          omp-deepseek-api-key = {
            format = "yaml";
            key = "deepseek_api_key";
            sopsFile = config.constants.resources.getSecretPath "omp-providers.yaml";
            owner = config.constants.nvirellia.username;
            mode = "0400";
          };
          omp-openrouter-api-key = {
            format = "yaml";
            key = "openrouter_api_key";
            sopsFile = config.constants.resources.getSecretPath "omp-providers.yaml";
            owner = config.constants.nvirellia.username;
            mode = "0400";
          };
        };
      };

    flake.modules.homeManager.omp =
      {
        config,
        lib,
        pkgs,
        ...
      }:
      let
        configDir = "${config.home.homeDirectory}/.omp/agent";
      in
      {
        key = "omp";

        imports = [ inputs.omp.homeManagerModules.default ];

        # Upstream owns the agent directory and installs config.yml as a
        # writable copy overwritten on every switch, so every setting worth
        # keeping is declared here; a runtime /settings change is lost at the
        # next switch. These are the role assignments and interface settings the
        # desktop user runs today, mirroring omp's own `omp config list`. The
        # key-authenticated DeepSeek provider carries the session default and
        # the cheap roles: smol for small workloads, and the low-thinking
        # tiny/commit plus memory, task and vision. Cursor's OAuth Sonnet plans
        # and advises, and Codex's gpt-6-astra:xhigh runs the slow role, so
        # those three selectors resolve only on a host that ran
        # `omp /login cursor` and `omp /login openai-codex`. setupVersion is the
        # onboarding wizard's completion marker (omp's CURRENT_SETUP_VERSION);
        # raise it when omp raises that constant, or the wizard reappears.
        programs.omp = {
          enable = lib.mkDefault true;
          settings = {
            modelRoles = {
              default = "deepseek/deepseek-flash:high";
              smol = "deepseek/deepseek-flash:high";
              tiny = "deepseek/deepseek-flash:low";
              commit = "deepseek/deepseek-flash:low";
              memory = "deepseek/deepseek-flash:high";
              task = "deepseek/deepseek-flash:high";
              vision = "deepseek/deepseek-flash:high";
              plan = "cursor/claude-sonnet-5-5:high";
              advisor = "cursor/claude-sonnet-5-5:high";
              slow = "openai-codex/gpt-6-astra:xhigh";
            };
            composer.shape = "claude";
            setupVersion = 2;
            symbolPreset = "nerd";
            theme.dark = "dark-rose-pine";
            hideThinkingBlock = true;
            github.enabled = true;
            task.isolation.enabled = true;
          };
        };

        home = lib.mkIf config.programs.omp.enable {
          packages = ompPackages pkgs;

          # models.yml is read-only user configuration, so a store symlink is
          # safe unlike config.yml, which omp rewrites.
          file."${configDir}/models.yml".text = providersYaml config.constants.resources.userSecretPaths;
        };
      };
  };
}
