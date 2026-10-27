{
  perSystem =
    { pkgs, ... }:
    {
      packages.nvirellia-im = pkgs.buildGoModule {
        pname = "nvirellia-im";
        version = "0-unstable";
        src = ./.;
        subPackages = [ "cmd/nvirellia-im" ];
        vendorHash = null;
        ldflags = [
          "-s"
          "-w"
        ];
        meta = {
          description = "nvirellia.im profile sheet";
          mainProgram = "nvirellia-im";
        };
      };
    };
}
