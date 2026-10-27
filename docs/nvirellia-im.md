# nvirellia.im

[`modules/services/nvirellia-im.nix`](../modules/services/nvirellia-im.nix) runs the
personal site on `edge`. The Go service, with the templates and static assets
it embeds, is vendored from `pelikanade/nvirellia.im` at
`104fbe048aa0e90ed7f658d9149aa2c4304cf7d2` in
[`modules/packages/nvirellia-im`](../modules/packages/nvirellia-im). The service
module carries the unit, its hardening and its options.

## The package and the aspect

`modules/packages/nvirellia-im/default.nix` builds the vendored source with
`buildGoModule`; the module has no Go dependencies, so there is no vendor hash.
The aspect takes the binary from `pkgs.selfPackages.nvirellia-im`, and importing
the aspect is what runs the service.

Both the package and the aspect are named `nvirellia-im`, so the binary and the
aspect that deploys it are easy to pair. The suffix also keeps the aspect
distinct from the maintainer's user module
([modules/users/nvirellia.nix](../modules/users/nvirellia.nix)), whose
`flake.modules.nixos.nvirellia` name would otherwise merge into it. The module
file, its sops template, and the option namespace and unit name all carry the
same suffix.

Updating the site means editing the vendored source; the repository no longer
follows an input for it.

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
sets `services.nvirellia-im.gatus.url` and `services.nvirellia-im.prometheus.url`;
both APIs are read-only and need no key. Gatus supplies per-endpoint uptime and its last result, while
Prometheus supplies node_exporter's CPU, memory, disk, host uptime, flake
revision and generation activation time for the targets declared in
[probe](probe.md).

The site compares each host's revision with the head of
`pelikanade/flake` through GitHub's public API and labels it up to date,
outdated, modified or unknown. That is the upstream default for
`services.nvirellia-im.prometheus.flakeRepository`, which is also the
repository the servers deploy from; the answer is cached for five
minutes and needs no token.

When either upstream has no data the tab's corresponding frame is omitted; when
both are empty the tab is disabled, just like Resources without Magpie.

## Verification

```sh
systemctl status nvirellia-im
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8080/healthz
curl -s http://127.0.0.1:8080/ | grep -o '<title>[^<]*</title>'
curl -sI https://nvirellia.im/ | head -1
```
