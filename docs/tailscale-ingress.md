# Tailscale Services ingress

`modules/services/tailscale-ingress.nix` publishes neko-sphere's own services under stable
Tailscale Services names. The daemon terminates the tailnet's HTTPS certificate
and forwards each endpoint to a loopback port; there is no Caddy instance, no
wildcard certificate, no ACME challenge and no Cloudflare token.

A Tailscale Service is a named, virtual address in the tailnet rather than a
node's address. Each one gets a MagicDNS name of its own, so clients use
`https://nsphere-paseo.dwelf-hoki.ts.net:6767/` or
`https://nsphere-magpie.dwelf-hoki.ts.net:3430/` even though every service runs
on the same host, and a service keeps its name if it later moves to another
host.

## What it publishes

| Service | Endpoint | Local target | Notes |
| --- | --- | --- | --- |
| `svc:nsphere-freezer` | `tcp:443` | `http://127.0.0.1:8080` | The freezer container; HTTPS is terminated here |
| `svc:nsphere-magpie` | `tcp:3425` | `http://127.0.0.1:3425` | Magpie's gateway, every route upstream serves |
| | `tcp:3430` | `http://127.0.0.1:3430` | Magpie's browser page, guarded by `magpie_web_key` |
| `svc:nsphere-nvirellia-im` | `tcp:80` | `http://127.0.0.1:8081` | The personal site over HTTP |
| | `tcp:443` | `http://127.0.0.1:8081` | The same backend over the tailnet certificate |
| `svc:nsphere-portainer` | `tcp:443` | `https+insecure://127.0.0.1:9443` | Portainer's own HTTPS listener with its self-signed certificate |
| `svc:nsphere-paseo` | `tcp:6767` | `http://127.0.0.1:6767` | The Paseo daemon, HTTP and WebSocket |

The tailnet answers `svc:<name>` at `<name>.<tailnetDnsName>`, so
`svc:nsphere-magpie` is `nsphere-magpie.dwelf-hoki.ts.net`.
`tailnetDnsName` is the constant in
[modules/constants/tailnet.nix](../modules/constants/tailnet.nix).

A target whose scheme is `http` or `https` gets Tailscale's layer-7 handler: the
daemon terminates TLS with a certificate for the service name and reverse-proxies
the request, preserving the original `Host` header and adding the forwarding
headers a web framework reads. A target with the `tcp` scheme would forward the
connection unmodified, which is what a database or an upstream that terminates
its own TLS needs. `https+insecure` is the layer-7 handler for an upstream that
serves HTTPS with a certificate the daemon cannot verify, as Portainer does.
TCP is the only transport a Service endpoint can advertise.

That table is the host's own publication table. It lives in the machine
definition as `services.tailscale-ingress.services`, keyed by service name, and each entry
maps the endpoints defined in the tailnet to local targets. The module knows how
to apply the configuration and advertise it; it does not define services, their
ports or their access policy.

## Tailnet setup

Three things live in the tailnet's admin console rather than in this repository:

1. **The Service definitions.** Each service needs its name, its endpoint set
   (`tcp:443`, or `tcp:3425` and `tcp:3430`, exactly as in the table), and
   optionally a tag.
2. **A tagged node identity.** A Service host must authenticate with a tag, not a
   user account. neko-sphere carries `tag:neko-sphere`, so it is eligible.
3. **Approval.** A newly advertised host waits for an admin unless an
   `autoApprovers.services` rule covers the service and the host's tag.

The module fails visibly when the local configuration cannot be applied: a
malformed endpoint or target makes `tailscale serve set-config` fail, and
`systemctl status tailscale-serve` and its journal say which one. A service the
tailnet does not define, or one whose endpoints do not match its definition, is
accepted locally but never becomes `Connected` in the admin console; the
`service-host` entry in `tailscale status --json` is where that shows.

## How it is applied

`systemd.services.tailscale-serve` is a oneshot unit:

```sh
tailscale serve set-config --all <generated-json>
```

The generated file is Tailscale's Service configuration format (`version
0.0.1`), one `svc:` entry per option, with the endpoints copied verbatim and
`advertised` true. `set-config --all` replaces every service's handlers and the
node's advertised-service list, so removing an entry from the machine definition
removes both its forwarding rule and its advertisement on the next switch. The
CLI's separate `advertise` subcommand is only needed when applying one service
with `--service`. Node-level Serve and Funnel entries are stored elsewhere and
are not touched.

The unit starts after `tailscaled` and `tailscaled-autoconnect`, waits until the
backend reports `Running`, then applies the configuration. `tailscaled.upholds`
starts it again whenever the daemon restarts, because a restart drops the
advertisements even though the configuration survives.

Retiring a service is declarative through the same command: the next switch
stops advertising it and deletes its handlers. To let existing connections close
gracefully first, drain it before the switch:

```sh
tailscale serve drain svc:<name>
```

## Reachability and authentication

Only tailnet traffic reaches a Service. The virtual address belongs to the
tailnet, the connection arrives through `tailscale0`, which
[the tailnet module](tailscale.md) lists as a trusted interface, and there is no
LAN listener and no firewall rule to widen. A device that has not joined the
tailnet cannot resolve or reach any of these names.

The `tailscale-ingress` module adds no authentication. Magpie's page needs its sign-in key, its
gateway requires an enabled gateway key for calls that arrive through the proxy
(as it does for any non-loopback caller), and the Paseo daemon needs its
password. The tailnet's ACLs are the other bound: an `svc:` name is a grant
destination, so a policy can admit one service without admitting the rest.

The services keep advertising their own addresses. `MAGPIE_PUBLIC_URL` still uses
the node's MagicDNS name and port, and the omp endpoint in
[modules/secrets/magpie.yaml](../modules/secrets/magpie.yaml) is still the
gateway's port. It adds names; it does not rename what the services
tell their clients.

## The personal site and Funnel

`nsphere-nvirellia-im` is the personal site. Its `tcp:443` endpoint is already a
layer-7 HTTPS handler, so the backend does not need to know whether the request
came from the tailnet or, later, from the public internet.

Tailscale Funnel does not accept a `svc:` target: it publishes a port on the
node's own MagicDNS name (`neko-sphere.dwelf-hoki.ts.net`). Public exposure is
therefore a separate declaration, and `nvirellia.im` CNAMEs to the Funnel name
Tailscale prints. The Service remains the tailnet-internal name; both paths can
reach the same local target.

Funnel works only over TLS and only on ports 443, 8443 and 10000. Port 443 on the
node is free here: Services listen on their own virtual addresses, and nothing
else on this host binds 443.

## Adding a service

1. Define the Service and its endpoints in the admin console.
2. Add its local mapping to the machine definition:

```nix
services.tailscale-ingress.services.nsphere-wiki.endpoints."tcp:443" =
  "http://127.0.0.1:3000";
```

The next switch writes the configuration and advertises the new host; approve it
if no auto-approver matched. The name is available as
`https://nsphere-wiki.dwelf-hoki.ts.net/` once the advertisement is active.

## Verifying

On the host:

```sh
tailscale serve get-config --all       # every service and its endpoint mapping
tailscale serve status                 # node-level Serve and Funnel entries
systemctl status tailscale-serve
tailscale status --json | jq '.Self.CapMap."service-host"'
```

From another tailnet device:

```sh
curl -sI https://nsphere-freezer.dwelf-hoki.ts.net/ | head -1          # 443
curl -sI https://nsphere-magpie.dwelf-hoki.ts.net:3430/ | head -1      # 401 or 200
curl -s  https://nsphere-magpie.dwelf-hoki.ts.net:3425/v1/models | head
curl -sI https://nsphere-nvirellia-im.dwelf-hoki.ts.net/ | head -1     # 443
curl -sI http://nsphere-nvirellia-im.dwelf-hoki.ts.net/ | head -1      # 80
curl -sI https://nsphere-portainer.dwelf-hoki.ts.net/ | head -1        # 443
curl -sI https://nsphere-paseo.dwelf-hoki.ts.net:6767/ | head -1
```

A name that resolves but refuses the connection usually means the host is not
approved for that service; a name that does not resolve means the Service is not
defined in the tailnet. A 502 from a name whose endpoint exists means the local
target is not listening. A Paseo client proves the WebSocket path only by
connecting: the daemon's own logs record the session.
