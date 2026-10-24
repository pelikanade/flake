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
      # Server hosts advertise Tailscale SSH so the deployment runner can
      # reach them as root under the tailnet's ACL. The base tailnet client
      # does not enable it; the server role does.
      options.services.tailscale-ssh.enable = lib.mkOption {
        type = lib.types.bool;
        default = config.services.tailscale.enable && (config.roles.server.imported or false);
        description = "Whether this host advertises Tailscale SSH for server deployments.";
      };

      config = {
        # The tailnet belongs to the host, not to the proxy: `tailscaled` owns a real
        # `tailscale0` interface with its own routes, its own resolver entries and its
        # own peer transport, so `tailscale serve`, the CLI and anything else the
        # client ships work normally. The sing-box module keeps that interface out of
        # its tun and out of its DNS; nothing of the tailnet is declared there.
        services.tailscale = {
          enable = true;
          package = pkgs.tailscale;
          # The WireGuard peer transport. Peers reach this port on the host's own
          # addresses rather than through the tunnel, so it is admitted everywhere,
          # as it was when the endpoint carried it.
          openFirewall = true;
          # Reuses the tailnet's subnet routes, matching the endpoint's policy; the
          # node advertises no exit node. The server role enables Tailscale SSH
          # separately through `services.tailscale-ssh.enable`, so a deployment
          # runner can reach the host as root under the tailnet's ACL.
          extraUpFlags = [ "--accept-routes" ];
          extraSetFlags = lib.mkIf config.services.tailscale-ssh.enable [ "--ssh" ];
          authKeyFile = config.sops.secrets.tailscale_auth_key.path;
        };

        # A peer's connection arrives on `tailscale0` instead of being dialled into
        # loopback by a userspace endpoint, so the interface is what admits it. The
        # tailnet is a WireGuard-authenticated network: whatever reaches this
        # interface comes from a peer the control plane placed in the tailnet, and
        # the tailnet's ACLs and each service's own authentication bound it.
        networking.firewall.trustedInterfaces = [ "tailscale0" ];

        # sing-box's tun captures locally generated traffic — it redirects TCP to its
        # own port and marks UDP and ICMP into its routing table — and it treats one
        # mark as "mine, leave it alone": the value in
        # `services.sing-box.tunBypassMark`, which it also puts on every connection it
        # dials itself. A connection that carries it keeps the route the kernel gave
        # it.
        #
        # The node's tailnet transport needs exactly that. Its control connection,
        # its DERP relays and its WireGuard handshakes go to addresses the tun would
        # otherwise route and proxy, which would put the whole tailnet behind the
        # proxy and leave the node relay-only: its observed endpoint would be the
        # proxy's address, so peers could not reach it directly. Marking this unit's
        # transport sockets keeps all of it on the physical interface, which is where
        # the endpoint that used to run inside sing-box dialled from too. The rule
        # exempts DNS before it sets the mark; the ruleset above explains why.
        #
        # The match is the daemon's own cgroup, so the rule names the service and
        # nothing else that happens to run as root. It is installed by a unit rather
        # than declared in `networking.nftables.tables` because a ruleset is checked
        # and loaded before that cgroup exists: a path the firewall cannot resolve
        # then would fail the whole ruleset, and the tun is loaded before the daemon.
        # If sing-box is not this host's proxy there is no tun to keep out of, and the
        # unit is not declared.
        systemd.services.tailscaled.upholds = lib.optional config.services.sing-box.enable "tailscale-tun-bypass.service";

        systemd.services.tailscale-tun-bypass = lib.mkIf config.services.sing-box.enable {
          description = "Keep the tailnet's own transport out of the proxy tun";

          # The cgroup exists while the daemon runs, and `Upholds=` above starts this
          # unit again whenever the daemon starts or restarts — which matters,
          # because the rule holds a reference to that instance's cgroup and a
          # restart replaces it.
          after = [ "tailscaled.service" ];
          requires = [ "tailscaled.service" ];
          wantedBy = [ "multi-user.target" ];

          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };

          # A failure here costs the tailnet its direct paths and nothing else, which
          # is why it is a unit of its own: the daemon does not wait for it, and the
          # unit reports itself failed instead of hiding in a start hook.
          script = ''
            ${lib.getExe pkgs.nftables} delete table inet tailscale-bypass 2>/dev/null || true
            ${lib.getExe pkgs.nftables} -f ${bypassRuleset}
          '';
        };

        # The tailnet's own auth key, in its own document: the node registers with it
        # once, and `tailscaled-autoconnect` reads it while the daemon reports that it
        # needs a login. Changing it re-runs that unit, so a replaced key is retried
        # without a restart of the daemon.
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
    };
}
