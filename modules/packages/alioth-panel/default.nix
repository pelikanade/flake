{
  # The panel only ever runs on the phone, so its *target* is always aarch64: on
  # a machine that already is aarch64 it is built natively, and anywhere else it
  # is a cross build — the only form a workstation can produce. The package
  # therefore adapts to the machine building it, instead of the caller having to
  # know which machine it is on.
  perSystem =
    { lib, pkgs, ... }:
    let
      target = "aarch64-linux";
      buildPkgs =
        if pkgs.stdenv.buildPlatform.system == target then pkgs else pkgs.pkgsCross.aarch64-multiplatform;

      panel = buildPkgs.rustPlatform.buildRustPackage {
        pname = "alioth-panel";
        version = "0.1.0";

        # No build script, no C dependencies, two pure-Rust crates: the
        # dependency tree is the part of such a build that breaks.
        src = ./.;
        cargoLock.lockFile = ./Cargo.lock;

        # The collector is not part of the binary, but it is part of the feature
        # and lives with it: one package, one version, two things to hand out.
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
