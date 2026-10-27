# The WiFi the phone joins on its own, and the fixed addresses it keeps.
{
  flake.modules.nixos.alioth =
    {
      config,
      ...
    }:
    let
      # The network the phone joins with its own radio, which is the only path
      # off the device that does not need a host at the far end of its USB
      # cable. Its passphrase is not here: it is a sops secret below.
      wifiSsid = "LoliHouse_5G";
    in
    {
      networking = {
        useNetworkd = true;
        # The phone's own network is its WiFi: the USB link needs a host at the
        # other end, and this is a device that is meant to run on its own. The
        # passphrase is a sops secret, so wpa_supplicant reads it through its
        # `ext:` password backend from the file sops renders, and `networking.wireless`
        # installs the regulatory database with the option.
        wireless = {
          enable = true;
          networks.${wifiSsid}.pskRaw = "ext:wifi_psk";
          secretsFile = config.sops.templates."alioth-wifi-secrets".path;
        };

        # This kernel carries no `pkttype` match for the iptables backend, and
        # no `nft_fib_inet` for the nftables backend's reverse-path filter. The
        # firewall runs with that filter off because with it on the generated
        # `fib saddr . mark . iif oif exists` rule in the `inet` table fails
        # with `Could not process rule: No such file or directory`, and a
        # firewall unit that fails to start fails every remote `nixos-rebuild
        # switch` with it. The phone forwards nothing, so the filter protects
        # little here; getting it back means `CONFIG_NFT_FIB_INET=m` in the
        # kernel configuration and a new boot image.
        nftables.enable = true;
        firewall = {
          enable = true;
          checkReversePath = false;
        };
      };

      # Nothing gives the wireless interface an address: it is left to NixOS's
      # own `99-wireless-client-dhcp` network file, which matches any wireless
      # station and takes an address by DHCP.

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

      # Power save is off on this interface because the kernel is built without
      # `CONFIG_CFG80211_DEFAULT_PS`, which is the symbol that makes cfg80211
      # set `WIPHY_FLAG_PS_ON_BY_DEFAULT` and turn power save on for every
      # wireless interface as it is created. Nothing else can be asked to leave
      # it off — no `.network` option, no module parameter, no wpa_supplicant
      # setting — and it is worth a factor of four on this link: measured
      # against the gateway, 4.0 ms average and 16 ms worst with it off against
      # 14.8 ms and 73 ms with it on, and nothing lost either way.
      # `modules/devices/alioth/kernel-config.aarch64` carries the symbol.

      # The WiFi passphrase is the phone's only secret and it stays out of the
      # store: sops decrypts it at activation into a file wpa_supplicant reads
      # through its `ext:` backend. The document names this host and the
      # maintainer; the host decrypts it with the SSH key NixOS generates into
      # its root filesystem, which a full flash replaces.
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
        # wpa_supplicant runs as its own user under the wireless module's
        # hardening, so the file has to belong to that user: root-owned and
        # mode 0400 is what made the daemon log
        # `EXT PW FILE: ... Permission denied` and never find a key.
        owner = "wpa_supplicant";
        group = "wpa_supplicant";
        mode = "0400";
        restartUnits = [ "wpa_supplicant.service" ];
      };
    };
}
