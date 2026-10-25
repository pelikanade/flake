# Copied from Mooling0602/nix-packages (pkgs/by-name/de/deepseek-harness-desktop)
# by Mooling0602: https://github.com/Mooling0602/nix-packages
#
# Why this is a separate package and not a second output of
# deepseek-harness-git: Nix builds every output of a derivation in one builder
# invocation. Measured on a probe derivation with outputs = [ "out" "desktop" ]
# whose desktop output referenced a unique throwaway dependency, `nix build
# ...out` printed "these 2 derivations will be built" and built that
# desktop-only dependency as well. A second output would therefore make every
# plain `nix build .#deepseek-harness-git` fetch a 360 MiB Electron and run the
# desktop installPhase. Keeping the two separate means CLI/Web users never touch
# Electron. (The two outputs' *runtime closures* are in fact independent; it is
# the build cost, not closure size, that forces the split.)
#
#  1. The Electron binary must NOT be named 'electron'. Electron treats an
#     executable by that name as "the default app" and reports
#     app.isPackaged === false, which sends main.ts down its development branch.
#
#  2. The bundled runtime lives at resources/app/dsh, not resources/dsh.
#     runtimeResources() (apps/desktop/src/main.ts) resolves the packaged path as
#     join(app.getAppPath(), 'dsh'), and upstream's electron-builder config packs
#     'dsh' *inside* the asar ({ from: dsh, to: 'dsh' }). This package ships no
#     asar, so app.getAppPath() is resources/app and the runtime sits beneath it.
#     With the runtime anywhere else the binary still starts, then dies later on
#     a missing desktop-runtime.json.
#
#  3. desktop-runtime.json is only partly validated at launch, which is why this
#     package checks it at build time instead. The reader the shipped shell runs
#     (readDesktopRuntime, inlined into lib/main.js) hard-fails unless both
#     @deepseek-ai/dsh and @deepseek-ai/dsh-desktop-host appear in sharedPackages
#     carrying exactly release.version, and unless release.nodeVersion and
#     release.pnpmVersion are semver strings. It does NOT compare
#     release.hostProtocolVersion, and it treats the 'files' inventory as
#     structural only: the byte-level integrity sweep and the protocol-generation
#     comparison both live in verifyDesktopRuntime, which upstream runs while
#     packaging and which never runs at launch. So an empty 'files' array is
#     legal (the store hash is a stronger guarantee), the protocol field is
#     informational at runtime, and a stale protocol or Node version would be
#     accepted silently. Both are therefore derived at build time (see 3a in the
#     install phase) rather than written down here.
#
#  4. Three environment details are load-bearing; the wrapper sets all three.
#     CHROME_DEVEL_SANDBOX points Chromium at its setuid sandbox helper, exactly
#     as nixpkgs' own electron wrapper does. Without it the process dies on
#     SIGILL before printing anything, and the only alternative is --no-sandbox,
#     which disables the sandbox outright. LD_LIBRARY_PATH must carry libstdc++,
#     because N-API addons are dlopen()ed out of a per-user cache directory
#     (node-addon-native-custom-loader copies them out of the store first), so
#     they do not inherit the Electron binary's RPATH; without it the Host aborts
#     with "No usable native binding found for
#     node-addon-require-builtin-linux-x64-gnu". It also carries the substituted
#     libvips directory, first, which note 5 explains.
#
#     PATH additionally carries bubblewrap, because dsh's own platform sandbox
#     probes for it first on Linux (chain: bwrap, then landlock) and refuses to
#     run a command unconfined when neither backend is usable. The landlock
#     launcher's optional platform package is not materialized by the offline
#     pnpm install, so without bwrap every workspace-write command fails with
#     SANDBOX_UNAVAILABLE and the desktop app can only ask for escalation.
#     Electron's chrome-sandbox is unrelated: it confines renderers, not the
#     commands the model runs.
#
#  5. sharp's native addon cannot run the libvips it ships with, so the package
#     substitutes a dynamically linked one. The addon
#     (node_modules/.pnpm/@img+sharp-linux-x64@*/.../sharp-linux-x64-<v>.node)
#     requires a prebuilt libvips-cpp.so.8.18.3 that statically embeds its own
#     glib: it exports ~1800 g_* symbols and has no libglib-2.0.so.0 in its
#     DT_NEEDED. Electron on Linux links a dynamically linked glib, and the
#     addon's own seven glib references (g_object_ref, g_object_unref,
#     g_signal_connect_data, g_malloc, g_free, g_log_set_handler,
#     g_utf8_validate) resolve out of the global scope, where Electron's
#     already-loaded copy is found before the libvips the addon's DT_NEEDED
#     names. So the addon calls Electron's glib on GObjects that the embedded
#     glib created, and the first raster operation dies with SIGSEGV. That is the
#     failure the desktop writes to
#     ~/.config/@deepseek-ai/dsh-desktop/logs/crash-<time>-host.log as "dsh
#     desktop host stopped", with only sharp's own [SharpElectronLinux] warning
#     on the captured stderr. Reproduced in isolation: a 4x4
#     sharp({ create }).png().toBuffer() under ELECTRON_RUN_AS_NODE=1
#     ./deepseek-harness exits 139, and preloading glib into a plain Node 24.20.0
#     makes the same pipeline exit 139 there too, while Node 24.20.0 alone exits
#     0. LD_DEBUG=bindings names the wrong library on the addon's g_object_ref
#     and g_object_unref bindings; sharp documents the same conflict under
#     "Electron and Linux" (https://sharp.pixelplumbing.com/install) and tracks
#     it upstream as electron#46323.
_: {
  perSystem =
    {
      pkgs,
      pkgsUnstable,
      self',
      ...
    }:
    let
      inherit (pkgsUnstable)
        applyPatches
        bubblewrap
        copyDesktopItems
        electron_44
        glib
        gsettings-desktop-schemas
        gtk3
        lib
        makeDesktopItem
        makeWrapper
        nodejs_24
        patchelf
        python312
        stdenv
        stdenvNoCC
        ;

      vips = lib.getLib pkgs.vips;

      dsh = self'.packages.deepseek-harness-git;

      versionData = lib.importJSON ../deepseek-harness-git/hashes.json;
      inherit (versionData) version pnpmVersion;

      outPath = "${dsh}/lib/deepseek-harness-git";

      nodeRuntimeVersion = nodejs_24.version;

      pythonEnv = python312.withPackages (
        ps: with ps; [
          numpy
          pandas
          python-dateutil
          six
          tzdata
          python-docx
          python-pptx
          openpyxl
          pillow
          lxml
          xlsxwriter
          typing-extensions
          et-xmlfile
        ]
      );

      # Names and versions must satisfy isDistributionMap() in
      # tool-workspace-dependencies: names ^[A-Za-z0-9][A-Za-z0-9._-]*$ and versions
      # ^[0-9][\w.!+-]*$. Read from the very packages linked below, so the manifest
      # cannot drift from the payload.
      pythonPackages = {
        numpy = python312.pkgs.numpy.version;
        pandas = python312.pkgs.pandas.version;
        python-dateutil = python312.pkgs.python-dateutil.version;
        six = python312.pkgs.six.version;
        tzdata = python312.pkgs.tzdata.version;
        python-docx = python312.pkgs.python-docx.version;
        python-pptx = python312.pkgs.python-pptx.version;
        openpyxl = python312.pkgs.openpyxl.version;
        Pillow = python312.pkgs.pillow.version;
        lxml = python312.pkgs.lxml.version;
        XlsxWriter = python312.pkgs.xlsxwriter.version;
        typing_extensions = python312.pkgs.typing-extensions.version;
        et_xmlfile = python312.pkgs.et-xmlfile.version;
      };

      appModules = [
        "semver"
        "ws"
        "electron-updater"
        "koffi"
        "sharp"
        "js-yaml"
        "extract-zip"
        "react"
        "react-dom"
        "cos-nodejs-sdk-v5"
        "@deepseek-ai/cordis"
        "@deepseek-ai/dsh-api-gateway"
        "@deepseek-ai/dsh-app-boot"
        "@deepseek-ai/dsh-atomic-write"
        "@deepseek-ai/dsh-client-shortcuts"
        "@deepseek-ai/dsh-client-ui-primitives"
        "@deepseek-ai/dsh-client-ui-settings-general"
        "@deepseek-ai/dsh-client-ui-sidebar-browser"
        "@deepseek-ai/dsh-client-ui-theme"
        "@deepseek-ai/dsh-deepseek-account"
        "@deepseek-ai/dsh-home-paths"
        "@deepseek-ai/node-addon-system"
      ];

      hostDependencies = [
        "@deepseek-ai/cordis"
        "@deepseek-ai/dsh-agent"
        "@deepseek-ai/dsh-app-boot"
        "@deepseek-ai/dsh-client-connection"
        "@deepseek-ai/dsh-deepseek-account"
        "@deepseek-ai/dsh-home-paths"
        "@deepseek-ai/dsh-host-webserver"
        "@deepseek-ai/dsh-jobs"
        "@deepseek-ai/dsh-schedule"
        "@deepseek-ai/dsh-skill-office"
        "@deepseek-ai/dsh-tool-workspace-dependencies"
        "@deepseek-ai/dsh-workspace"
        "@deepseek-ai/libreoffice-kit"
        "koffi"
      ];

      dshRuntimeTree = stdenvNoCC.mkDerivation {
        pname = "deepseek-harness-desktop-runtime";
        inherit version;
        dontUnpack = true;
        dontConfigure = true;
        dontBuild = true;
        dontFixup = true;
        installPhase = ''
          runHook preInstall
          mkdir -p "$out/node_modules/@deepseek-ai"
          ln -s ${outPath}/apps/cli          "$out/node_modules/@deepseek-ai/dsh"
          ln -s ${outPath}/apps/web          "$out/node_modules/@deepseek-ai/dsh-web-frontend"
          ln -s ${outPath}/apps/desktop-host "$out/node_modules/@deepseek-ai/dsh-desktop-host"
          for name in ${lib.concatStringsSep " " hostDependencies}; do
            mkdir -p "$out/node_modules/$(dirname "$name")"
            ln -s "${outPath}/apps/desktop-host/node_modules/$name" "$out/node_modules/$name"
          done
          cat > "$out/package.json" <<'JSON'
          {
            "name": "@deepseek-ai/dsh-desktop-runtime",
            "private": true,
            "version": "${version}",
            "type": "module"
          }
          JSON
          runHook postInstall
        '';
      };

      appModulesTree = stdenvNoCC.mkDerivation {
        pname = "deepseek-harness-desktop-app-modules";
        inherit version;
        dontUnpack = true;
        dontConfigure = true;
        dontBuild = true;
        dontFixup = true;
        installPhase = ''
          runHook preInstall
          mkdir -p "$out"
          for name in ${lib.concatStringsSep " " appModules}; do
            mkdir -p "$out/$(dirname "$name")"
            ln -s "${outPath}/apps/desktop/node_modules/$name" "$out/$name"
          done
          runHook postInstall
        '';
      };
      sharpLibvips = stdenvNoCC.mkDerivation {
        pname = "deepseek-harness-desktop-sharp-libvips";
        inherit version;
        dontUnpack = true;
        dontConfigure = true;
        dontBuild = true;
        dontFixup = true;
        nativeBuildInputs = [ patchelf ];
        installPhase = ''
          runHook preInstall
          addon="$(ls ${outPath}/node_modules/.pnpm/@img+sharp-linux-x64@*/node_modules/@img/sharp-linux-x64/lib/sharp-linux-x64-*.node)"
          soname="$(patchelf --print-needed "$addon" | grep -E '^libvips-cpp[.]so[.]' || true)"
          if [ -z "$soname" ] || [ "$(printf '%s\n' "$soname" | wc -l)" -ne 1 ]; then
            echo "desktop: expected one libvips-cpp DT_NEEDED entry in $addon, got: $soname" >&2
            exit 1
          fi
          # The name is the addon's own, so it is honoured as written below; only
          # its major.minor series has to match nixpkgs' vips (note 5): libvips
          # keeps ABI within a stable series, and the patch field is a libtool
          # revision, which carries no interface change.
          addon_series="''${soname#libvips-cpp.so.}"
          addon_series="''${addon_series%.*}"
          vips_series="${lib.versions.majorMinor vips.version}"
          if [ "$addon_series" != "$vips_series" ]; then
            echo "desktop: sharp's addon requires $soname (series $addon_series), but this package links vips ${vips.version} (series $vips_series)" >&2
            echo "desktop: the substitute must be from the same upstream stable series as the libvips that prebuilt addon was linked against; move vips to the addon's series in default.nix, then re-run this build and its sharp probe (note 5)" >&2
            exit 1
          fi
          # The real file, not the unversioned symlink, so the loader reports the
          # versioned name in its trace and the build check below stays exact.
          set -- $(find ${vips}/lib -maxdepth 1 -type f -name 'libvips-cpp.so.*')
          if [ "$#" -ne 1 ]; then
            echo "desktop: expected one libvips-cpp.so.* in ${vips}/lib, found $#" >&2
            exit 1
          fi
          mkdir -p "$out/lib"
          ln -s "$1" "$out/lib/$soname"
          test -e "$out/lib/$soname"
          runHook postInstall
        '';
      };

      electron = electron_44;
      nodejs = nodejs_24;
      python = pythonEnv;
      pythonVersion = python312.version;
      coverageScript = ./desktop-coverage.mjs;
      descriptorScript = ./desktop-runtime-json.mjs;
      hostManifest = "${outPath}/apps/desktop-host/package.json";
      protocolSource = "${outPath}/apps/desktop/src/host-protocol.ts";
      appRoot = "${outPath}/apps/desktop";
      pnpmRoot = "${outPath}/node_modules/pnpm";
      skillOfficeAssets = "${outPath}/packages/skill/skill-office/assets";

      # The desktop shell's lib tree with this package's one source change applied
      # (note 6). applyPatches is the standard patch phase over a tree this
      # derivation does not unpack itself: it copies the tree, runs patchPhase
      # with `patches`, and installs the result, so the hunk is applied by the
      # same machinery as any nixpkgs `patches = [...]`, with its -p1 default and
      # a failed build when the context no longer matches. Its output holds the
      # tree's contents at the root, which is why hide-menu-bar.patch names
      # main.js rather than lib/main.js.
      appLib = applyPatches {
        name = "deepseek-harness-desktop-lib";
        src = "${appRoot}/lib";
        patches = [ ./hide-menu-bar.patch ];
      };

      # nixpkgs's Electron ships its payload under libexec/electron.
      electronDir = "${electron.unwrapped}/libexec/electron";

      # wrapGAppsHook3 only auto-wraps $out/bin and this binary is not there, so the
      # hook's two variables are spelled out by hand. They are kept as plain values
      # rather than a list of pre-joined "--prefix ..." strings: makeWrapper needs
      # each flag as its own argument, and passing a list through
      # lib.escapeShellArgs would quote a whole flag into a single argument, which it
      # rejects with "makeWrapper doesn't understand the arg --prefix ...".
      xdgDataDirs = lib.concatStringsSep ":" [
        "${gsettings-desktop-schemas}/share"
        "${gtk3}/share/gsettings-schemas/${gtk3.name}"
        "${glib}/share"
      ];
      gsettingsSchemasPath = "${gsettings-desktop-schemas}/share/gsettings-schemas/${gsettings-desktop-schemas.name}";

      # libstdc++ must be on LD_LIBRARY_PATH (see note 4): the Node-API addon is
      # dlopen()ed out of a per-user cache directory, so it does not inherit the
      # Electron binary's RPATH. sharpLibvips comes first so that the addon finds
      # the substituted libvips before its own DT_RUNPATH does (see note 5).
      runtimeLibraryPath = lib.concatStringsSep ":" [
        "${sharpLibvips}/lib"
        (lib.makeLibraryPath [
          glib
          gtk3
          stdenv.cc.cc.lib
        ])
      ];

      pythonMajorMinor = lib.versions.majorMinor pythonVersion;
      pythonSitePackages = "${python}/lib/python${pythonMajorMinor}/site-packages";

      descriptorTemplate = builtins.toFile "desktop-runtime-template.json" (
        builtins.toJSON {
          schemaVersion = 1;
          release = {
            schemaVersion = 1;
            inherit version pnpmVersion;
          };
          platform = "linux";
          arch = if stdenvNoCC.hostPlatform.isAarch64 then "arm64" else "x64";
          sharedPackages = [
            {
              name = "@deepseek-ai/dsh";
              inherit version;
              path = "node_modules/@deepseek-ai/dsh";
            }
            {
              name = "@deepseek-ai/dsh-desktop-host";
              inherit version;
              path = "node_modules/@deepseek-ai/dsh-desktop-host";
            }
          ];
          files = [ ];
        }
      );

      # parsePrimaryRuntime() validates this. workspaceDependencyPaths() then derives
      # the site-packages location from `python`, so that value must be the real one.
      runtimeManifest = builtins.toJSON {
        desktopVersion = version;
        platform = "linux";
        arch = if stdenvNoCC.hostPlatform.isAarch64 then "arm64" else "x64";
        python = pythonVersion;
        node = nodeRuntimeVersion;
        pnpm = pnpmVersion;
        inherit pythonPackages;
      };

      nodeVersionProbe = stdenvNoCC.mkDerivation {
        pname = "deepseek-harness-desktop-node-version";
        inherit version;
        dontUnpack = true;
        dontConfigure = true;
        dontBuild = true;
        dontFixup = true;
        installPhase = ''
          runHook preInstall
          reported="$(${nodejs}/bin/node -p 'process.versions.node')"
          if [ "$reported" != "${nodeRuntimeVersion}" ]; then
            echo "desktop: runtime.json declares Node ${nodeRuntimeVersion} but ${nodejs}/bin/node reports $reported" >&2
            exit 1
          fi
          printf '%s' "$reported" > "$out"
          runHook postInstall
        '';
      };
    in
    {
      packages.deepseek-harness-desktop = stdenvNoCC.mkDerivation {
        pname = "deepseek-harness-desktop";
        inherit version;

        dontUnpack = true;
        dontConfigure = true;
        dontBuild = true;
        dontFixup = true;

        nativeBuildInputs = [
          makeWrapper
          copyDesktopItems
        ];

        desktopItems = [
          (makeDesktopItem {
            name = "deepseek-harness";
            desktopName = "DeepSeek Harness";
            comment = "Open-source agent harness developed by DeepSeek AI";
            exec = "deepseek-harness %u";
            icon = "deepseek-harness";
            categories = [ "Development" ];
            startupWMClass = "DeepSeek Harness";
            mimeTypes = [ "x-scheme-handler/dsh" ];
          })
        ];

        installPhase = ''
          runHook preInstall
          # 1. The Electron distribution. A real copy, not a symlink: resourcesPath is
          #    derived from the realpath of the executable, so a symlinked binary would
          #    resolve back into the store and resources/app would never be found.
          mkdir -p "$out"
          cp -a ${electronDir}/. "$out/"
          chmod -R u+w "$out"
          mv "$out/electron" "$out/deepseek-harness"        # see note 1
          chmod +x "$out/deepseek-harness"

          # The bundled Electron reports the Node version this release ships. It is read
          # here, before the application tree exists, so the probe sees the bare Electron
          # distribution: with resources/app present the binary would find an application
          # to run. ELECTRON_RUN_AS_NODE makes it behave as plain Node, which is how
          # upstream's prepare-runtime.ts reads the same value.
          if ! node_version="$(ELECTRON_RUN_AS_NODE=1 "$out/deepseek-harness" -p 'process.versions.node' 2>&1)"; then
            echo "desktop: the bundled Electron failed to report process.versions.node: $node_version" >&2
            exit 1
          fi
          if [ -z "$node_version" ]; then
            echo "desktop: the bundled Electron reported an empty process.versions.node" >&2
            exit 1
          fi

          resources="$out/resources"
          rm -f "$resources/default_app.asar"

          app="$resources/app"
          mkdir -p "$app/lib"
          cp -a ${appLib}/. "$app/lib/"
          cp -a ${appRoot}/renderer "$app/renderer"
          cp -a ${appRoot}/resources "$app/resources"
          cp ${appRoot}/package.json "$app/package.json"
          chmod -R u+w "$app"
          find "$app/lib" -name '*.tsbuildinfo' -delete
          cp -a ${appModulesTree} "$app/node_modules"

          # 3. The bundled dsh runtime, inside the app directory (see note 2), plus the
          #    descriptor readDesktopRuntime() validates before the Host is started.
          #    cp -a preserves the store's read-only modes, so the tree is made writable
          #    before the descriptor is added to it.
          cp -a ${dshRuntimeTree} "$app/dsh"
          chmod -R u+w "$app/dsh"

          # 3a. The two release facts that describe this tree are read out of it rather
          #     than restated in default.nix, so an upstream bump cannot leave them
          #     stale. The shell type-checks both without comparing either, so a stale
          #     copy would be accepted silently at launch.
          #
          #     nodeVersion: what the bundled Electron reports as process.versions.node.
          #     ELECTRON_RUN_AS_NODE makes the renamed binary run as plain Node, which is
          #     how upstream's prepare-runtime.ts obtains it too.
          #
          #     hostProtocolVersion: the lifecycle generation upstream compiles into its
          #     release metadata. Read from apps/desktop/src/host-protocol.ts, which is
          #     the declaration of record. electron-builder never ships lib/types -- its
          #     `files` list is lib/main.js, the five preloads, lib/welcome, renderer and
          #     package.json -- and the shipped main.js inlines readDesktopRuntime without
          #     comparing this field. The check that used to be here read
          #     lib/types/host-protocol.js, a file that is copied but never loaded.
          host_protocol_version="$(sed -n 's/.*DESKTOP_HOST_PROTOCOL_VERSION = \([0-9][0-9]*\).*/\1/p' ${protocolSource} | head -n 1)"
          if [ -z "$host_protocol_version" ]; then
            echo "desktop: no DESKTOP_HOST_PROTOCOL_VERSION in ${protocolSource}" >&2
            exit 1
          fi
          # Verify the Node the primary runtime links and declares (see nodeVersionProbe).
          # The value is unused below beyond this check, but reading it here makes the
          # probe a build dependency of the output rather than a detached derivation.
          # `cat`, not `read`: the probe writes no trailing newline, and `read` returns
          # non-zero at a premature EOF, which under `set -e` would abort silently.
          node_runtime_version="$(cat ${nodeVersionProbe})"
          if [ -z "$node_runtime_version" ]; then
            echo "desktop: the primary-runtime Node version probe produced nothing" >&2
            exit 1
          fi
          cp ${descriptorTemplate} "$app/dsh/desktop-runtime.json"
          chmod u+w "$app/dsh/desktop-runtime.json"
          ${nodejs}/bin/node ${descriptorScript} \
            "$app/dsh/desktop-runtime.json" "$app/dsh/desktop-runtime.json" \
            "$host_protocol_version" "$node_version"

          # 3b. The descriptor still has to satisfy the reader that actually ships.
          #     lib/main.js is ESM loaded by Electron, so it cannot be imported here;
          #     instead the invariants whose failure would surface at launch are checked
          #     directly: both shared packages must carry release.version at a path that
          #     exists, and every release field the reader requires must be present.
          ${nodejs}/bin/node -e '
            const { readFileSync, existsSync } = require("node:fs");
            const { join } = require("node:path");
            // The descriptor sits at the runtime root, and every path it records is
            // relative to that same root ($app/dsh), not to the application directory.
            const root = process.argv[1];
            const d = JSON.parse(readFileSync(join(root, "desktop-runtime.json"), "utf8"));
            for (const name of ["@deepseek-ai/dsh", "@deepseek-ai/dsh-desktop-host"]) {
              const e = d.sharedPackages.find(p => p.name === name);
              if (!e || e.version !== d.release.version) { console.error("desktop: descriptor has no " + name + " at " + d.release.version); process.exit(1); }
              if (!existsSync(join(root, e.path, "package.json"))) { console.error("desktop: descriptor path " + e.path + " is missing"); process.exit(1); }
            }
            for (const f of ["nodeVersion", "pnpmVersion", "hostProtocolVersion"]) {
              if (d.release[f] === undefined) { console.error("desktop: descriptor lacks release." + f); process.exit(1); }
            }
          ' "$app/dsh"

          # 3c. Both explicit module lists above are checked against upstream
          #     rather than trusted. A package upstream adds to either manifest and this
          #     file does not list fails at launch with ERR_MODULE_NOT_FOUND today; here
          #     it fails the build and names the package.
          ${nodejs}/bin/node ${coverageScript} app "$app"
          ${nodejs}/bin/node ${coverageScript} host "$app/dsh" ${hostManifest}

          cp ${appRoot}/resources/icon.png "$resources/icon.png"

          mkdir -p "$resources/runtime/bin"
          # skill-office refuses to load in a packaged app without a standalone Node.
          cp ${appRoot}/scripts/node-bin/node "$resources/runtime/bin/node"
          chmod +x "$resources/runtime/bin/node"
          cp -a ${pnpmRoot}/. "$resources/runtime/pnpm/"
          cp -a ${skillOfficeAssets} "$resources/runtime/office-skills"

          # primary-runtime: the interpreters and libraries behind the
          # load_workspace_dependencies tool. validatePayloadEntries() requires the
          # python file, the node file and the site-packages directory to exist.
          pr="$resources/runtime/primary-runtime"
          mkdir -p "$pr/dependencies/node/bin" "$pr/dependencies/node/node_modules"
          mkdir -p "$pr/dependencies/python/bin"
          mkdir -p "$pr/dependencies/python/lib/python${pythonMajorMinor}"
          ln -s ${nodejs}/bin/node "$pr/dependencies/node/bin/node"
          ln -s ${python}/bin/python3 "$pr/dependencies/python/bin/python3"
          cp -a ${pythonSitePackages} \
            "$pr/dependencies/python/lib/python${pythonMajorMinor}/site-packages"
          cp ${builtins.toFile "runtime.json" runtimeManifest} "$pr/runtime.json"

          install -Dm644 ${appRoot}/resources/icon.png \
            "$out/share/icons/hicolor/512x512/apps/deepseek-harness.png"

          makeWrapper "$out/deepseek-harness" "$out/bin/deepseek-harness" \
            --set CHROME_DEVEL_SANDBOX "$out/chrome-sandbox" \
            --prefix LD_LIBRARY_PATH : "${runtimeLibraryPath}" \
            --prefix PATH : "${
              lib.makeBinPath [
                nodejs
                bubblewrap
              ]
            }" \
            --prefix XDG_DATA_DIRS : "${xdgDataDirs}" \
            --prefix GSETTINGS_SCHEMAS_PATH : "${gsettingsSchemasPath}"

          runHook postInstall
        '';

        meta = {
          description = "Electron desktop shell for DeepSeek Harness";
          homepage = "https://github.com/deepseek-ai/deepseek-harness";
          license = lib.licenses.mit;
          sourceProvenance = [ lib.sourceTypes.binaryBytecode ];
          platforms = [ "x86_64-linux" ];
          mainProgram = "deepseek-harness";
        };
      };
    };
}
