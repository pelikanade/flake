# Beszel

[`modules/services/beszel-hub.nix`](../modules/services/beszel-hub.nix) runs the
hub and [`modules/services/beszel-agent.nix`](../modules/services/beszel-agent.nix)
the agents for
[Beszel](https://beszel.dev), a small monitor that keeps per-host history of CPU,
memory, disk, containers and systemd units. The hub owns the web UI and the
SQLite data; every monitored host runs an agent.

## Composition

| Aspect | Host | Role |
| --- | --- | --- |
| `beszel-hub` | `edge` | Web UI on `0.0.0.0:8090`, data in `/var/lib/beszel-hub` |
| `beszel-agent` | `edge` | Dials `http://127.0.0.1:8090` |
| `beszel-agent` | `neko-sphere` | Dials `https://probe.nvirellia.im` |

Agents connect out to the hub over a WebSocket and listen on no port at all:
`DISABLE_SSH=true` on both sides removes the SSH server and the hub's SSH
fallback, so a disconnected agent is marked down rather than dialled. The hub is
published by [Caddy](caddy.md) at `https://probe.nvirellia.im/`, and binds every
interface so tailnet peers reach it directly; its port stays closed on the
public firewall.

`neko-sphere` dials the public name because the tailnet ACL does not admit that
tagged node to `edge:8090`; `tailscaled` logs the rejection as
`rejected due to acl`. Its WebSocket therefore goes out through the proxy to
Cloudflare to `edge`. Granting the node that destination lets the URL become
`http://edge.dwelf-hoki.ts.net:8090` instead.

## Registration

One universal token authenticates every agent. It lives in
`modules/secrets/beszel.yaml` (recipient: the maintainer and both agents) and is
rendered into `TOKEN=` in the unit's `EnvironmentFile` by sops. The hub creates a
system per agent the first time it connects, named after the agent's
`SYSTEM_NAME` (the machine's hostname) and keyed by a fingerprint derived from
`/etc/machine-id`, so restarts and reconnects reuse the same system.

`KEY` stays in the agent's environment although it no longer authenticates
anything: the agent refuses to start without a public key. The private half
lives in `/var/lib/beszel-hub/beszel_data/id_ed25519`; back up that directory
with the database.

## Verification

```sh
systemctl status beszel-hub beszel-agent
journalctl -u beszel-agent -b --no-pager | grep WebSocket   # "WebSocket connected"
ss -ltn | grep 45876                                        # no output: no agent listener
```

The hub's database records the registered systems:

```sh
nix shell nixpkgs#sqlite -c sqlite3 -readonly \
  /var/lib/beszel-hub/beszel_data/data.db "select name, host, status from systems;"
```
