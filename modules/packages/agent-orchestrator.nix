_:
let
  # Orchestrator.inc (OrchestratorInc/agent-orchestrator, formerly
  # Untrivial-ai/agent-orchestrator and AgentWrapper/agent-orchestrator) is a
  # desktop workspace that runs and supervises coding-agent sessions.
  #
  # Why the published Linux AppImage and not the sources: upstream ships no Nix
  # package (their flake.nix is a development shell only) and the desktop app is
  # an Electron shell around a prebuilt Go daemon. Building it means
  # reconstructing three download pipelines that run inside the builder —
  # tmux/libevent/ncurses/utf8proc compiled from source, the agent-browser
  # binary, and the ACP runtime's own Node plus an npm tree — and reproducing
  # build-acp-runtime's marker signature so its patched adapters are not
  # re-generated. The release artifact already contains all of them, and it is
  # the only Linux artifact upstream supports; wrap it instead.
  #
  # Update: bump `version`, then refresh `hash` from the release asset
  #   nix store prefetch-file --json \
  #     https://github.com/OrchestratorInc/agent-orchestrator/releases/download/v<version>/agent-orchestrator-linux-x64.AppImage
  #
  # The bundle carries its own update feed (resources/app-update.yml points at
  # this GitHub repo), but electron-updater's AppImage path needs APPIMAGE to
  # name a real AppImage file, and appimage-exec leaves it empty here, so the
  # update check stays inert and cannot write into the store.
  package =
    {
      lib,
      appimageTools,
      fetchurl,
    }:
    let
      pname = "agent-orchestrator";
      version = "0.13.5";

      src = fetchurl {
        url = "https://github.com/OrchestratorInc/agent-orchestrator/releases/download/v${version}/${pname}-linux-x64.AppImage";
        hash = "sha256-X0JiwbX61eY8CxKR1aLkyHjJU0lvXKQw7f5MBhmHvyg=";
      };

      # Read out of the same artifact the wrapper runs: the desktop entry (which
      # also declares the ao-app:// scheme the sign-in callback needs) and the
      # 1024x1024 icon it installs into the hicolor theme.
      appimageContents = appimageTools.extract { inherit pname version src; };
    in
    appimageTools.wrapType2 {
      inherit pname version src;

      # AppRun probes `unshare -Ur true` to decide whether Chromium's
      # user-namespace sandbox is usable, and silently appends --no-sandbox when
      # the probe cannot run at all. util-linux supplies that unshare; without it
      # every launch would drop the sandbox. The libraries the bundled Electron
      # dlopens (nss, cups, atk, libgbm, libxkbcommon, libsecret, gtk3, ...) are
      # already in appimageTools' FHS default set.
      extraPkgs = pkgs: [ pkgs.util-linux ];

      extraInstallCommands = ''
        install -m 444 -D ${appimageContents}/agent-orchestrator.desktop \
          $out/share/applications/agent-orchestrator.desktop
        # The entry's Exec is AppRun, which only exists inside an AppImage.
        substituteInPlace $out/share/applications/agent-orchestrator.desktop \
          --replace-fail 'Exec=AppRun %U' 'Exec=agent-orchestrator %U'
        install -m 444 -D ${appimageContents}/agent-orchestrator.png \
          $out/share/icons/hicolor/1024x1024/apps/agent-orchestrator.png
      '';

      meta = {
        description = "Desktop workspace that runs and supervises teams of coding agents";
        homepage = "https://github.com/OrchestratorInc/agent-orchestrator";
        changelog = "https://github.com/OrchestratorInc/agent-orchestrator/releases/tag/v${version}";
        license = lib.licenses.asl20;
        sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
        maintainers = [ lib.maintainers.asterismono ];
        mainProgram = pname;
        platforms = [ "x86_64-linux" ];
      };
    };
in
{
  perSystem =
    { pkgs, ... }:
    {
      packages.agent-orchestrator = pkgs.callPackage package { };
    };
}
