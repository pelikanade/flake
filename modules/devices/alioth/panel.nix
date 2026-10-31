{
  flake.modules.nixos.alioth =
    { lib, pkgs, ... }:
    let
      panel = pkgs.selfPackages.alioth-panel;
      collect = pkgs.selfPackages.alioth-panel.passthru.collect;

      # The panel gives the display back on its own; this is the belt for a
      # crash that never got there, and rebinding fbcon repaints the console.
      giveDisplayBack = pkgs.writeShellScript "alioth-panel-vtcon" ''
        echo 1 > /sys/class/vtconsole/vtcon1/bind
      '';
    in
    {
      boot.kernelParams = [ "fbcon=rotate:3" ];
      console.font = "ter-132n";
      console.packages = [ pkgs.terminus_font ];

      systemd.targets.getty.wants = lib.mkForce [ ];

      systemd.tmpfiles.rules = [
        "d /run/alioth-panel 0755 root root -"
      ];

      systemd.services.alioth-panel = {
        description = "Status panel on the phone's own display";
        wantedBy = [ "multi-user.target" ];
        after = [ "local-fs.target" ];
        serviceConfig = {
          Type = "simple";
          ExecStart = lib.getExe panel;
          Environment = [
            "ALIOTH_PANEL_FONT_DIR=${pkgs.maple-mono.NF-CN}/share/fonts/truetype"
          ];
          Restart = "always";
          RestartSec = 2;
          ExecStopPost = "${giveDisplayBack}";
        };
      };

      systemd.services.alioth-panel-status = {
        description = "Collect the facts the status panel shows";
        after = [ "multi-user.target" ];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = lib.getExe collect;
        };
      };

      systemd.timers.alioth-panel-status = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "15s";
          OnUnitActiveSec = "30s";
          AccuracySec = "1s";
        };
      };

      environment.systemPackages = [
        panel
        collect
        pkgs.fastfetch
      ];
    };
}
