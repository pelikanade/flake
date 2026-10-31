# The charge window that keeps the battery of a phone that lives plugged in
# from sitting at its design charge voltage.
{
  flake.modules.nixos.alioth =
    { pkgs, ... }:
    let
      # The window the battery is kept in. This pack's design charge voltage is
      # 4.46 V, and a phone that lives plugged in would otherwise spend its life
      # there. Below the low mark it charges; at the high mark the charge is
      # switched off, which leaves the adapter powering the phone while the
      # battery sits still. `capacity` is clamped at 99% near full and only
      # tracks the pack lower down, so the marks are rough by nature.
      chargeWindowLow = 50;
      chargeWindowHigh = 60;
    in
    {
      # A phone that lives plugged in should not sit on a charger.
      # `charging_enabled` is the switch that works on this charger: writing 0
      # stops the charge, and writing 0 then 1 starts one. The other writable
      # property, `current_max`, did nothing a two-hour controlled run could see
      # — with it at 0 the cell went on charging — so it is not touched.
      #
      # Holding the window does not take the supply away from the system: the
      # adapter powers the phone whether or not the cell is charging, and
      # current the cell is not taking is current the system can have.
      systemd.services.alioth-charge-window = {
        description = "Keep the battery inside a charge window";
        wantedBy = [ "multi-user.target" ];
        after = [ "sysinit.target" ];
        serviceConfig = {
          Type = "simple";
          Restart = "always";
          RestartSec = 60;
        };
        script = ''
          set -eu

          charger=/sys/class/power_supply/pm8150b-charger
          battery=/sys/class/power_supply/qcom-battery
          low=${toString chargeWindowLow}
          high=${toString chargeWindowHigh}

          # Both power supplies appear seconds after this starts, and reading
          # them before they do is what made this unit restart in a loop.
          for _ in $(${pkgs.coreutils}/bin/seq 300); do
            if [ -r "$charger/charging_enabled" ] && [ -r "$battery/capacity" ]; then
              break
            fi
            ${pkgs.coreutils}/bin/sleep 1
          done

          while :; do
            capacity=$(${pkgs.coreutils}/bin/cat "$battery/capacity")

            if [ "$capacity" -ge "$high" ]; then
              echo 0 > "$charger/charging_enabled"
            elif [ "$capacity" -le "$low" ]; then
              echo 0 > "$charger/charging_enabled"
              ${pkgs.coreutils}/bin/sleep 1
              echo 1 > "$charger/charging_enabled"
            fi

            ${pkgs.coreutils}/bin/sleep 60
          done
        '';
      };
    };
}
