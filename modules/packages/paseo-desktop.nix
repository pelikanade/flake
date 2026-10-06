_:
let
  package =
    {
      lib,
      buildNpmPackage,
      fetchFromGitHub,
      nodejs_22,
      python3,
      makeShellWrapper,
      copyDesktopItems,
      makeDesktopItem,
      electron_42,
      libuv,
      autoPatchelfHook,
      wrapGAppsHook3,
      glib,
      gtk3,
      gtk4,
      gsettings-desktop-schemas,
      libGL,
      libnotify,
      coreutils,
      util-linux,
      gcc-unwrapped,
    }:
    buildNpmPackage (finalAttrs: {
      pname = "paseo-desktop";
      version = "0.10.3";

      src = fetchFromGitHub {
        owner = "getpaseo";
        repo = "paseo";
        tag = "v${finalAttrs.version}";
        hash = "sha256-yI/H8XPC0lLdmokePJ4qyVxaV+/PsgePzQupumm5LPQ=";
      };

      nodejs = nodejs_22;

      npmDepsFetcherVersion = 2;
      npmDepsHash = "sha256-tetnvvpOxeMIWpJ0qVz5octD7rUM216mj0b1rYnNMzM=";

      # Prevent onnxruntime-node's install script from running during automatic
      # npm rebuild. We manually rebuild only node-pty in buildPhase.
      npmRebuildFlags = [ "--ignore-scripts" ];

      nativeBuildInputs = [
        python3 # for node-gyp (node-pty)
        makeShellWrapper
        copyDesktopItems
        autoPatchelfHook
        wrapGAppsHook3
      ];

      buildInputs = [
        libuv
        gcc-unwrapped.lib
        glib
        gtk3
        gtk4
        gsettings-desktop-schemas
      ];

      dontNpmBuild = true;
      dontWrapGApps = true;
      # Electron already carries nixpkgs' interpreter and RPATHs.
      dontAutoPatchelf = true;

      env = {
        EXPO_NO_TELEMETRY = "1";
        ELECTRON_SKIP_BINARY_DOWNLOAD = "1";
        # Expo's web build pulls in some pre-bundled assets; ensure it doesn't try
        # to phone home during the build.
        CI = "1";
      };

      buildPhase = ''
        runHook preBuild

        # Native deps (terminal emulation; libuv-linked on Linux).
        # node-gyp-build skips compilation when a matching prebuilt binary exists,
        # so remove the bundled prebuilds first to force a real build.
        rm -rf packages/server/node_modules/node-pty/prebuilds
        npm rebuild node-pty --workspace=@getpaseo/server

        # Server workspaces (highlight + relay + protocol + client + server + cli)
        npm run build:server

        # App workspace deps not covered by build:server
        npm run build --workspace=@getpaseo/expo-two-way-audio

        # Expo web export for the Electron renderer
        ( cd packages/app && PASEO_WEB_PLATFORM=electron npx expo export --platform web )

        # Desktop main process and upstream Linux packaging (no installer targets).
        npm run build:main --workspace=@getpaseo/desktop

        cp -r ${electron_42.dist} electronDist
        chmod -R u+w electronDist
        electronDist="$PWD/electronDist"
        (
          cd packages/desktop
          npx --no-install electron-builder --dir --linux --publish never \
            --config electron-builder.yml \
            -c.electronDist="$electronDist" \
            -c.electronVersion=${electron_42.version}
        )

        runHook postBuild
      '';

      installPhase = ''
        runHook preInstall

        mkdir -p $out/share/paseo-desktop $out/bin

        # Preserve the complete builder/afterPack layout. Paseo is a shell launcher;
        # Paseo.bin is the application's own Electron ELF, beside its resources.
        cp -r packages/desktop/release/linux*unpacked/. $out/share/paseo-desktop/
        patchShebangs --build $out/share/paseo-desktop/Paseo \
          $out/share/paseo-desktop/resources/bin/paseo

        # Linux's upstream extraResources omits the window icon used by main.ts.
        install -Dm644 packages/desktop/assets/icon.png \
          $out/share/paseo-desktop/resources/icon.png
        install -Dm644 packages/desktop/assets/icon.png \
          $out/share/icons/hicolor/512x512/apps/paseo-desktop.png

        runHook postInstall
      '';

      postFixup = ''
        # Only repair application native resources, preserving nixpkgs Electron.
        autoPatchelf $out/share/paseo-desktop/resources/app.asar.unpacked

        # The unpacked app uses AppImageUpdater, which is inactive without APPIMAGE.
        # Do not inherit a parent AppImage's updater/CLI-install identity.
        # Follow nixpkgs' NIXOS_OZONE_WL/Wayland convention through upstream's
        # Chromium-flags environment variable; argv is reserved for CLI passthrough.
        makeShellWrapper $out/share/paseo-desktop/Paseo $out/bin/paseo-desktop \
          "''${gappsWrapperArgs[@]}" \
          --prefix LD_LIBRARY_PATH : "${
            lib.makeLibraryPath [
              libGL
              libnotify
            ]
          }" \
          --prefix PATH : "${
            lib.makeBinPath [
              coreutils
              util-linux
            ]
          }" \
          --set CHROME_DEVEL_SANDBOX "$out/share/paseo-desktop/chrome-sandbox" \
          --unset APPIMAGE \
          --run 'if [[ -n "''${NIXOS_OZONE_WL:-}" && -n "''${WAYLAND_DISPLAY:-}" ]]; then export PASEO_ELECTRON_FLAGS="--enable-wayland-ime --ozone-platform=wayland --enable-features=WaylandWindowDecorations''${PASEO_ELECTRON_FLAGS:+ $PASEO_ELECTRON_FLAGS}"; fi'
      '';

      desktopItems = [
        (makeDesktopItem {
          name = "paseo-desktop";
          desktopName = "Paseo";
          genericName = "AI Coding Agents";
          comment = "Self-hosted daemon for AI coding agents";
          exec = "paseo-desktop";
          icon = "paseo-desktop";
          categories = [ "Development" ];
          startupWMClass = "Paseo";
        })
      ];

      meta = {
        description = "Voice-controlled desktop development environment for AI coding agents";
        homepage = "https://paseo.sh";
        changelog = "https://github.com/getpaseo/paseo/releases/tag/v${finalAttrs.version}";
        license = lib.licenses.asl20;
        sourceProvenance = [ lib.sourceTypes.fromSource ];
        # nvirellia's nixpkgs maintainer entry keeps its original attribute name.
        maintainers = [ lib.maintainers.asterismono ];
        mainProgram = "paseo-desktop";
        platforms = lib.platforms.linux;
      };
    });

in
{
  perSystem =
    { pkgsUnstable, ... }:
    {
      packages.paseo-desktop = pkgsUnstable.callPackage package { };
    };
}
