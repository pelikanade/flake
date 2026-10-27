_: {
  perSystem =
    { pkgsUnstable, ... }:
    let
      pkgs = pkgsUnstable;
    in
    {
      packages.herdr-reviewr = pkgs.rustPlatform.buildRustPackage (finalAttrs: {
        pname = "herdr-reviewr";
        version = "0.48.0";

        src = pkgs.fetchFromGitHub {
          owner = "persiyanov";
          repo = "herdr-reviewr";
          rev = "a253b1bfe4b34182af3204b7fcc42ccfed1b87d9";
          hash = "sha256-Y1AJHvXiIoIkjC3eU9rIBvBl99lvsQ2RIusNXONu2tY=";
        };

        cargoHash = "sha256-6+GnGBWRwfFMPXoim3p8Q8zoj3MdtK2smxkg7133xMg=";

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

        # Upstream's integration tests exercise Herdr pane behavior and are too
        # heavyweight for this local plugin package.
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
