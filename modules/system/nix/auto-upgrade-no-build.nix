{
  # A machine whose memory cannot absorb a local build still wants the daily
  # upgrade. Nix has no substitute-only mode, but with no local build slots and
  # no remote builders every derivation has to come from the configured caches:
  # a revision whose closure is not published yet fails the unit and leaves the
  # running system untouched. Scoped to the upgrade unit, so the operator can
  # still build on this machine by hand.
  flake.modules.nixos.auto-upgrade-no-build = {
    system.autoUpgrade.flags = [
      "--option"
      "max-jobs"
      "0"
    ];
  };
}
