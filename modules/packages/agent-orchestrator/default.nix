# Agent Orchestrator: the desktop workspace from
# https://github.com/OrchestratorInc/agent-orchestrator, built from source.
#
# Why this is not the released AppImage (which the package used to wrap): upstream
# ships no Nix package and no source-built Linux artifact, only an Electron
# AppImage assembled by electron-forge. This file rebuilds that artifact here,
# from the release tag, with the same toolchain steps upstream's own build runs.
# It also drops the appimageTools FHS sandbox that every launch used to enter.
#
# The five moving parts, and what each replaces:
#
#  1. Electron 33.4.11, the version upstream's frontend lock pins. nixpkgs no
#     longer carries 33.x in any form, so this instantiates nixpkgs' own
#     electron packaging (`.../electron/binary/generic.nix`, which unzips the
#     upstream distribution and patches the interpreter, RUNPATHs, libvulkan and
#     ANGLE) at that version. Its `dist` becomes the payload of the output; its
#     `src` (the untouched zip) goes to @electron/packager through
#     `electronZipDir`, so packaging never reaches the network.
#
#     nixpkgs marks every pre-42 Electron as EOL via knownVulnerabilities, and
#     the marker is cleared here: the engine version is upstream's decision, and
#     matching the pin is the point of this package. A newer Electron would run
#     untested paths in an application upstream only tests against 33.
#
#  2. The Go daemon (`frontend/scripts/build-daemon.mjs` runs
#     `go build ./cmd/ao` in backend/). Built with buildGo127Module, since
#     backend/go.mod declares go 1.27.1, and GOWORK=off, since the repository's
#     go.work also pulls in ./cloud, which the daemon does not use.
#
#  3. Bundled tmux 3.5a. Upstream compiles tmux plus libevent, ncurses and
#     utf8proc from pinned tarballs; the four archives are fetched here and
#     placed where build-tmux.mjs looks for them, so the script still does the
#     compiling and its own smoke test. forge.config.ts's postPackage gate then
#     asserts `tmux -V` reports 3.5a, which rules out substituting nixpkgs' tmux.
#
#  4. The agent-browser runtime: one prebuilt binary plus three license files,
#     all pinned by the checksums prepare-agent-browser.mjs already hardcodes.
#
#  5. The ACP runtime (a Node distribution plus an npm tree, built by
#     build-acp-runtime.mjs from frontend/acp-runtime). Rebuilt here as an npm
#     tree with acp-runtime's own lock, upstream's three adapter patches, and
#     nixpkgs' Node 22 in place of the downloaded distribution. The
#     `.ao-acp-runtime.json` marker upstream writes is read only by that build
#     script, never at runtime, so it is not reproduced.
#
# Everything else is upstream's own build: the Vite plugin produces .vite/,
# electron-forge packages it into app.asar with its extraResources, and
# @electron/rebuild compiles better-sqlite3 against Electron's headers before
# packaging (upstream's forge config asks for it with force; forge's own
# post-copy rebuild then skips, because the .forge-meta file that step leaves
# behind matches the ABI). Those headers come from nixpkgs' electron and are
# handed to node-gyp through npm_config_nodedir, so that step is offline too.
#
# Update: bump `version`/`rev`, then refresh the pinned hashes with
#   nix store prefetch-file --unpack --json https://codeload.github.com/OrchestratorInc/agent-orchestrator/tar.gz/REV
#   nix store prefetch-file --json https://github.com/electron/electron/releases/download/vVER/electron-vVER-linux-x64.zip
#   nix store prefetch-file --json https://artifacts.electronjs.org/headers/dist/vVER/node-vVER-headers.tar.gz
#   prefetch-npm-deps frontend/package-lock.json
#   prefetch-npm-deps frontend/acp-runtime/package-lock.json
#   (buildGo127Module's vendorHash is reported by a build with lib.fakeHash)
_:
let
  package =
    {
      lib,
      pkgs,
      stdenv,
      fetchurl,
      fetchFromGitHub,
      fetchNpmDeps,
      npmHooks,
      buildGo127Module,
      nodejs_22,
      nodejs_24,
      python3,
      glibc,
      bashInteractive,
      makeWrapper,
      wrapGAppsHook3,
      copyDesktopItems,
      makeDesktopItem,
      gsettings-desktop-schemas,
      glib,
      gtk3,
      gtk4,
      runCommand,
      writeText,
    }:
    let
      pname = "agent-orchestrator";
      version = "0.13.5";
      electronVersion = "33.4.11";

      src = fetchFromGitHub {
        owner = "OrchestratorInc";
        repo = "agent-orchestrator";
        rev = "c95ae361eee48d33c2f443c6d2fe69c445f548a8";
        hash = "sha256-FMEZTFyCeCXmJTViIoqZTzs37r4TpdiORfHIEck3ez0=";
      };

      # See note 1. meta.knownVulnerabilities is cleared deliberately, and on
      # the same derivation the rest of this file consumes, so nothing pulls the
      # EOL-marked original into the build closure.
      electron =
        let
          base =
            (pkgs.callPackage "${pkgs.path}/pkgs/development/tools/electron/binary/generic.nix" { })
              electronVersion
              {
                x86_64-linux = "sha256-IS1DHHyRYpIxHHl82R+ERnxavW5pg88ksWLv/2TO6Kk=";
                headers = "sha256-elyhLPCksR3Gbi/apwJONt5IVgCIAT4D6T6XLpKwkT8=";
              };
        in
        base.overrideAttrs (prev: {
          meta = prev.meta // {
            knownVulnerabilities = [ ];
          };
        });

      # @electron/packager resolves `electronZipDir` + electron-v<version>-<platform>-<arch>.zip.
      electron-zip-dir = runCommand "electron-zip-dir" { } ''
        mkdir -p $out
        ln -s ${electron.src} $out/${electron.src.name}
      '';

      # See note 2.
      daemon = buildGo127Module {
        pname = "${pname}-daemon";
        inherit version src;
        modRoot = "backend";
        subPackages = [ "cmd/ao" ];
        vendorHash = "sha256-HHSFVH/Yl1pmNBZbK2L8NHbPCAA+gNRQoPrj2rBmjwo=";
        env.GOWORK = "off";
      };

      # See note 3. Names and hashes are the ones build-tmux.mjs verifies.
      tmuxSources = [
        (fetchurl {
          name = "tmux-3.5a.tar.gz";
          url = "https://github.com/tmux/tmux/releases/download/3.5a/tmux-3.5a.tar.gz";
          hash = "sha256-FiFr0IdxcN/MZBVwhbqQE2ELErCCVIx8lULMAQMZiVE=";
        })
        (fetchurl {
          name = "libevent-2.1.12-stable.tar.gz";
          url = "https://github.com/libevent/libevent/releases/download/release-2.1.12-stable/libevent-2.1.12-stable.tar.gz";
          hash = "sha256-kubeG+nsF2Qo/SNnZ35hzv/C7hyxGQNQN6J9NGsEA7s=";
        })
        (fetchurl {
          name = "ncurses-6.5.tar.gz";
          url = "https://invisible-mirror.net/archives/ncurses/ncurses-6.5.tar.gz";
          hash = "sha256-E22RvCaamleF5fnpgLx2q1dCj2BM4+WlqQzrx2eXHMY=";
        })
        (fetchurl {
          name = "utf8proc-2.10.0.tar.gz";
          url = "https://github.com/JuliaStrings/utf8proc/archive/refs/tags/v2.10.0.tar.gz";
          hash = "sha256-b08bY52qbcqfgLxdsSM+nLqjGmd5CIcQYWCzPvdD8TY=";
        })
      ];

      tmuxBundle = stdenv.mkDerivation {
        pname = "${pname}-tmux";
        version = "3.5a";
        inherit src;

        nativeBuildInputs = [
          nodejs_24
          pkgs.bison # tmux's parser needs yacc
          pkgs.pkg-config
          pkgs.glibc.bin # ldd, used by the script's linkage check
          pkgs.util-linux # the script's own `script`-driven terminfo attach check
        ];

        buildPhase = ''
          runHook preBuild

          cd "$NIX_BUILD_TOP/$sourceRoot"

          # build-tmux.mjs skips its download step when the archive is already
          # present and hashes to the value it pins.
          mkdir -p .cache/bundled-tmux/downloads
          ${lib.concatMapStrings (source: ''
            ln -s ${source} ".cache/bundled-tmux/downloads/${source.name}"
          '') tmuxSources}

          cd frontend
          node scripts/build-tmux.mjs

          runHook postBuild
        '';

        installPhase = ''
          runHook preInstall
          mkdir -p $out
          cp -a "$NIX_BUILD_TOP/$sourceRoot/frontend/tmux/." $out/
          runHook postInstall
        '';

        meta.description = "tmux 3.5a as bundled by ${pname}";
      };

      # See note 4. The binary targets a generic Linux environment, so
      # autoPatchelf supplies NixOS's interpreter and glibc RUNPATH; the
      # AppImage ran it inside its FHS sandbox instead.
      agent-browser = stdenv.mkDerivation {
        pname = "${pname}-agent-browser";
        version = "0.38.1";

        src = fetchurl {
          url = "https://github.com/vercel-labs/agent-browser/releases/download/v0.38.1/agent-browser-linux-x64";
          hash = "sha256-UQAUmhkDIRyIneTlRb822QgDdAzqT5mqImUWSfkgXqE=";
        };

        dontUnpack = true;

        nativeBuildInputs = [ pkgs.autoPatchelfHook ];
        buildInputs = [ stdenv.cc.cc.lib ];

        installPhase = ''
            runHook preInstall

            mkdir -p $out
            install -m 755 $src $out/agent-browser
          install -m 644 ${
            fetchurl {
              url = "https://unpkg.com/agent-browser@0.38.1/LICENSE";
              hash = "sha256-AUuzHoPVwudq6hzG6CIXNGq0E2LzLLNVrQ9cEKoK6v8=";
            }
          } $out/LICENSE-agent-browser
          install -m 644 ${
            fetchurl {
              url = "https://unpkg.com/agent-browser@0.38.1/cli/src/native/a11y/LICENSE-axe-core.txt";
              hash = "sha256-rxdbnZbuk8IaA2FS4bkFsLlTBNSujCySHHYJEAuo334=";
            }
          } $out/LICENSE-axe-core
          install -m 644 ${
            fetchurl {
              url = "https://unpkg.com/agent-browser@0.38.1/cli/src/native/a11y/LICENSE-axe-core-THIRD-PARTY.txt";
              hash = "sha256-yt+S1d8L+Uu010+QbVIH9hmJI+T5av8LZ5PXk/X4Dnc=";
            }
          } $out/LICENSE-axe-core-THIRD-PARTY
          printf '0.38.1' > $out/.license-version

            runHook postInstall
        '';

        meta.description = "Browser automation runtime as bundled by ${pname}";
      };

      # See note 5. Upstream's patches mutate the installed adapter, so they run
      # through upstream's own helper module rather than a copy of it.
      acpPatchScript = writeText "ao-patch-acp-runtime.mjs" ''
        import {
          patchClaudeContextUsage,
          patchClaudeHibernationCheck,
          patchClaudeRetryDetails,
        } from "${src}/frontend/scripts/build-acp-runtime-helpers.mjs";

        const adapter = process.argv[2];
        for (const patch of [patchClaudeRetryDetails, patchClaudeContextUsage, patchClaudeHibernationCheck]) {
          if (!patch(adapter)) {
            throw new Error(`''${patch.name} did not apply`);
          }
        }
      '';

      # Upstream excludes these with --omit=optional; this removal is the same
      # defense-in-depth step its build script takes.
      claudeNativePackages = [
        "claude-agent-sdk-darwin-arm64"
        "claude-agent-sdk-darwin-x64"
        "claude-agent-sdk-linux-arm64"
        "claude-agent-sdk-linux-arm64-musl"
        "claude-agent-sdk-linux-x64"
        "claude-agent-sdk-linux-x64-musl"
        "claude-agent-sdk-win32-arm64"
        "claude-agent-sdk-win32-x64"
      ];

      acpRuntime = stdenv.mkDerivation {
        pname = "${pname}-acp-runtime";
        inherit version;

        src = runCommand "acp-runtime-src" { } ''
          mkdir -p $out
          cp -a ${src}/frontend/acp-runtime/. $out/
        '';

        nativeBuildInputs = [
          npmHooks.npmConfigHook
          nodejs_24
        ];

        npmDeps = fetchNpmDeps {
          src = runCommand "acp-runtime-lock" { } ''
            mkdir -p $out
            cp ${src}/frontend/acp-runtime/package.json \
              ${src}/frontend/acp-runtime/package-lock.json $out/
          '';
          hash = "sha256-aYI6jqh4wzfJJZMnM+HwSnXTZ9mPpjt1WjWA4y2KL3k=";
        };

        npmInstallFlags = [
          "--omit=dev"
          "--omit=optional"
        ];
        npmRebuildFlags = [ "--ignore-scripts" ];

        dontNpmBuild = true;

        installPhase = ''
          runHook preInstall

          cd "$NIX_BUILD_TOP/$sourceRoot"

          mkdir -p $out
          cp -a package.json package-lock.json node_modules $out/
          chmod -R u+w $out

          ${nodejs_24}/bin/node ${acpPatchScript} \
            $out/node_modules/@agentclientprotocol/claude-agent-acp/dist/acp-agent.js

          for name in ${lib.concatStringsSep " " claudeNativePackages}; do
            rm -rf "$out/node_modules/@anthropic-ai/$name"
          done

          # Upstream ships Node's own release tarball here. NixOS cannot run that
          # binary without a shim, so the packaged Node is nixpkgs' 22.x, which
          # is the interface the adapter declares.
          mkdir -p $out/node/bin
          ln -s ${nodejs_22}/bin/node $out/node/bin/node

          runHook postInstall
        '';

        meta.description = "ACP runtime as bundled by ${pname}";
      };

      frontend = stdenv.mkDerivation {
        inherit pname version src;

        nativeBuildInputs = [
          npmHooks.npmConfigHook
          nodejs_24
          python3 # node-gyp, for better-sqlite3
          makeWrapper
          wrapGAppsHook3
          copyDesktopItems
        ];

        buildInputs = [
          gsettings-desktop-schemas
          glib
          gtk3
          gtk4
        ];

        # npm lives in frontend/, not at the repository root.
        npmRoot = "frontend";

        npmDeps = fetchNpmDeps {
          src = runCommand "frontend-lock" { } ''
            mkdir -p $out
            cp ${src}/frontend/package.json ${src}/frontend/package-lock.json $out/
          '';
          hash = "sha256-ktUmytX4MDdnsk5Q0GrYxkYsItAtMMfat5kYUnl3rDI=";
        };

        # Nothing here wants dependency lifecycle scripts: better-sqlite3 is
        # compiled by forge below, and electron's postinstall would try to
        # download a distribution nixpkgs already provides.
        npmRebuildFlags = [ "--ignore-scripts" ];

        # npm writes to the dependency cache while installing this lock.
        makeCacheWritable = true;

        dontNpmBuild = true;
        dontNpmInstall = true;
        dontWrapGApps = true;
        dontAutoPatchelf = true;

        postPatch = ''
          # Upstream's release workflow stamps the tag's version into
          # frontend/package.json; the committed file still carries the version
          # of the last development bump.
          ${nodejs_24}/bin/node -e '
            const fs = require("node:fs");
            const path = "frontend/package.json";
            const manifest = JSON.parse(fs.readFileSync(path, "utf8"));
            manifest.version = "${version}";
            fs.writeFileSync(path, JSON.stringify(manifest, null, "\t") + "\n");
          '

          # @electron/packager would otherwise fetch the Electron zip through
          # @electron/get.
          substituteInPlace frontend/forge.config.ts \
            --replace-fail 'packagerConfig: {' 'packagerConfig: { electronZipDir: "${electron-zip-dir}",'
        '';

        buildPhase = ''
          runHook preBuild

          export HOME="$TMPDIR"
          export AO_RELEASE_REPO="OrchestratorInc/agent-orchestrator"
          export ELECTRON_SKIP_BINARY_DOWNLOAD=1
          # forge.config.ts's postPackage gate runs the packaged tmux.
          export SHELL=${bashInteractive}/bin/bash

          # node-gyp compiles better-sqlite3 for Electron inside forge. The npm
          # config hook set npm_config_nodedir to nixpkgs' Node source, which
          # would produce an addon for the wrong ABI; point it at Electron's
          # headers instead, so the rebuild downloads nothing.
          export npm_config_nodedir=${electron.headers}

          cd "$NIX_BUILD_TOP/$sourceRoot/frontend"

          # The four runtime trees forge copies through `extraResource`.
          rm -rf daemon tmux agent-browser resources/acp-runtime
          mkdir -p daemon resources
          install -m 755 ${daemon}/bin/ao daemon/ao
          mkdir -p tmux agent-browser
          cp -a ${tmuxBundle}/. tmux/
          cp -a ${agent-browser}/. agent-browser/
          cp -a ${acpRuntime} resources/acp-runtime

          # forge.config.ts writes resources/app-update.yml itself from
          # AO_RELEASE_REPO. Nothing in the store can be replaced by an update,
          # and app.isPackaged plus a read-only store leave the updater inert.
          npx electron-forge package --platform=linux --arch=x64

          runHook postBuild
        '';

        installPhase = ''
          runHook preInstall

          # Everything of the application lives under share/agent-orchestrator,
          # the way paseo-desktop is laid out: home-manager merges every package
          # into one profile, and an application directory at the root would
          # collide with the other Electron packages' own resources/ entries.
          app="$out/share/agent-orchestrator"

          # 1. nixpkgs' patched Electron payload at upstream's pinned version
          #    (see note 1). A real copy, not a symlink: the application resolves
          #    process.resourcesPath from the executable's real path.
          mkdir -p "$app"
          cp -a ${electron.dist}/. "$app/"
          chmod -R u+w "$app"
          mv "$app/electron" "$app/agent-orchestrator"
          chmod +x "$app/agent-orchestrator"
          rm -f "$app/resources/default_app.asar"

          # 2. forge's application directory: app.asar, its unpacked native
          #    modules, and every extraResource. packagerConfig.name carries a
          #    space ("Agent Orchestrator"), so the directory is not nameable.
          out_root="$NIX_BUILD_TOP/$sourceRoot/frontend/out"
          pkgdir="$(ls -d "$out_root"/*-linux-x64 2>/dev/null || true)"
          if [ "$(printf '%s\n' "$pkgdir" | wc -l)" -ne 1 ] || [ ! -d "$pkgdir" ]; then
            echo "packaging: expected exactly one packaged application under $out_root:" >&2
            ls -la "$out_root" >&2
            exit 1
          fi
          cp -a "$pkgdir/resources/." "$app/resources/"

          install -Dm644 "$NIX_BUILD_TOP/$sourceRoot/frontend/assets/icon.png" \
            $out/share/icons/hicolor/512x512/apps/agent-orchestrator.png

          runHook postInstall
        '';

        postFixup = ''
          # CHROME_DEVEL_SANDBOX is nixpkgs' own Electron convention, and
          # gappsWrapperArgs carries the GSettings schema path the file dialogs
          # need.
          makeWrapper $out/share/agent-orchestrator/agent-orchestrator $out/bin/agent-orchestrator \
            "''${gappsWrapperArgs[@]}" \
            --set CHROME_DEVEL_SANDBOX "$out/share/agent-orchestrator/chrome-sandbox"
        '';

        desktopItems = [
          (makeDesktopItem {
            name = "agent-orchestrator";
            desktopName = "Agent Orchestrator";
            genericName = "Coding agent workspace";
            comment = "Run and supervise teams of coding agents";
            exec = "agent-orchestrator %U";
            icon = "agent-orchestrator";
            categories = [ "Development" ];
            startupWMClass = "Agent Orchestrator";
            # The WorkOS sign-in callback arrives as ao-app://.
            mimeTypes = [ "x-scheme-handler/ao-app" ];
          })
        ];

        meta = {
          description = "Desktop workspace that runs and supervises teams of coding agents";
          homepage = "https://github.com/OrchestratorInc/agent-orchestrator";
          changelog = "https://github.com/OrchestratorInc/agent-orchestrator/releases/tag/v${version}";
          license = lib.licenses.asl20;
          sourceProvenance = [ lib.sourceTypes.fromSource ];
          maintainers = [ lib.maintainers.asterismono ];
          mainProgram = "agent-orchestrator";
          platforms = [ "x86_64-linux" ];
        };
      };
    in
    frontend;
in
{
  perSystem =
    { pkgs, ... }:
    {
      packages.agent-orchestrator = pkgs.callPackage package { };
    };
}
