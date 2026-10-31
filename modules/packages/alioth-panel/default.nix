{
  perSystem =
    { lib, pkgs, ... }:
    let
      target = "aarch64-linux";
      buildPkgs =
        if pkgs.stdenv.buildPlatform.system == target then pkgs else pkgs.pkgsCross.aarch64-multiplatform;

      panel = buildPkgs.rustPlatform.buildRustPackage {
        pname = "alioth-panel";
        version = "0.1.0";

        src = ./.;
        cargoLock.lockFile = ./Cargo.lock;

        passthru.collect = buildPkgs.writeShellScriptBin "alioth-panel-collect" (
          builtins.readFile ./collect.sh
        );

        meta = {
          description = "Status panel for the phone's own display";
          mainProgram = "alioth-panel";
          platforms = lib.platforms.linux;
        };
      };
    in
    {
      packages.alioth-panel = panel;
    };
}
