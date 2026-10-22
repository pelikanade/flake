# Copied from Mooling0602/nix-packages (pkgs/by-name/de/deepseek-harness-git)
# by Mooling0602: https://github.com/Mooling0602/nix-packages
{ inputs, ... }:
{
  # The package resolves pnpm-lock.yaml integrity hashes through
  # importPnpmLock/iplConfigHook, which nixpkgs does not provide. Pinned to the
  # revision the copied package was built against.
  flake-file.inputs.importPnpmLock = {
    url = "git+https://tangled.org/scrumplex.net/importPnpmLock.nix?rev=4bd9cc54e6a5431930b4d09898e1ef49cb2ed241";
    inputs = {
      nixpkgs.follows = "nixpkgs";
      systems.follows = "systems";
    };
  };

  perSystem =
    { pkgsUnstable, ... }:
    let
      pkgs = pkgsUnstable.extend inputs.importPnpmLock.overlays.default;
      inherit (pkgs)
        bashInteractive
        bubblewrap
        fetchFromGitHub
        fetchurl
        lib
        makeWrapper
        nodejs_24
        stdenv
        versionCheckHook
        ;
      inherit (pkgs) importPnpmLock iplConfigHook;

      pname = "deepseek-harness-git";

      versionData = lib.importJSON ./hashes.json;
      inherit (versionData) version rev;

      src = fetchFromGitHub {
        owner = "deepseek-ai";
        repo = "deepseek-harness";
        inherit rev;
        hash = versionData.srcHash;
      };

      # Upstream maintains pnpm-lock.yaml with the `packageManager` pin from the
      # root package.json (currently pnpm@${versionData.pnpmVersion}). nixpkgs
      # pnpm 11.22 changed offline / supply-chain behaviour in ways that reject
      # these lockfiles, so run the exact pinned pnpm through nixpkgs nodejs
      # (same approach as openfic-git).
      pnpm' = stdenv.mkDerivation {
        pname = "pnpm-for-deepseek-harness";
        version = versionData.pnpmVersion;

        src = fetchurl {
          url = "https://registry.npmjs.org/pnpm/-/pnpm-${versionData.pnpmVersion}.tgz";
          hash = versionData.pnpmHash;
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
        lockFile = ./pnpm-lock.yaml;
      };

      # The runtime resolver reaches Node's internal module loader through the
      # prebuilt `node-addon-require-builtin` binary, which cannot locate V8's
      # `builtin_module_require` getter in nixpkgs' GCC-built Node (see
      # installPhase). The launcher already passes `--expose-internals`, so the
      # accessor can fall back to a plain `require` before touching the addon.
      addonRequireBuiltin = "    return api.requireBuiltin(moduleId);";
      addonRequireBuiltinPatched =
        "    if (process.execArgv.includes('--expose-internals')) {\n"
        + "      try { return require(moduleId); } catch (_error) {}\n"
        + "    }\n"
        + "    return api.requireBuiltin(moduleId);";

    in
    {
      packages.deepseek-harness-git = stdenv.mkDerivation {
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
        ];

        env = {
          # Never let an interactive prompt block the sandbox (module purges).
          CI = "true";
          DSH_TELEMETRY_DISABLED = "1";
          # build.ts wants `git rev-parse HEAD`; the tarball has no .git, so pass
          # the pinned rev explicitly (sliced to 7 chars upstream).
          DSH_CLIENT_COMMIT_HASH = rev;
        };

        buildPhase = ''
          runHook preBuild

          pnpm run build:official

          runHook postBuild
        '';

        installPhase = ''
          runHook preInstall

          mkdir -p "$out/lib/${pname}"
          cp -a -T . "$out/lib/${pname}"

          # pnpm leaves a few dangling links for optional platform binaries it did
          # not materialize (dev tooling like @oxlint-tsgolint and the aliased
          # @openai/codex platform alias; the published npm package ships neither).
          find "$out/lib/${pname}" -xtype l -delete

          # 0.1.7 removed upstream's pure-JS `link` profile resolution mode, so the
          # runtime resolver now reaches Node's internal module loader exclusively
          # through the prebuilt `node-addon-require-builtin` N-API binary. That
          # binary locates V8's `builtin_module_require` getter by pattern-matching
          # the machine code of a known Node build; nixpkgs compiles Node with GCC,
          # whose codegen for that getter differs from the upstream release binaries
          # (an extra `xor edi,edi` before `ret`), so every `requireBuiltin` call
          # fails with `Unsupported/no-getter (x64 sysv getter is not a recognized
          # this->field accessor)` and boot aborts. `--expose-internals` exposes the
          # very same internal modules through a plain `require`, so try that first
          # and fall back to the native addon — the same order the vendored Cordis
          # loader uses (vendor/loader/src/internal.ts). Patch the addon package
          # rather than upstream's resolver source: its entry file is stable across
          # releases and is shared by the host and the Worker resolution bootstrap.
          while IFS= read -r addonEntry; do
            substituteInPlace "$addonEntry" \
              --replace-fail "${addonRequireBuiltin}" "${addonRequireBuiltinPatched}"
          done < <(find "$out/lib/${pname}" -path '*node-addon-require-builtin/lib/index.js' -type f)

          # /bin/bash does not exist on NixOS (issue #8086)
          substituteInPlace \
            "$out/lib/${pname}/packages/terminal/terminal-bash/lib/index.js" \
            --replace-fail '"/bin/bash"' '"${lib.getExe bashInteractive}"'

          # dsh-sandbox-local probes `bwrap` from PATH for its preferred Linux
          # sandbox backend (chain: bwrap, then landlock); the landlock launcher's
          # optional platform package is not materialized by the offline pnpm
          # install, so bwrap is the only working backend here.
          makeWrapper "${nodejs_24}/bin/node" "$out/bin/dsh" \
            --argv0 dsh \
            --prefix PATH : ${lib.makeBinPath [ bubblewrap ]} \
            --add-flags "--expose-internals" \
            --add-flags "$out/lib/${pname}/apps/cli/lib/bin.js"

          runHook postInstall
        '';

        doInstallCheck = true;
        nativeInstallCheckInputs = [
          versionCheckHook
        ];
        versionCheckProgramArg = "--version";

        passthru.update = {
          kind = "script";
          label = "dsh";
          script = "modules/packages/deepseek-harness-git/update.sh";
          files = [
            "modules/packages/deepseek-harness-git/hashes.json"
            "modules/packages/deepseek-harness-git/pnpm-lock.yaml"
          ];
          versionFile = "modules/packages/deepseek-harness-git/hashes.json";
        };

        meta = {
          description = "Open-source agent harness and CLI developed by DeepSeek AI (built from git release tags)";
          homepage = "https://github.com/deepseek-ai/deepseek-harness";
          changelog = "https://github.com/deepseek-ai/deepseek-harness/releases/tag/dsh-v${version}";
          license = lib.licenses.mit;
          sourceProvenance = with lib.sourceTypes; [
            # node-pty ships prebuilt platform bindings in prebuilds/
            binaryBytecode
            fromSource
          ];
          maintainers = [ ];
          mainProgram = "dsh";
          platforms = [ "x86_64-linux" ];
        };
      };
    };
}
