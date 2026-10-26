{ inputs, lib, ... }: {
  flake-file.inputs.git-hooks = {
    url = "github:cachix/git-hooks.nix";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  perSystem =
    {
      config,
      pkgs,
      system,
      ...
    }:
    {
      checks = {
        pre-commit-check = inputs.git-hooks.lib.${system}.run {
          src = ./.;
          hooks = {
            nixfmt.enable = true;
            statix = {
              enable = true;
              settings.config = lib.toString ../statix.toml;
            };
          };
        };
      };

      devShells.default = pkgs.mkShell {
        packages = with pkgs; [
          android-tools
          bun
          nixd
          nixfmt
          just
          nh
          nix-update
          sops
          age
          ssh-to-age
          nixos-rebuild-ng
          nixos-anywhere
          uv
          python3
          sshpass
          pinentry-gnome3
        ];
        inherit (config.checks.pre-commit-check) shellHook;
        buildInputs = config.checks.pre-commit-check.enabledPackages;
        EDITOR = "nvim";
      };
    };
}
