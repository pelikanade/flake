_:
let
  package =
    {
      lib,
      buildGoModule,
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
      versionCheckHook,
    }:
    buildGoModule (finalAttrs: {
      pname = "magpie";
      version = "0.1.726";

      src = fetchFromGitHub {
        owner = "yetone";
        repo = "magpie";
        tag = "v${finalAttrs.version}";
        hash = "sha256-j7D8ZHPHYG1RIPPP/AYeA2C1QnfWMywiuCzLmbXJN54=";
      };

      vendorHash = "sha256-XEaHZVw3co0yUV6fLUlSkvg9LlroKFj2B2sjMW1e6BU=";

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
        # Updates belong to Nix; never ask polkit to replace the store binary.
        substituteInPlace internal/gui/update.go \
          --replace-fail '(update.Writable(filepath.Dir(exe)) || update.CanElevate())' \
          'update.Writable(filepath.Dir(exe))'
        substituteInPlace update_cli.go \
          --replace-fail 'ctx, cancel := context.WithTimeout(context.Background(), 10*time.Minute)' \
          'if len(args) < 2 || args[1] != "check" { return fmt.Errorf("this magpie is managed by Nix; update its Nix package instead") }; ctx, cancel := context.WithTimeout(context.Background(), 10*time.Minute)'

        # Desktop links and login startup must retain the GTK wrapper.
        substituteInPlace internal/gui/scheme_linux.go internal/autostart/autostart.go \
          --replace-fail 'exe, err := os.Executable()' \
          'exe, err := os.Executable(); if filepath.Base(exe) == ".magpie-wrapped" { exe = filepath.Join(filepath.Dir(exe), "magpie") }'
      '';

      nativeCheckInputs = [
        dbus
        bun
      ];
      preCheck = ''
        # The fake CLIs deliberately clear PATH, so use absolute store paths.
        substituteInPlace internal/agent/cliupdate_test.go internal/library/rtk_upgrade_test.go \
          --replace-fail '/bin/cat' '${coreutils}/bin/cat'
        substituteInPlace internal/library/rtk_test.go \
          --replace-fail '/bin/mkdir' '${coreutils}/bin/mkdir'
        substituteInPlace internal/gui/providers_fetching_unix_test.go \
          --replace-fail '"/usr/bin"+string(os.PathListSeparator)+"/bin"' \
          '"${lib.makeBinPath [ coreutils ]}"'
        substituteInPlace internal/agent/zed_credential_secret_test.go \
          --replace-fail '"--session"' '"--config-file=${dbus}/share/dbus-1/session.conf"'
        # This source-policy test applies only to Magpie, not vendored libraries.
        substituteInPlace internal/proc/proc_test.go \
          --replace-fail 'd.Name() == "node_modules"' \
          'd.Name() == "node_modules" || d.Name() == "vendor"'
      '';
      checkPhase = ''
        runHook preCheck
        go test -tags=production,gtk3 ./...
        runHook postCheck
      '';

      preFixup = ''
        # Use a Nix-managed runtime instead of downloading generic Linux Bun.
        gappsWrapperArgs+=(--set-default MAGPIE_BUN "${lib.getExe bun}")
        gappsWrapperArgs+=(--prefix PATH : "${
          lib.makeBinPath [
            xdg-utils
            desktop-file-utils
          ]
        }" --unset APPIMAGE)
      '';

      postInstall = ''
        install -Dm644 internal/gui/icon-1024.png \
          $out/share/icons/hicolor/1024x1024/apps/magpie.png
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
        # Exercise the installed wrapper and plugin host without network or auth.
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
      # rest of the build on stable.
      packages.magpie = pkgs.callPackage package { inherit (pkgsUnstable) bun; };
    };
}
