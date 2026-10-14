{
  flake.modules.nixos.ingress =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      domain = config.services.ingress.domain;
      # The wildcard covers every name this host publishes, so one more service
      # costs one entry in `services.ingress.proxies` and no new certificate or
      # ACME order.
      certName = "*.${domain}";
      # Port 80 only moves browsers to HTTPS: the certificate comes from the
      # DNS-01 challenge, so no ACME request reaches this host.
      ports = [
        80
        443
      ];
      portList = lib.concatMapStringsSep ", " toString ports;

      reverseProxy =
        proxy:
        if proxy.upstreamInsecureTls then
          ''
            reverse_proxy ${proxy.upstream} {
              transport http {
                tls_insecure_skip_verify
              }
            }
          ''
        else
          "reverse_proxy ${proxy.upstream}";

      # One handle block per published name, matched on the host the client
      # asked for. Caddy evaluates handle blocks in order and runs exactly one;
      # the catch-all below answers what no name claims. Caddy flushes a
      # response with an unknown length or an event-stream content type
      # immediately, so an upstream that streams needs no option here.
      renderProxy =
        label: proxy:
        let
          matcher = "@" + lib.replaceStrings [ "-" "." ] [ "_" "_" ] label;
        in
        ''
          ${matcher} host ${label}.${domain}
          handle ${matcher} {
            ${reverseProxy proxy}
          }
        '';
    in
    {
      options.services.ingress = {
        domain = lib.mkOption {
          type = lib.types.str;
          example = "neko-sphere.nvirellia.im";
          description = ''
            The zone this host's services answer under. Each published name is
            `<label>.<domain>`, the certificate covers `*.<domain>`, and the
            zone's DNS records point at this host, so no other host may serve
            part of it.
          '';
        };

        proxies = lib.mkOption {
          type = lib.types.attrsOf (
            lib.types.submodule {
              options = {
                upstream = lib.mkOption {
                  type = lib.types.str;
                  example = "127.0.0.1:3000";
                  description = ''
                    The address Caddy proxies this name to, with a scheme when
                    the upstream serves HTTPS.
                  '';
                };

                upstreamInsecureTls = lib.mkOption {
                  type = lib.types.bool;
                  default = false;
                  description = ''
                    Accept the upstream's certificate without verifying it, for
                    a listener that serves the self-signed certificate it
                    generated itself.
                  '';
                };
              };
            }
          );
          default = { };
          description = ''
            The names this host publishes, keyed by their label: `proxies.foo`
            answers at `foo.<domain>`. The importing machine declares its own
            services here; the ingress knows about TLS and reachability, not
            about which services run beside it.
          '';
        };

        lanSources = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          example = [ "10.0.0.0/24" ];
          description = ''
            IPv4 sources that reach the ingress besides the tailnet. A host
            whose LAN and public addresses share one interface cannot admit the
            LAN by interface without also admitting the internet, so these are
            matched as packet sources instead.
          '';
        };
      };

      config = {
        sops.secrets."cloudflare-api-token" = {
          format = "yaml";
          key = "cloudflare_api_token";
          sopsFile = config.constants.resources.getSecretPath "ingress.yaml";
          owner = "root";
          group = "root";
          mode = "0400";
          restartUnits = [ "caddy.service" ];
        };

        # The DNS provider reads the token from its environment, and an
        # environment file needs `NAME=value`: the secret's own file holds the
        # bare value, so render the variable from its placeholder.
        sops.templates."caddy-env" = {
          content = "CLOUDFLARE_API_TOKEN=${config.sops.placeholder."cloudflare-api-token"}";
          owner = "root";
          group = "root";
          mode = "0400";
          restartUnits = [ "caddy.service" ];
        };

        services.caddy = {
          enable = true;

          # nixos-26.05 carries no Caddy with the Cloudflare DNS plugin, and only
          # the DNS-01 challenge can issue the wildcard certificate. Take the
          # unstable set's builder and add that one provider.
          package = pkgs.unstable.caddy.withPlugins {
            plugins = [ "github.com/caddy-dns/cloudflare@v0.2.4" ];
            hash = "sha256-Oirb6ZtU/c6C/SfICWpfBAEGDTepWShPQdWW0LlhF20=";
          };

          email = config.constants.nvirellia.email;
          environmentFile = config.sops.templates."caddy-env".path;

          virtualHosts.${certName} = {
            # The wildcard site cannot separate its names by filename, so the
            # whole zone shares one access log.
            logFormat = "output file ${config.services.caddy.logDir}/access-${domain}.log";

            extraConfig = ''
              tls {
                dns cloudflare {env.CLOUDFLARE_API_TOKEN}
              }

              ${lib.concatStringsSep "\n" (lib.mapAttrsToList renderProxy config.services.ingress.proxies)}
              # A name in the zone that no service claims still resolves, and it
              # must answer rather than fall through to the first handle block.
              handle {
                respond "No service is published under this name." 404
              }
            '';
          };
        };

        networking.firewall = {
          # The tailnet reaches the ingress through its own interface, like every
          # other service on this host.
          interfaces.tailnet0.allowedTCPPorts = ports;

          extraInputRules = lib.concatMapStrings (source: ''
            ip saddr ${source} tcp dport { ${portList} } accept
          '') config.services.ingress.lanSources;
        };
      };
    };
}
