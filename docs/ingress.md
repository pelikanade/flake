# HTTPS ingress

`modules/services/ingress.nix` gives neko-sphere's own services a browser-trusted
HTTPS name each: one Caddy instance terminates TLS on 80 and 443 with a wildcard
certificate for `*.neko-sphere.nvirellia.im`, and routes by host name to the
service's loopback port. It replaces the per-service tailnet certificate route —
self-signed warnings, one certificate per service, and a port number in every URL
— for clients that reach the host on the tailnet or on its LAN.

The certificate comes from the ACME DNS-01 challenge, so the wildcard needs no
inbound port 80 and no publicly reachable address. Reachability is a separate
question, answered by the firewall below.

## What it publishes

| Name | Upstream | Notes |
| --- | --- | --- |
| `magpie.neko-sphere.nvirellia.im` | `127.0.0.1:3430` | Magpie's browser page, guarded by `magpie_web_key` |
| `magpie-api.neko-sphere.nvirellia.im` | `127.0.0.1:3425` | The model gateway, every route upstream serves; Caddy flushes a streamed response immediately, so no buffering option is needed |
| `portainer.neko-sphere.nvirellia.im` | `https://127.0.0.1:9443` | Portainer's own listener with its self-signed certificate, which the ingress cannot verify |
| `paseo.neko-sphere.nvirellia.im` | `127.0.0.1:6767` | The Paseo daemon, HTTP and WebSocket |

Any other name in the zone answers 404. The gateway gets its own name rather than
a path prefix, because only upstream knows its full route set; the page and the
gateway are one process on two ports, and a client that needs a base URL needs it
to cover every route.

That list is the host's own publication table. It lives in the machine definition
as `services.ingress.proxies` — one entry per service, keyed by the label it
answers under — and the ingress module knows nothing about which services run
beside it, only how to terminate TLS, route by name and admit what may reach it.

The ingress adds no authentication of its own. Each upstream keeps whatever it
has: the page needs `magpie_web_key`, Portainer needs its login, the Paseo daemon
needs its password, and the gateway accepts what it always accepted — upstream
requires a key only when sharing is enabled, so a caller that reaches the port
uses it. Widening `lanSources` therefore widens access to all four.

The services keep advertising their own addresses: `MAGPIE_PUBLIC_URL` is still
the MagicDNS name, and the omp endpoint in
[modules/secrets/magpie.yaml](../modules/secrets/magpie.yaml) is still the
gateway's port. The ingress adds names; it does not rename what the services tell
their clients.

## DNS

The zone belongs to this host: the wildcard certificate covers `*.<domain>`, so
every name in it must resolve to this host and nothing else may serve part of it.
`services.ingress.domain` names the zone, and the machine definition sets it
beside `networking.hostName`.

Two record sets make the names reachable, and each one serves a different client:

```dns
*.neko-sphere.nvirellia.im      A       10.0.0.21
*.neko-sphere.nvirellia.im      AAAA    <the host's tailnet IPv6 address>
```

- The A record is the LAN address, so a device on the home network reaches the
  names without the tailnet and without a resolver override. A router that strips
  private answers (rebind protection) sees a public record pointing at
  `10.0.0.0/8`; if it does, override the zone on the router or resolve through DoH.
- The AAAA record is the address the tailnet assigns this host (`100.64.0.0/10`
  for IPv4, `fd7a:115c:a1e0::/48` for IPv6). Read it from the tailnet's admin
  console, or from the endpoint's own management API on the host, and add the
  record once the endpoint is enrolled. A tailnet peer that resolves the name
  reaches the host wherever it is; a client outside the tailnet cannot route that
  address at all, which is the point.

Certificates for the zone need a Cloudflare API token with DNS edit rights on the
zone that holds it — the delegated `neko-sphere.nvirellia.im` zone if you made
one, otherwise `nvirellia.im`. That token is a secret and lives in the encrypted
document described below.

## The certificate

Caddy answers the DNS-01 challenge itself, using the Cloudflare provider compiled
into its binary. `nixos-26.05` carries no Caddy with that plugin, so the ingress
takes the unstable set's `caddy.withPlugins` with one plugin pinned by version and
vendor hash; the package therefore builds a private Caddy rather than reusing the
cached one.

The token read is `cloudflare_api_token` in
[modules/secrets/ingress.yaml](../modules/secrets/ingress.yaml), whose recipients
are neko-sphere's host key and the maintainer. NixOS activation renders it into
the variable `CLOUDFLARE_API_TOKEN` in a root-only environment file, which the
Caddyfile reaches as `{env.CLOUDFLARE_API_TOKEN}`; Caddy reads it at start and
Caddy's own storage holds the issued certificate under `/var/lib/caddy`.

Until the document holds a real token, Caddy starts and every request fails TLS:
the placeholder `REPLACE_WITH_CLOUDFLARE_API_TOKEN` is not a credential. Fill it
from a checkout with `sops modules/secrets/ingress.yaml`, and give the zone's
records time to exist before the first issuance — the DNS-01 challenge waits for
the TXT record it creates, but not for anything else. `journalctl -u caddy` names
the failure; a staging run with a real token is the fastest way to see a
certificate without burning production rate limits.

## Reachability

`networking.firewall` admits 80 and 443 on `tailnet0`, the interface the sing-box
Tailscale endpoint presents to peers, exactly as the other service ports on this
host are admitted. The host carries its LAN and its public addresses on one
interface, so admitting the LAN by interface would also admit the internet:
`services.ingress.lanSources` lists the IPv4 sources that may reach the ingress,
and the module renders one `ip saddr <source> tcp dport { 80, 443 } accept` rule
for each. Nothing is admitted on the host's public addresses — the machine
definition lists only its LAN subnet.

Two things this does not do:

- Port 443 is not open to the internet. The zone's records point at LAN and
  tailnet addresses, so a request from outside cannot reach a listener anyway, and
  no rule admits one. Making the ingress public is a separate decision that needs
  records, a firewall rule and an honest look at the four upstreams' own
  authentication.
- The tailnet half is a firewall boundary only while the endpoint owns
  `tailnet0`. Today `modules/services/sing-box.nix` leaves `system_interface` at
  its default, so the Tailscale endpoint runs in sing-box's userspace network
  stack: peer packets are forwarded to loopback by sing-box itself and never
  traverse this host's firewall, where every `tailnet0` rule is inert. Reachability
  is unaffected — loopback keeps working, so the ingress answers peers — but the
  rule above is not what restricts them. A host that needs the firewall to bound
  peer access has to turn `system_interface` on and verify the routes it changes.

## Adding a service

A new name in the zone costs one entry in the machine definition and no new
certificate:

```nix
services.ingress.proxies.wiki = { upstream = "127.0.0.1:3000"; };
```

The module renders one `handle` block per entry and keeps the catch-all 404 last,
so entries need no ordering care. An upstream that serves its own self-signed
certificate takes `upstreamInsecureTls = true` beside an `https://` address, as
Portainer does. Add the DNS record only if the name must resolve; the certificate
already covers it.

## Verifying

Deployment is separate and authorized on its own; after a switch, from a LAN
client and from a tailnet peer:

```sh
curl -sI https://magpie.neko-sphere.nvirellia.im/ | head -1        # 401 or 200
curl -s  https://magpie-api.neko-sphere.nvirellia.im/v1/models | head
openssl s_client -connect magpie.neko-sphere.nvirellia.im:443 -servername magpie.neko-sphere.nvirellia.im \
  </dev/null 2>/dev/null | openssl x509 -noout -subject -dates
curl -sI https://portainer.neko-sphere.nvirellia.im/ | head -1     # Portainer's login page
curl -si http://magpie.neko-sphere.nvirellia.im/ | head -1         # 308 to the https URL
```

The certificate's subject must be `*.neko-sphere.nvirellia.im` and its issuer a
public CA; a browser that still warns is reading another host's answer. A Paseo
client proves the WebSocket path only by connecting: the daemon's own logs record
the session. `journalctl -u caddy` holds issuance and routing failures, and
`/var/log/caddy/access-neko-sphere.nvirellia.im.log` holds one line per request
with the host name it carried.
