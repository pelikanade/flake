{
  flake.modules.nixos.installer =
    {
      config,
      modulesPath,
      pkgs,
      ...
    }:
    {
      imports = [
        "${modulesPath}/installer/cd-dvd/installation-cd-minimal.nix"
      ];

      users.users.root.openssh.authorizedKeys.keys = [ config.constants.nvirellia.sshPubKey ];

      environment.systemPackages = with pkgs; [
        age
        bat
        duf
        dust
        eza
        fish
        fzf
        git
        jq
        just
        lazygit
        nh
        nix-output-monitor
        nixd
        nixfmt
        nixos-anywhere
        nixos-rebuild-ng
        ripgrep
        sbctl
        sops
        ssh-to-age
        starship
      ];

      programs.fish = {
        enable = true;
        interactiveShellInit = ''
          starship init fish | source
        '';
        shellInit = ''
          function fish_greeting
            echo "NixOS installer"
            echo ""
            echo "  1. Connect to the network: nmtui"
            echo "  2. From your workstation, connect as root:"
            echo "       ssh root@<this host>"
            echo ""
            echo "This environment holds no flake checkout and does not install"
            echo "itself. Installations run from a workstation:"
            echo "  just generate-luks-password <machine>"
            echo "  just install <machine> root@<this host> <passphrase-file>"
            echo ""
          end
        '';
        shellAliases = {
          l = "eza -l";
          ll = "eza -al";
          ls = "eza -l";
          tree = "eza --tree";
        };
      };

      users.users.nixos.shell = pkgs.fish;
    };
}
