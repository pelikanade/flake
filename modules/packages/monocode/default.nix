# MonoCode: the Tauri desktop GUI for coding-agent CLIs, built from the
# upstream release tag.
#
# The frontend is React/Vite and the shell is Rust/Tauri, so the build is
# upstream's own `cargo tauri build` driven by nixpkgs' cargo-tauri hook. That
# hook runs the configured `beforeBuildCommand` (`npm run build`), compiles the
# Rust binary, and unpacks the generated .deb into the output, which leaves the
# store path with the usual /bin, /share/applications and hicolor icon layout.
#
# No runtime Node is shipped: the desktop app only embeds the web bundle. The
# separately distributed `monocode-host` runtime used for remote sessions is
# downloaded on demand by the app, so it is not a build input here.
#
# Update: bump `version`, then refresh the three hashes with
#   nix store prefetch-file --unpack --json \
#     https://codeload.github.com/hardbeat920/monocode/tar.gz/refs/tags/vVER
#   nix shell nixpkgs#prefetch-npm-deps -c prefetch-npm-deps package-lock.json
#   nix build .#monocode   # cargoHash mismatch reports the correct value
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

      # Tauri's updater is configured with an empty pubkey and no endpoints; the
      # bundled updater plugin is inert rather than a build-time dependency.
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
