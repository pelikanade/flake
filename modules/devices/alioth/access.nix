{
  flake.modules.nixos.alioth =
    { config, ... }:
    {
      # A login prompt on the gadget's serial port is the console of a phone
      # without a display session. NixOS installs upstream's
      # serial-getty@.service as a drop-in, and an instantiated template starts
      # only through a target that wants it.
      systemd.services."serial-getty@ttyGS0" = {
        enable = true;
        wantedBy = [ "getty.target" ];
        serviceConfig.Restart = "always";
      };

      services.openssh = {
        enable = true;
        hostKeys = [
          {
            path = "/etc/ssh/ssh_host_ed25519_key";
            type = "ed25519";
          }
        ];
      };

      users.users.root = {
        initialHashedPassword = config.constants.nvirellia.hashedPassword;
        openssh.authorizedKeys.keys = [ config.constants.nvirellia.sshPubKey ];
      };
    };
}
