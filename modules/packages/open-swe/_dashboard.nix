{
  pkgs,
  src,
  version,
}:
let
  inherit (pkgs) lib;
  pnpm = pkgs.pnpm_11;
  pnpmWorkspaces = [ "open-swe-dashboard..." ];
in
pkgs.stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "open-swe-dashboard";
  inherit src version pnpmWorkspaces;

  pnpmDeps = pkgs.fetchPnpmDeps {
    inherit pnpm;
    inherit (finalAttrs)
      pname
      src
      version
      pnpmWorkspaces
      ;
    fetcherVersion = 4;
    hash = "sha256-5Sr6uUO69kXpmX4banF2cihBiyeGd4WJqutsC/vBJrg=";
  };

  nativeBuildInputs = [
    pkgs.nodejs_24
    pnpm
    pkgs.pnpmConfigHook
    pkgs.jq
    pkgs.writableTmpDirAsHomeHook
  ];

  # Rolldown, Oxc and Tailwind load native addons while compiling the UI.
  env = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
    LD_LIBRARY_PATH = lib.makeLibraryPath [ pkgs.stdenv.cc.cc.lib ];
  };

  postPatch = ''
    substituteInPlace ui/vite.config.ts \
      --replace-fail 'const BUNDLE_BUILD_AT = new Date().toISOString()' \
        'const BUNDLE_BUILD_AT = new Date(Number(process.env.SOURCE_DATE_EPOCH) * 1000).toISOString()'
  '';

  buildPhase = ''
    runHook preBuild

    export NODE_ENV=production
    export SOURCE_COMMIT=${lib.escapeShellArg src.rev}
    export DASHBOARD_BASE_PATH="$(jq -r '(.http.mount_prefix // "") + "/"' langgraph.json)"
    pnpm --filter open-swe-dashboard run build

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p "$out"
    cp -r ui/.output/public/. "$out/"

    runHook postInstall
  '';

  meta = {
    description = "Bundled web dashboard for Open SWE";
    homepage = "https://github.com/langchain-ai/open-swe";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
  };
})
