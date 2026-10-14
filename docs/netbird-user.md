# NetBird in userspace

A NetBird client in userspace networking mode — WireGuard on a Go TCP/IP stack
instead of a TUN device — running as an unprivileged system service and serving
declared services from the network on loopback ports. The client, its tunnels and
the CLI are declared in
[modules/services/netbird-user.nix](../modules/services/netbird-user.nix) as
`services.netbird-user`; the `workstation` role imports the module, and each host
declares what it needs in its own machine definition.

## Why a separate client

The kernel client from
[modules/apps/netbird-desktop.nix](../modules/apps/netbird-desktop.nix) is the
workplace one: it is a system service with `CAP_NET_ADMIN`, it owns the `wt0`
interface, the routing rules and the resolver, and it is registered by hand
through the desktop UI.

This module is for a network whose owner hands out a peer address and nothing
else, and it is deliberately not that kind of client. In userspace mode it needs
no capability, creates no interface, and adds no route, resolver entry, SSH
configuration or firewall rule: the host's own traffic is untouched. Both clients
are separate peers with separate keys and separate state, so neither one's
registration disturbs the other.

What userspace mode does provide is a SOCKS5 proxy on loopback, which is the
client's only opening. Every entry in `services.netbird-user.tunnels` is a `socat`
process that accepts a connection on `127.0.0.1:<localPort>` and dials the peer's
`<address>:<port>` through that proxy.

## Declaring a tunnel

```nix
services.netbird-user = {
  managementUrl = "https://api.example.com:443";  # only for a self-hosted network
  hostname = "laptop";                            # optional; defaults to the machine hostname
  setupKeyFile = "/run/secrets/netbird-setup-key"; # optional; see below

  tunnels.postgres = {
    localPort = 15432;      # serves on 127.0.0.1:15432
    address = "100.69.0.7"; # the peer's NetBird address
    port = 5432;            # the service's port on that peer
  };
};
```

A tunnel entry carries TCP only: the client's SOCKS5 proxy offers no UDP, so a
service that needs UDP (media streams, for instance) does not work through it.
Targets are IPv4: socat's `SOCKS5-CONNECT` takes its target as an IPv4 address, so
an IPv6 literal cannot be expressed and a destination that answers on IPv6 only —
an IPv6 subnet route, or a peer's `fd00::`-style address — has no tunnel here.
`address` is whatever this client reaches inside the network, and never a name,
because netstack mode has no resolver inside the tunnel: either the peer's own
NetBird address, or an address inside a subnet route that a routing peer
advertises. Userspace mode installs no route for such a prefix — the host's route
table is untouched — but the prefix still reaches the client's WireGuard device
as an allowed IP of the routing peer, so a connection the proxy dials for it is
encrypted to that peer and forwarded from there. A route is accepted unless it
was deselected, and management can override the choice, so reaching a subnet route
normally needs no step beyond the tunnel entry:
`sudo netbird-user networks list` shows the routes and their state, and
`sudo netbird-user networks select <network>` or `deselect` changes it. Two
tunnels cannot share a `localPort`, and the port has to be 1024 or above, since
the forwarder runs unprivileged.

## Joining the network

With `setupKeyFile`, the host registers unattended: `netbird-user-register.service`
runs `netbird up` once per boot, `After=` the client's own unit and
`sops-install-secrets.service`, and the account it stores in
`/var/lib/netbird-user` is what the client reconnects with. Rerunning it is
harmless. A key that management refuses leaves the unit failing and retrying every
30 seconds, which the journal shows.

Without a key, joining is one manual step:

```sh
sudo netbird-user up
```

It prints an activation URL for the network's SSO login and waits for the browser
step. The CLI carries the same environment as the daemon — state directory,
socket, management URL, hostname — so it addresses this client rather than the
workplace daemon.

## What is not exposed

The client's own numbers are fixed in the module rather than options: state in
`/var/lib/netbird-user`, the daemon socket in `/run/netbird-user/sock`, and the
SOCKS5 proxy on `127.0.0.1:1080`. The tunnels are the only consumer of the proxy,
and every program of every local user can reach both it and the tunnel ports:
neither the ports nor the proxy ask for credentials, and nothing restricts them by
user. The WireGuard port is whatever the client picks, because the workplace
client usually holds 51820 already. Nothing opens a firewall port, so peers reach
this host only through the network's relay servers unless an operator adds a rule
for that port.

The `netbird-user` service user owns the state and runtime directories, and the
client runs as it; root is what operates the daemon through the CLI. A
`setupKeyFile` has to be readable by that service user. No encrypted document
holds one yet: declaring it belongs to
[the secrets configuration](../modules/secrets/default.nix) and needs its own
authorized change.

## Verification

What was exercised: the configuration evaluates, and a host declaring tunnels and
a setup key produces the client, registration and per-tunnel units with the
expected directives; the CLI wrapper carries the module's environment; the daemon
starts without privileges under that environment, writes its keys, serves its
socket and answers `netbird-user status` with `NeedsLogin`; `up` starts the SSO
device flow and prints the activation URL; `NB_SETUP_KEY_FILE` is read and sent,
which management rejected for a placeholder key; and a `socat` process with the
module's own argument form forwarded a connection through a stand-in SOCKS5
server.

What was not, and needs a network to join: the netstack client reaching peers, the
SOCKS5 proxy answering with a peer behind it, a tunnel carrying real traffic,
registration with a valid key, reconnection after a restart or a reboot, and how
the client behaves while the workplace client and sing-box are also up. A subnet
route as a tunnel target rests on the client's source alone — userspace mode
skips the host's route table but still adds a route prefix to the routing peer's
allowed IPs — so probe it with `sudo netbird-user networks list` and a connection
through the proxy before relying on it.
