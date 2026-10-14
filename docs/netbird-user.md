# NetBird in userspace

An unprivileged NetBird client for a network this host joins as a peer and reaches
only through a port it forwards. The client, its forwards and its state directory
are declared in
[modules/apps/netbird-user.nix](../modules/apps/netbird-user.nix), as
`services.netbird-user` in Home Manager; the `workstation` role imports it.

## Why a second client

The kernel client from
[modules/apps/netbird-desktop.nix](../modules/apps/netbird-desktop.nix) is the
workplace one: it is a system service with `CAP_NET_ADMIN`, it owns the `wt0`
interface, the routing rules and the resolver, and it is logged in by hand through
the desktop UI.

This module is for a different network — one whose owner hands out a peer address
and nothing else — and it is deliberately not that kind of client. It runs as the
logged-in user in userspace networking mode (netstack), where WireGuard runs on a
Go TCP/IP stack instead of a TUN device: no root, no interface, no route, no
resolver entry, no firewall rule, and no packet of the host's traffic is diverted.
Both clients are separate peers with separate keys and separate state, so neither
one's login disturbs the other's.

What userspace mode does provide is a SOCKS5 proxy on loopback — the client's only
opening — and every forward in `services.netbird-user.forwards` is a `socat`
process that accepts a connection on `127.0.0.1:<localPort>` and dials the peer's
`<peer>:<peerPort>` through that proxy. Both listeners are loopback-only, the
proxy asks for no credentials, and the peer is addressed by its NetBird address:
netstack mode has no resolver inside the tunnel, so no name resolves there.

Everything the client persists — profile, WireGuard and SSH keys, and the daemon
socket — lives in `~/.local/state/netbird-user`, created `0700`, and the CLI
wrapper points at it, so `netbird-user` talks to this client and not to the
workplace daemon's socket.

## First login

The daemon starts with the user's session and waits. Joining the network is one
interactive step, in a terminal on the workstation:

```sh
netbird-user up
```

It prints an activation URL for the network's SSO login and waits for the browser
step. A network that issues setup keys instead:

```sh
netbird-user up --management-url https://... --setup-key <key>
```

The login is stored in the state directory, so later sessions reconnect without
it. `netbird-user status --detail` reports the peers with their addresses, and
those addresses are what a forward names.

The WireGuard port is the client's own; when the workplace client already holds
51820 the daemon picks a free port and says so in the journal, and the peers fall
back to the network's relay servers unless that port is reachable from outside.

## Verification

Only part of this has been exercised. What was: the configuration evaluates and
the generated user units carry the expected directives; the daemon starts without
privileges under the module's environment, creates its keys in the state
directory, serves the socket there and answers `netbird-user status` with
`NeedsLogin`, and prints the SSO activation URL for `up`; a `socat` process with
the module's own argument form forwarded a connection through a stand-in SOCKS5
server. Not exercised, and needing a network to join: the netstack client reaching
peers, the SOCKS5 proxy answering with a peer behind it, a forward carrying real
traffic, login surviving a restart, and reboot behaviour.
