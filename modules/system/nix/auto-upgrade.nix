{
  # Every machine follows the newest revision of the published repository every
  # day at 05:00. The run switches the running system but never reboots on its
  # own, so a kernel update waits for a reboot the operator chooses.
  flake.modules.nixos.auto-upgrade = {
    system.autoUpgrade = {
      enable = true;
      dates = "05:00";

      # The published repository, not a local checkout: each run re-resolves the
      # ref and builds its current revision.
      flake = "github:pelikanade/flake";

      # A flake build carries its own lock and the unit passes `--refresh`, so
      # the channel update that `--upgrade` would trigger does not apply.
      upgrade = false;
    };
  };
}
