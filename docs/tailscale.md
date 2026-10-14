# Native sing-box Tailscale pilot

Every host that needs the tailnet ends up importing `sing-box`: the `workstation`
role carries it for Asymmetry and Parallax, and neko-sphere imports it alongside
`server`.
A host that should join the tailnet *without* sing-box needs its own `tailscaled`
module, which does not exist yet. The endpoint, the MagicDNS server and the routing
rules are declared in [modules/services/sing-box.nix](../modules/services/sing-box.nix)
with the rest of the sing-box configuration. `tailscaled` is not installed or
enabled, and no separate Tailscale service or runtime configuration merge is used.

`modules/secrets/tailscale.yaml` holds only the tailnet auth key, so the same
document serves the endpoint here and a `tailscaled` module later.
`modules/secrets/sing-box.yaml` holds the proxy credentials and endpoints.
Asymmetry, Parallax and neko-sphere all read both and all run the endpoint, so filling the
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
the service's existing `StateDirectory`, `ephemeral=false`, sing-box's userspace
network stack, and the WireGuard peer port `41641`. It omits `hostname`, so each
host registers under its own system hostname. It accepts subnet routes advertised
by other nodes, does not use or advertise an exit node, and enables neither
Tailscale SSH nor Taildrop.

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

The endpoint runs in sing-box's userspace network stack, so peer packets reach
its Netstack rather than a real interface. A peer that dials this host's tailnet
address lands there, and sing-box rewrites the destination to loopback before the
routing engine sees it: it then dials `127.0.0.1:<port>` and the service answers a
local connection. Nothing of the kind traverses the host firewall, and no
`tailnet0` exists for a rule to name.

Locally generated traffic to a peer takes the other direction. `auto_redirect`
sends new connections into the tun before the kernel's route is used, and the rule
for `100.64.0.0/10` and `fd7a:115c:a1e0::/48` routes them to the `tailnet`
endpoint, which dials the peer over the tunnel. Without that rule such a connection
would match no rule, fall through to the `final` proxy and never reach the peer:
`ip_is_private` does not cover Tailscale's CGNAT range.

Because delivery is to loopback, a service that peers should reach only has to
listen there; every service on this host binds every interface, which covers it.
The DNS section above is unaffected: sing-box resolves names itself, so the
`tailnet-dns` rule still applies.

`system_interface: true` would replace all of that with a real `tailnet0` whose
routes the kernel owns. Peer traffic would then enter the host's firewall, where
the input chain's policy drops what it is not told to admit, and a host that turns
it on has to name every port peers should reach.

### Firewall

`modules/services/sing-box.nix` opens UDP 41641 for the endpoint's peer transport,
because peers reach that port on the host's own addresses rather than through the
tunnel. Nothing else is opened for the tailnet, and no service needs
`openFirewall`: with the endpoint in its userspace stack, a peer's connection
arrives as a local dial and never reaches the input chain, so a `tailnet0` rule
would match nothing.

One port is nonetheless admitted everywhere: `services.openssh.openFirewall`
defaults to true in nixos-26.05, and its `allowedTCPPorts` entry puts 22 on every
interface, this host's public address included. Nothing else on this host is
reachable without a key or a password, and that rule is the only thing that admits
SSH on a LAN address; `openFirewall = false` in
[modules/services/ssh.nix](../modules/services/ssh.nix) would close it.

The tailnet's ACLs and each service's own authentication are therefore the whole
boundary for peer traffic. Every service binds every interface, so the endpoint
forwards anything a peer asks for, loopback listeners included — the Paseo daemon
takes `0.0.0.0:6767` and keeps its password, and SSH keeps its keys. Restrict 6767
with tailnet grants before relying on direct access.

The [HTTPS ingress](ingress.md) is the one thing the firewall still names, and it
matches this host's LAN subnet as a packet source rather than an interface: the
host's LAN and public addresses share one interface, so the LAN is what a local
override resolves to and the public address must stay closed.

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
