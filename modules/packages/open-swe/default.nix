{ inputs, ... }:
{
  flake-file.inputs = {
    pyproject-nix = {
      url = "github:pyproject-nix/pyproject.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    uv2nix = {
      url = "github:pyproject-nix/uv2nix";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        pyproject-nix.follows = "pyproject-nix";
      };
    };
    pyproject-build-systems = {
      url = "github:pyproject-nix/build-system-pkgs";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        pyproject-nix.follows = "pyproject-nix";
        uv2nix.follows = "uv2nix";
      };
    };
    open-swe = {
      url = "github:langchain-ai/open-swe/7755cc730c860c2d6803d8c01d550981c4263977";
      flake = false;
    };
  };

  perSystem =
    { pkgs, pkgsUnstable, ... }:
    let
      src = inputs.open-swe;
      version = "0.1.0-unstable-2026-10-11";
      workspace = inputs.uv2nix.lib.workspace.loadWorkspace { workspaceRoot = src; };
      pythonSet =
        (pkgs.callPackage inputs.pyproject-nix.build.packages {
          python = pkgs.python314;
        }).overrideScope
          (
            pkgs.lib.composeManyExtensions [
              inputs.pyproject-build-systems.overlays.wheel
              (workspace.mkPyprojectOverlay { sourcePreference = "wheel"; })
              (
                final: prev:
                pkgs.lib.genAttrs [ "bsdiff4" "forbiddenfruit" ] (
                  name:
                  # These source distributions omit setuptools build metadata.
                  prev.${name}.overrideAttrs (old: {
                    nativeBuildInputs =
                      old.nativeBuildInputs
                      ++ final.resolveBuildSystem {
                        setuptools = [ ];
                      };
                  })
                )
              )
              (_final: prev: {
                wasmtime = prev.wasmtime.overrideAttrs (old: {
                  # 49.0.0's "any" wheel contains only a Windows DLL. Select the
                  # host's manylinux artifact while retaining uv.lock's hash.
                  src =
                    let
                      lock = builtins.fromTOML (builtins.readFile "${src}/uv.lock");
                      package = pkgs.lib.findFirst (p: p.name == "wasmtime") null lock.package;
                      wheel = pkgs.lib.findFirst (
                        w:
                        pkgs.lib.hasInfix "-manylinux" w.url
                        && pkgs.lib.hasSuffix "_${pkgs.stdenv.hostPlatform.parsed.cpu.name}.whl" w.url
                      ) (throw "Open SWE: no locked Wasmtime wheel for this platform") package.wheels;
                    in
                    pkgs.fetchurl {
                      inherit (wheel) url;
                      sha256 = pkgs.lib.removePrefix "sha256:" wheel.hash;
                    };
                  buildInputs = (old.buildInputs or [ ]) ++ [ pkgs.stdenv.cc.cc.lib ];
                });
              })
            ]
          );
      backend = pythonSet.mkVirtualEnv "open-swe-env-${version}" {
        open-swe-agent = [ ];
      };
      dashboard = import ./_dashboard.nix { inherit pkgs src version; };
      upstreamConfig = builtins.fromJSON (builtins.readFile "${src}/langgraph.json");
      runtimeConfig = pkgs.writeText "open-swe-langgraph.json" (
        builtins.toJSON (
          (builtins.removeAttrs upstreamConfig [
            "env"
            "dockerfile_lines"
          ])
          // {
            # The CLI requires a dependency; Nix has already installed this one.
            dependencies = [ "open-swe-agent" ];
          }
        )
      );
    in
    {
      # The bundled LangGraph runtime uses Elastic-2.0. Reuse the repository's
      # unfree-enabled package set for the launcher; build dependencies stay stable.
      packages.open-swe = pkgsUnstable.stdenvNoCC.mkDerivation {
        pname = "open-swe";
        inherit version;
        dontUnpack = true;
        nativeBuildInputs = [ pkgs.makeWrapper ];

        installPhase = ''
          runHook preInstall
          mkdir -p "$out/share/open-swe"
          ln -s ${dashboard} "$out/share/open-swe/dashboard"
          ln -s ${runtimeConfig} "$out/share/open-swe/langgraph.json"
          printf '%s\n' '${builtins.toJSON { commit = src.rev; }}' \
            > "$out/share/open-swe/open-swe-build-info.json"
          makeWrapper ${backend}/bin/langgraph "$out/bin/open-swe" \
            --add-flags "dev --config ${runtimeConfig} --no-browser --no-reload" \
            --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.gh ]} \
            --set-default DASHBOARD_STATIC_DIR ${dashboard} \
            --set-default OPEN_SWE_BUILD_INFO_DIR "$out/share/open-swe"
          runHook postInstall
        '';

        doInstallCheck = true;
        installCheckPhase = ''
          runHook preInstallCheck
          ${backend}/bin/python - <<'PY'
          from quickjs_rs import Runtime
          with Runtime() as runtime:
              with runtime.new_context() as context:
                  assert context.eval("6 * 7") == 42
          PY
          runHook postInstallCheck
        '';

        passthru = { inherit backend dashboard; };
        meta = {
          description = "Open SWE development server with its web dashboard";
          homepage = "https://github.com/langchain-ai/open-swe";
          license = [
            pkgs.lib.licenses.mit
            pkgs.lib.licenses.elastic20
          ];
          mainProgram = "open-swe";
          platforms = [
            "x86_64-linux"
            "aarch64-linux"
          ];
        };
      };
    };
}
