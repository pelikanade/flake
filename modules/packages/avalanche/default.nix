{
  perSystem =
    { pkgs, ... }:
    {
      packages.avalanche = pkgs.buildGoModule {
        pname = "avalanche";
        version = "0.1.0";
        src = ./.;
        vendorHash = null;
        subPackages = [
          "cmd/avalanche-client"
          "cmd/avalanche-target"
        ];
        meta.mainProgram = "avalanche-client";
      };
    };
}
