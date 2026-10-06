_:
let
  package =
    {
      lib,
      stdenv,
      buildNpmPackage,
      nodejs_22,
      python3,
      makeWrapper,
      autoPatchelfHook,
      libuv,
      paseo-desktop,
    }:
    buildNpmPackage {
      pname = "paseo";
      inherit (paseo-desktop)
        src
        version
        npmDeps
        npmDepsHash
        ;

      nodejs = nodejs_22;
      npmDepsFetcherVersion = 2;
      # Avoid downloading onnxruntime binaries; rebuild only node-pty below.
      npmRebuildFlags = [ "--ignore-scripts" ];

      nativeBuildInputs = [
        python3
        makeWrapper
      ]
      ++ lib.optionals stdenv.hostPlatform.isLinux [ autoPatchelfHook ];

      buildInputs = lib.optionals stdenv.hostPlatform.isLinux [
        libuv
        stdenv.cc.cc.lib
      ];

      dontNpmBuild = true;

      buildPhase = ''
        runHook preBuild

        rm -rf packages/server/node_modules/node-pty/prebuilds
        npm rebuild node-pty --workspace=@getpaseo/server
        npm run build:server
        npm run build:daemon-web-ui

        runHook postBuild
      '';

      installPhase = ''
        runHook preInstall

        mkdir -p $out/lib/paseo
        node scripts/trace-daemon.mjs > daemon-files.txt

        # node-pty loads the compiled addon and spawn helper through computed
        # paths, outside the static trace.
        find packages/server/node_modules/node-pty/build/Release -maxdepth 1 -type f \
          >> daemon-files.txt
        # Terminal hooks resolve the CLI package through its workspace link.
        printf '%s\n' node_modules/@getpaseo/cli >> daemon-files.txt
        sort -u -o daemon-files.txt daemon-files.txt

        while IFS= read -r path; do
          [ -z "$path" ] && continue
          mkdir -p "$out/lib/paseo/$(dirname "$path")"
          cp -a "$path" "$out/lib/paseo/$path"
        done < daemon-files.txt

        cp package.json $out/lib/paseo/
        cp -r packages/server/dist/server/web-ui $out/lib/paseo/packages/server/dist/server/
        # Terminal hooks invoke this script directly, outside the CLI wrapper.
        patchShebangs --build $out/lib/paseo/packages/cli/bin/paseo

        mkdir -p $out/bin
        # Paseo's runtime mode is separate from agents' inherited NODE_ENV.
        makeWrapper ${nodejs_22}/bin/node $out/bin/paseo-server \
          --add-flags "$out/lib/paseo/packages/server/dist/scripts/supervisor-entrypoint.js" \
          --set PASEO_NODE_ENV production
        makeWrapper ${nodejs_22}/bin/node $out/bin/paseo \
          --add-flags "$out/lib/paseo/packages/cli/dist/index.js" \
          --set NODE_PATH "$out/lib/paseo/node_modules" \
          --set PASEO_NODE_ENV production

        runHook postInstall
      '';

      meta = {
        description = "Self-hosted daemon for Claude Code, Codex, and OpenCode";
        homepage = "https://github.com/getpaseo/paseo";
        license = lib.licenses.asl20;
        maintainers = [ lib.maintainers.asterismono ];
        mainProgram = "paseo";
        platforms = lib.platforms.linux ++ lib.platforms.darwin;
      };
    };

in
{
  perSystem =
    { config, pkgs, ... }:
    {
      packages.paseo-daemon = pkgs.callPackage package {
        inherit (config.packages) paseo-desktop;
      };
    };
}
