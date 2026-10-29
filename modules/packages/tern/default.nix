_:
let
  # Tern is closed source and, during its closed beta, published only through
  # Stencil's build service. That service answers an unauthenticated request with
  # a redirect to auth.stencil.so, so fetchurl cannot take it and no Nix build can
  # reach it. requireFile pins the artifact and names the missing tarball, and the
  # build succeeds only once its hash is in the store. See docs/tern.md.
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
      glib,
      gtk3,
      xdg-utils,
      vulkan-loader,
      libGL,
      libxkbcommon,
      libxcb,
      wayland,
      webkitgtk_4_1,
      waylandIme,
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
          # The input-method shadow has to be found before the wayland client it
          # shadows, and by every launch path: `tern register` writes the desktop
          # entries with the path of the executable it runs from, which is the
          # wrapped binary, so a launcher starts Tern without the wrapper's
          # environment. RUNPATH is what the executable's own dlopen reads, so
          # this is where the shadow belongs (shim.c carries the story).
          waylandIme
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
      # through `gdbus` from glib. The input-method shadow needs no variable
      # here: it rides the RUNPATH above, which `tern register` cannot strip
      # from a launch the way it strips a wrapper's environment.
      postFixup = ''
        mv $out/bin/tern $out/bin/.tern-wrapped
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
      '';

      doInstallCheck = true;
      nativeInstallCheckInputs = [ versionCheckHook ];
      versionCheckProgramArg = "--version";

      # The shadow only works if the executable's own RUNPATH resolves
      # `libwayland-client.so.0` to it, with no LD_LIBRARY_PATH in play — that
      # is the environment a launcher gives a registered desktop entry. Reuse
      # the built binary's RUNPATH on a probe that performs the same dlopen, so
      # a regression in how the shadow is delivered fails the build rather than
      # silently returning to env-only delivery.
      installCheckPhase = ''
        runHook preInstallCheck

        cat > probe.c <<'EOF'
        #define _GNU_SOURCE
        #include <dlfcn.h>
        #include <stdio.h>

        int main(void) {
          void *handle = dlopen("libwayland-client.so.0", RTLD_NOW | RTLD_LOCAL);
          if (!handle) {
            fprintf(stderr, "dlopen: %s\n", dlerror());
            return 1;
          }
          /* An interposed symbol: delegating ones report the real library, so
             the shadow is identified by the functions it defines itself. */
          Dl_info info;
          if (!dladdr(dlsym(handle, "wl_proxy_add_dispatcher"), &info)) {
            fprintf(stderr, "no wl_proxy_add_dispatcher\n");
            return 1;
          }
          puts(info.dli_fname);
          return 0;
        }
        EOF

        $CC -o probe probe.c -ldl

        # The probe keeps its own RUNPATH so the loader still finds libc, and
        # gains Tern's ahead of it, which is the order the real process sees.
        probeRunpath="$(patchelf --print-rpath $out/bin/.tern-wrapped):$(patchelf --print-rpath probe)"
        patchelf --set-rpath "$probeRunpath" probe

        resolved="$(env --ignore-environment ./probe)"
        if [ "$resolved" != "${waylandIme}/lib/libwayland-client.so.0" ]; then
          echo "libwayland-client.so.0 resolves to '$resolved', not the shadow" >&2
          exit 1
        fi

        runHook postInstallCheck
      '';

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
    { pkgsUnstable, self', ... }:
    {
      # pkgsUnstable is the one perSystem set that allows unfree packages, and
      # Tern has no free variant to take from the stable set.
      packages.tern = pkgsUnstable.callPackage package {
        waylandIme = self'.packages."tern-wayland-ime";
      };
    };
}
