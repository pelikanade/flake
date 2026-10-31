{
  flake.modules.nixos.alioth =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    {
      options.alioth = {
        kernelCmdline = lib.mkOption {
          type = lib.types.str;
          description = "The command line the vendor boot image carries.";
        };

        rootLabel = lib.mkOption {
          type = lib.types.str;
          description = "The label of the ext4 root filesystem.";
        };
      };

      config = {
        alioth = {
          kernelCmdline = lib.concatStringsSep " " ([ "init=/init" ] ++ config.boot.kernelParams);

          rootLabel = "alioth";
        };

        nixpkgs.hostPlatform = "aarch64-linux";
        nixpkgs.buildPlatform = "x86_64-linux";

        boot.kernelPackages = pkgs.linuxPackagesFor config.alioth.kernel;

        boot.loader.grub.enable = false;

        boot.kernelParams = [
          "console=tty0"
          "clocksource=arch_mmio_counter"
        ];
        boot.consoleLogLevel = 7;

        time.timeZone = "Asia/Shanghai";

        boot.initrd = {
          includeDefaultModules = false;
          kernelModules = [ "panel-samsung-ams667xx01" ];
        };

        boot.initrd.systemd.services.initrd-nixos-activation.serviceConfig.StandardOutput =
          "journal+console";
        boot.initrd.systemd.services.initrd-nixos-activation.serviceConfig.StandardError =
          "journal+console";

        # The phone has no TPM, and its kernel carries no TPM drivers, so
        # systemd defaults that pull `tpm-crb` into the initramfs fail its
        # build.
        boot.initrd.systemd.tpm2.enable = false;
        systemd.tpm2.enable = false;

        fileSystems."/" = {
          device = "/dev/disk/by-label/${config.alioth.rootLabel}";
          fsType = "ext4";
          autoResize = true;
        };

        documentation.enable = false;

        systemd.services.alioth-register-nix-paths = {
          description = "Register the Nix store paths of a freshly written image";
          unitConfig.DefaultDependencies = false;
          unitConfig.ConditionPathExists = "/nix-path-registration";
          wantedBy = [ "sysinit.target" ];
          before = [
            "sysinit.target"
            "shutdown.target"
            "nix-daemon.socket"
            "nix-daemon.service"
          ];
          after = [ "local-fs.target" ];
          conflicts = [ "shutdown.target" ];
          restartIfChanged = false;
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };
          script = ''
            ${lib.getExe' config.nix.package.out "nix-store"} --load-db < /nix-path-registration

            # nixos-rebuild requires a "system" profile and an /etc/NIXOS tag.
            touch /etc/NIXOS
            ${lib.getExe' config.nix.package.out "nix-env"} -p /nix/var/nix/profiles/system --set /run/current-system

            rm -f /nix-path-registration
          '';
        };

        # The bootloader counts unsuccessful boots and switches to the other
        # slot after a few, so every boot has to mark its slot as successful.
        systemd.services.alioth-mark-boot-successful = {
          description = "Mark the current Android A/B slot as successfully booted";
          wantedBy = [ "multi-user.target" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = "${lib.getExe pkgs.qbootctl} -m";
          };
        };
      };
    };
}
