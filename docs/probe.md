# Probe

[`modules/services/probe.nix`](../modules/services/probe.nix) exports two
aspects:

| Aspect | Host | Role |
| --- | --- | --- |
| `probe-hub` | `edge` | Prometheus on `127.0.0.1:9090` |
| `probe-agent` | `edge`, `neko-sphere` | node_exporter on `0.0.0.0:9100`, closed publicly |

Prometheus scrapes each agent and keeps the history in its own TSDB. The
profile sheet's Status tab reads the same HTTP API, so there is no dashboard
database, user account, or per-host login to keep in sync.

## Targets

The hub aspect defines `services.probe.targets`; the machine supplies the hosts.
`edge` declares itself over loopback and its peer by MagicDNS name:

```nix
services.probe.targets = [
  { name = "edge"; address = "127.0.0.1"; }
  { name = "neko-sphere"; address = tailnet "neko-sphere"; }
];
```

Each target becomes a `node` job entry with a `host` label. The label is the
display name the site uses, so keep it short and stable.

## API used by the site

The site sets `services.nvirellia.prometheus.url = "http://127.0.0.1:9090"` and
queries the read-only API. It reads `up{job="node"}` for the target state and
derives CPU, memory, root-disk percentage and host uptime from the standard
node_exporter series. Metrics for a target whose `up` is `0` are left blank
rather than showing the last stale sample.

Prometheus binds loopback, node_exporter's port stays closed on the public
firewall, and the tailnet interface is trusted. Nothing here needs a secret.

## Verification

```sh
systemctl status prometheus prometheus-node-exporter
curl -s 'http://127.0.0.1:9090/api/v1/query?query=up%7Bjob%3D%22node%22%7D' | jq
curl -s 'http://127.0.0.1:9090/api/v1/query?query=time()%20-%20node_boot_time_seconds%7Bjob%3D%22node%22%7D' | jq
ss -ltn | grep -E '9090|9100'
```

The last command shows Prometheus on loopback and node_exporter on every
interface; `nixos-fw` refuses 9100 from the public network.
