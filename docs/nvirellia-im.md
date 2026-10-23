# nvirellia.im

[`modules/services/nvirellia-im.nix`](../modules/services/nvirellia-im.nix) runs the
personal site on `edge`. The site is its own flake
([`pelikanade/nvirellia.im`](https://github.com/pelikanade/nvirellia.im)): a Go
service whose templates and static assets are embedded in the binary. This
repository takes it as an input and contributes only the deployment.

## The input and the aspect

`flake-file.inputs.nvirellia-im` pins the upstream flake, with `nixpkgs` following
this repository's. The aspect imports its `nixosModules.default` and enables
`services.nvirellia`; the unit, its hardening and its options belong upstream.

Both the input and the aspect are named `nvirellia-im`, so the upstream flake
and the aspect that deploys it are easy to pair. The suffix also keeps the
aspect distinct from the maintainer's user module
([modules/users/nvirellia.nix](../modules/users/nvirellia.nix)), whose
`flake.modules.nixos.nvirellia` name would otherwise merge into it. The module
file and its sops template carry the same suffix; only the upstream-fixed
`services.nvirellia` option namespace and `nvirellia.service` unit name keep the
bare name.

The service listens on `127.0.0.1:8080`, the upstream default, and Caddy
reverse-proxies `nvirellia.im` and `www.nvirellia.im` to it ([caddy.md](caddy.md)).

## Magpie panel

The sheet's Resources panel queries Magpie's web API through its tailnet Service,
addressed with `constants.getTailnetFqdn "nsphere-magpie"`. The key is
`magpie_web_key` in `modules/secrets/magpie.yaml`; the aspect declares that secret
and renders `MAGPIE_WEB_KEY=...` into a sops template the unit reads as its
`EnvironmentFile`, so the key never enters the Nix store. Enrollment is per
document, so `edge` can unwrap the whole Magpie document, not only the web key.

## Status tab

The Status tab reads two loopback APIs on `edge`: Gatus at
`http://127.0.0.1:3001` and Prometheus at `http://127.0.0.1:9090`. The aspect
sets `services.nvirellia.gatus.url` and `services.nvirellia.prometheus.url`;
both APIs are read-only and need no key. Gatus supplies per-endpoint uptime and its last result, while
Prometheus supplies node_exporter's CPU, memory, disk and host uptime for the
targets declared in [probe](probe.md).

When either upstream has no data the tab's corresponding frame is omitted; when
both are empty the tab is disabled, just like Resources without Magpie.

## Verification

```sh
systemctl status nvirellia
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8080/healthz
curl -s http://127.0.0.1:8080/ | grep -o '<title>[^<]*</title>'
curl -sI https://nvirellia.im/ | head -1
```
