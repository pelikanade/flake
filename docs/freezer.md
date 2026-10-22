# Freezer

[Freezer](https://github.com/pelikanade/freezer) is the host's Nix flake build
service. It polls the registered repositories' default branches, builds what
their `.freezer.yaml` lists, and publishes the results to the signed public
cache at `https://cache.nvirellia.im`, so consumers substitute them instead of
rebuilding. `neko-sphere` runs it as `freezer.service`, built from upstream's
NixOS module rather than a container.

## Machine composition

Add `freezer` to the selected machine's aspect imports, preserving `base`:

```nix
imports = with inputs.self.modules.aspects; [
  base
  server
  freezer
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
| `cache.bucket` | `nix-binary-cache` |
| `cache.endpoint` | the R2 S3 endpoint of the cache account |
| `publicUrl` | `https://freezer.neko-sphere.nvirellia.im`, used only as the commit-status link |
| `pollInterval` | `10m` |

The bucket is served publicly through the custom domain
`https://cache.nvirellia.im`; that is the substituter consumers configure, not
Freezer's own address. The cache's public key is in
`modules/system/nix/default.nix`.

The upstream module writes the server YAML into the store from these options
and passes it to the binary. The YAML holds public data only: repository names,
URLs, the cache endpoint, and the signing-key path.

## Secrets

`modules/secrets/freezer.yaml` is the sops document for this feature:

| Key | Consumer |
| --- | --- |
| `github-token` | commit statuses on `pelikanade/flake` |
| `r2-access-key-id`, `r2-secret-access-key` | S3 credentials Nix uses to publish |
| `signing-key` | the `freezer-cache-1` ed25519 binary-cache key Nix uses to sign published paths |

The three credentials are rendered into
`/run/secrets/rendered/freezer-environment` by a sops template; systemd reads
that file as root and passes the values to the service. The signing key is
provisioned at `/run/secrets/freezer-signing-key`, owned by `freezer` with mode
`0400`, because the Nix process the service spawns opens it when copying. The
service itself never reads the key.

The signing key must remain the existing `freezer-cache-1` identity. Replacing
it invalidates substitution for the already-published objects, which are signed
with the public half recorded in `modules/system/nix/default.nix`. Edit the
document with `sops modules/secrets/freezer.yaml`; the declared
`restartUnits` restart `freezer.service` when a secret or the rendered
environment changes.

## Migrating from the container

The previous deployment was a rootless Podman container in the `paseo`
account, started from `/var/lib/paseo/freezer/compose.yaml`, with its state in
`/var/lib/paseo/freezer/state`. The state is not migrated: `/var/lib/freezer`
starts empty, and the first poll rebuilds or records cache hits. Only the
credentials and the signing key move, and they now live in the sops document.

Both deployments bind `127.0.0.1:8080`, so retire the container before starting
the unit:

```sh
sudo -u paseo podman stop freezer
sudo -u paseo podman rm freezer
```

Then deploy this configuration. Once the unit answers and a build has completed,
delete the old deployment directory; it holds the plaintext environment file
and signing key that sops now replaces:

```sh
rm -r /var/lib/paseo/freezer
```

Do not delete it before the new service is confirmed working.

## Verification

After switching:

```sh
systemctl status freezer
journalctl -u freezer --since today
curl -fsS http://127.0.0.1:8080/ >/dev/null
```

The UI's home page lists the registered repository and recent jobs. Press
**Build now** for a repair, or wait for the poll. A successful event posts its
commit status with context `freezer`, and the job transcript shows the
`nix copy` that published. Configuration evaluation and a package build prove
only that the unit is generated and the binary starts; they do not prove the R2
credentials or the GitHub token.

## Updates

The package follows the `freezer` flake input. Update that input alone and
rebuild; do not run a blanket `nix flake update`:

```sh
nix flake update freezer
nix develop -c just build
```

The state under `/var/lib/freezer` survives switches and reboots. See
[upstream's runbook](https://github.com/pelikanade/freezer/blob/main/docs/runbook.md)
for retention, backups, cache repair, and the environment-file contract.
