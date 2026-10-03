{
  flake.modules.nixos.sing-box =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      # NetBird reaches its management, relays and peers with its own WireGuard,
      # STUN and relay traffic, which does not survive being proxied. Route its
      # own ranges through an outbound bound to its interface instead of marking
      # the client's packets by cgroup.
      netbirdInterface = config.services.netbird.clients.default.interface or null;
      netbirdOutbound = {
        type = "direct";
        tag = "netbird";
        bind_interface = netbirdInterface;
      };
      netbirdRule = {
        ip_cidr = [
          "100.69.0.0/16"
          "100.79.0.0/16"
          "fd2b:a214:7af1:40d2::/64"
          "fdd3:c8c7:a7e5:d757::/64"
        ];
        action = "route";
        outbound = "netbird";
      };

      # The configuration is declared here and assembled at activation: the
      # nixpkgs module replaces every `_secret` below with the contents of the
      # named file. Proxy credentials and endpoints stay in sing-box.yaml, and the
      # tailnet auth key in tailscale.yaml, so no secret reaches Nix evaluation,
      # the store or git.
      singBoxSecrets = [
        "snemeow_vless_laxp_server"
        "snemeow_vless_laxp_uuid"
        "snemeow_vless_laxp_server_name"
        "snemeow_vless_jptp_server"
        "snemeow_vless_jptp_uuid"
        "snemeow_vless_jptp_server_name"
        "snemeow_vless_hkgp_server"
        "snemeow_vless_hkgp_uuid"
        "snemeow_vless_hkgp_server_name"
        "snemeow_hysteria2_laxp_server"
        "snemeow_hysteria2_laxp_password"
        "snemeow_hysteria2_laxp_server_name"
        "snemeow_hysteria2_jptp_server"
        "snemeow_hysteria2_jptp_password"
        "snemeow_hysteria2_jptp_server_name"
        "snemeow_hysteria2_hkgp_server"
        "snemeow_hysteria2_hkgp_password"
        "snemeow_hysteria2_hkgp_server_name"
      ];
      secret = name: { _secret = config.sops.secrets.${name}.path; };
      secretFrom = file: name: {
        format = "yaml";
        key = name;
        sopsFile = config.constants.resources.getSecretPath file;
        path = "/run/secrets/${name}";
        owner = "root";
        group = "root";
        mode = "0400";
        restartUnits = [ "sing-box.service" ];
      };

      nodeTags = [
        "snemeow-vless-laxp"
        "snemeow-vless-jptp"
        "snemeow-vless-hkgp"
        "snemeow-hysteria2-laxp"
        "snemeow-hysteria2-jptp"
        "snemeow-hysteria2-hkgp"
      ];

      vlessNode =
        {
          tag,
          port,
          prefix,
        }:
        {
          type = "vless";
          inherit tag;
          tcp_multi_path = true;
          server = secret "${prefix}_server";
          server_port = port;
          uuid = secret "${prefix}_uuid";
          flow = "xtls-rprx-vision";
          tls = {
            enabled = true;
            server_name = secret "${prefix}_server_name";
          };
        };

      hysteria2Node =
        {
          tag,
          port,
          prefix,
        }:
        {
          type = "hysteria2";
          inherit tag;
          tcp_multi_path = true;
          server = secret "${prefix}_server";
          server_port = port;
          password = secret "${prefix}_password";
          tls = {
            enabled = true;
            server_name = secret "${prefix}_server_name";
            alpn = "h3";
          };
          stream_receive_window = 0;
          connection_receive_window = 0;
        };

      singBoxSettings = {
        log = {
          level = "info";
          timestamp = true;
        };

        dns = {
          servers = [
            {
              type = "udp";
              tag = "home-dns";
              server = "10.0.0.3";
            }
            {
              type = "udp";
              tag = "alidns";
              server = "223.5.5.5";
            }
            {
              type = "udp";
              tag = "cfdns";
              detour = "proxy";
              server = "1.1.1.1";
            }
            {
              type = "local";
            }
            {
              type = "tailscale";
              tag = "tailnet-dns";
              endpoint = "tailnet";
              accept_default_resolvers = false;
              accept_search_domain = true;
            }
          ];

          rules = [
            # MagicDNS names and tailnet DNS suffixes resolve through the
            # endpoint; every other name keeps the resolvers below.
            {
              preferred_by = "tailnet-dns";
              action = "route";
              server = "tailnet-dns";
            }
            # x.ai resolves AAAA and HTTPS records to addresses that break its
            # client, so answer those queries with an empty result.
            {
              domain_suffix = [
                "x.ai"
                "grok.com"
                "grokusercontent.com"
                "grok-sandbox.com"
              ];
              query_type = [
                "AAAA"
                "HTTPS"
              ];
              action = "predefined";
              answer = [ ];
            }
            # At home, use the router's resolver before any public one.
            {
              wifi_ssid = [
                "LoliHouse"
                "LoliHouse_5G"
              ];
              action = "route";
              server = "home-dns";
            }
            {
              rule_set = "geosite-cn";
              action = "route";
              server = "alidns";
            }
            {
              server = "cfdns";
              action = "route";
            }
          ];

          final = "cfdns";
          strategy = "prefer_ipv4";
        };

        # Remote rule-sets download through the selector, never the default
        # outbound, which is what sing-box 1.16 will require.
        http_clients = [
          {
            tag = "rule-set-proxy";
            version = 2;
            detour = "proxy";
            stream_receive_window = 0;
            connection_receive_window = 0;
          }
        ];

        # The tun is the only inbound: nothing points applications at a proxy
        # environment variable, and auto_redirect routes their traffic anyway, so
        # a local mixed proxy listener would only add another port.
        inbounds = [
          {
            type = "tun";
            mtu = 1380;
            address = [
              "172.19.0.1/30"
              "fdfe:dcba:9876::1/126"
            ];
            auto_route = true;
            auto_redirect = true;
            route_exclude_address = [
              "10.0.0.0/8"
              "fe80::/10"
              # The tailnet reaches its peers through its own interface, not the
              # tun, so keep those ranges out of the tun's routes.
              "100.64.0.0/10"
              "fd7a:115c:a1e0::/48"
            ];
            # NetBird's interface: what arrives on it is already inside the
            # NetBird tunnel and must not enter the tun.
            exclude_interface = lib.optional (netbirdInterface != null) netbirdInterface;
          }
        ];

        outbounds = [
          {
            type = "direct";
            tag = "direct";
          }
          (vlessNode {
            tag = "snemeow-vless-laxp";
            port = 37327;
            prefix = "snemeow_vless_laxp";
          })
          (vlessNode {
            tag = "snemeow-vless-jptp";
            port = 33724;
            prefix = "snemeow_vless_jptp";
          })
          (vlessNode {
            tag = "snemeow-vless-hkgp";
            port = 17170;
            prefix = "snemeow_vless_hkgp";
          })
          (hysteria2Node {
            tag = "snemeow-hysteria2-laxp";
            port = 32737;
            prefix = "snemeow_hysteria2_laxp";
          })
          (hysteria2Node {
            tag = "snemeow-hysteria2-jptp";
            port = 14459;
            prefix = "snemeow_hysteria2_jptp";
          })
          (hysteria2Node {
            tag = "snemeow-hysteria2-hkgp";
            port = 41348;
            prefix = "snemeow_hysteria2_hkgp";
          })
          {
            type = "selector";
            tag = "proxy";
            outbounds = nodeTags;
            default = "snemeow-vless-laxp";
            interrupt_exist_connections = true;
          }
        ]
        ++ lib.optional (netbirdInterface != null) netbirdOutbound;

        route = {
          rules = lib.optional (netbirdInterface != null) netbirdRule ++ [
            {
              action = "sniff";
            }
            {
              ip_is_private = true;
              outbound = "direct";
            }
            # The LAN, the NetBird ULA and the tailnet are reached directly. The
            # tailnet's CGNAT range matters here because `ip_is_private` does not
            # cover it: without this rule a connection to a peer falls through to
            # `final` and is proxied out to the internet instead.
            {
              ip_cidr = [
                "10.0.0.0/24"
                "fe80::/10"
                "100.64.0.0/10"
                "fd2b:a214:7af1:40d2::/64"
                "fd7a:115c:a1e0::/48"
              ];
              outbound = "direct";
            }
            {
              rule_set = "steam@cn";
              outbound = "direct";
            }
            {
              rule_set = "steam";
              outbound = "proxy";
            }
            {
              rule_set = [
                "geoip-cn"
                "geosite-cn"
              ];
              outbound = "direct";
            }
          ];

          rule_set = [
            {
              type = "remote";
              tag = "geosite-cn";
              url = "https://cdn.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@refs/heads/sing/geo/geosite/cn.srs";
            }
            {
              type = "remote";
              tag = "geoip-cn";
              url = "https://cdn.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@refs/heads/sing/geo/geoip/cn.srs";
            }
            {
              type = "remote";
              tag = "steam";
              url = "https://cdn.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@refs/heads/sing/geo/geosite/steam.srs";
            }
            {
              type = "remote";
              tag = "steam@cn";
              url = "https://cdn.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@refs/heads/sing/geo/geosite/steam@cn.srs";
            }
          ];

          final = "proxy";
          auto_detect_interface = true;
          default_domain_resolver = "alidns";
          default_http_client = "rule-set-proxy";
        };

        experimental = {
          cache_file.enabled = true;
          clash_api = {
            external_controller = "0.0.0.0:9990";
            access_control_allow_private_network = true;
          };
        };

        endpoints = [
          {
            type = "tailscale";
            tag = "tailnet";
            state_directory = "/var/lib/sing-box/tailscale";
            auth_key = secret "tailscale_auth_key";
            ephemeral = false;
            system_interface = true;
            system_interface_name = "tailnet0";
            accept_routes = false;
            advertise_exit_node = false;
            ssh_server = false;
            listen_port = 41641;
          }
        ];
      };
    in
    {
      # Workstation policy and the tailnet aspect compose this same feature.
      key = "sing-box";

      # UDP replies injected through the tun arrive on a different interface
      # than the route to their source. Allow that asymmetry while still
      # rejecting packets whose source has no route.
      networking.firewall.checkReversePath = "loose";

      # The Tailscale endpoint's peer transport. Peers reach it on this host's
      # own addresses rather than through the tunnel, so it is open on every
      # interface; each service admits its own TCP ports on `tailnet0`.
      networking.firewall.allowedUDPPorts = [ 41641 ];

      # sing-box publishes the tun as the interface resolver through
      # systemd-resolved (dns_mode "hijack" -> SetLinkDNS with domain "~."), so
      # without resolved nothing points the system at the tun and DNS keeps
      # going to whatever DHCP handed out.
      services.resolved.enable = true;

      # MagicDNS answers fully qualified names. Giving the resolver the tailnet's
      # search domain is what makes a short peer name such as `box` expand to
      # `box.<tailnet>.ts.net`, which the Pi extension and every other tool expect.
      services.resolved.settings.Resolve.Domains = [ "leaffish-halfmoon.ts.net" ];

      # resolved only accepts those SetLinkDNS/SetDomains/SetDefaultRoute calls
      # from the sing-box user when polkit applies the rule shipped in the
      # sing-box package. Without it they fail with "Access denied" and sing-tun
      # discards the error, leaving the tun without a resolver.
      security.polkit.enable = true;

      # sing-tun also calls resolve1.revert when the tun goes away, which the
      # packaged rule does not cover; grant it so that call is not denied too.
      security.polkit.extraConfig = ''
        // systemd-resolved access for the sing-box tun
        polkit.addRule(function(action, subject) {
          var actions = [
            "org.freedesktop.resolve1.revert",
            "org.freedesktop.resolve1.set-default-route",
            "org.freedesktop.resolve1.set-dns-servers",
            "org.freedesktop.resolve1.set-domains",
          ];
          if (actions.indexOf(action.id) >= 0 && subject.user == "sing-box") {
            return polkit.Result.YES;
          }
        });
      '';

      # NetBird's own WireGuard, STUN and relay traffic does not survive being
      # proxied, so its ranges leave through the NetBird interface instead.
      # Nothing here marks packets by cgroup any more.

      # One root-owned, root-only file per value. The nixpkgs module renders
      # them into the runtime configuration as root before the service starts,
      # so the sing-box user never reads a secret file itself. The tailnet key
      # comes from its own document: a host that joins the tailnet through
      # tailscaled instead of this endpoint needs the same key.
      sops.secrets = lib.genAttrs singBoxSecrets (secretFrom "sing-box.yaml") // {
        tailscale_auth_key = secretFrom "tailscale.yaml" "tailscale_auth_key";
      };

      services.sing-box = {
        enable = true;
        package = pkgs.unstable.sing-box;
        settings = singBoxSettings;
      };
    };
}
