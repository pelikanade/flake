{ inputs, ... }:
let
  package =
    {
      lib,
      rustPlatform,
      fetchFromGitHub,
      pkg-config,
      wrapGAppsHook4,
      makeWrapper,
      versionCheckHook,
      bubblewrap,
      cairo,
      fontconfig,
      glib,
      gst_all_1,
      gtk4,
      gtksourceview5,
      poppler,
    }:
    rustPlatform.buildRustPackage (finalAttrs: {
      pname = "strata";
      version = "1.0.0";

      # The v1.0.0 tag. `src.rev` is the commit the About dialog names, so it is
      # set from the pinned revision rather than left to build.rs, which finds
      # no git checkout in the sandbox.
      src = fetchFromGitHub {
        owner = "lgse";
        repo = "strata";
        rev = "0a086aa3bdb251842a1e8413e2a6b35970d0b409";
        hash = "sha256-dFNsFCnkeZs0VwmYRyu+6Jh8XxJzv+agUlP70Fdxa5Q=";
      };

      # Two Nix-specific integrations, neither of which upstream's AUR packages
      # need. The updater learns that an executable under /nix/store is owned by
      # Nix -- a store path cannot be replaced in place, and upstream reserves
      # its `share/strata/install-source.toml` marker for pacman -- and the
      # trusted-helper lookup accepts the bubblewrap that a closure supplies.
      patches = [ ./nix-integration.patch ];

      cargoHash = "sha256-vuhHierqb4WsMdg890NpkaztYnfsnck2FxMz5cPMwCQ=";

      nativeBuildInputs = [
        pkg-config
        wrapGAppsHook4
        makeWrapper
      ];

      buildInputs = [
        cairo
        fontconfig
        glib
        gst_all_1.gstreamer
        gst_all_1.gst-plugins-base
        gtk4
        gtksourceview5
        poppler
      ];

      env = {
        STRATA_BUILD_COMMIT = lib.substring 0 12 finalAttrs.src.rev;
        # Previews and thumbnails run inside bwrap, which the app resolves from
        # trusted system directories and never from PATH. A closure copy is how
        # it reaches NixOS, which keeps such tools out of the system profile.
        STRATA_HELPER_PATH = lib.makeBinPath [ bubblewrap ];
      };

      postInstall = ''
        install -Dm644 data/io.github.lgse.Strata.desktop \
          $out/share/applications/io.github.lgse.Strata.desktop
        install -Dm644 data/icons/scalable/apps/io.github.lgse.Strata.svg \
          $out/share/icons/hicolor/scalable/apps/io.github.lgse.Strata.svg
        install -Dm644 LICENSE THIRD_PARTY_LICENSES.md \
          --target-directory=$out/share/licenses/strata
        install -Dm644 data/licenses/*.txt --target-directory=$out/share/licenses/strata
      '';

      # Upstream runs its suite against a container image with ffmpeg, a display
      # and a Docker daemon; none of that is hermetic here.
      doCheck = false;

      # The wrapped binary loading at all is what this sandbox can still prove.
      doInstallCheck = true;
      nativeInstallCheckInputs = [ versionCheckHook ];
      versionCheckProgramArg = "--version";

      meta = {
        description = "Fast, keyboard-first file manager for Linux";
        longDescription = ''
          A GTK4 file manager built around spatial Miller-column navigation,
          with Icons and List views, fuzzy search, rich previews that render
          inside a bubblewrap sandbox, and optional desktop integration for
          the file chooser portal, folder handling, and encrypted-volume unlock.
        '';
        homepage = "https://github.com/lgse/strata";
        changelog = "https://github.com/lgse/strata/releases/tag/v${finalAttrs.version}";
        # The default `rar` feature statically links the vendored UnRAR reader
        # (LicenseRef-UnRAR, shipped as data/licenses/UnRAR.txt).
        license = lib.licenses.mit;
        maintainers = [ lib.maintainers.asterismono ];
        mainProgram = "strata";
        platforms = lib.platforms.linux;
      };
    });
in
{
  # The dependency tree needs Rust 1.96 (kstring 2.0.4), and nixos-26.05 ships
  # 1.95, so take nixos-unstable's 1.98 toolchain -- the release line upstream
  # builds with. GTK, GStreamer, poppler, and the rest would build on the
  # stable set.
  perSystem =
    { pkgsUnstable, ... }:
    {
      packages.strata = pkgsUnstable.callPackage package { };
    };
}
