{ inputs, ... }:
{
  # Upstream ships the launcher as a flake module that builds it against the
  # consuming system's nixpkgs, so the input carries no second package set.
  flake-file.inputs.anime-games-launcher = {
    url = "github:an-anime-team/anime-games-launcher";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  flake.modules.nixos.anime-games-launcher = {
    imports = [ inputs.anime-games-launcher.nixosModules.anime-games-launcher ];

    programs.anime-games-launcher.enable = true;
  };
}
