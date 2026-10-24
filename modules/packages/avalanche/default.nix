{
  perSystem =
    { lib, pkgs, ... }:
    {
      packages.avalanche = pkgs.buildGoModule {
        pname = "avalanche";
        version = "0.1.0";
        src = ./.;
        vendorHash = "sha256-JpPiD8F/3t4kMMVWmQunAC24VuhBj2S0NeLBnYMlt+I=";
        subPackages = [
          "cmd/avalanche-client"
          "cmd/avalanche-server"
        ];
        meta.mainProgram = "avalanche-client";
      };
    };
}
