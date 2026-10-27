# The boot configuration of the Xiaomi POCO F3 / Redmi K40 / Mi 11X (codename
# alioth): the kernel package and command line, the initramfs, the root
# filesystem, and the services that make a freshly written image bootable.
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
        # The bootloader appends its own arguments after these, so the phone
        # boots with both. ABL passes `init=/init` as well, which is the same
        # program: the root filesystem carries /init as a symlink to the system
        # closure, and the initramfs hands over to it. Everything else the phone
        # needs on its command line is in `boot.kernelParams`, which also
        # carries the consoles and the log level this configuration asks for.
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

        # This machine is aarch64 and the repository has no aarch64 builder, so
        # the workstation cross-compiles the system for it.
        nixpkgs.hostPlatform = "aarch64-linux";
        nixpkgs.buildPlatform = "x86_64-linux";

        boot.kernelPackages = pkgs.linuxPackagesFor config.alioth.kernel;

        # The device's own bootloader boots the Android boot image built beside
        # this, so NixOS installs no bootloader of its own.
        boot.loader.grub.enable = false;

        # The display is the only kernel console. `ttyGS0` is deliberately not
        # one: a tty nobody reads blocks its writer, and the kernel's own
        # messages — the charger's APSD retries alone are several a second —
        # fill the tty buffer while no host is attached, which stalls the boot
        # until the watchdog resets it. The serial port still carries a login
        # prompt, which is what it is for; its output goes only to a session
        # that asked for it.
        boot.kernelParams = [
          "console=tty0"
        ];
        boot.consoleLogLevel = 7;

        # The panel's dimming schedule reads local time, and a phone that lives
        # on one shelf has no reason to think it is in UTC.
        time.timeZone = "Asia/Shanghai";

        # UFS, the root filesystem, and the USB gadget are all built into the
        # kernel; only the panel driver has to be loaded for the framebuffer
        # console to come up, which happens before the root filesystem is
        # mounted. Listing it as a module to load is also what puts it in the
        # initramfs: stage 1 builds the image from `availableKernelModules` and
        # `kernelModules` together.
        boot.initrd = {
          includeDefaultModules = false;
          kernelModules = [ "panel-samsung-ams667xx01" ];
        };

        # The hand-over from the initramfs to the root filesystem runs the
        # system's activation inside a chroot; when it fails, its output is the
        # only thing that says why, and the initramfs has no getty.
        boot.initrd.systemd.services.initrd-nixos-activation.serviceConfig.StandardOutput =
          "journal+console";
        boot.initrd.systemd.services.initrd-nixos-activation.serviceConfig.StandardError =
          "journal+console";

        # The phone has no TPM, and its kernel carries no TPM drivers, so
        # systemd defaults that pull `tpm-crb` into the initramfs fail its
        # build.
        boot.initrd.systemd.tpm2.enable = false;
        systemd.tpm2.enable = false;

        # The image's filesystem is only as large as the system closure it
        # carries, and `autoResize` is what grows it to the partition before
        # anything mounts or writes to it.
        fileSystems."/" = {
          device = "/dev/disk/by-label/${config.alioth.rootLabel}";
          fsType = "ext4";
          autoResize = true;
        };

        # A headless handset does not carry a documentation closure.
        documentation.enable = false;

        # The root filesystem is a copy of the system closure, placed in a
        # filesystem image whose size follows its contents; the store paths it
        # brings are registered on the first boot of a freshly written image,
        # which is also where a system profile and the `/etc/NIXOS` tag that
        # `nixos-rebuild` wants come from.
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
