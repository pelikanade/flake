_: {
  perSystem =
    { pkgsUnstable, ... }:
    let
      pkgs = pkgsUnstable;
    in
    {
      packages.herdr-reviewr = pkgs.rustPlatform.buildRustPackage (finalAttrs: {
        pname = "herdr-reviewr";
        version = "0.49.1";

        src = pkgs.fetchFromGitHub {
          owner = "persiyanov";
          repo = "herdr-reviewr";
          rev = "92c51e2bd4e2caf42fa00bc193ae2f48955df64f";
          hash = "sha256-Yl6IM1v+uvHj1SENUC3dvM3vmbGMgkQzqTXFBF9GFfY=";
        };

        cargoHash = "sha256-3j49IyB/3oWBfA+W8eabwpZ4N7jwRXfiV5t01Ow6/Hw=";

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
