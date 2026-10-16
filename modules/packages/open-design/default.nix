# OpenDesign (`od`) — local-first design-agent workspace, built from the
# upstream release tag.
#
# Upstream publishes desktop installers for macOS and Windows only; on Linux
# the supported deployment is the daemon, which serves the statically exported
# web workspace itself. This builds that daemon + web pair from source, and
# installs the same runtime layout upstream's container image uses: the daemon
# with its production dependency closure, the exported web UI, and the content
# trees the daemon reads from its workspace root.
{ inputs, ... }:
{
  # The package resolves pnpm-lock.yaml integrity hashes through
  # importPnpmLock/iplConfigHook, which nixpkgs does not provide.
  flake-file.inputs.importPnpmLock = {
    url = "git+https://tangled.org/scrumplex.net/importPnpmLock.nix?rev=4bd9cc54e6a5431930b4d09898e1ef49cb2ed241";
    inputs = {
      nixpkgs.follows = "nixpkgs";
      systems.follows = "systems";
    };
  };

  perSystem =
    { pkgs, pkgsUnstable, ... }:
    let
      # pnpm-lock.yaml integrity hashes come from the importPnpmLock overlay.
      pnpmPkgs = pkgsUnstable.extend inputs.importPnpmLock.overlays.default;
      inherit (pnpmPkgs) iplConfigHook importPnpmLock;
      inherit (pkgsUnstable)
        autoPatchelfHook
        bashInteractive
        fetchFromGitHub
        fetchurl
        git
        lib
        makeWrapper
        node-gyp
        nodejs_24
        patchelf
        poppler-utils
        python3
        stdenv
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

      # importPnpmLock reads the integrity hashes straight out of the lockfile,
      # so there is no pnpmDepsHash to maintain and no second copy of the
      # lockfile to keep in sync.
      mitmCache = importPnpmLock {
        inherit pname version;
        lockFile = "${src}/pnpm-lock.yaml";
      };
    in
    {
      packages.open-design = stdenv.mkDerivation (finalAttrs: {
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
          # node-gyp compiles better-sqlite3 and node-pty against nixpkgs' Node.
          npm_config_nodedir = "${nodejs_24}";
          npm_config_build_from_source = "true";
        };

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

          # Build every workspace package the daemon and the web app import,
          # then the Next.js static export the daemon serves as the web UI.
          # `@open-design/dsh-runtime` is the bridge the daemon installs into an
          # existing `dsh` CLI, packaged below into the resource root.
          pnpm -r --if-present \
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
      });
    };
}
