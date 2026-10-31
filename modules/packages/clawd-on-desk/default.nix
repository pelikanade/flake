_: {
  perSystem =
    { pkgsUnstable, ... }:
    let
      inherit (pkgsUnstable)
        buildNpmPackage
        copyDesktopItems
        electron_44
        fetchFromGitHub
        lib
        makeDesktopItem
        makeWrapper
        patchelf
        stdenv
        ;

      pname = "clawd-on-desk";
      version = "1.4.0";
      rev = "93a0e67004f1d7f1b20b72ad08256ecd00dbfe27";

      host = stdenv.hostPlatform;

      # koffi ships one prebuilt addon per platform and architecture, named the
      # way process.platform and process.arch spell them; its loader picks its
      # own directory at runtime. Upstream's scripts/after-pack-koffi.js keeps
      # exactly this one and deletes the other seventeen.
      koffiTriplet =
        let
          platform =
            if host.isLinux then
              "linux"
            else if host.isDarwin then
              "darwin"
            else
              null;
          arch =
            if host.isAarch64 then
              "arm64"
            else if host.isx86_64 then
              "x64"
            else
              null;
        in
        if platform == null || arch == null then
          throw "clawd-on-desk: koffi has no prebuilt addon for ${host.system}"
        else
          "${platform}_${arch}";

      # Where the application tree goes. Upstream's electron-builder release
      # keeps it in resources/app.asar (an archive) with the native addons and
      # the hook scripts in resources/app.asar.unpacked beside it; this package
      # ships no archive, so the whole application is the unpacked directory.
      #
      # The name is load-bearing: `hooks/auto-start.js` — the SessionStart hook
      # the app registers with the coding agents, which starts the pet when one
      # of them starts — decides whether it runs from a release or from a source
      # checkout by looking for "app.asar" in its own directory name, and the
      # release branch is the one that spawns <install>/clawd-on-desk instead of
      # `require("electron")` out of a node_modules this package does not have.
      installDir = "$out/share/${pname}";
      appDir = "${installDir}/resources/app.asar.unpacked";

      # The NixOS-wide "Electron applications, use Wayland" switch is set by this
      # repository's desktop aspect (modules/apps/gnome/default.nix). The app
      # has a switch of its own with the same meaning: on a Wayland session with
      # an X server present it relaunches itself under XWayland
      # (--ozone-platform=x11), which is what makes the pet draggable, while
      # CLAWD_OZONE_PLATFORM=wayland keeps it on Chromium's own Ozone default.
      # This translates the session variable into the app's, and leaves an
      # explicit CLAWD_OZONE_PLATFORM alone, so that
      # `CLAWD_OZONE_PLATFORM=x11 clawd-on-desk` still overrides both.
      ozoneWayland = ''
        if [ -n "''${NIXOS_OZONE_WL:-}" ] && [ -n "''${WAYLAND_DISPLAY:-}" ] && [ -z "''${CLAWD_OZONE_PLATFORM:-}" ]; then
          export CLAWD_OZONE_PLATFORM=wayland
        fi
      '';
    in
    {
      packages.${pname} = buildNpmPackage (finalAttrs: {
        inherit pname version;

        src = fetchFromGitHub {
          owner = "rullerzhou-afk";
          repo = "clawd-on-desk";
          inherit rev;
          hash = "sha256-p/SaWXj/GLu9JbUAMwmWGglWpyjKZNM08DCW7o7k2to=";
        };

        npmDepsHash = "sha256-cvVGMqbrCJX4DtERHzhfEoo4AHofpHPujm0Ks5ZEPkc=";

        # The devDependencies are the packaging toolchain — electron,
        # electron-builder, @electron/asar — and the app runs on this
        # repository's Electron instead. `npm run build` is electron-builder,
        # which must not run here either.
        npmInstallFlags = [ "--omit=dev" ];
        dontNpmBuild = true;

        # Upstream's launcher (launch.js) spawns the Electron from the
        # `electron` npm package, which this package does not install; the
        # wrapper below is the launcher. Only the Linux "start at login" writer
        # still reaches for it, and it does so in a way that cannot work on
        # NixOS anyway: the autostart entry it writes runs `node launch.js`,
        # which needs a `node` on PATH (/usr/bin/node does not exist here) that
        # can resolve that package. The patch makes Linux write the same entry
        # the app already writes for macOS in this situation — the executable it
        # is running from, given the application directory as its argument.
        patches = [ ./clawd-on-desk-autostart.patch ];

        nativeBuildInputs = [
          copyDesktopItems
          makeWrapper
          patchelf
        ];

        desktopItems = [
          (makeDesktopItem {
            name = pname;
            desktopName = "Clawd on Desk";
            comment = "A pixel desktop pet that reacts to your AI coding agent in real time";
            exec = "${pname} %u";
            icon = pname;
            categories = [ "Utility" ];
            mimeTypes = [ "x-scheme-handler/clawd" ];
            # Electron takes the window class from the application name
            # (package.json "name"), which is what every window of this build
            # carries — the pet as "Clawd", the rest as "clawd-on-desk".
            startupWMClass = pname;
          })
        ];

        installPhase = ''
          runHook preInstall
          app="${appDir}"
          mkdir -p "$app/assets"

          cp package.json NOTICE.md LICENSE "$app/"
          cp -r src agents hooks extensions themes pwa "$app/"

          # Exactly what upstream's electron-builder `files` list ships: the
          # rest of assets/ is README material.
          cp assets/icon.png assets/dock-icon.png assets/tray-icon*.png "$app/assets/"
          cp -r assets/icons assets/svg assets/accessories assets/sounds "$app/assets/"

          cp -r node_modules "$app/node_modules"

          # Keep only the addon this host loads. node_modules is otherwise made
          # up of every platform's copy of it (26 MiB of 28 MiB).
          koffi="$app/node_modules/koffi/build/koffi"
          test -f "$koffi/${koffiTriplet}/koffi.node"
          find "$koffi" -mindepth 1 -maxdepth 1 -type d ! -name '${koffiTriplet}' -print0 | xargs -0 -r rm -r
          find "$koffi/${koffiTriplet}" -type f ! -name koffi.node -delete
          test "$(ls "$koffi/${koffiTriplet}")" = koffi.node

          # The addon needs libstdc++, which nothing else in the tree does:
          # Chromium and Electron link their own C++ runtime, and the loader
          # that resolves the addon's DT_NEEDED list is the dlopen() that pulls
          # it in, which consults this object's own RPATH and then the loader
          # cache — never the RPATH of the process that dlopen()ed it. Without
          # this the load fails with "libstdc++.so.6: cannot open shared object
          # file" and every koffi caller in the app degrades to its fallback:
          # on Linux that is the X11 input hint (src/linux-x11-input-hint.js,
          # issue #980) that keeps the pet's render window from taking focus.
          patchelf --set-rpath "${lib.makeLibraryPath [ stdenv.cc.cc.lib ]}" \
            "$koffi/${koffiTriplet}/koffi.node"

          install -Dm644 assets/icons/256x256.png \
            "$out/share/icons/hicolor/256x256/apps/${pname}.png"
          install -Dm644 assets/icons/512x512.png \
            "$out/share/icons/hicolor/512x512/apps/${pname}.png"

          # The launcher runs the Electron binary under its own name, with the
          # application directory as its argument — the layout `npm start`
          # uses. Electron takes that directory as the app: app.isPackaged
          # stays false, app.getAppPath() is the directory, and the app
          # resolves its own src/, agents/, hooks/, themes/ and assets/
          # relative to it, so every path it resolves is one contributors run.
          # The in-app updater short-circuits on !app.isPackaged, which is what
          # a Nix-managed installation wants, and the Linux start-at-login
          # writer is the one place that assumed a release (see the patch).
          makeWrapper ${lib.getExe electron_44} "$out/bin/${pname}" \
            --add-flags "$app" \
            --run ${lib.escapeShellArg ozoneWayland}

          # hooks/auto-start.js spawns the release layout's executable, three
          # directories above the hooks it runs from.
          makeWrapper ${lib.getExe electron_44} "${installDir}/${pname}" \
            --add-flags "$app" \
            --run ${lib.escapeShellArg ozoneWayland}

          runHook postInstall
        '';

        passthru.update = {
          kind = "rev";
          file = "modules/packages/clawd-on-desk/default.nix";
          repo = "rullerzhou-afk/clawd-on-desk";
          files = [
            "modules/packages/clawd-on-desk/default.nix"
            "modules/packages/clawd-on-desk/clawd-on-desk-autostart.patch"
          ];
        };

        meta = {
          description = "Pixel desktop pet that reacts to AI coding agents in real time";
          homepage = "https://github.com/rullerzhou-afk/clawd-on-desk";
          # The source is AGPL-3.0, the bundled artwork and theme assets are not.
          license = lib.licenses.agpl3Only;
          mainProgram = "clawd-on-desk";
          platforms = lib.platforms.linux ++ lib.platforms.darwin;
        };
      });
    };
}
