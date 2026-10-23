# Beszel

[`modules/services/beszel.nix`](../modules/services/beszel.nix) runs
[Beszel](https://beszel.dev), a small monitor that keeps per-host history of CPU,
memory, disk, containers and systemd units. One hub owns the web UI and the
SQLite data; every monitored host runs an agent.

## Composition

| Aspect | Host | Role |
| --- | --- | --- |
| `beszel-hub` | `edge` | Web UI on `127.0.0.1:8090`, data in `/var/lib/beszel-hub` |
| `beszel-agent` | `edge` | Listens on `127.0.0.1:45876`, dialled by the local hub |
| `beszel-agent` | `neko-sphere` | Listens on `45876` on every interface; only the tailnet reaches it |

The hub dials each agent over SSH on 45876, so the agent needs the hub's public
key and nothing else; no agent secret is stored here. `edge`'s agent binds
loopback because the hub is on the same host. `neko-sphere`'s agent binds all
interfaces, but its firewall only admits the `tailscale0` interface, so the hub
reaches it at `neko-sphere.dwelf-hoki.ts.net:45876` without a public port.

The hub publishes through [Caddy](caddy.md) at
`https://probe.nvirellia.im/`.

## The hub key

The hub generates `id_ed25519` in its data directory on first start, and
`services.beszel.agent.environment.KEY` carries its public half. The private half
is what the hub signs agent connections with: back up
`/var/lib/beszel-hub/beszel_data/` with the database. If the key is lost, every
agent's `KEY` changes and the systems have to be registered again.

## Adding a system

The hub keeps its system list in its own database, so the agents are not
registered declaratively. After creating the admin account at
`https://probe.nvirellia.im/`, add one system per host:

| Name | Host | Port |
| --- | --- | --- |
| `edge` | `127.0.0.1` | `45876` |
| `neko-sphere` | `neko-sphere.dwelf-hoki.ts.net` | `45876` |

## Verification

The agent's SSH endpoint answers a successful handshake with a stats document,
which proves the key is accepted without the UI:

```sh
ssh -p 45876 -i /var/lib/beszel-hub/beszel_data/id_ed25519 \
  -o UserKnownHostsFile=/dev/null beszel@neko-sphere.dwelf-hoki.ts.net
systemctl status beszel-hub beszel-agent
```
