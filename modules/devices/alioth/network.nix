{
  flake.modules.nixos.alioth =
    {
      config,
      ...
    }:
    let
      wifiSsid = "LoliHouse_5G";
    in
    {
      networking = {
        useNetworkd = true;
        wireless = {
          enable = true;
          networks.${wifiSsid}.pskRaw = "ext:wifi_psk";
          secretsFile = config.sops.templates."alioth-wifi-secrets".path;
        };

        nftables.enable = true;
        firewall = {
          enable = true;
          checkReversePath = false;
        };
      };

      # The board file this radio loads carries no MAC address, so the firmware
      # invents one at every boot and the network hands the phone a different
      # address with it. A `.link` file gives the interface a fixed
      # locally-administered address before anything brings it up, which is what
      # keeps the phone at one address across boots. A matching `.link` file
      # replaces the system default instead of adding to it, so the naming
      # policy has to be repeated here: without it the interface stays `wlan0`
      # and everything that names it stops matching.
      systemd.network.links."10-wireless" = {
        matchConfig = {
          Type = "wlan";
          OriginalName = "wlan0";
        };
        linkConfig = {
          NamePolicy = [ "path" ];
          MACAddress = "02:01:02:03:04:07";
        };
      };

      sops.secrets."alioth-wifi-psk" = {
        sopsFile = config.constants.resources.getSecretPath "alioth-wifi.yaml";
        key = "wifi_psk";
        owner = "root";
        mode = "0400";
      };

      sops.templates."alioth-wifi-secrets" = {
        content = ''
          wifi_psk=${config.sops.placeholder."alioth-wifi-psk"}
        '';
        owner = "wpa_supplicant";
        group = "wpa_supplicant";
        mode = "0400";
        restartUnits = [ "wpa_supplicant.service" ];
      };
    };
}
