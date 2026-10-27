{
  perSystem =
    { pkgs, ... }:
    {
      packages.freezer = pkgs.buildGoModule {
        pname = "freezer";
        version = "0.2.3";
        src = ./.;
        vendorHash = "sha256-ym2IdO2nmzfaIVErrPSQYlcTNAFKj+/oQnPBAPsxbaE=";
        subPackages = [ "." ];
        env.CGO_ENABLED = "0";
        ldflags = [
          "-s"
          "-w"
        ];
        # The acceptance suite needs the host Nix daemon and the devenv S3 service.
        doCheck = false;
        meta = {
          description = "Polling Nix flake build service with optional signed S3 binary-cache publication";
          mainProgram = "freezer";
          platforms = [
            "x86_64-linux"
            "aarch64-linux"
          ];
        };
      };
    };
}
