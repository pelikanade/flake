# Deployment

A push to `main` makes the runner build the configured servers and ask each one
to activate the closure. No host pulls the repository on a timer, and the
runner never gets SSH access.

```text
push main ──> Deploy workflow (self-hosted runner on neko-sphere)
                 └─ nixos-deploy-trigger
                      ├─ nix build every target toplevel
                      ├─ POST store path + bearer token to each remote target
                      │    └─ deploy-trigger.service (non-root)
                      │         └─ nixos-deploy.path
                      │              └─ transient root unit
                      │                   ├─ nix-store --realise <path>   # from Harmonia
                      │                   ├─ nix-env -p /nix/var/nix/profiles/system --set <path>
                      │                   └─ switch-to-configuration switch
                      └─ POST to neko-sphere last
```

## Trigger

[`deploy.yml`](../.github/workflows/deploy.yml) runs on:

- a push to `main`;
- `workflow_dispatch` from `main`.

A dispatch from another ref is skipped. The runner builds every target before
it sends a trigger; a build failure leaves every host on its current generation.

The update workflow pushes its commits with `GITHUB_TOKEN`. GitHub does not
start a new `push` workflow for that token, so
[`update-packages.yml`](../.github/workflows/update-packages.yml) explicitly
runs `gh workflow run deploy.yml --ref main` after a push. This is why that
workflow needs the `actions: write` permission.

## Runner

`modules/services/github-runner.nix` registers one repository-level runner,
named `neko-sphere`, with the labels `self-hosted` and `neko-sphere`. It is
ephemeral: it registers, processes one job, deregisters, and is registered
again by systemd for the next job.

The runner service runs as the static `github-runner` user. It has no root, no
SSH key, and no deployment unit of its own. Its `nixos-deploy-trigger` command:

1. reads the shared trigger token from sops;
2. builds every target with `nix build --no-link --print-out-paths`;
3. POSTs the resulting toplevel store path to each target, remote targets
   first and its own host last.

### Registration token

The runner daemon needs a credential before any job exists. A workflow's
`GITHUB_TOKEN` is issued only after a runner has picked up a job and does not
have the `administration` permission required by the runner registration API.
The NixOS module therefore reads a long-lived fine-grained PAT from
`/run/secrets/github_runner_token`.

Create a fine-grained PAT with:

- **Repository access:** only `pelikanade/flake`;
- **Repository permissions:** `Administration: Read and write`;
  `Metadata: Read` is added automatically;
- an expiry you are prepared to rotate.

The value lives in `modules/secrets/github-runner.yaml`, encrypted to the
maintainer and `neko-sphere`. Rotation: update the encrypted document, switch
`neko-sphere` (or restart `github-runner-neko-sphere`); the next job registers
with the new value.

## Targets

A machine is a deployment target when it imports the `deploy-target` aspect.
The option `services.deploy-target.enable` defaults to true and can be set to
false to keep the aspect imported while disabling the service. Currently
`neko-sphere` and `edge` import it; `asymmetry`, `parallax`, and the installer
do not.

The runner derives the target list by reading
`services.deploy-target.enable` from each materialized configuration. Add the
aspect to a machine to include it; remove it or disable the option to exclude
it.

## Deploy trigger

Each target runs `deploy-trigger.service` as the non-root `deploy-trigger` user.
It listens on `127.0.0.1:8080`; `tailscale-serve-deploy.service` publishes that
port with:

```sh
tailscale serve --bg --http=8080 8080
```

The runner calls `http://<machine>.<tailnetDnsName>:8080/deploy`, so this uses
the node's own MagicDNS name. No Tailscale Service is needed in the admin
console, and Tailscale SSH is not used.

The request carries `Authorization: Bearer <token>` and a toplevel store path.
The handler validates both, writes a request file, and waits for a result file.
A `systemd.path` unit starts `nixos-deploy.service`, which starts a **transient**
`systemd-run` unit. That unit:

```sh
nix-store --realise <store-path> --option max-jobs 0
nix-env -p /nix/var/nix/profiles/system --set <store-path>
<store-path>/bin/switch-to-configuration switch
```

The transient unit is outside the NixOS configuration, so the switch cannot
restart it mid-activation. If the runner is restarted by the local switch, the
transient unit keeps going; the workflow may report the job as lost.

## Cache

Harmonia on `neko-sphere` serves the host's Nix store and signs with the
`freezer-cache-1` key. Every tailnet host already trusts
`http://nsphere-cache…` through `modules/system/nix/default.nix`. The runner
builds on `neko-sphere`, so the closure is already in that cache; there is no
separate upload step.

`max-jobs 0` on the target makes the activation fail rather than build if the
cache does not have a required path.

## Token

`modules/secrets/deploy-trigger.yaml` holds one shared value,
`deploy_trigger_token`, encrypted to the maintainer and every target. The
module provisions it as `root:deploy` with mode `0440`; `github-runner` and
`deploy-trigger` are both in the `deploy` group.

Rotation: replace the value with `sops`, then switch the targets (or restart
`deploy-trigger.service`). The runner reads the new value on its next job.

A shared token means any compromised target can trigger another target. Each
target still validates the store path against its own hostname and can only
pull signed paths from Harmonia. If that blast radius is unacceptable, use one
token per target.

## Bootstrap

The target service and token do not exist until the configuration that adds
them has been activated. The first deployment is therefore manual:

1. Land the change.
2. From a workstation, deploy both hosts once with the normal privileged path,
   for example `just rdeploy neko-sphere root@<neko-sphere>` and
   `just rdeploy edge root@<edge>`.
3. Verify on each target:
   ```sh
   systemctl status deploy-trigger tailscale-serve-deploy nixos-deploy.path
   tailscale serve status
   ```
4. Run the workflow once with `gh workflow run deploy.yml --ref main`, or push
   a trivial commit, and confirm the targets switch.

The push that landed the change may already have queued a `Deploy` run. It
stays queued until the manually installed runner comes online.

## Rollback

Revert the offending commit on `main`; the resulting push triggers the workflow
and returns every target to the previous configuration. For a single host or a
workflow failure, run the normal switch from a workstation:

```sh
nixos-rebuild switch --flake .#<machine> --target-host root@<host>
```

A partial deployment is possible. Remote targets are triggered first; the
runner's own host is triggered last. Both remain on the last successfully
activated revision after the next run.

## Troubleshooting

- **Runner is offline:** `systemctl status github-runner-neko-sphere` and
  `journalctl -u github-runner-neko-sphere`. A missing or expired PAT fails
  during runner registration.
- **Trigger refused:** check `journalctl -u deploy-trigger`, the token file's
  group, and `tailscale serve status`. The tailnet policy must allow `tcp:8080`
  from the runner to the target if it is not already open.
- **Deployment fails:** `journalctl -u nixos-deploy` shows the request; the
  transient unit is `nixos-deploy-run-<nonce>`. Check that the target can reach
  `nsphere-cache` and that the store path is present there.
- **Local job is lost:** the `neko-sphere` switch can restart the runner before
  the HTTP response arrives. The transient unit still completes; check it with
  `journalctl -u nixos-deploy-run-<nonce>`.

## Security

The repository is public, and GitHub warns against self-hosted runners on
public repositories. Keep **Require approval for all outside collaborators**
enabled and do not approve workflows from untrusted pull requests: an approved
job runs as `github-runner` on `neko-sphere`.

The runner is ephemeral and unprivileged; it cannot SSH to a target. The target
trigger is non-root and bound to loopback, its only public surface is
`tailscale serve` with a bearer token, and the root work happens in a transient
unit that validates the store path and only substitutes signed paths from
Harmonia.
