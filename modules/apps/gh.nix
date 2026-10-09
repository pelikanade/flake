{
  flake.modules.nixos.gh = { pkgs, ... }: {
    environment.systemPackages = [ pkgs.gh ];
  };
}
