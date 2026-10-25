_:
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
      coreutils,
      ffmpeg,
      ffmpegthumbnailer,
      fontconfig,
      glib,
      gst_all_1,
      gtk4,
      gtksourceview5,
      imagemagick,
      librsvg,
      libraw,
      poppler,
      squashfs-tools,
      util-linux,
    }:
    rustPlatform.buildRustPackage (finalAttrs: {
      pname = "strata";
      version = "1.1.0";

      src = fetchFromGitHub {
        owner = "lgse";
        repo = "strata";
        rev = "4b9a6ace71017888b3a2124d7d911c5c664cc767";
        hash = "sha256-FoYYsjvWY+1SuZtvxancdVR6h7iFmnbtHXW2eTlVCJI=";
      };

      # Upstream's updater recognizes pacman-owned binaries, not store paths:
      # a store path is immutable, and upstream reserves its
      # `share/strata/install-source.toml` marker for pacman. Trusted helper
      # lookup uses upstream's STRATA_TRUSTED_COMMAND_PATH.
      patches = [ ./nix-integration.patch ];

      cargoHash = "sha256-U52ypUksrz/2G8apmyh7x9c+47ZBStT1lHIWso7KfU4=";

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
        gst_all_1.gst-plugins-good
        gst_all_1.gst-libav
        gtk4
        gtksourceview5
        librsvg
        poppler
      ];

      env = {
        STRATA_BUILD_COMMIT = lib.substring 0 12 finalAttrs.src.rev;

        # Previews and thumbnails run inside a bubblewrap namespace whose
        # environment is cleared, so everything the helpers need is bound and
        # baked here at build time; launching-time variables have no effect.
        # Upstream documents the same knobs for Nix in docs/preview-sandbox.md.
        #
        # `/nix/store` replaces `/usr` as the sandbox's read-only runtime tree:
        # it carries the executable's loader and libraries, the GdkPixbuf
        # loaders, and every helper below. The system profile is not part of it
        # and cannot be, so hosts cannot supply these tools.
        STRATA_SANDBOX_ROOT = "/nix/store";
        STRATA_SANDBOX_PRLIMIT = lib.getExe' util-linux "prlimit";
        STRATA_SANDBOX_GDK_PIXBUF_MODULE_FILE = "${librsvg}/lib/gdk-pixbuf-2.0/2.10.0/loaders.cache";
        # Every helper the sandboxed workers exec by name: ffmpeg/ffprobe and
        # ffmpegthumbnailer for video, ImageMagick and libraw for camera RAW,
        # `nice` and `prlimit` around the media decoder, `fc-list` for text in
        # documents, and `unsquashfs` for AppImage icons.
        STRATA_SANDBOX_PATH = lib.makeBinPath [
          coreutils
          ffmpeg
          ffmpegthumbnailer
          fontconfig
          imagemagick
          libraw
          squashfs-tools
          util-linux
        ];

        # bubblewrap itself is resolved from trusted system directories and never
        # from PATH, so the closure supplies it.
        STRATA_TRUSTED_COMMAND_PATH = lib.makeBinPath [ bubblewrap ];
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

      doInstallCheck = true;
      nativeInstallCheckInputs = [ versionCheckHook ];
      versionCheckProgramArg = "--version";

      passthru.update = {
        kind = "rev";
        file = "modules/packages/strata/default.nix";
        repo = "lgse/strata";
        files = [
          "modules/packages/strata/default.nix"
          "modules/packages/strata/nix-integration.patch"
        ];
      };

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
