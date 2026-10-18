{ inputs, ... }:
let
  package =
    {
      lib,
      buildGoModule,
      go,
      fetchFromGitHub,
      bun,
      pkg-config,
      wrapGAppsHook3,
      copyDesktopItems,
      makeDesktopItem,
      gtk3,
      webkitgtk_4_1,
      glib-networking,
      gst_all_1,
      xdg-utils,
      desktop-file-utils,
      coreutils,
      dbus,
      python3,
      bash,
      procps,
      versionCheckHook,
      grok,
      claude-code,
    }:
    (buildGoModule.override { inherit go; }) (finalAttrs: {
      pname = "magpie";
      version = "0.1.1275";

      src = fetchFromGitHub {
        owner = "yetone";
        repo = "magpie";
        tag = "v${finalAttrs.version}";
        hash = "sha256-KbzRWxEWQD2cycXzflCyBPbwAWoLyaoY5uNPNgsO6ko=";
      };

      vendorHash = "sha256-pBk3sQZ9/1sVdz2ZteBGgQrI49fDfgsQ8ur7pzM477A=";

      subPackages = [ "." ];
      tags = [
        "production"
        "gtk3"
      ];
      ldflags = [
        "-s"
        "-w"
        "-X main.version=${finalAttrs.version}"
      ];

      nativeBuildInputs = [
        pkg-config
        wrapGAppsHook3
        copyDesktopItems
      ];
      buildInputs = [
        gtk3
        webkitgtk_4_1
        glib-networking
        gst_all_1.gstreamer
        gst_all_1.gst-plugins-base
        gst_all_1.gst-plugins-good
        gst_all_1.gst-libav
      ];

      postPatch = ''
        # Updates belong to Nix; never ask polkit to replace the store binary,
        # and never download a release the store cannot take.
        substituteInPlace internal/gui/update.go \
          --replace-fail '// canElevate is update.CanElevate, inContainer gateway.InContainer; tests' \
          '// canElevate never elevates under Nix, inContainer is gateway.InContainer; tests' \
          --replace-fail $'\tcanElevate  = update.CanElevate' \
          $'\tcanElevate  = func() bool { return false }'
        substituteInPlace internal/cli/update_cli.go \
          --replace-fail $'\tfmt.Println(muted.Render("  downloading " + update.BinaryAsset() + via(ctx) + " …"))\n\tif err := update.ReplaceBinary(ctx, rel); err != nil {\n\t\treturn err\n\t}\n\tfmt.Println(green.Render("✓"), "updated to", rel.Version)\n\treturn nil' \
          $'\treturn fmt.Errorf("this magpie is managed by Nix; update its Nix package instead")'

        # A failed init call races the host's own death: the write to its stdin
        # hits EPIPE as soon as the host is gone, before the reader goroutine
        # has seen EOF, so the host was not counted as crashed and a Bun that
        # cannot start it stayed in use instead of the previous one being tried.
        # TestHostFallsBackWhenTheNewBunDies fails on that race, and a broken
        # stdin pipe is proof the host is gone.
        sed -i 's|"sync/atomic"|"sync/atomic"\n\t"syscall"|' internal/plugin/host.go
        substituteInPlace internal/plugin/host.go \
          --replace-fail 'crashed := !h.alive()' \
          'crashed := !h.alive() || errors.Is(err, syscall.EPIPE)'

        # Scheme registration shadows the packaged desktop item. Use the profile
        # command, not a store path that becomes stale after an upgrade and GC.
        substituteInPlace internal/gui/scheme_linux.go \
          --replace-fail $'exe, err := os.Executable()\n\tif err != nil {\n\t\treturn err\n\t}' \
          'exe := "magpie"'

        # Login startup must retain the GTK wrapper.
        substituteInPlace internal/autostart/autostart.go \
          --replace-fail 'exe, err := os.Executable()' \
          'exe, err := os.Executable(); if filepath.Base(exe) == ".magpie-wrapped" { exe = filepath.Join(filepath.Dir(exe), "magpie") }'
      '';

      nativeCheckInputs = [
        dbus
        bun
        procps
      ];
      preCheck = ''
        export MAGPIE_BUN="${lib.getExe bun}"
        substituteInPlace internal/gui/scheme_linux_test.go \
          --replace-fail 'exe, err := os.Executable()' '_, err := os.Executable()' \
          --replace-fail '"Exec="+exe+" %u\n"' '"Exec=magpie %u\n"'
        substituteInPlace internal/agent/omp_wsl_key_test.go \
          --replace-fail '#!/usr/bin/env bun' '#!${coreutils}/bin/env bun' \
          --replace-fail ':/usr/bin:/bin' ':${lib.makeBinPath [ coreutils ]}'
        substituteInPlace internal/gateway/automode_test.go \
          --replace-fail '#!/usr/bin/env python3' '#!${lib.getExe python3}'
        # The fake CLIs deliberately clear PATH, so use absolute store paths.
        substituteInPlace internal/agent/cliupdate_test.go internal/library/rtk_upgrade_test.go \
          --replace-fail '/bin/cat' '${coreutils}/bin/cat'
        substituteInPlace internal/agent/cliupdate_admin_test.go internal/daemon/daemon_test.go \
          --replace-fail '/bin/cat' '${coreutils}/bin/cat'
        # The WSL probe resolves nvm versions with ls and sort and reads nvm.sh
        # with bash, none of which the PATH the test gives it reaches.
        substituteInPlace internal/agent/wsl_nvm_test.go \
          --replace-fail ':/usr/bin:/bin' ':${
            lib.makeBinPath [
              coreutils
              bash
            ]
          }'
        # The fish stand-in prints its answer through a PATH of its own.
        substituteInPlace internal/proc/path_other_test.go \
          --replace-fail "#!/bin/sh\ncat '" "#!/bin/sh\n${coreutils}/bin/cat '"
        # The rtk and keychain stand-ins are shell scripts reaching for
        # absolute paths the sandbox has no /bin for.
        substituteInPlace internal/library/rtk_test.go internal/library/rtk_agy_test.go \
          --replace-fail '/bin/mkdir' '${coreutils}/bin/mkdir' \
          --replace-fail '/bin/cat' '${coreutils}/bin/cat'
        substituteInPlace internal/provider/codex_keychain_ask_unix_test.go \
          --replace-fail '/bin/sleep' '${coreutils}/bin/sleep'
        substituteInPlace internal/gui/providers_fetching_unix_test.go \
          --replace-fail '"/usr/bin"+string(os.PathListSeparator)+"/bin"' \
          '"${lib.makeBinPath [ coreutils ]}"' \
          --replace-fail $'\t"os"\n' '''
        substituteInPlace internal/agent/zed_credential_secret_test.go \
          --replace-fail '"--session"' '"--config-file=${dbus}/share/dbus-1/session.conf"'
        substituteInPlace internal/proc/proc_test.go internal/sqlitedb/sqlitedb_test.go \
          --replace-fail 'd.Name() == "node_modules"' \
          'd.Name() == "node_modules" || d.Name() == "vendor"'
        # The fake Claude Code logs the request line through the sandbox's
        # shell, whose echo leaves a JSON string's escapes alone. printf writes
        # the line as it arrived, so the assertion reads the sent form.
        substituteInPlace internal/gateway/claude_resume_test.go \
          --replace-fail 'echo "told $line" >> $log' \
          'printf "told %s\n" "$line" >> $log'
        substituteInPlace internal/gateway/claude_client_cache_test.go \
          --replace-fail '\\u003cexternal_system_instructions\\u003e\nshared\n\\u003c/external_system_instructions\\u003e\n\n' \
          '\\u003cexternal_system_instructions\\u003e\\nshared\\n\\u003c/external_system_instructions\\u003e\\n\\n'
      '';
      checkPhase = ''
        runHook preCheck
        go test -tags=production,gtk3 ./...
        runHook postCheck
      '';

      preFixup = ''
        # Use a Nix-managed runtime instead of downloading generic Linux Bun.
        gappsWrapperArgs+=(--set-default MAGPIE_BUN "${lib.getExe bun}")
        gappsWrapperArgs+=(--suffix PATH : "${
          lib.makeBinPath [
            grok
            claude-code
          ]
        }")
        gappsWrapperArgs+=(--prefix PATH : "${
          lib.makeBinPath [
            xdg-utils
            desktop-file-utils
          ]
        }" --unset APPIMAGE)
      '';

      postInstall = ''
        # 1024x1024 is not indexed by the standard hicolor theme.
        for size in 16 32 48 64 128 256; do
          install -Dm644 build/windows/icon-$size.png \
            $out/share/icons/hicolor/''${size}x$size/apps/magpie.png
        done
      '';

      desktopItems = [
        (makeDesktopItem {
          name = "magpie";
          desktopName = "Magpie";
          comment = "Manage AI agents' models and providers";
          exec = "magpie %u";
          icon = "magpie";
          categories = [ "Development" ];
          mimeTypes = [ "x-scheme-handler/magpie" ];
        })
      ];

      doInstallCheck = true;
      nativeInstallCheckInputs = [ versionCheckHook ];
      preInstallCheck = ''
        export HOME="$TMPDIR/install-check-home"
        export XDG_CONFIG_HOME="$HOME/.config"
        export XDG_CACHE_HOME="$HOME/.cache"
        mkdir -p "$HOME"
      '';
      postInstallCheck = ''
        unset MAGPIE_BUN
        cp internal/plugin/testdata/fake/index.js "$HOME/nix-test-plugin.js"
        $out/bin/magpie plugin add "$HOME/nix-test-plugin.js"
        $out/bin/magpie plugin list --json > "$TMPDIR/plugins.json"
        grep -q '"id": "fakeco"' "$TMPDIR/plugins.json"
        test ! -e "$XDG_CACHE_HOME/magpie/bun/${bun.version}/bun"
      '';
      versionCheckProgramArg = "--version";

      meta = {
        description = "Desktop and terminal interface for managing AI agents' models and providers";
        homepage = "https://github.com/yetone/magpie";
        changelog = "https://github.com/yetone/magpie/releases/tag/v${finalAttrs.version}";
        license = lib.licenses.mit;
        maintainers = [ lib.maintainers.asterismono ];
        mainProgram = "magpie";
        platforms = lib.platforms.linux;
      };
    });
in
{
  perSystem =
    {
      pkgs,
      pkgsUnstable,
      ...
    }:
    {
      # Magpie never runs a Bun older than its BunVersion floor (1.4.2), which
      # nixos-26.05 does not carry yet; take the unstable set's Bun and leave the
      # rest of the build on stable. Its go.mod demands go >= 1.26.8, past the
      # channel's default Go (1.26.7), so build with the channel's newer go_1_27
      # rather than with another package set's toolchain.
      packages.magpie = pkgs.callPackage package {
        inherit (pkgsUnstable) bun;
        go = pkgs.go_1_27;
        inherit (inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}) grok claude-code;
      };
    };
}
