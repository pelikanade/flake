_: {
  flake-file.inputs = {
    home-manager = {
      url = "github:nix-community/home-manager/release-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  flake.modules.nixos.nvirellia =
    { config, pkgs, ... }:
    let
      inherit (config.constants) nvirellia;
    in
    {
      users.users."${nvirellia.username}" = {
        isNormalUser = true;
        description = nvirellia.preferredName;
        extraGroups = [
          "wheel"
          "video"
          "networkmanager"
          "input"
          "podman"
        ];
        shell = pkgs.fish;
        initialHashedPassword = nvirellia.hashedPassword;
        openssh.authorizedKeys.keys = [ nvirellia.sshPubKey ];
      };

      programs.fish.enable = true;

      home-manager = {
        users."${nvirellia.username}" = { };

        useGlobalPkgs = true;
        useUserPackages = true;
      };
    };

  flake.modules.homeManager.nvirellia =
    { config, ... }:
    let
      inherit (config.constants) nvirellia;
    in
    {
      home = {
        inherit (nvirellia) username;
        homeDirectory = "/home/${nvirellia.username}";
        sessionVariables = {
          LANG = "zh_CN.UTF-8";
          LANGUAGE = "zh_CN:en_US";
        };
        stateVersion = "26.05";
      };

      xdg.userDirs = {
        enable = true;
        createDirectories = true;
      };
    };
}
