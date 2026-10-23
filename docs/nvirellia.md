# nvirellia.im

[`modules/services/nvirellia.nix`](../modules/services/nvirellia.nix) runs the
personal site on `edge`. The site is its own flake
([`pelikanade/nvirellia.im`](https://github.com/pelikanade/nvirellia.im)): a Go
service whose templates and static assets are embedded in the binary. This
repository takes it as an input and contributes only the deployment.

## The input and the aspect

`flake-file.inputs.nvirellia` pins the upstream flake, with `nixpkgs` following
this repository's. The aspect imports its `nixosModules.default` and enables
`services.nvirellia`; the unit, its hardening and its options belong upstream.

The aspect is named `nvirellia-im`, not `nvirellia`: the latter is the
maintainer's user module ([modules/users/nvirellia.nix](../modules/users/nvirellia.nix)),
and two files declaring the same `flake.modules.nixos` name are merged rather
than kept apart.

The service listens on `127.0.0.1:8080`, the upstream default, and Caddy
reverse-proxies `nvirellia.im` and `www.nvirellia.im` to it ([caddy.md](caddy.md)).

## Magpie panel

The sheet's Resources panel queries Magpie's web API through its tailnet Service,
addressed with `constants.getTailnetFqdn "nsphere-magpie"`. The key is
`magpie_web_key` in `modules/secrets/magpie.yaml`; the aspect declares that secret
and renders `MAGPIE_WEB_KEY=...` into a sops template the unit reads as its
`EnvironmentFile`, so the key never enters the Nix store. Enrollment is per
document, so `edge` can unwrap the whole Magpie document, not only the web key.

## Verification

```sh
systemctl status nvirellia
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8080/healthz
curl -s http://127.0.0.1:8080/ | grep -o '<title>[^<]*</title>'
curl -sI https://nvirellia.im/ | head -1
```
