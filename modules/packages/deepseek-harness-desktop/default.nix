# Standalone Nix package for the DeepSeek Harness desktop application.
#
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
# Only the desktop assembly is new here; this file documents the on-disk layout
# and the five load-bearing details, each verified against the unmodified
# upstream application. Note 6 is this package's one deliberate deviation from
# that application.
# Desktop assembly notes.
#
# Layout, relative to the output root:
#
#   deepseek-harness                            the Electron binary
#   resources/app/                              app.getAppPath()
#   resources/app/dsh/                          the bundled dsh runtime
#   resources/app/dsh/desktop-runtime.json      runtime descriptor
#   resources/runtime/office-skills/            boot-required skill assets
#   resources/runtime/bin/node                  standalone Node for skill-office
#   resources/runtime/pnpm/                     pnpm CLI
#   resources/runtime/primary-runtime/          interpreters + Python libraries
#   resources/icon.png                          window/taskbar icon
#
# Five details are load-bearing; each was verified experimentally against the
# unmodified upstream application.
#
#  1. The Electron binary must NOT be named 'electron'. Electron treats an
#     executable by that name as "the default app" and reports
#     app.isPackaged === false, which sends main.ts down its development branch.
#     Verified on identical trees: renamed -> isPackaged true, untouched -> false.
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
#
#     sharpLibvips therefore supplies the one thing the addon is missing: a
#     dynamically linked libvips of the same upstream version, reachable under
#     the addon's own DT_NEEDED name. The addon resolves libvips through
#     DT_RUNPATH (verified with readelf -d, not DT_RPATH), and LD_LIBRARY_PATH is
#     searched first, so exporting that directory is enough to make the addon
#     load it instead of the prebuilt library. It links glib dynamically, and the
#     loader resolves libglib-2.0.so.0 to the copy Electron already loaded, which
#     leaves one glib and one GObject type system in the process. The wrapper
#     prepends the directory to LD_LIBRARY_PATH.
#
#     The addon's DT_NEEDED fixes the name this package has to provide, nothing
#     about the library behind it, so the substitute is the vips this package
#     already links, from the stable input. That is safe because libvips keeps ABI
#     within a stable series and says so in its soname: the ABI name is
#     libvips-cpp.so.42 and the upstream patch version is the last field of the
#     versioned file (42.20.3 for 8.18.3, against 42.20.7 for the 8.18.7 that the
#     sharp 0.35.5 addon names), i.e. a libtool revision change, which by
#     definition carries no interface change -- abidiff on those two builds
#     reports none. sharpLibvips therefore reads that name from the addon with
#     patchelf and refuses any other major.minor series, so a sharp or vips bump
#     to a new series breaks the build in a place that names both versions
#     instead of segfaulting the app, while a patch bump inside the series costs
#     nothing and does not move this package to a second, unstable-based vips
#     closure. The prebuilt libvips stays in the tree, unreferenced, because it is
#     part of the shared source package.
#
#  6. The window menu bar is not drawn. This is the one deliberate deviation
#     from upstream, and it changes drawing only: the application menu stays
#     installed. Linux draws that menu as a native bar across the top of every
#     window -- the localized "Application / Edit" strip. The bar carries About,
#     Check for Updates and Quit, and the Edit menu's roles; the roles have their
#     usual mouse equivalents and Quit is also on the window controls, so the
#     pointer paths it costs are About and the manual update check (scheduled
#     checks are unaffected). Removing the menu instead would cost more than the
#     bar: the Edit roles, the Quit role's Ctrl+Q and a hidden F12 devtools toggle
#     all come from that one template, and keyboard.ts toggles
#     setIgnoreMenuShortcuts against a menu it expects to exist.
#     hide-menu-bar.patch therefore wraps the bundled refreshApplicationMenu
#     instead: it hides each window's bar for the windows that exist each time
#     the menu is (re)built, and, through one 'browser-window-created' hook, for
#     every window created afterwards. The menu and each window's visibility flag
#     are main-process state, so the renderer and the Host observe nothing else.
#     The hunk is applied by appLib above with the standard patch phase (the
#     `patches` mechanism), not by hand, so it carries that mechanism's -p1
#     convention and its failure mode: an upstream restructuring that breaks the
#     context stops the build instead of silently reinstating the bar. Verified by
#     screenshotting the built package under Xvfb with an isolated home: the
#     unmodified build draws the bar on its welcome window and this assembly does
#     not, while F12 still toggles devtools in both, so the menu itself survived.
{ inputs, ... }:
{
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

      # The libvips that replaces sharp's prebuilt one (note 5). Taken from the
      # stable input: the addon's DT_NEEDED pins a soname, not a version, and
      # sharpLibvips below accepts any release of that soname's own major.minor
      # series, so this stays the one vips this package links. pkgs.vips' own
      # default output is bin, so read the out output, which is where
      # libvips-cpp lives.
      vips = lib.getLib pkgs.vips;

      dsh = self'.packages.deepseek-harness-git;

      # Read from the source package's own pin file: importing a manifest out of
      # dsh's store path would be an import-from-derivation and would also require
      # that package to be built just to evaluate this one.
      versionData = lib.importJSON ../deepseek-harness-git/hashes.json;
      inherit (versionData) version pnpmVersion;

      # deepseek-harness-git installs the repository tree under $out/lib/<pname>,
      # not at the store root (see its installPhase).
      outPath = "${dsh}/lib/deepseek-harness-git";

      # release.nodeVersion and release.hostProtocolVersion are deliberately not
      # written down here. Both describe the tree the build assembles -- what the
      # bundled Electron reports, and the protocol generation in upstream's
      # apps/desktop/src/host-protocol.ts -- so the assembly reads them out of that
      # tree. A literal would go stale on an upstream or nixpkgs bump, and the
      # shipped shell accepts both fields without comparing either, so the drift
      # would not show up as a launch failure.
      #
      # This one is different: it is the standalone Node the primary runtime links,
      # and parsePrimaryRuntime() records it as the payload's version. Taking it from
      # the package being linked keeps the claim true when nixpkgs bumps Node.
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

      # Host direct dependencies, resolved by bare name at startup, named as
      # upstream's own manifest names them: the workspace packages under the
      # @deepseek-ai scope, plus libreoffice-kit and koffi, which come from the
      # registry. Linked rather than copied: pnpm's layout is a web of relative
      # symlinks, so copying only this subtree would leave them dangling.
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

      # resources/app/dsh: the bundled runtime. Links point at the shared store tree;
      # each target's own relative links still resolve, because they are followed
      # from the target's real location.
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
      # The libvips the sharp addon will actually load, under the name the addon
      # asks for. See note 5: the addon's DT_NEEDED is read out of the addon
      # rather than restated here, so a sharp bump that moves to a new libvips
      # fails this build instead of segfaulting the app at run time, and it is
      # checked against the pinned vips' own version for the same reason.
      #
      # A symlink, not a copy: the addon only needs the soname it names to be
      # findable on LD_LIBRARY_PATH, and the loader then maps the real library
      # with the substituted build's own RUNPATH intact.
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

      # The template descriptorScript fills in. See note 3 for what the reader
      # checks. release.nodeVersion and release.hostProtocolVersion are omitted on
      # purpose: both describe the tree this build assembles, so the install phase
      # reads them out of that tree and passes them to the script.
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

      # nodeRuntimeVersion is the Node package's own version, which nixpkgs derives
      # from the release it packages. parsePrimaryRuntime() trusts this manifest when
      # the workspace-dependencies tool runs, so the claim is checked against the
      # binary that is actually linked; a mismatch fails the build, not the tool call.
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
