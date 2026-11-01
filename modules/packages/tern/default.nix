_:
let
  # Tern is closed source and, during its closed beta, published only through
  # Stencil's build service. That service answers an unauthenticated request with
  # a redirect to auth.stencil.so, so fetchurl cannot take it and no Nix build can
  # reach it. requireFile pins the artifact and names the missing tarball, and the
  # build succeeds only once its hash is in the store.
  package =
    {
      lib,
      stdenv,
      requireFile,
      autoPatchelfHook,
      makeWrapper,
      makeDesktopItem,
      copyDesktopItems,
      versionCheckHook,
      desktop-file-utils,
      git,
      glib,
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
      version = "0.9.5";

      # The glibc artifact. NixOS is glibc, and the published musl artifact needs
      # /lib/ld-musl-x86_64.so.1 plus a musl libstdc++, so it saves nothing here.
      #
      # The service's download ids are per-build and only visible to a signed-in
      # account, so the URL is its version-independent product path; the hash is
      # what pins the build.
      src = requireFile {
        name = "Tern-${finalAttrs.version}-linux-x86_64.tar.gz";
        url = "https://build.stencil.so/d/tern/latest/Tern-${finalAttrs.version}-linux-x86_64.tar.gz";
        hash = "sha256-ApOSXrYtSrfOLOuLx17Ox6xYNeh+awudb+vn0MgKzlI=";
      };

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
        copyDesktopItems
      ];

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
          # The windowing dlopens libxcb.so.1 for the X11 backend and says
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

      # git serves `tern plugin install`, `tern register` shells out to the
      # desktop entry, icon and MIME caches, and the settings portal is read
      # through `gdbus` from glib.
      postFixup = ''
        mv $out/bin/tern $out/bin/.tern-wrapped

        # autoPatchelfHook's own postFixup hook runs after this one, and
        # `tern register` below has to execute the binary, which has no
        # interpreter until it has been patched. Patch it here; the hook's pass
        # then finds nothing left to do.
        autoPatchelf "$out"

        makeWrapper $out/bin/.tern-wrapped $out/bin/tern \
          --prefix PATH : ${
            lib.makeBinPath [
              desktop-file-utils
              git
              glib
              gtk3
              xdg-utils
            ]
          }

        # A launch from a package store never writes desktop integration itself
        # ("desktop integration left to the package store"); only `tern
        # register` does, and it is also the only thing that renders the icons.
        # Take the icons from it here, into a throwaway home, rather than from a
        # copy that drifts with the version.
        export HOME="$TMPDIR/register-home"
        export XDG_DATA_HOME="$HOME/.local/share"
        export XDG_CONFIG_HOME="$HOME/.config"
        export XDG_STATE_HOME="$HOME/.local/state"
        mkdir -p "$HOME"
        timeout 120 $out/bin/tern register
        icon_root="$XDG_DATA_HOME/icons"
        for icon in "$icon_root"/hicolor/*/apps/so.stencil.tern.png; do
          install -Dm644 "$icon" "$out/share/icons/''${icon#"$icon_root"/}"
        done
      '';

      # `tern register` writes these three entries, with Exec on the binary it
      # ran from — the unwrapped store path, which carries none of the wrapper's
      # PATH. The wrapper is what a launcher should start, so they name `tern`
      # on PATH instead, as the other agent desktops here do. Everything else is
      # upstream's: GNOME matches the window by StartupWMClass, and the file
      # types and the tern:// scheme are what Open With and a pairing link offer.
      desktopItems = [
        (makeDesktopItem {
          name = "so.stencil.tern";
          desktopName = "Tern";
          exec = "tern";
          icon = "so.stencil.tern";
          terminal = false;
          categories = [
            "System"
            "TerminalEmulator"
          ];
          startupWMClass = "so.stencil.tern";
          extraConfig."X-TerminalArgExec" = "-e";
        })
        (makeDesktopItem {
          name = "so.stencil.tern.url";
          desktopName = "Tern";
          exec = "tern --open-url %u";
          icon = "so.stencil.tern";
          noDisplay = true;
          terminal = false;
          mimeTypes = [ "x-scheme-handler/tern" ];
          startupWMClass = "so.stencil.tern";
        })
        (makeDesktopItem {
          name = "so.stencil.tern.open";
          desktopName = "Tern";
          exec = "tern --open-file %f";
          icon = "so.stencil.tern";
          noDisplay = true;
          terminal = false;
          mimeTypes = [
            "text/plain"
            "text/markdown"
            "text/x-source"
            "image/png"
            "image/jpeg"
            "image/gif"
            "image/webp"
            "image/svg+xml"
            "application/vnd.sqlite3"
            "application/x-sqlite3"
            "application/x-sqbpro"
            "application/x-ipynb+json"
            "inode/directory"
          ];
          startupWMClass = "so.stencil.tern";
        })
      ];

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
