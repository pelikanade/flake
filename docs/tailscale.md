# Tailnet

Every host that joins the tailnet runs `tailscaled` on its own, beside the proxy
rather than inside it:

| Module | Owns |
| --- | --- |
| [modules/services/tailscale.nix](../modules/services/tailscale.nix) | The daemon: the auth key, the peer port, the trusted interface, and the rule that keeps the node's own transport out of the tun. |
| [modules/apps/tailscale-desktop.nix](../modules/apps/tailscale-desktop.nix) | The desktop side: the account that may drive the daemon, certificate access, and Trayscale. |

`workstation` imports both for Asymmetry and Parallax; neko-sphere imports the
daemon alone. [sing-box](sing-box.md) is the proxy and nothing else: it declares
no tailnet endpoint, no tailnet DNS server, no tailnet route and no tailnet key.

The daemon owns a real `tailscale0` interface with the node's tailnet address, its
own routes and its own resolver entries. That is what the endpoint inside sing-box
could not offer: `tailscale status`, `tailscale serve`, `tailscale cert` and the
rest of the client work, because there is an interface and a daemon to drive.

## The auth key

`modules/secrets/tailscale.yaml` holds one value, `tailscale_auth_key`, and the
daemon is its only consumer. It is provisioned root-only at
`/run/secrets/tailscale_auth_key` and read by `tailscaled-autoconnect.service`,
which runs `tailscale up` while the daemon reports that it needs a login.

```sh
nix develop
sops modules/secrets/tailscale.yaml
```

The key must be reusable: every host that imports the daemon registers with the
same document. Choose its reuse, approval and expiry settings in the tailnet, build
the affected machines, then authorize deployment separately. Replacing the value
restarts `tailscaled-autoconnect.service`, which retries the login without a
restart of the daemon.

## Runtime policy

The daemon listens for peer traffic on UDP `41641`, which the module opens on every
interface: peers reach that port on the host's own addresses, not through the
tunnel. It accepts subnet routes advertised by other nodes, matching the policy the
sing-box endpoint had; it advertises no exit node and neither uses one nor enables
Tailscale SSH. It omits `hostname`, so each host registers under its system
hostname, and its state lives under `/var/lib/tailscale`.

A peer's connection arrives on `tailscale0`, which the module adds to
`networking.firewall.trustedInterfaces`. That is the whole firewall story on this
side: the tailnet is a WireGuard-authenticated network, what arrives on the
interface comes from a peer the control plane placed in the tailnet, and the
tailnet's ACLs and each service's own authentication are what bound it. Peer
traffic enters the input chain, which it did not when the endpoint forwarded
connections into loopback from its own userspace stack.

Because the node has a real interface, `tailscale serve` can also front a service
that listens only on loopback — which is how a service that should not be reachable
on the LAN stays reachable on the tailnet.

## Why the tun and the tailnet do not fight

Two mechanisms keep the two apart, and both are needed.

**The carrier-grade NAT range belongs to the tailnet.** `100.64.0.0/10` and
`fd7a:115c:a1e0::/48` are in the tun's `route_exclude_address`, which keeps them
out of the tun's routes *and* out of the redirect that carries local traffic into
it. A connection to a peer therefore keeps the route the kernel gave it — through
`tailscale0`, which the daemon owns — and the tailnet's resolver at
`100.100.100.100` answers for the node instead of being hijacked into sing-box. The
same exclusion covers NetBird's ranges, which are inside the same CGNAT block, so
NetBird's peers and its routes leave through `wt0` as the kernel routes them.

**The node's own transport belongs on the physical interface.** Its control
connection, its DERP relays and its WireGuard handshakes go to public addresses,
which the tun *would* capture and proxy. The module therefore runs a unit beside
the daemon — `tailscale-tun-bypass.service`, upheld by `tailscaled.service`, so it
re-runs whenever the daemon (re)starts — that installs an nftables rule in the
output hook, at a priority below the tun's own chains, matching
`socket cgroupv2 level 2 "system.slice/tailscaled.service"` and setting
`services.sing-box.tunBypassMark`: the mark the tun treats as its own, and the mark
it puts on every connection it dials itself. sing-box skips a packet that carries
it, so the whole transport keeps the route the kernel gave it.

The rule is installed at run time rather than declared in
`networking.nftables.tables` because the boot ruleset is checked and loaded before
the daemon's cgroup exists: a rule whose cgroup path cannot be resolved fails the
whole ruleset, and the firewall is loaded long before `tailscaled`. A separate unit
also fails visibly (in `systemctl --failed`) instead of hiding in a start hook, and
its failure costs only the tailnet's direct paths.

Neither of the daemon's own defences substitutes for this rule. Its interface
enumeration decides which local endpoints it advertises and how it hole-punches, not
whether its packets enter the tun: `auto_redirect` captures them in the output hook
before any of that matters. The mark it sets on its own sockets (`SO_MARK 0x80000`
on Linux, with the `fwmark 0x80000/0xff0000` routing rules it installs) is not this
mark — sing-box skips only `services.sing-box.tunBypassMark` — and measured against
this configuration, a socket carrying `0x80000` is captured exactly like an unmarked
one, over TCP and UDP alike. The one thing sing-box does skip is a socket bound with
`SO_BINDTODEVICE`, when `strict_route` is off as it is here, and that is the
daemon's fallback only when `SO_MARK` is unavailable or
`TS_FORCE_LINUX_BIND_TO_DEVICE` is set.

Without that rule the tailnet would be exposed to the proxy, which is worse than it
sounds: the node's observed endpoint, the address peers are told to dial, would be
whatever addresses the proxy exits from, so peers could never establish a direct
path to it. The tailnet would fall back to relaying every connection through a
public DERP server, through the proxy on this side.

## DNS

The tailnet's own resolver is `100.100.100.100`, which `tailscaled` reaches through
its interface and publishes to the system resolver with the tailnet's routing and
search domains, once MagicDNS is enabled in the tailnet. Because that address is
inside the excluded range, the tun's DNS hijack never sees those queries.

Ordinary name resolution is unchanged: the tun still routes everything else to its
own resolver on `172.19.0.2`, sing-box answers from the servers and rules declared
in [the sing-box module](sing-box.md), and a query that reaches a public resolver
address directly is captured by the tun rather than leaving the host. A consumer
that must not depend on the resolver's search list addresses a peer as
`<peer>.<tailnetDnsName>` through `constants.getTailnetFqdn`; that name needs only
the routing domain.

The tailnet's own DNS settings matter here: if the tailnet is configured to
override local DNS with a global nameserver, `tailscaled` publishes that nameserver
for every name and the arrangement above no longer holds. Keep global nameservers
off and use split DNS, or accept that the tailnet's server answers everything.

## Verification

Checked here, on 2026-10-17, without a tailnet:

- All three machine configurations evaluate and build, and the rendered sing-box
  configuration passes `sing-box check` with no tailnet endpoint, DNS server,
  outbound or route left in it.
- A disposable network namespace ran the repository's tun options verbatim (tun
  address, `auto_route`, `auto_redirect`, `route_exclude_address`) with the
  nixos-fw ruleset this configuration generates, a veth pair named `tailscale0`
  with a peer behind it, a second pair standing in for the physical interface, and
  a sing-box route set whose catch-all refuses what the tun captured. Then:
  - a peer's `100.64.0.5` answered TCP and UDP from the host — the tun neither
    captured nor routed those connections;
  - the tailnet resolver at `100.100.100.100` answered for itself, so the query was
    not hijacked into sing-box, while a query to the tun's own resolver address was
    answered by sing-box and a query to a public resolver address was captured;
  - traffic carrying `services.sing-box.tunBypassMark` reached a public destination
    that an unmarked connection could not — both TCP and UDP;
  - a peer reached a service bound to the host's tailnet address through the
    generated firewall ruleset, which is the path `tailscale serve` uses;
  - the chains sing-box installed carry counters on the two rules that matter:
    `ip daddr { 10.0.0.0/8, 100.64.0.0/10 } return` and `meta mark 0x2024 return`
    both took packets, and the tun's table held no route for either range.
- The real `tailscaled` ran beside the same tun in a namespace: it created its
  `tailscale0`, its own routing rules and its own `ip filter`/`ip nat` tables
  without disturbing the tun's `inet sing-box` table, `tailscale status` answered
  `Logged out.` through the daemon's socket, and the tun still captured a public
  destination afterwards. `tailscale serve` in that state reports `Logged out.`,
  which is as far as it can be exercised without a control plane.

Not checked here, because they need the real tailnet and a deployment. Once the
auth key is in place and deployment is separately authorized, on each enrolled
host:

```sh
tailscale status                                   # the node is Running, peers listed
tailscale ping <a peer>                            # direct, not only "via DERP"
ip route get 100.100.100.100                       # dev tailscale0, not tun0
resolvectl query <peer>                            # a bare peer name, then its FQDN
curl --fail --silent http://<a peer>:<port>/       # a peer reaches this host
systemctl status tailscaled tailscale-tun-bypass   # both active; the second installs the bypass rule
```

Then exercise `tailscale serve`: publish a loopback-only service (`tailscale serve
--bg 8080`, or the GUI) and reach it from another tailnet device by the node's
MagicDNS name, including after a reboot, and confirm with
`tailscale serve status` that the node reports the right name. Serving HTTPS also
needs the tailnet to grant the node the `https` capability — a tailnet-side setting,
not a repository one.
