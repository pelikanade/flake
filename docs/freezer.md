# Freezer

[Freezer](https://github.com/pelikanade/freezer) is the host's Nix flake build
service. It polls the registered repositories' default branches and builds what
their `.freezer.yaml` lists. It is configured without a cache: the outputs stay
in `neko-sphere`'s Nix store, and [Harmonia](#the-cache) serves that store over
the tailnet. `neko-sphere` runs it as `freezer.service`, from upstream's NixOS
module rather than a container.

## The cache

Harmonia reads `/nix/store` and the Nix database directly, so no copy or object
storage is involved. `modules/services/harmonia.nix` enables it on loopback:

| Setting | Value |
| --- | --- |
| `cache.settings.bind` | `127.0.0.1:5000` |
| `cache.signKeyPaths` | `config.sops.secrets.cache-signing-key.path` |

The cache is published as the Tailscale Service `svc:nsphere-cache`, so clients
use `http://<nsphere-cache>.<tailnet>` and the daemon terminates the
certificate. The Service and its endpoint are defined in the tailnet's admin
console; `modules/machines/neko-sphere.nix` only forwards `tcp:80` to
`127.0.0.1:5000`.

When `services.tailscale.enable` is true, consumers get the substituter and
the public key from `modules/system/nix/default.nix`; machines without
Tailscale keep only the public nix-community substituter. The key is the
existing `freezer-cache-1` identity, so no client key changes.

Built paths are not GC roots. The weekly `nix-collect-garbage` on
`neko-sphere` can collect anything no profile references, after which Harmonia
returns a miss and the client rebuilds. Treat this as a hot cache; add roots or
retention if that becomes too costly.

## Machine composition

Add `freezer` and `harmonia` to the selected machine's aspect imports,
preserving `base`:

```nix
imports = with inputs.self.modules.aspects; [
  base
  server
  freezer
  harmonia
  tailscale-ingress
];
```

`modules/services/freezer.nix` declares the flake input and imports
`inputs.freezer.nixosModules.default`. The upstream module owns the service
account, the systemd unit, the generated server configuration, and the
hardening; this repository supplies only the deployment's values and secrets.

The UI listens on `127.0.0.1:8080` and is published as `svc:nsphere-freezer` by
[the Tailscale ingress module](tailscale-ingress.md). Nothing inbound is needed
for triggering: the service resolves branch heads itself.

## Configuration

The host's values live in `modules/services/freezer.nix`:

| Option | Value |
| --- | --- |
| `repositories` | `flake` — `https://github.com/pelikanade/flake.git`, `pelikanade/flake` |
| `cache` | unset; Freezer builds into the host store and publishes nothing |
| `publicUrl` | `http://nsphere-freezer.dwelf-hoki.ts.net`, used only as the commit-status link |
| `pollInterval` | `10m` |

The upstream module writes the server YAML into the store from these options
and passes it to the binary. The YAML holds public data only: repository names
and URLs.

## Secrets

`modules/secrets/freezer.yaml` is the sops document for the build service and
the cache key:

| Key | Consumer |
| --- | --- |
| `github-token` | commit statuses on `pelikanade/flake` |
| `signing-key` | Harmonia's `cache-signing-key`, the `freezer-cache-1` ed25519 key |

`github-token` is rendered into `/run/secrets/rendered/freezer-environment` by a
sops template. The signing key is provisioned at
`/run/secrets/cache-signing-key`; Harmonia's unit loads it as root through
`LoadCredential`, so its owning user does not need to be the service account.
Neither service reads the key itself.

The signing key must remain the existing `freezer-cache-1` identity. Replacing
it invalidates substitution for clients that trust the public half in
`modules/system/nix/default.nix`. Edit the document with
`sops modules/secrets/freezer.yaml`; the declared `restartUnits` restart the
consuming units.

The retired R2 access keys may remain in the encrypted document until they are
removed with `sops`; no module consumes them.

## Verification

After switching:

```sh
systemctl status freezer harmonia
journalctl -u freezer --since today
curl -fsS http://127.0.0.1:8080/ >/dev/null
curl -fsS http://127.0.0.1:5000/nix-cache-info
```

The UI's home page lists the registered repository and recent jobs. Press
**Build now** for a repair, or wait for the poll. A successful job's transcript
shows `nix build`, not `nix copy`; it posts its commit status with context
`freezer`. Substitution is proved from another tailnet machine:

```sh
nix path-info --store http://<nsphere-cache>.<tailnet> /nix/store/<path>
```

Configuration evaluation and a package build prove only that the unit is
generated and the binary starts; they do not prove the tailnet Service, the
Harmonia key, or the GitHub token.

## Updates

The package follows the `freezer` flake input. Update that input alone and
rebuild; do not run a blanket `nix flake update`:

```sh
nix flake update freezer
nix develop -c just build
```

The state under `/var/lib/freezer` survives switches and reboots. See
[upstream's runbook](https://github.com/pelikanade/freezer/blob/main/docs/runbook.md)
for retention, backups, and the environment-file contract.
