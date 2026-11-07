_: {
  perSystem =
    { pkgsUnstable, ... }:
    let
      pkgs = pkgsUnstable;
    in
    {
      packages.herdr-reviewr = pkgs.rustPlatform.buildRustPackage (finalAttrs: {
        pname = "herdr-reviewr";
        version = "0.51.0";

        src = pkgs.fetchFromGitHub {
          owner = "persiyanov";
          repo = "herdr-reviewr";
          rev = "7e36b29692985ea633dedd15f311fd2fb21e9a7a";
          hash = "sha256-HE4WrgOgJqmoT3Ld5i+hN8BV6ZgotplF/kJNhZMb6nI=";
        };

        cargoHash = "sha256-nTe9HsSL9oj0OI2pp54eztTXtxe/YFCFA/825q6GfdM=";

        nativeBuildInputs = with pkgs; [
          makeWrapper
          pkg-config
        ];

        buildInputs = with pkgs; [
          libgit2
          oniguruma
          zlib
        ];

        env = {
          LIBGIT2_NO_VENDOR = true;
          RUSTONIG_SYSTEM_LIBONIG = true;
        };

        doCheck = false;

        postInstall = ''
          wrapProgram $out/bin/herdr-reviewr \
            --prefix PATH : ${pkgs.lib.makeBinPath (with pkgs; [ git ])}

          cp -R herdr herdr-plugin.toml README.md LICENSE $out/
        '';

        passthru.update = {
          kind = "rev";
          file = "modules/packages/herdr-reviewr/default.nix";
          repo = "persiyanov/herdr-reviewr";
          files = [ "modules/packages/herdr-reviewr/default.nix" ];
        };

        meta = {
          description = "Code-review pane for Herdr";
          homepage = "https://github.com/persiyanov/herdr-reviewr";
          changelog = "https://github.com/persiyanov/herdr-reviewr/blob/${finalAttrs.src.rev}/CHANGELOG.md";
          license = pkgs.lib.licenses.mit;
          mainProgram = "herdr-reviewr";
          platforms = pkgs.lib.platforms.linux ++ pkgs.lib.platforms.darwin;
        };
      });
    };
}
