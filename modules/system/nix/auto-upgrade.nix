{
  # Follows the newest revision of the machine's published flake every day at
  # 05:00. The run switches the running system but never reboots on its own, so
  # a kernel update waits for a reboot the operator chooses.
  flake.modules.nixos.auto-upgrade = {
    system.autoUpgrade = {
      enable = true;
      dates = "05:00";
      # A flake build carries its own lock and `--refresh` re-resolves the ref,
      # so the channel update that `--upgrade` would trigger does not apply.
      upgrade = false;
    };
  };
}
