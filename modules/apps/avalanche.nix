{
  flake.modules.nixos.avalanche-client =
    { pkgs, ... }:
    {
      environment.systemPackages = [ pkgs.selfPackages.avalanche ];
    };
}
