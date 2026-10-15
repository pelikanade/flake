# HTTPS ingress

`modules/services/ingress.nix` gives neko-sphere's own services a browser-trusted
HTTPS name each: one Caddy instance terminates TLS on 80 and 443 with a wildcard
certificate for `*.neko-sphere.nvirellia.im`, and routes by host name to the
service's loopback port. It replaces the per-service tailnet certificate route —
self-signed warnings, one certificate per service, and a port number in every URL
— for every client that has joined the tailnet, a home device included.

The certificate comes from the ACME DNS-01 challenge, so the wildcard needs no
inbound port 80 and no publicly reachable address. Reachability is a separate
question, answered by the firewall below.

## What it publishes

| Name | Upstream | Notes |
| --- | --- | --- |
| `magpie.neko-sphere.nvirellia.im` | `127.0.0.1:3430` | Magpie's browser page, guarded by `magpie_web_key` |
| `magpie-api.neko-sphere.nvirellia.im` | `127.0.0.1:3425` | The model gateway, every route upstream serves. Caddy's forwarding header makes upstream treat the call as one from another machine, so it needs an enabled gateway key; Caddy flushes a streamed response immediately, so no buffering option is needed |
| `portainer.neko-sphere.nvirellia.im` | `https://127.0.0.1:9443` | Portainer's own listener with its self-signed certificate, which the ingress cannot verify |
| `paseo.neko-sphere.nvirellia.im` | `127.0.0.1:6767` | The Paseo daemon, HTTP and WebSocket. It refuses an unknown `Host` header, so the module declares this zone to it through `PASEO_HOSTNAMES` |

Any other name in the zone answers 404. The gateway gets its own name rather than
a path prefix, because only upstream knows its full route set; the page and the
gateway are one process on two ports, and a client that needs a base URL needs it
to cover every route.

That list is the host's own publication table. It lives in the machine definition
as `services.ingress.proxies` — one entry per service, keyed by the label it
answers under — and the ingress module knows nothing about which services run
beside it, only how to terminate TLS, route by name and admit what may reach it.

The ingress adds no authentication of its own, and it changes what each upstream
sees. Magpie's gateway reads a forwarding header as "not this machine" and then
requires an enabled gateway key, so calls through the ingress carry one, exactly
as a client of the shared gateway does; a caller that reaches the port directly on
loopback needs none. The page beside it needs its own sign-in key, Portainer needs
its login, and the Paseo daemon needs its password. Widening `lanSources`
therefore widens access to all four, subject to those credentials.

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

One wildcard record makes the names reachable, and it points into the tailnet:

```dns
*.neko-sphere.nvirellia.im      A       <the host's tailnet IPv4 address>
```

The tailnet assigns that address to this node and keeps it; read it from the
tailnet's admin console once the endpoint is enrolled, and add the record then. It
routes only inside the tailnet, so a client that has joined resolves the zone to an
address it can connect to, while a client that has not joined learns an address it
cannot reach instead of a port that answers. There is no AAAA record beside it: a
second address family would only add something for every client to race against,
and the tailnet's IPv6 address reaches the same host.

A device on the home network that is not on the tailnet reaches the names through
the LAN instead, which needs a local answer rather than the public one: point the
zone at `10.0.0.21` in the router's DNS or in that device's hosts file. The
firewall admits the LAN subnet as a source for exactly that case. Without the
override such a device resolves the public record, finds no route into
`100.64.0.0/10`, and cannot connect.

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

That vendor hash covers the vendored dependency graph of the Caddy version beside
it, so it is only as current as the `nixpkgs-unstable` pin: an input update that
moves Caddy makes the build fail with `hash mismatch`, naming the hash to put
back. A hash taken from that failure cannot quietly pick a different plugin: the
package's install check reads Caddy's own `build-info` and requires
`github.com/caddy-dns/cloudflare` at the pinned version.

The token read is `cloudflare_api_token` in
[modules/secrets/ingress.yaml](../modules/secrets/ingress.yaml), whose recipients
are neko-sphere's host key and the maintainer. NixOS activation renders it into
the variable `CLOUDFLARE_API_TOKEN` in a root-only environment file, which the
Caddyfile reaches as `{env.CLOUDFLARE_API_TOKEN}`; Caddy reads it at start and
Caddy's own storage holds the issued certificate under `/var/lib/caddy`.

A document that still holds its placeholder (`REPLACE_WITH_CLOUDFLARE_API_TOKEN`)
is not a credential: Caddy starts, and every request fails TLS until it is filled
from a checkout with `sops modules/secrets/ingress.yaml`. The zone's records must
exist before the first issuance — the DNS-01 challenge waits for the TXT record it
creates, but for nothing else. `journalctl -u caddy` names the failure: a token
without DNS edit rights on that zone is refused there, and a staging run with a
real token is the fastest way to see a certificate without burning production rate
limits.

## Reachability

The tailnet needs no firewall rule: a peer reaches this host's tailnet address and
sing-box's userspace endpoint delivers the connection to loopback, which never
enters the input chain. The firewall's only job here is the LAN, and the host
carries its LAN and its public addresses on one interface, so admitting the LAN by
interface would also admit the internet: `services.ingress.lanSources` lists the
IPv4 sources that may reach the ingress, and the module renders one
`ip saddr <source> tcp dport { 80, 443 } accept` rule for each. The machine
definition lists only its LAN subnet, which is what a device that overrides the
zone locally needs; nothing is admitted on the host's public addresses.

Two things this does not do:

- Port 443 is not open to the internet. The zone's record points into the tailnet,
  so a request from outside cannot reach a listener anyway, and no rule admits one.
  Making the ingress public is a separate decision that needs records, a firewall
  rule and an honest look at the four upstreams' own authentication.
- Nothing bounds a peer beyond the tailnet's ACLs and the upstreams' own
  authentication: the endpoint runs in sing-box's userspace stack, so a peer's
  connection to this host's tailnet address becomes a local dial, and every
  listener on the host accepts what the endpoint forwards, not only the ingress.
  A host that wants the firewall to bound peer access has to turn
  `system_interface` on — which puts peer traffic on a real interface — and then
  name every port peers should reach, because the input chain drops the rest.

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

Deployment is separate and authorized on its own; after a switch, from a tailnet
peer, and from a LAN client that resolves the zone through the LAN:

```sh
curl -sI https://magpie.neko-sphere.nvirellia.im/ | head -1        # 401 or 200
curl -s -H "Authorization: Bearer $MAGPIE_KEY" \
  https://magpie-api.neko-sphere.nvirellia.im/v1/models | head   # $MAGPIE_KEY: the gateway key from modules/secrets/magpie.yaml
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
