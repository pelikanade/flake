# Native sing-box Tailscale pilot

Every host that needs the tailnet ends up importing `sing-box`: the `workstation`
role carries it for Asymmetry and Parallax, and box imports it alongside `server`.
A host that should join the tailnet *without* sing-box needs its own `tailscaled`
module, which does not exist yet. The endpoint, the MagicDNS server and the routing
rules are declared in [modules/services/sing-box.nix](../modules/services/sing-box.nix)
with the rest of the sing-box configuration. `tailscaled` is not installed or
enabled, and no separate Tailscale service or runtime configuration merge is used.

`modules/secrets/tailscale.yaml` holds only the tailnet auth key, so the same
document serves the endpoint here and a `tailscaled` module later.
`modules/secrets/sing-box.yaml` holds the proxy credentials and endpoints.
Asymmetry, Parallax and box all read both and all run the endpoint, so filling the
auth key enrolls every host that runs sing-box, not just the two workstations. Use a
reusable auth key, because the same key is read by more than one host.

NetBird's workstation UI and its local daemon remain for workplace login. The
workstation machines declare a NetBird client, but no account is provisioned, so
joining a NetBird network is a manual step through the desktop UI. Personal peer
access uses Tailscale.

## Configure the auth key

The endpoint's `auth_key` is the placeholder
`REPLACE_WITH_TAILSCALE_AUTH_KEY`, stored in its own document as
`tailscale_auth_key`. Edit it with SOPS, without creating a plaintext secret file:

```sh
nix develop
sops modules/secrets/tailscale.yaml
```

Choose the key's reuse, approval and expiry settings in the tailnet. Build the
affected configurations, then separately authorize deployment.

While the placeholder is unchanged, sing-box still starts: the endpoint logs a
failed login and every other inbound, outbound, DNS server and route keeps
working. Replacing the value restarts `sing-box.service` wherever activation
rereads the document.

## Runtime policy

### Endpoint

The `tailnet` endpoint uses persistent `/var/lib/sing-box/tailscale` state under
the service's existing `StateDirectory`, `ephemeral=false`, the system interface
`tailnet0`, and the WireGuard peer port `41641`. It omits `hostname`, so each
host registers under its own system hostname. It does not accept subnet routes,
use or advertise an exit node, enable Tailscale SSH or run Taildrop.

### DNS

The `tailnet-dns` server points at the `tailnet` endpoint with
`accept_default_resolvers=false` and `accept_search_domain=true`. A prepended DNS
rule with `preferred_by` gates MagicDNS names and DNS route suffixes to it. The
existing resolvers and the `cfdns` final rule stay in place, so ordinary name
resolution is unchanged. Enable MagicDNS in the tailnet to use peer names.

MagicDNS answers fully qualified names only, and a search domain does not help
here: the `resolve` NSS module answers "not found" for a bare label before `dns`,
the only module that applies a search list, ever runs. A consumer therefore
addresses a peer fully qualified; `constants.getTailnetFqdn` in
[modules/constants/tailnet.nix](../modules/constants/tailnet.nix) expands a peer
name for a module that needs the address.

### Routes

With `system_interface: true` the endpoint owns the real interface `tailnet0` and
the kernel owns its routes: peer traffic enters and leaves through `tailnet0`
without returning to sing-box's routing engine. The document therefore carries no
`inbound: "tailnet"` or endpoint-preference route rules — they would match nothing
— and inbound peer traffic is governed by the host firewall instead.

`auto_redirect` still redirects locally generated connections into the tun before
the kernel's route is used, so the tailnet's own ranges are declared `direct` in
the route rules: `100.64.0.0/10` and `fd7a:115c:a1e0::/48` go out directly, and the
same ranges stay out of the tun's routes. Without the direct rule a connection to
a peer matches no rule, falls through to the `final` proxy and never reaches the
peer — `ip_is_private` does not cover Tailscale's CGNAT range.

Because a peer addresses the host's tailnet address rather than loopback, every
service that peers should reach listens on all interfaces. The DNS section above is
unaffected: sing-box resolves names itself, so the `tailnet-dns` rule still
applies.

Turning `system_interface` off would put the endpoint back in sing-box's userspace
network stack, where peer packets do reach the routing engine; that configuration
would need inbound and endpoint-preference rules again.

### Firewall

`modules/services/sing-box.nix` opens UDP 41641 for the endpoint's peer transport,
because peers reach that port on the host's own addresses rather than through the
tunnel. Every other port belongs to the service that listens on it, and each one
admits only the tailnet interface `tailnet0`: `ssh` opens 22 and `paseo-daemon`
6767. A service that is not imported opens nothing, and none of them needs
`openFirewall`.

The firewall, not the route rules, is what admits inbound peer traffic. Every
service binds all interfaces so it is reachable on the host's tailnet address —
the Paseo daemon takes `0.0.0.0:6767` — and loopback keeps working. Nothing is
admitted on a LAN or public interface.

Restrict 6767 with tailnet grants and configure the Paseo password before relying
on direct access.

## Pilot verification

Configuration checks and `sing-box check` do not enroll a host. After the real key
is filled in and deployment is authorized, verify peer-name DNS, SSH in both
directions, direct versus DERP connectivity, and ordinary internet proxy
behavior on each enrolled host. Confirm workplace NetBird login still works
through the desktop UI, and exercise omp's model selection, streaming, search and
a tool-calling conversation. Check reboot persistence and how a sing-box restart
interrupts peer connections before expanding the pilot. Verify that a peer really
reaches the Paseo daemon on 6767, instead of trusting evaluation alone. See the
upstream
[endpoint](https://sing-box.sagernet.org/configuration/endpoint/tailscale/),
[DNS server](https://sing-box.sagernet.org/configuration/dns/server/tailscale/)
and [routing rules](https://sing-box.sagernet.org/configuration/route/rule/).
