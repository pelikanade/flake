# NetBird in userspace

A NetBird client in userspace networking mode — WireGuard on a Go TCP/IP stack
instead of a TUN device — running as an unprivileged system service and serving
declared services from the network on loopback ports. The client, its tunnels and
its CLI are declared in
[modules/services/netbird-userspace.nix](../modules/services/netbird-userspace.nix)
as `services.netbird-userspace`; neko-sphere imports it and is the only host that
runs it.

## Why a separate client

The kernel client from
[modules/apps/netbird-desktop.nix](../modules/apps/netbird-desktop.nix) is the
workplace one: it is a system service with `CAP_NET_ADMIN`, it owns the `wt0`
interface, the routing rules and the resolver, and it is registered by hand
through the desktop UI.

This one joins a different network, whose owner hands out a peer address and
nothing else, and it is deliberately not that kind of client. In userspace mode it
needs no capability, creates no interface, and adds no route, resolver entry, SSH
configuration or firewall rule: the host's own traffic is untouched. Both clients
are separate peers with separate keys and separate state, so neither one's
registration disturbs the other.

What userspace mode does provide is a SOCKS5 proxy on loopback, which is the
client's only opening. Every entry in `services.netbird-userspace.tunnels` is a
`socat` process that accepts a connection on `127.0.0.1:<localPort>` and dials the
target through that proxy.

## The encrypted document

The network's endpoint and its setup key are data in
[modules/secrets/netbird-userspace.yaml](../modules/secrets/netbird-userspace.yaml),
as `management_url` and `setup_key`, so neither appears in the repository or in the
Nix store. The document is encrypted for neko-sphere, the only host that reads it,
and for the maintainer, who keeps it editable:

```sh
nix develop
sops modules/secrets/netbird-userspace.yaml
```

`setup_key` is the placeholder `REPLACE_WITH_NETBIRD_SETUP_KEY` until the network
issues a real one. While it stays a placeholder, the registration unit keeps
failing and retrying every 30 seconds, which the journal shows; nothing else is
affected, and a first login by hand works meanwhile:

```sh
sudo netbird-userspace up
```

It prints an activation URL for the network's SSO login and waits for the browser
step. With a key filled in, registration is unattended instead: each boot runs
`netbird up` against the running daemon, and the account and endpoint it stores in
`/var/lib/netbird-userspace` are what the client reconnects with afterwards.
`sudo netbird-userspace status --detail` lists the peers and their addresses.

## Declaring a tunnel

```nix
services.netbird-userspace = {
  hostname = "neko-sphere"; # optional; defaults to the machine hostname

  tunnels.techinteaching = {
    localPort = 18083;       # serves on 127.0.0.1:18083
    address = "172.0.161.24";
    port = 8083;
  };
};
```

A tunnel entry carries TCP only: the client's SOCKS5 proxy offers no UDP, so a
service that needs UDP (media streams, for instance) does not work through it.
Targets are IPv4: socat's `SOCKS5-CONNECT` takes its target as an IPv4 address, so
an IPv6 literal cannot be expressed and a destination that answers on IPv6 only —
an IPv6 subnet route, or a peer's `fd00::`-style address — has no tunnel here.

`address` is whatever this client reaches inside the network, and never a name,
because netstack mode has no resolver inside the tunnel: either a peer's own
NetBird address, or an address inside a subnet route that a routing peer
advertises. Userspace mode installs no route for such a prefix — the host's route
table is untouched — but the prefix still reaches the client's WireGuard device as
an allowed IP of the routing peer, so a connection the proxy dials for it is
encrypted to that peer and forwarded from there. A route is accepted unless it was
deselected, and management can override the choice, so reaching a subnet route
normally needs no step beyond the tunnel entry: `sudo netbird-userspace networks
list` shows the routes and their state, and `sudo netbird-userspace networks
select <network>` or `deselect` changes it.

Two tunnels cannot share a `localPort`, and the port has to be 1024 or above, since
the forwarder runs unprivileged.

## What is not exposed

The client's own numbers are fixed in the module rather than options: state in
`/var/lib/netbird-userspace`, the daemon socket in `/run/netbird-userspace/sock`,
and the SOCKS5 proxy on `127.0.0.1:1080`. The tunnels are the only consumer of the
proxy, and every program of every local user can reach both it and the tunnel
ports: neither the ports nor the proxy ask for credentials, and nothing restricts
them by user. The WireGuard port is whatever the client picks, because the kernel
client usually holds 51820 where both run. Nothing opens a firewall port, so peers
reach this host only through the network's relay servers unless an operator adds a
rule for that port.

The `netbird-userspace` service user owns the state and runtime directories, and
the client runs as it; root operates the daemon through the CLI and reads the
document's files the same way. The two secrets are provisioned `0400` for that
user, and a change to either re-runs registration.

## Verification

What was exercised: the configuration evaluates, and neko-sphere produces the
client, registration and tunnel units with the expected directives; the CLI wrapper
and the registration unit carry the module's environment, the latter with the
setup key path and an endpoint read at run time; the encrypted document holds
exactly its two keys, names the two intended recipients, and carries no plaintext
endpoint — checked on the ciphertext, since only neko-sphere's host key or the
maintainer's key decrypts it, and the same payload round-tripped through a
throwaway age key to prove the encryption command; the daemon starts without
privileges under that environment, writes its keys, serves its socket and answers
`netbird-userspace status` with `NeedsLogin`; `up` starts the SSO device flow and
prints the activation URL; `NB_SETUP_KEY_FILE` is read and sent, which management
rejected for a placeholder key; and a `socat` process with the module's own
argument form forwarded a connection through a stand-in SOCKS5 server.

What was not, and needs a real key: registration, the netstack client reaching
peers, the SOCKS5 proxy answering with a peer behind it, the tunnel carrying
traffic on 18083, reconnection after a restart or a reboot, and how neko-sphere's
sing-box treats the client's own traffic. That last one is the open question worth
watching: sing-box runs a tun whose `final` route is the proxy selector, so the
client's endpoint, signal, relay and peer traffic — ordinary TCP and UDP to public
addresses — leaves through that proxy rather than around it, and whether those
nodes carry the relay and peer UDP is unverified. If the tunnel does not come up,
excluding the client's traffic in that module is the first thing to try.
