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
      # STUN and relay traffic, which does not survive being proxied. Its peers
      # and its accepted routes are in the carrier-grade NAT range, which the tun
      # excludes below, so that traffic keeps the routes NetBird installed on its
      # own interface; the client's packets are not captured and no rule has to
      # name them.
      netbirdInterface = config.services.netbird.clients.default.interface or null;

      # The configuration is declared here and assembled at activation: the
      # nixpkgs module replaces every `_secret` below with the contents of the
      # named file. Proxy credentials and endpoints stay in sing-box.yaml, so no
      # secret reaches Nix evaluation, the store or git. The tailnet is not part
      # of this feature: it has its own module and its own key, and the tun keeps
      # out of its addresses.
      nodes = [
        {
          tag = "snemeow-vless-laxp";
          type = "vless";
          port = 37327;
          prefix = "snemeow_vless_laxp";
        }
        {
          tag = "snemeow-vless-jptp";
          type = "vless";
          port = 33724;
          prefix = "snemeow_vless_jptp";
        }
        {
          tag = "snemeow-vless-hkgp";
          type = "vless";
          port = 17170;
          prefix = "snemeow_vless_hkgp";
        }
        {
          tag = "snemeow-hysteria2-laxp";
          type = "hysteria2";
          port = 32737;
          prefix = "snemeow_hysteria2_laxp";
        }
        {
          tag = "snemeow-hysteria2-jptp";
          type = "hysteria2";
          port = 14459;
          prefix = "snemeow_hysteria2_jptp";
        }
        {
          tag = "snemeow-hysteria2-hkgp";
          type = "hysteria2";
          port = 41348;
          prefix = "snemeow_hysteria2_hkgp";
        }
      ];

      nodeSecrets =
        node:
        if node.type == "vless" then
          [
            "${node.prefix}_server"
            "${node.prefix}_uuid"
            "${node.prefix}_server_name"
          ]
        else
          [
            "${node.prefix}_server"
            "${node.prefix}_password"
            "${node.prefix}_server_name"
          ];

      singBoxSecrets = lib.concatMap nodeSecrets nodes;
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

      nodeTags = map (node: node.tag) nodes;

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
          ];

          rules = [
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
            # Declared rather than defaulted: the mark is the tun's contract with
            # whatever must stay outside it, and `services.sing-box.tunBypassMark`
            # is where that value is written down.
            auto_redirect_output_mark = config.services.sing-box.tunBypassMark;
            # The carrier-grade NAT range belongs to interfaces the kernel owns:
            # the tailnet's `tailscale0` and NetBird's tunnel both carry their own
            # addresses and routes, and a connection to one of their peers is not
            # the proxy's business. Excluding the range keeps it out of the tun's
            # routes and out of the redirect that carries local traffic into it, so
            # those connections keep the route the kernel gave them — and DNS sent
            # to the tailnet's resolver at 100.100.100.100 is not hijacked into
            # sing-box either.
            route_exclude_address = [
              "10.0.0.0/8"
              "100.64.0.0/10"
              "fe80::/10"
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
        ]
        ++ map (
          node:
          (if node.type == "vless" then vlessNode else hysteria2Node) {
            inherit (node) tag port prefix;
          }
        ) nodes
        ++ [
          {
            type = "selector";
            tag = "proxy";
            outbounds = nodeTags;
            default = "snemeow-vless-laxp";
            interrupt_exist_connections = true;
          }
        ];

        route = {
          rules = [
            {
              action = "sniff";
            }
            {
              ip_cidr = [
                "10.0.0.0/24"
                "fe80::/10"
              ];
              outbound = "direct";
            }
            {
              ip_is_private = true;
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
      };
    in
    {
      # Machine and workstation policy compose this same feature.
      key = "sing-box";

      # The mark this tun treats as its own, read-only because it is a contract
      # rather than a knob: the tun sets `auto_redirect_output_mark` from it, and a
      # feature whose own transport must not be proxied marks its sockets with it —
      # the tailnet's daemon does, and reads this value to do so. Changing it here
      # would be changing both sides of that contract.
      options.services.sing-box.tunBypassMark = lib.mkOption {
        type = lib.types.str;
        readOnly = true;
        default = "0x2024";
        description = ''
          The nftables mark this tun treats as its own.

          `auto_redirect` skips a packet that carries it: the redirect that
          carries local TCP into the tun returns, the mark that carries local UDP
          and ICMP into it is not set, and the routing rule that sends that mark
          to the tun's table is skipped. sing-box puts it on every connection it
          dials itself.
        '';
      };

      config = {
        networking.nftables.enable = true;
        networking.firewall = {
          backend = "nftables";
          trustedInterfaces = [ "tun0" ];
          extraReversePathFilterRules = ''iifname "tun0" accept'';
        };

        services.resolved = {
          enable = true;
          settings.Resolve.ResolveUnicastSingleLabel = true;
        };

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
        # proxied. Its interface is excluded above with the rest of the
        # carrier-grade NAT range, so its peers and its routes leave through `wt0`
        # as the kernel routes them, without an outbound bound to that interface.

        # The root pre-start renderer reads these files into the runtime config, so
        # the service itself never needs direct secret-file access and every
        # credential file stays root-only.
        sops.secrets = lib.genAttrs singBoxSecrets (secretFrom "sing-box.yaml");

        services.sing-box = {
          enable = true;
          package = pkgs.unstable.sing-box;
          settings = singBoxSettings;
        };
      };
    };
}
