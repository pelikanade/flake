{
  flake.modules.nixos.tailscale =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      # The rule the unit below installs: this service's own transport keeps the
      # route the kernel gave it. Priority -151 sits above the tun's capture chains.
      #
      # DNS is the exception. The mark exists so the control connection, the DERP
      # relays and the WireGuard handshakes stay on the physical interface instead
      # of being proxied; the daemon's name resolution must not join them. Its
      # resolver entries point at the system resolver (`127.0.0.53`), which is the
      # path every other local client uses and the one sing-box feeds its DNS
      # servers and rules into. Marked, a query to that resolver skips the path
      # sing-box installs for DNS and times out, so `tailscale cert` cannot resolve
      # the ACME directory and `tailscale status` reports the configured DNS
      # servers unreachable. Return before the mark for port 53, for both
      # transports; the chain is `inet`, so this covers IPv4 and IPv6 alike.
      bypassRuleset = pkgs.writeText "tailscale-bypass.nft" ''
        table inet tailscale-bypass {
          chain output {
            type filter hook output priority -151; policy accept;
            socket cgroupv2 level 2 "system.slice/tailscaled.service" udp dport 53 return
            socket cgroupv2 level 2 "system.slice/tailscaled.service" tcp dport 53 return
            socket cgroupv2 level 2 "system.slice/tailscaled.service" meta mark set ${config.services.sing-box.tunBypassMark}
          }
        }
      '';
    in
    {
      services.tailscale = {
        enable = true;
        package = pkgs.tailscale;
        openFirewall = true;
        extraUpFlags = [ "--accept-routes" ];
        authKeyFile = config.sops.secrets.tailscale_auth_key.path;
      };

      networking.firewall.trustedInterfaces = [ "tailscale0" ];

      systemd.services.tailscaled.upholds = lib.optional config.services.sing-box.enable "tailscale-tun-bypass.service";

      systemd.services.tailscale-tun-bypass = lib.mkIf config.services.sing-box.enable {
        description = "Keep the tailnet's own transport out of the proxy tun";

        after = [ "tailscaled.service" ];
        requires = [ "tailscaled.service" ];
        wantedBy = [ "multi-user.target" ];

        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };

        script = ''
          ${lib.getExe pkgs.nftables} delete table inet tailscale-bypass 2>/dev/null || true
          ${lib.getExe pkgs.nftables} -f ${bypassRuleset}
        '';
      };

      sops.secrets.tailscale_auth_key = {
        format = "yaml";
        key = "tailscale_auth_key";
        sopsFile = config.constants.resources.getSecretPath "tailscale.yaml";
        path = "/run/secrets/tailscale_auth_key";
        owner = "root";
        group = "root";
        mode = "0400";
        restartUnits = [ "tailscaled-autoconnect.service" ];
      };
    };
}
