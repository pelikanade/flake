# The status panel on the phone's own display.
#
# A small Rust program owns tty1's framebuffer: it draws in landscape
# coordinates and blits them, rotated, into the portrait panel, which is what
# buys true colour and antialiased type without a GPU — this device's has no
# firmware, so there is no GL to be had. It takes the display away from fbcon
# while it draws and gives it back on the way out, so a crash leaves a working
# console behind it, and `systemctl start getty@tty1` is a way back in.
#
# `alioth-panel-collect` feeds it the facts that need a process or the cluster
# API; everything cheap it reads itself.
{
  flake.modules.nixos.alioth =
    { lib, pkgs, ... }:
    let
      # No build script, no C dependencies, two pure-Rust crates: this is
      # cross-compiled for aarch64 from x86_64, and the dependency tree is the
      # part of such a build that breaks.
      panel = pkgs.rustPlatform.buildRustPackage {
        pname = "alioth-panel";
        version = "0.1.0";
        src = ./alioth/panel;
        cargoLock.lockFile = ./alioth/panel/Cargo.lock;
        meta.description = "Status panel for the phone's own display";
      };

      collect = pkgs.writeShellScriptBin "alioth-panel-collect" (
        builtins.readFile ./alioth/panel/collect.sh
      );

      # The panel gives the display back on its own; this is the belt for a
      # crash that never got there, and rebinding fbcon repaints the console.
      giveDisplayBack = pkgs.writeShellScript "alioth-panel-vtcon" ''
        echo 1 > /sys/class/vtconsole/vtcon1/bind
      '';
    in
    {
      # The console behind the panel is rotated to match, so a boot that never
      # reaches the panel does not come up sideways. This reaches the boot image
      # through `boot.kernelParams`, which the vendor boot image carries.
      boot.kernelParams = [ "fbcon=rotate:3" ];
      console.font = "ter-132n";
      console.packages = [ pkgs.terminus_font ];

      # tty1 is the panel's, so nothing starts a login prompt there.
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
            # The font is read straight from its store path, so no font stack is
            # installed for this: one file, one path.
            "ALIOTH_PANEL_FONT_DIR=${pkgs.maple-mono.NF-CN}/share/fonts/truetype"
          ];
          Restart = "always";
          RestartSec = 2;
          ExecStopPost = lib.getExe giveDisplayBack;
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

      # The second view runs `fastfetch` and shows what it prints, so the
      # binary has to be on the service's PATH.
      environment.systemPackages = [
        panel
        collect
        pkgs.fastfetch
      ];
    };
}
