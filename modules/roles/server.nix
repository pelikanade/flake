{ inputs, ... }:
{
  flake.modules.aspects.server.imports = [ inputs.self.modules.aspects.ssh ];

  flake.modules.nixos.server =
    { config, lib, ... }:
    {
      options.roles.server.imported = lib.mkOption {
        type = lib.types.bool;
        default = true;
        readOnly = true;
        internal = true;
        description = "Whether the server role module was imported.";
      };

      config = {
        boot.loader = {
          systemd-boot.configurationLimit = 5;
          grub.configurationLimit = 5;
        };

        documentation = {
          man.enable = false;
          dev.enable = false;
          doc.enable = false;
          nixos.enable = false;
        };
        fonts.fontconfig.enable = false;

        programs.vim = {
          enable = true;
          defaultEditor = true;
        };
        programs.git.enable = true;

        users.mutableUsers = false;

        users.users.root = {
          initialHashedPassword = config.constants.nvirellia.hashedPassword;
          openssh.authorizedKeys.keys = [ config.constants.nvirellia.sshPubKey ];
        };

        systemd = {
          enableEmergencyMode = false;

          # For more detail, see:
          #   https://0pointer.de/blog/projects/watchdog.html
          settings.Manager = {
            # systemd will send a signal to the hardware watchdog at half
            # the interval defined here, so every 10s.
            # If the hardware watchdog does not get a signal for 20s,
            # it will forcefully reboot the system.
            RuntimeWatchdogSec = "20s";
            # Forcefully reboot if the final stage of the reboot
            # hangs without progress for more than 30s.
            # For more info, see:
            # https://utcc.utoronto.ca/~cks/space/blog/Systemd/SystemdShutdownWatchdog
            RebootWatchdogSec = "30s";
            # Forcefully reboot when a host hangs after kexec.
            # This may be the case if the firmware does not support kexec.
            KExecWatchdogSec = "1m";
          };
        };

        boot.kernel.sysctl = {
          "net.core.default_qdisc" = "fq";
          "net.ipv4.tcp_congestion_control" = "bbr";
        };
      };
    };
}
