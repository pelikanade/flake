{ inputs, ... }:
{
  flake-file.inputs.importPnpmLock = {
    url = "git+https://tangled.org/scrumplex.net/importPnpmLock.nix?rev=4bd9cc54e6a5431930b4d09898e1ef49cb2ed241";
    inputs = {
      nixpkgs.follows = "nixpkgs";
      systems.follows = "systems";
    };
  };

  perSystem =
    {
      pkgs,
      pkgsUnstable,
      self',
      ...
    }:
    let
      pnpmPkgs = pkgsUnstable.extend inputs.importPnpmLock.overlays.default;
      inherit (pnpmPkgs) iplConfigHook importPnpmLock;
      inherit (pkgsUnstable)
        autoPatchelfHook
        bashInteractive
        copyDesktopItems
        electron_42
        fetchFromGitHub
        fetchurl
        git
        lib
        libGL
        makeDesktopItem
        makeWrapper
        node-gyp
        nodejs_24
        patchelf
        pciutils
        poppler-utils
        python3
        stdenv
        vulkan-loader
        wrapGAppsHook3
        xdg-utils
        ;

      # The dynamically linked libvips that replaces the one sharp's prebuilt
      # addon ships (see the substitution in installPhase). Taken from the stable
      # input rather than pkgsUnstable because 26.05 carries exactly the 8.18.3
      # that addon's DT_NEEDED names; the build fails when the two disagree.
      # pkgs.vips' default output is bin, so read the out output, where
      # libvips-cpp lives.
      vips = lib.getLib pkgs.vips;

      pname = "open-design";
      version = "0.25.0";
      rev = "de6d2c072a18dfef80ecad4a455b31f0d5aca090";
      pnpmVersion = "10.33.2";

      src = fetchFromGitHub {
        owner = "nexu-io";
        repo = "open-design";
        inherit rev;
        hash = "sha256-l7qTQ5XTKpuAw48zbRXp+T58XUIvq8MHDOzmus7Gnj0=";
      };

      # Upstream pins pnpm@10.33.2 in package.json#packageManager and keeps its
      # lockfile at that version, so run the exact pinned pnpm instead of the
      # one nixpkgs carries.
      pnpm' = stdenv.mkDerivation {
        pname = "pnpm-for-open-design";
        version = pnpmVersion;

        src = fetchurl {
          url = "https://registry.npmjs.org/pnpm/-/pnpm-${pnpmVersion}.tgz";
          hash = "sha256-envPE9f2zrOUbAOXg3PZm+n94cr8MAC9/tTE95EWdhA=";
        };

        nativeBuildInputs = [
          nodejs_24
          makeWrapper
        ];

        dontConfigure = true;
        dontBuild = true;
        dontFixup = true;

        installPhase = ''
          runHook preInstall
          mkdir -p "$out/lib/pnpm"
          cp -r . "$out/lib/pnpm/"
          makeWrapper "${nodejs_24}/bin/node" "$out/bin/pnpm" \
            --add-flags "$out/lib/pnpm/bin/pnpm.cjs"
          runHook postInstall
        '';
      };

      mitmCache = importPnpmLock {
        inherit pname version;
        lockFile = "${src}/pnpm-lock.yaml";
      };

      # The Vela CLI and the OpenCode companion its release pins. The daemon
      # spawns them for Cloud sign-in and every other AMR-backed call
      # (`apps/daemon/src/integrations/vela.ts` wraps `vela collab …`), and it
      # accepts a packaged installation only as that pair: `packagedBuiltInExecutable`
      # takes `$OD_RESOURCE_ROOT/bin/vela` when `bin/libexec/opencode/opencode`
      # sits beside it, and falls back to PATH otherwise. Upstream's packaging
      # step copies exactly these two into the resource root; the version tracks
      # the `@powerformer/vela-cli` optional dependency in
      # `tools/pack/package.json`, which upstream's `--require-vela-cli`
      # packaging validates the bundled binary against.
      velaVersion = "0.1.6";
      vela = stdenv.mkDerivation {
        pname = "vela-cli";
        version = velaVersion;

        src = fetchurl {
          url = "https://registry.npmjs.org/@powerformer/vela-cli-linux-x64/-/vela-cli-linux-x64-${velaVersion}.tgz";
          hash = "sha256-nfom7kK37dC8XoMzoeJT/4fN5twWbmPp739/8LaR6BE=";
        };

        # Both binaries are glibc-linked linux-x64 builds from the npm tarball;
        # stdenv's single-directory check picks the tarball's `package/` as the
        # source root.
        nativeBuildInputs = [ autoPatchelfHook ];
        buildInputs = [ stdenv.cc.cc.lib ];

        dontConfigure = true;
        dontBuild = true;

        installPhase = ''
          runHook preInstall
          install -Dm755 bin/vela "$out/bin/vela"
          cp -r bin/libexec "$out/bin/libexec"
          runHook postInstall
        '';

        # The OpenCode companion is a Bun standalone executable: the kernel maps
        # its embedded module graph from the `.bun` section at the virtual
        # address a compiled-in pointer names. `strip` rewrites that section
        # layout, the pointer no longer resolves, and the binary falls back to
        # Bun's own CLI — every agent spawn then exits 1 with
        # `error: Script not found "json"` (the daemon's
        # `run --format json` argv reaches Bun as a script name). Keep it out of
        # the fixup strip. `patchelf` and `--shrink-rpath` leave the payload
        # alone, so autoPatchelfHook stays enabled.
        stripExclude = [ "opencode" ];

        doInstallCheck = true;
        installCheckPhase = ''
          runHook preInstallCheck
          test "$("$out/bin/vela" --version)" = "${velaVersion}"
          if "$out/bin/libexec/opencode/opencode" --help 2>&1 \
              | grep -qF 'Bun is a fast JavaScript runtime'; then
            echo "vela-cli: the OpenCode companion fell back to the Bun CLI; its embedded payload was damaged" >&2
            exit 1
          fi
          runHook postInstallCheck
        '';
      };
    in
    {
      packages.open-design = stdenv.mkDerivation {
        inherit
          pname
          version
          src
          mitmCache
          ;

        nativeBuildInputs = [
          nodejs_24
          pnpm'
          iplConfigHook
          makeWrapper
          autoPatchelfHook
          node-gyp
          python3
        ];

        buildInputs = [
          stdenv.cc.cc.lib
        ];

        env = {
          CI = "true";
          NEXT_TELEMETRY_DISABLED = "1";
          npm_config_nodedir = "${nodejs_24}";
          npm_config_build_from_source = "true";
        };

        # The resource root carries the OpenCode companion from the vela
        # derivation; stripping that Bun standalone executable destroys the
        # embedded payload it resolves at startup (see vela's stripExclude).
        stripExclude = [ "opencode" ];

        # The daemon anchors scratch space for its design-system importers at the
        # workspace root, which upstream's container image makes writable. A
        # store path is not, so those importers write under the daemon data
        # directory instead — the same place every other runtime file lives.
        postPatch = ''
          substituteInPlace apps/daemon/src/routes/static-resource.ts \
            --replace-fail "path.join(PROJECT_ROOT, '.tmp')" "path.join(RUNTIME_DATA_DIR, 'tmp')"
        '';

        buildPhase = ''
          runHook preBuild

          # Next's in-process type check runs past V8's default old-space limit
          # for this build; the desktop package sets the same ceiling for the
          # same `@open-design/web` compile.
          NODE_OPTIONS=--max-old-space-size=4096 pnpm -r --if-present \
            --filter '@open-design/daemon...' \
            --filter '@open-design/web...' \
            --filter '@open-design/dsh-runtime...' \
            run build

          runHook postBuild
        '';

        installPhase = ''
          runHook preInstall

          root="$out/lib/${pname}"
          resources="$root/resources"
          mkdir -p "$root/apps/web" "$resources"

          cp -r apps/web/out "$root/apps/web/out"

          # Content the daemon reads through OD_RESOURCE_ROOT, in the packaged
          # layout its own packaging step builds (tools/pack/src/resources):
          # skills, design systems and templates, craft rules, prompt templates,
          # bundled plugins, the pets and frames the home surface serves, and the
          # plugin-preview manifest.
          for dir in skills design-templates design-systems craft prompt-templates; do
            cp -r "$dir" "$resources/$dir"
          done
          mkdir -p "$resources/plugins" "$resources/data"
          cp -r plugins/_official plugins/registry "$resources/plugins/"
          cp -r data/plugin-previews "$resources/data/plugin-previews"
          cp -r assets/frames "$resources/frames"
          cp -r assets/community-pets "$resources/community-pets"

          # The Vela CLI and its OpenCode companion, which the daemon looks for
          # at `$OD_RESOURCE_ROOT/bin` for Cloud sign-in and AMR-backed calls.
          # Without them `/api/integrations/vela/login` answers "vela binary not
          # found; install vela or configure VELA_BIN" and the cloud transport
          # surfaces as 502.
          mkdir -p "$resources/bin"
          install -Dm755 ${vela}/bin/vela "$resources/bin/vela"
          cp -r ${vela}/bin/libexec "$resources/bin/libexec"

          # The DeepSeek Harness connection component, integrity-addressed the
          # same way tools-pack bakes it: `od agent setup deepseek-harness`
          # installs this tarball into the user's own `dsh` profile.
          dsh="$resources/agent-runtimes/deepseek-harness"
          mkdir -p "$dsh"
          pnpm -C packages/dsh-runtime pack --pack-destination "$dsh"
          tarball="$(basename "$(find "$dsh" -name '*.tgz')")"
          cat > "$dsh/manifest.json" <<JSON
          {
            "file": "$tarball",
            "packageName": "@open-design/dsh-runtime",
            "schemaVersion": 1,
            "sha256": "$(sha256sum "$dsh/$tarball" | cut -d' ' -f1)",
            "version": "$(node -p "require('./packages/dsh-runtime/package.json').version")"
          }
          JSON

          # The daemon's production closure, installed in a trimmed workspace
          # copy: pnpm installs the projects a workspace contains, so leaving out
          # the web app (already exported above), the Electron shells, the tools
          # and the test suite keeps their dependencies — and every dev
          # dependency — out of the package. Upstream's container image trims its
          # build context the same way.
          work=/build/deploy-tree
          mkdir -p "$work/apps"
          cp pnpm-lock.yaml pnpm-workspace.yaml package.json "$work/"
          cp -r packages "$work/packages"
          cp -r apps/daemon "$work/apps/daemon"
          rm -rf "$work/apps/daemon/node_modules"
          ( cd "$work" && pnpm install --prod --frozen-lockfile --config.ignore-scripts=true )

          # The daemon resolves its workspace root from its own location
          # (apps/daemon/dist) and reaches every dependency through the relative
          # symlinks pnpm created, so the package keeps that shape: the daemon,
          # the workspace packages those `@open-design/*` links point at, the
          # pruned store beside them, and the exported web UI it serves. Only the
          # paths the daemon's own `files` field ships are copied, so its sources
          # and tests do not travel.
          mkdir -p "$root/apps/daemon"
          cp -a "$work/apps/daemon"/bin "$work/apps/daemon"/dist \
            "$work/apps/daemon"/package.json "$work/apps/daemon"/node_modules \
            "$root/apps/daemon/"
          cp -a "$work/packages" "$root/packages"
          cp -a "$work/node_modules" "$root/node_modules"

          # iplConfigHook installed with --ignore-scripts, so the two native
          # modules the daemon loads at runtime are compiled by hand, before the
          # sources they build from are pruned below. Neither ships a linux
          # prebuild in its tarball, and prebuild-install cannot reach the network
          # from the sandbox regardless.
          for module in better-sqlite3 node-pty; do
            moduleDir="$(readlink -f "$root/apps/daemon/node_modules/$module")"
            ( cd "$moduleDir" && node-gyp rebuild )
          done
          test -f "$(readlink -f "$root/apps/daemon/node_modules/better-sqlite3")/build/Release/better_sqlite3.node"
          test -f "$(readlink -f "$root/apps/daemon/node_modules/node-pty")/build/Release/pty.node"

          # Prune what upstream's container image prunes from the same tree:
          # type declarations, source maps, docs, test folders and build-only
          # sources, none of which the daemon reads. Scoped to the installed
          # modules and the workspace packages, never to the resource root, whose
          # `examples` and `docs` directories are content.
          find "$root/node_modules" "$root/packages" -type d \
            \( -name test -o -name tests -o -name __tests__ -o -name docs \
            -o -name doc -o -name example -o -name examples -o -name .github \) \
            -prune -exec rm -rf '{}' +
          find "$root/node_modules" "$root/packages" -type f \
            \( -name '*.md' -o -name '*.markdown' -o -name '*.d.ts' -o -name '*.d.cts' \
            -o -name '*.d.mts' -o -name '*.map' -o -name '*.tsbuildinfo' \
            -o -name 'binding.gyp' \) -delete

          # paseo removes node-pty's prebuilds so the addon it compiled is the one
          # that loads; on this target the directory only holds darwin and win32
          # binaries, and `deps`/`third_party` are the sources node-gyp just read.
          rm -rf "$root"/node_modules/.pnpm/node-pty@*/node_modules/node-pty/prebuilds \
            "$root"/node_modules/.pnpm/node-pty@*/node_modules/node-pty/deps \
            "$root"/node_modules/.pnpm/node-pty@*/node_modules/node-pty/third_party

          # onnxruntime-node ships every platform's binaries and the loader picks
          # bin/napi-v3/<platform>/<arch> for the running process, so the other
          # platforms are dead weight here.
          onnxRuntime="$(ls -d "$root"/node_modules/.pnpm/onnxruntime-node@*/node_modules/onnxruntime-node/bin/napi-v3)"
          find "$onnxRuntime" -mindepth 1 -maxdepth 1 -type d \
            ! -name '${stdenv.hostPlatform.node.platform}' -exec rm -rf '{}' +

          # sharp's prebuilt libvips-cpp cannot run in this process: it statically
          # embeds its own glib, so the addon's g_* references bind to whatever
          # glib the loader already resolved and the first raster operation dies
          # with SIGSEGV (deepseek-harness-desktop documents the same failure).
          # Expose the dynamically linked libvips under the name the addon asks
          # for and put it on LD_LIBRARY_PATH; the version check below fails the
          # build instead of segfaulting the daemon if nixpkgs' vips ever moves.
          addon="$(find "$root/node_modules/.pnpm" -type f -name 'sharp-linux-x64-*.node')"
          if [ "$(printf '%s\n' "$addon" | wc -l)" -ne 1 ]; then
            echo "open-design: expected one sharp addon in the closure, got:" >&2
            printf '%s\n' "$addon" >&2
            exit 1
          fi
          soname="$(patchelf --print-needed "$addon" | grep -E '^libvips-cpp[.]so[.]' || true)"
          if [ "$soname" != "libvips-cpp.so.${vips.version}" ]; then
            echo "open-design: sharp's addon requires '$soname', but this package pins vips ${vips.version} (${vips})" >&2
            echo "open-design: the substitute has to be the same upstream version as the libvips the prebuilt addon was linked against; pin vips accordingly, then re-run the sharp probe in installCheck" >&2
            exit 1
          fi
          vipsLib="$(find ${vips}/lib -maxdepth 1 -type f -name 'libvips-cpp.so.*')"
          mkdir -p "$root/sharp-libvips/lib"
          ln -s "$vipsLib" "$root/sharp-libvips/lib/$soname"

          # pnpm leaves dangling links for optional platform packages it did not
          # materialize.
          find "$root" -xtype l -delete

          runHook postInstall
        '';

        postFixup = ''
          makeWrapper ${lib.getExe nodejs_24} "$out/bin/od" \
            --argv0 od \
            --add-flags "$out/lib/${pname}/apps/daemon/bin/od.mjs" \
            --prefix PATH : ${
              lib.makeBinPath [
                bashInteractive
                git
                poppler-utils
                xdg-utils
              ]
            } \
            --set OD_NODE_BIN ${lib.getExe nodejs_24} \
            --set OD_BIN "$out/bin/od" \
            --set OD_RESOURCE_ROOT "$out/lib/${pname}/resources" \
            --prefix LD_LIBRARY_PATH : "$out/lib/${pname}/sharp-libvips/lib" \
            --run 'export OD_DATA_DIR="''${OD_DATA_DIR:-''${XDG_DATA_HOME:-$HOME/.local/share}/open-design}"'
        '';

        doInstallCheck = true;
        installCheckPhase = ''
          runHook preInstallCheck

          "$out/bin/od" --help | grep -qF 'od [--port <n>] [--host <addr>] [--no-open]'

          # The Vela CLI and its companion are what Cloud sign-in spawns; the
          # `--version` read also proves the ELF patching in the vela derivation
          # held, since an unpatched binary cannot start here.
          vela="$out/lib/${pname}/resources/bin/vela"
          test -x "$vela"
          test "$("$vela" --version)" = "${velaVersion}"
          opencode="$out/lib/${pname}/resources/bin/libexec/opencode/opencode"
          test -x "$opencode"
          if "$opencode" --help 2>&1 | grep -qF 'Bun is a fast JavaScript runtime'; then
            echo "open-design: the OpenCode companion fell back to the Bun CLI; its embedded payload was damaged" >&2
            exit 1
          fi

          # The substituted libvips has to actually load and rasterize; the
          # prebuilt one this package drops exits 139 on the same call.
          hyperframes="$(find "$out/lib/${pname}/node_modules/.pnpm" -maxdepth 1 -type d -name 'hyperframes@*' | head -1)/node_modules/hyperframes"
          ( cd "$hyperframes" && LD_LIBRARY_PATH="$out/lib/${pname}/sharp-libvips/lib" \
              node -e '
                const sharp = require("sharp");
                sharp({ create: { width: 4, height: 4, channels: 3, background: "red" } })
                  .png()
                  .toBuffer()
                  .then((buf) => {
                    if (buf.length === 0) throw new Error("empty png");
                    console.log("sharp rasterized", buf.length, "bytes with libvips", sharp.versions.vips);
                  })
                  .catch((err) => {
                    console.error(err);
                    process.exit(1);
                  });
              ' )

          runHook postInstallCheck
        '';

        meta = {
          description = "Local-first design-agent workspace (daemon and web UI)";
          longDescription = ''
            OpenDesign runs design skills against a local coding agent and
            streams the artifacts into a sandboxed preview. This package ships
            the `od` daemon and the web workspace it serves; `od` starts both and
            opens the URL in the browser. Project files live in the daemon data
            directory, `$XDG_DATA_HOME/open-design` unless OD_DATA_DIR says
            otherwise.
          '';
          homepage = "https://open-design.ai/";
          changelog = "https://github.com/nexu-io/open-design/releases/tag/open-design-v${version}";
          license = lib.licenses.asl20;
          sourceProvenance = with lib.sourceTypes; [
            # node-pty builds from source; sharp, onnxruntime-node, and
            # @ffmpeg-installer/ffmpeg ship prebuilt platform binaries.
            binaryBytecode
            fromSource
          ];
          mainProgram = "od";
          maintainers = [ lib.maintainers.asterismono ];
          platforms = [ "x86_64-linux" ];
        };
      };

      # electron-builder is not run: upstream's Linux config for a directory
      # target (asar:false, npmRebuild:false, nodeGypRebuild:false in
      # tools/pack/src/linux.ts) leaves exactly the pieces this install phase
      # places, and copying them needs neither electron-builder's Electron
      # download nor a cache the sandbox cannot fill.
      packages.open-design-desktop = stdenv.mkDerivation {
        pname = "open-design-desktop";
        inherit
          version
          src
          mitmCache
          ;

        nativeBuildInputs = [
          nodejs_24
          pnpm'
          iplConfigHook
          makeWrapper
          autoPatchelfHook
          copyDesktopItems
          node-gyp
          patchelf
          python3
          wrapGAppsHook3
        ];

        buildInputs = [
          libGL
          pciutils
          stdenv.cc.cc.lib
          vulkan-loader
        ];

        # The unpacked Electron runtime is nixpkgs' own build: its binaries carry
        # the RPATH that reaches every library it needs, and the dist even has the
        # bundled Vulkan loader replaced already. The hook would rewrite that
        # RPATH from this derivation's inputs and fail on the libraries it cannot
        # see, so it is disabled here and applied to the app tree instead (see
        # postFixup), which is what needs the patch: the two modules compiled by
        # hand-local-linkage node-gyp.
        dontAutoPatchelf = true;
        # wrapGAppsHook3 only supplies `gappsWrapperArgs` here, so the wrapper
        # below can hand Electron the GSettings schemas path its GTK surfaces read.
        dontWrapGApps = true;

        # The copied resource root contains the OpenCode companion, whose Bun
        # standalone payload `strip` would destroy (see vela's stripExclude).
        stripExclude = [ "opencode" ];

        env = {
          CI = "true";
          NEXT_TELEMETRY_DISABLED = "1";
          npm_config_nodedir = "${nodejs_24}";
          npm_config_build_from_source = "true";
        };

        # Same patch as the daemon package: the design-system importers clone into
        # the workspace root, which a store path cannot host.
        postPatch = ''
          substituteInPlace apps/daemon/src/routes/static-resource.ts \
            --replace-fail "path.join(PROJECT_ROOT, '.tmp')" "path.join(RUNTIME_DATA_DIR, 'tmp')"
        '';

        # Upstream's packaged workspace build, stage for stage
        # (tools/pack/src/workspace-build.ts WORKSPACE_BUILD_COMMANDS). The
        # packaged web sidecar is a Next.js server, not the static export the
        # daemon serves, and Next type-checks the app in-process, so the heap
        # ceiling upstream sets applies here too.
        buildPhase = ''
          runHook preBuild

          pnpm --filter '@open-design/dsh-runtime...' \
            --workspace-concurrency=1 --if-present run build

          NODE_OPTIONS=--max-old-space-size=4096 OD_WEB_OUTPUT_MODE=server \
            pnpm --filter '@open-design/packaged^...' \
            --workspace-concurrency=1 --if-present run build

          pnpm --filter @open-design/web run build:sidecar
          pnpm --filter @open-design/packaged run build

          runHook postBuild
        '';

        installPhase = ''
          runHook preInstall

          root="$out/lib/${pname}"
          executableName="Open Design"
          unpacked="$root/linux-unpacked"
          app=/build/app-tree
          resources=/build/resources

          # The production closure of the four projects the packaged runtime
          # loads, installed in a trimmed workspace copy: pnpm installs the
          # projects a workspace contains, so the tools, the test suite and the
          # build-only dependencies stay out (the same trick the daemon package
          # and upstream's container image use).
          mkdir -p "$app/apps"
          cp pnpm-lock.yaml pnpm-workspace.yaml package.json "$app/"
          cp -r packages "$app/packages"
          for name in daemon web desktop packaged; do
            cp -r "apps/$name" "$app/apps/$name"
            rm -rf "$app/apps/$name/node_modules"
          done
          ( cd "$app" && pnpm install --prod --frozen-lockfile --config.ignore-scripts=true )

          # The bundle root is where the app resolves its own packages from:
          # main.cjs imports @open-design/packaged, and the runtime resolves the
          # `@open-design/{daemon,web}/sidecar` entries through node_modules
          # (apps/packaged/src/sidecars.ts). tools-pack reaches the same state by
          # installing packed tarballs into the assembled app; the workspace's own
          # layout carries it here.
          mkdir -p "$app/node_modules/@open-design"
          for pkg in release components contracts registry-protocol sidecar-proto \
            launcher-proto platform sidecar download host agui-adapter \
            plugin-runtime diagnostics; do
            ln -s "../../packages/$pkg" "$app/node_modules/@open-design/$pkg"
          done
          for name in daemon web desktop packaged; do
            ln -s "../../apps/$name" "$app/node_modules/@open-design/$name"
          done

          # Entry points, exactly what tools-pack writes: the packaged package as
          # an import, the preload the shell expects beside it, and the app
          # manifest Electron reads for `main`.
          cat > "$app/main.cjs" <<'ENTRY'
          import("@open-design/packaged").catch((error) => {
            console.error("packaged entry failed", error);
            process.exit(1);
          });
          ENTRY
          cp apps/desktop/dist/main/preload.cjs "$app/preload.cjs"
          cat > "$app/package.json" <<JSON
          {
            "name": "open-design-packaged",
            "productName": "Open Design",
            "version": "${version}",
            "private": true,
            "main": "main.cjs",
            "description": "Local-first design product: detects your installed code-agent CLI, runs design skills + design systems, streams artifacts into a sandboxed preview.",
            "author": "Open Design Team",
            "repository": {
              "type": "git",
              "url": "https://github.com/nexu-io/open-design.git"
            }
          }
          JSON

          # The daemon sidecar needs the two native modules, compiled for the Node
          # this package ships rather than for Electron (see the wrapper).
          for module in better-sqlite3 node-pty; do
            moduleDir="$(readlink -f "$app/apps/daemon/node_modules/$module")"
            ( cd "$moduleDir" && node-gyp rebuild )
          done
          test -f "$(readlink -f "$app/apps/daemon/node_modules/better-sqlite3")/build/Release/better_sqlite3.node"
          test -f "$(readlink -f "$app/apps/daemon/node_modules/node-pty")/build/Release/pty.node"

          # sharp's prebuilt libvips-cpp cannot run here (it statically embeds its
          # own glib), so expose the dynamically linked one under the name the
          # addon asks for and put it on LD_LIBRARY_PATH; the daemon package
          # documents the failure this avoids.
          addon="$(find "$app/node_modules/.pnpm" -type f -name 'sharp-linux-x64-*.node')"
          if [ "$(printf '%s\n' "$addon" | wc -l)" -ne 1 ]; then
            echo "open-design-desktop: expected one sharp addon in the closure, got:" >&2
            printf '%s\n' "$addon" >&2
            exit 1
          fi
          soname="$(patchelf --print-needed "$addon" | grep -E '^libvips-cpp[.]so[.]' || true)"
          if [ "$soname" != "libvips-cpp.so.${vips.version}" ]; then
            echo "open-design-desktop: sharp's addon requires '$soname', but this package pins vips ${vips.version} (${vips})" >&2
            exit 1
          fi
          vipsLib="$(find ${vips}/lib -maxdepth 1 -type f -name 'libvips-cpp.so.*')"
          mkdir -p "$app/sharp-libvips/lib"
          ln -s "$vipsLib" "$app/sharp-libvips/lib/$soname"

          # Prune what the daemon package prunes, plus the sources the three
          # non-web apps do not ship (`files` names their built output only).
          find "$app/node_modules" "$app/packages" -type d \
            \( -name test -o -name tests -o -name __tests__ -o -name docs \
            -o -name doc -o -name example -o -name examples -o -name .github \) \
            -prune -exec rm -rf '{}' +
          find "$app/node_modules" "$app/packages" -type f \
            \( -name '*.md' -o -name '*.markdown' -o -name '*.d.ts' -o -name '*.d.cts' \
            -o -name '*.d.mts' -o -name '*.map' -o -name '*.tsbuildinfo' \
            -o -name 'binding.gyp' \) -delete
          rm -rf "$app"/apps/daemon/src "$app"/apps/daemon/tests \
            "$app"/apps/desktop/src "$app"/apps/desktop/tests \
            "$app"/apps/packaged/src "$app"/apps/packaged/tests
          rm -rf "$app"/node_modules/.pnpm/node-pty@*/node_modules/node-pty/prebuilds \
            "$app"/node_modules/.pnpm/node-pty@*/node_modules/node-pty/deps \
            "$app"/node_modules/.pnpm/node-pty@*/node_modules/node-pty/third_party
          onnxRuntime="$(ls -d "$app"/node_modules/.pnpm/onnxruntime-node@*/node_modules/onnxruntime-node/bin/napi-v3)"
          find "$onnxRuntime" -mindepth 1 -maxdepth 1 -type d \
            ! -name '${stdenv.hostPlatform.node.platform}' -exec rm -rf '{}' +

          mkdir -p "$resources/open-design/bin"
          cp -r ${self'.packages.open-design}/lib/${pname}/resources/. "$resources/open-design/"
          # A real copy, not a symlink: Node reports process.execPath from
          # /proc/self/exe, and the daemon accepts OD_RESOURCE_ROOT only when that
          # path sits under a `resources/open-design/bin/` marker — a symlink
          # would make it the store path instead (apps/daemon/src/daemon-paths.ts).
          cp ${lib.getExe nodejs_24} "$resources/open-design/bin/node"
          chmod u+w "$resources/open-design/bin/node"

          # Read from resourcesPath/open-design-config.json (apps/packaged/src/
          # config.ts). Portable, so no build-machine root is baked — the same
          # reason upstream's release builds pass --portable.
          cat > "$resources/open-design-config.json" <<JSON
          {
            "appVersion": "${version}",
            "namespace": "default",
            "nodeCommandRelative": "open-design/bin/node",
            "webOutputMode": "server"
          }
          JSON

          # The unpacked Electron runtime. The binary must not keep the name
          # `electron`: Electron treats an executable by that name as its default
          # app and reports app.isPackaged === false, which sends the shell down
          # its development branch (deepseek-harness-desktop documents this).
          mkdir -p "$unpacked/resources"
          cp -a ${electron_42.dist}/. "$unpacked/"
          chmod -R u+w "$unpacked"
          mv "$unpacked/electron" "$unpacked/$executableName"
          rm -f "$unpacked/resources/default_app.asar"

          cp -a "$app" "$unpacked/resources/app"
          cp -a "$resources/open-design" "$unpacked/resources/open-design"
          cp "$resources/open-design-config.json" "$unpacked/resources/open-design-config.json"
          # Editable-PPTX export reads this from process.resourcesPath.
          cp apps/desktop/vendor/dom-to-pptx/dom-to-pptx.bundle.js.gz \
            "$unpacked/resources/dom-to-pptx.bundle.js.gz"

          find "$unpacked" -xtype l -delete

          install -Dm644 tools/pack/resources/linux/icon.png \
            "$out/share/icons/hicolor/512x512/apps/open-design.png"

          runHook postInstall
        '';

        # Wayland follows nixpkgs' NIXOS_OZONE_WL convention: the flags appear only
        # when that and WAYLAND_DISPLAY are both set. They are the explicit
        # `--ozone-platform=wayland` form, not the `--ozone-platform-hint=auto`
        # the distribution uses for other Chromium applications — this Electron
        # does not carry that switch at all, and passing it leaves the app on X11
        # (verified against a headless Wayland compositor). Chromium reads its
        # switches out of argv, which the packaged launcher here ignores: it parses
        # only its own flags.
        postFixup = ''
          unpacked="$out/lib/${pname}/linux-unpacked"

          # The one thing in the bundle that needs patching: the native modules
          # compiled by node-gyp, plus the prebuilt binaries shipped in the store
          # that already carry their own RPATHs.
          autoPatchelf "$unpacked/resources/app"

          # The fixup phase's shrink-rpath keeps only directories that satisfy
          # DT_NEEDED; ANGLE dlopens libGL and libvulkan by name and Chromium
          # dlopens libpci for GPU discovery. Restore those paths after the
          # shrink, as nixpkgs does for its own Electron dist — without them
          # the GPU process falls back to software compositing.
          for elf in "libGLESv2.so" "Open Design"; do
            patchelf --add-rpath "${
              lib.makeLibraryPath [
                libGL
                pciutils
                vulkan-loader
              ]
            }" "$unpacked/$elf"
          done

          makeShellWrapper "$unpacked/Open Design" "$out/bin/open-design-desktop" \
            "''${gappsWrapperArgs[@]}" \
            --prefix LD_LIBRARY_PATH : "$unpacked/resources/app/sharp-libvips/lib" \
            --prefix PATH : ${
              lib.makeBinPath [
                bashInteractive
                git
                poppler-utils
                xdg-utils
              ]
            } \
            --set CHROME_DEVEL_SANDBOX "$unpacked/chrome-sandbox" \
            --unset APPIMAGE \
            --add-flags "\''${NIXOS_OZONE_WL:+\''${WAYLAND_DISPLAY:+--ozone-platform=wayland --enable-features=WaylandWindowDecorations --enable-wayland-ime=true --wayland-text-input-version=3}}"
        '';

        desktopItems = [
          (makeDesktopItem {
            name = "open-design";
            desktopName = "Open Design";
            genericName = "Design workspace";
            comment = "Local-first design-agent workspace";
            exec = "open-design-desktop %U";
            icon = "open-design";
            categories = [
              "Development"
              "Utility"
            ];
            startupWMClass = "Open Design";
            mimeTypes = [ "x-scheme-handler/od" ];
          })
        ];

        doInstallCheck = true;
        installCheckPhase = ''
          runHook preInstallCheck

          app="$out/lib/${pname}/linux-unpacked/resources/app"

          ( cd "$app" && node --input-type=module -e '
              for (const entry of ["@open-design/packaged", "@open-design/desktop/main"]) {
                await import.meta.resolve(entry);
              }
              for (const entry of ["@open-design/daemon/sidecar", "@open-design/web/sidecar"]) {
                await import.meta.resolve(entry);
              }
              console.log("packaged entries resolve");
            ' )

          test -x "$out/lib/${pname}/linux-unpacked/Open Design"
          test -x "$out/bin/open-design-desktop"
          test -f "$out/lib/${pname}/linux-unpacked/resources/open-design/bin/node"
          test -x "$out/lib/${pname}/linux-unpacked/resources/open-design/bin/vela"
          opencode="$out/lib/${pname}/linux-unpacked/resources/open-design/bin/libexec/opencode/opencode"
          test -x "$opencode"
          if "$opencode" --help 2>&1 | grep -qF 'Bun is a fast JavaScript runtime'; then
            echo "open-design-desktop: the OpenCode companion fell back to the Bun CLI; its embedded payload was damaged" >&2
            exit 1
          fi
          test -f "$out/lib/${pname}/linux-unpacked/resources/open-design-config.json"

          # ANGLE and Chromium dlopen these by name, so shrink-rpath cannot
          # see them; assert the postFixup restore put them back.
          for elf in "libGLESv2.so" "Open Design"; do
            rpath="$(patchelf --print-rpath "$out/lib/${pname}/linux-unpacked/$elf")"
            for needle in libglvnd vulkan-loader pciutils; do
              case "$rpath" in
                *"$needle"*) ;;
                *)
                  echo "open-design-desktop: $elf lost $needle from its RPATH: $rpath" >&2
                  exit 1
                  ;;
              esac
            done
          done

          runHook postInstallCheck
        '';

        meta = {
          description = "Local-first design-agent workspace as a packaged desktop application";
          longDescription = ''
            The Electron application upstream ships to macOS and Windows,
            assembled for Linux: the shell starts a daemon sidecar and a Next.js
            web sidecar and loads the workspace itself. It is one of two ways to
            run OpenDesign here — the `od` daemon package serves the same
            workspace in a browser, and is the one upstream supports on Linux.
          '';
          homepage = "https://open-design.ai/";
          changelog = "https://github.com/nexu-io/open-design/releases/tag/open-design-v${version}";
          license = lib.licenses.asl20;
          sourceProvenance = with lib.sourceTypes; [
            # node-pty builds from source; sharp, onnxruntime-node, and
            # @ffmpeg-installer/ffmpeg ship prebuilt platform binaries.
            binaryBytecode
            fromSource
          ];
          mainProgram = "open-design-desktop";
          maintainers = [ lib.maintainers.asterismono ];
          platforms = [ "x86_64-linux" ];
        };
      };
    };
}
