_: {
  perSystem =
    { pkgsUnstable, ... }:
    let
      pkgs = pkgsUnstable;
    in
    {
      packages.herdr-reviewr = pkgs.rustPlatform.buildRustPackage (finalAttrs: {
        pname = "herdr-reviewr";
        version = "0.49.0";

        src = pkgs.fetchFromGitHub {
          owner = "persiyanov";
          repo = "herdr-reviewr";
          rev = "1760576166ac0e76e80a70ed76a31cae3f75a6a3";
          hash = "sha256-Ko3q1ATlR7Gm4hknFV8N174oOZiPpRZfJp/zDW+UdvY=";
        };

        cargoHash = "sha256-s4H2RwDqe+b2OP5QuFa25kH27RT5x4ydXiFlHpgmWDQ=";

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
