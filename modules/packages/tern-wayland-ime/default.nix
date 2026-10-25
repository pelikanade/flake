_: {
  perSystem =
    { pkgsUnstable, ... }:
    let
      # The shadow is dlopened by the client as "libwayland-client.so.0" and has
      # to answer for the whole API behind that name, so it carries that SONAME
      # itself and names the real library among its dependencies. That
      # dependency is an absolute store path because the loader resolves a bare
      # SONAME through LD_LIBRARY_PATH, which is the shadow's own directory.
      #
      # It must be the same libwayland the consuming package links: two copies
      # in one process would mix proxy objects between their functions. Both
      # sides therefore take it from pkgsUnstable. lib.getLib reads the output
      # holding lib/ (the default one is out here, lib only says so explicitly).
      inherit (pkgsUnstable)
        lib
        patchelf
        stdenv
        wayland
        ;

      realLib = "${lib.getLib wayland}/lib/libwayland-client.so.0";
    in
    {
      # Sends the zwp_text_input_v3 disable() a client forgets when its surface
      # loses focus, which is what Hyprland needs to re-activate the input
      # method; shim.c carries the whole story. Tern is the consumer, through
      # LD_LIBRARY_PATH in its wrapper.
      packages.tern-wayland-ime = stdenv.mkDerivation {
        pname = "tern-wayland-ime";
        version = "1";

        # The directory holds shim.c and this expression; unpackPhase copies it
        # in, so the compiler sees ./shim.c.
        src = ./.;

        dontConfigure = true;

        buildPhase = ''
          runHook preBuild
          mkdir -p $out/lib
          $CC -shared -fPIC -O2 -Wall \
            ./shim.c \
            ${realLib} \
            -Wl,-soname,libwayland-client.so.0 \
            -o $out/lib/libwayland-client.so.0
          runHook postBuild
        '';

        nativeBuildInputs = [ patchelf ];

        # The link above records the SONAME, which the loader would look up in
        # LD_LIBRARY_PATH and find the shadow again: point the dependency at the
        # store path of the real library instead.
        postFixup = ''
          patchelf --replace-needed libwayland-client.so.0 ${realLib} \
            $out/lib/libwayland-client.so.0
        '';

        # The failure this catches is the wiring, not the code: a client asks
        # this library for the whole libwayland C API, so a shadow that cannot
        # answer for the real one behind it breaks the client outright. Probed
        # rather than reasoned about, because a wrong SONAME or dependency
        # resolves at load time and nowhere earlier.
        doInstallCheck = true;
        installCheckPhase = ''
          runHook preInstallCheck
          cat > probe.c <<'EOF'
          #include <dlfcn.h>
          #include <stdio.h>

          static const char *wanted[] = {
            "wl_display_connect",
            "wl_display_dispatch",
            "wl_display_flush",
            "wl_proxy_marshal_array",
            "wl_proxy_marshal_array_constructor_versioned",
            "wl_proxy_add_dispatcher",
            "wl_proxy_add_listener",
            "wl_proxy_get_display",
          };

          int main(int argc, char **argv) {
            if (argc != 2)
              return 2;

            void *handle = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
            if (!handle) {
              fprintf(stderr, "dlopen: %s\n", dlerror());
              return 1;
            }

            for (unsigned i = 0; i < sizeof(wanted) / sizeof(wanted[0]); i++) {
              if (!dlsym(handle, wanted[i])) {
                fprintf(stderr, "no %s\n", wanted[i]);
                return 1;
              }
            }

            return 0;
          }
          EOF
          $CC -o probe probe.c
          ./probe $out/lib/libwayland-client.so.0
          runHook postInstallCheck
        '';

        meta = {
          description = "libwayland-client shadow that sends the zwp_text_input_v3 disable clients forget";
          license = lib.licenses.mit;
          platforms = lib.platforms.linux;
        };
      };
    };
}
