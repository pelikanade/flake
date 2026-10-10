_:
let
  # Tern is closed source and, during its closed beta, published only through
  # Stencil's build service. That service answers an unauthenticated request with
  # a redirect to auth.stencil.so, so fetchurl cannot take it and no Nix build can
  # reach it. requireFile pins the artifact and names the missing tarball, and the
  # build succeeds only once its hash is in the store. See docs/tern.md.
  build = "20261010-153042-487bca1";

  package =
    {
      lib,
      stdenv,
      requireFile,
      autoPatchelfHook,
      makeWrapper,
      versionCheckHook,
      desktop-file-utils,
      git,
      gtk3,
      xdg-utils,
      vulkan-loader,
      libGL,
      libxkbcommon,
      libxcb,
      wayland,
      webkitgtk_4_1,
    }:
    stdenv.mkDerivation (finalAttrs: {
      pname = "tern";
      version = "0.7.1";

      # The glibc artifact. NixOS is glibc, and the published musl artifact needs
      # /lib/ld-musl-x86_64.so.1 plus a musl libstdc++, so it saves nothing here.
      src = requireFile {
        name = "Tern-${finalAttrs.version}-linux-x86_64.tar.gz";
        url = "https://build.stencil.so/d/tern/${build}/Tern-${finalAttrs.version}-linux-x86_64.tar.gz";
        hash = "sha256-cLJAECXSNFYLJZgi9XeOxOhjmb01Ce2It2eI8tJOA9w=";
      };

      # The archive holds tern/tern and nothing else.
      unpackPhase = ''
        runHook preUnpack
        tar -xzf "$src"
        runHook postUnpack
      '';
      sourceRoot = "tern";

      dontConfigure = true;
      dontBuild = true;

      nativeBuildInputs = [
        autoPatchelfHook
        makeWrapper
      ];

      # Beyond glibc, which the stdenv supplies, Tern links only libstdc++ and
      # libgcc_s.
      buildInputs = [ stdenv.cc.cc.lib ];

      # Tern draws through wgpu, which dlopens Vulkan, EGL and the Wayland client
      # instead of linking them, so patchelf sees no DT_NEEDED entry for any of
      # them. RUNPATH is what dlopen from the executable itself reads. The GPU
      # driver is not in the store: autoPatchelfHook replaces the RUNPATH
      # addDriverRunpath would have set, so that path is appended here instead.
      appendRunpaths = [
        (lib.makeLibraryPath [
          vulkan-loader
          libGL
          libxkbcommon
          # 0.6.0's windowing dlopens libxcb.so.1 for the X11 backend and says
          # "failed to load libxcb" without it; libxkbcommon already carries the
          # libxkbcommon-x11.so.0 that pairs with it.
          libxcb
          wayland
          # The browser pane finds its engine by dlopening libWPEWebKit-2.0.so.1
          # and then libwebkit2gtk-4.1.so.0, which is the name Tern's own error
          # asks for. No WPE build is provided, so the GTK one is what answers;
          # webkit2gtk carries the RUNPATHs of everything it needs itself, so its
          # lib directory is the whole requirement.
          webkitgtk_4_1
        ])
        "/run/opengl-driver/lib"
      ];

      installPhase = ''
        runHook preInstall
        install -Dm755 tern $out/bin/tern
        runHook postInstall
      '';

      # git serves `tern plugin install`, and `tern register` shells out to the
      # desktop entry, icon and MIME caches.
      postFixup = ''
        mv $out/bin/tern $out/bin/.tern-wrapped
        makeWrapper $out/bin/.tern-wrapped $out/bin/tern \
          --prefix PATH : ${
            lib.makeBinPath [
              desktop-file-utils
              git
              gtk3
              xdg-utils
            ]
          }
      '';

      # Runs the patched, wrapped binary: the only check that proves the artifact
      # still loads against this nixpkgs.
      doInstallCheck = true;
      nativeInstallCheckInputs = [ versionCheckHook ];
      versionCheckProgramArg = "--version";

      meta = {
        description = "Native multiplexing terminal for panes, files and remote sessions";
        homepage = "https://stencil.so/tern";
        # Nothing here can be rebuilt or redistributed: the artifact is the
        # product, and the build service gates it behind a Stencil account.
        license = lib.licenses.unfree;
        sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
        maintainers = [ lib.maintainers.asterismono ];
        mainProgram = "tern";
        platforms = [ "x86_64-linux" ];
      };
    });
in
{
  perSystem =
    { pkgsUnstable, ... }:
    {
      # pkgsUnstable is the one perSystem set that allows unfree packages, and
      # Tern has no free variant to take from the stable set.
      packages.tern = pkgsUnstable.callPackage package { };
    };
}
