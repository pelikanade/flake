{
  inputs,
  ...
}:
let
  # omp is the harness a gateway client runs, and its only provider is the Magpie
  # gateway, which holds every credential and reaches the vendors. omp brings its
  # own tools, shell and native code, so this adds what an agent host expects from
  # the system anyway: the interpreter its eval cells use, jq for ad-hoc shell
  # work, and the shell, git, ssh, nix and ripgrep its tool calls reach for.
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

        # The gateway answers to its MagicDNS name, and the resolver does not
        # expand a bare peer name, so address it fully qualified. A host that runs
        # its own gateway talks over loopback instead. This is a session variable
        # rather than a Home Manager one because this host sources only
        # /etc/set-environment at login, never Home Manager's session vars.
        environment.sessionVariables.PI_MAGPIE_URL =
          if config.systemd.services ? magpie then
            "http://127.0.0.1:3425"
          else
            "http://${config.constants.getTailnetFqdn "box"}:3425";
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

        # Upstream owns the agent directory and config.yml. The only value this
        # adds points omp at the gateway: the extension registers the provider
        # from PI_MAGPIE_URL, and the default role selects it.
        programs.omp = {
          enable = lib.mkDefault true;
          settings.modelRoles.default = lib.mkDefault "magpie/cursor/auto";
        };

        home = lib.mkIf config.programs.omp.enable {
          packages = ompPackages pkgs;

          file."${configDir}/extensions/magpie.ts".source = ./magpie.ts;
        };
      };
  };
}
