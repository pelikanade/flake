_: {
  flake.modules.nixos.steam = { pkgs, ... }: {
    programs.gamescope.enable = true;

    programs.steam = {
      enable = true;
      extraCompatPackages = [ pkgs.proton-ge-bin ];
    };
  };
}
