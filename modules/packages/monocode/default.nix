_:
let
  package =
    {
      lib,
      rustPlatform,
      fetchFromGitHub,
      fetchNpmDeps,
      cargo-tauri,
      nodejs_24,
      npmHooks,
      git,
      pkg-config,
      wrapGAppsHook4,
      openssl,
      webkitgtk_4_1,
      libsoup_3,
      glib-networking,
    }:
    rustPlatform.buildRustPackage (finalAttrs: {
      pname = "monocode";
      version = "0.14.0";

      src = fetchFromGitHub {
        owner = "hardbeat920";
        repo = "monocode";
        tag = "v${finalAttrs.version}";
        hash = "sha256-Qfi76rxkQn4fzvIQ+Gxb0a7g7NpCDoGDa0405PHa8BY=";
      };

      cargoHash = "sha256-gIMjkM4+2Q0uaWRLT7y//06d2qfwUvfXYIp8MTMGFXQ=";

      npmDeps = fetchNpmDeps {
        inherit (finalAttrs) src;
        hash = "sha256-7v0s/+a0fbTi1sbQPlx2uzxXOtNfsXhLoYgEXGmvlw8=";
      };

      nativeBuildInputs = [
        cargo-tauri.hook
        nodejs_24
        npmHooks.npmConfigHook
        pkg-config
        wrapGAppsHook4
      ];

      nativeCheckInputs = [ git ];

      buildInputs = [
        openssl
        webkitgtk_4_1
        libsoup_3
        glib-networking
      ];

      meta = {
        description = "GUI for coding agents";
        homepage = "https://usemono.dev";
        changelog = "https://github.com/hardbeat920/monocode/blob/v${finalAttrs.version}/CHANGELOG.md";
        license = lib.licenses.mit;
        mainProgram = "monocode";
        platforms = lib.platforms.linux;
      };
    });
in
{
  perSystem =
    { pkgs, ... }:
    {
      packages.monocode = pkgs.callPackage package { };
    };
}
