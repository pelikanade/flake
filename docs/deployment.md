# Deployment

A push to `main` activates the servers instead of each host pulling the
repository on a timer.

```text
push main ──> Deploy workflow (self-hosted runner on neko-sphere)
                 ├─ build neko-sphere and edge
                 ├─ nixos-deploy-request edge
                 │     └─ nixos-deploy@edge.service (root, unsandboxed)
                 │           └─ clone main + nixos-rebuild --target-host root@edge…
                 └─ nixos-deploy-request neko-sphere
                       └─ nixos-deploy@neko-sphere.service (root)
                             └─ clone main + nixos-rebuild switch
```

Only `neko-sphere` and `edge` are deployed. `asymmetry`, `parallax`, and the
installer have no automatic deployment path.

## Trigger

[`deploy.yml`](../.github/workflows/deploy.yml) runs on:

- a push to `main`;
- `workflow_dispatch` from `main`.

A dispatch from another ref is skipped. The workflow builds both toplevels
before it starts either deployment; a build failure leaves both hosts on their
current generation.

The update workflow pushes its commits with `GITHUB_TOKEN`. GitHub does not
start a new `push` workflow for that token, so
[`update-packages.yml`](../.github/workflows/update-packages.yml) explicitly
runs `gh workflow run deploy.yml --ref main` after a push. This is why that
workflow needs the `actions: write` permission.

## Runner

`modules/services/github-runner.nix` registers one repository-level runner,
named `neko-sphere`, with the labels `self-hosted` and `neko-sphere`. It is
ephemeral: it registers, processes one job, deregisters, and is registered
again by systemd for the next job. `replace = true` removes a stale
registration with the same name.

The runner service runs as the static `github-runner` user. It is not root and
cannot build or activate a system itself. It never gains privileges: a polkit
rule lets it ask PID 1 to start the two deployment units.

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
maintainer and `neko-sphere`. The module provisions it for the
`github-runner` user with mode `0400` and hides the path from job processes.
Rotation: update the encrypted document, switch `neko-sphere` (or restart
`github-runner-neko-sphere`); the next job registers with the new value.

A short-lived registration token from the repository's **Add new self-hosted
runner** page is not suitable: it expires after one hour, while an ephemeral
runner registers repeatedly. A GitHub App installation token would work but
needs an additional token-minting service.

## Deploy path

The runner invokes one request command as itself:

```sh
/run/current-system/sw/bin/nixos-deploy-request <neko-sphere|edge>
```

A polkit rule allows `github-runner` to start exactly the two
`nixos-deploy@…` units, and only with the `start` verb. The runner keeps the
module's `NoNewPrivileges=true`; no setuid helper, `sudo`, or capability grant is
involved. The request wrapper validates the machine name and starts
`nixos-deploy@<machine>.service`; that unit runs as root, outside the runner's
sandbox, so activation does not inherit the runner's filesystem or capability
restrictions.

The unit clones `https://github.com/pelikanade/flake.git` at `main` into
`/var/lib/nixos-deploy/<machine>` and runs:

```sh
nixos-rebuild switch --flake /var/lib/nixos-deploy/<machine>#<machine>
```

For `edge` it adds `--target-host root@edge.dwelf-hoki.ts.net`; the build stays
local on `neko-sphere` and the closure is copied over Tailscale SSH. The clone
preserves `.git`, so `inputs.self.rev` remains available to the probe.

The workflow's checkout and build are a gate and a store warmer. The unit does
not trust the runner's working tree: it deploys the current `main` revision from
GitHub. A job can trigger a deployment of `main`; it cannot point the unit at a
modified flake.

`TimeoutStartSec` is two hours. Edge is deployed first, then `neko-sphere`:
the `neko-sphere` switch can restart the runner, but the root unit keeps
running independently, so the deployment finishes even if the job is reported
as lost.

## Tailscale SSH

Both servers import the `server` role and the `tailscale` aspect. The server
role sets `services.tailscale.extraSetFlags = [ "--ssh" ]` when the tailscale
option exists and is enabled, so both advertise Tailscale SSH. The deployment
uses it for `edge` only; `neko-sphere` is switched locally.

The tailnet policy needs an `accept` SSH rule for the deployment source as
`root`; the default `check` action would require interactive re-authentication.
See [Tailscale SSH for deployment](tailscale.md#tailscale-ssh-for-deployment).

The root unit accepts the edge host key on first use in
`/var/lib/nixos-deploy/known_hosts`. After reinstalling `edge`, remove that file
so the next deployment learns the new key.

## Bootstrap

The runner does not exist until the configuration that adds it has been
activated. The first deployment is therefore manual:

1. Create the PAT and encrypt `modules/secrets/github-runner.yaml` as described
   above.
2. Add the tailnet SSH rule.
3. Land the change.
4. From a workstation, deploy both hosts once with the normal privileged path,
   for example `just rdeploy neko-sphere root@<neko-sphere>` and
   `just rdeploy edge root@<edge>`. This installs the runner and enables
   Tailscale SSH.
5. Verify:
   ```sh
   systemctl status github-runner-neko-sphere
   journalctl -u github-runner-neko-sphere
   ssh root@edge.dwelf-hoki.ts.net true
   ```
6. Run the workflow once with `gh workflow run deploy.yml --ref main`, or push
   a trivial commit, and confirm both hosts switch.

The push that landed the change may already have queued a `Deploy` run. It
stays queued until the manually installed runner comes online.

## Rollback

Revert the offending commit on `main`; the resulting push triggers the workflow
and returns both hosts to the previous configuration. For a single host or a
workflow failure, run the same switch from a workstation:

```sh
nixos-rebuild switch --flake .#<machine> --target-host root@<host>
```

A partial deployment is possible: `edge` can succeed while `neko-sphere` fails.
Both hosts remain on the same revision after the next successful run.

## Troubleshooting

- **Runner is offline:** `systemctl status github-runner-neko-sphere` and
  `journalctl -u github-runner-neko-sphere`. A missing or expired PAT fails
  during runner registration.
- **Deployment fails:** `systemctl status nixos-deploy@<machine>` and, as root,
  `journalctl -u nixos-deploy@<machine>`. The workflow reports the request
  wrapper's exit status.
- **Tailscale SSH hangs or is denied:** `tailscale status` on both hosts,
  `ssh root@edge.dwelf-hoki.ts.net true`, and confirm the tailnet policy has an
  `accept` rule for `root`. `check` mode requires an interactive login.
- **Host key mismatch:** remove `/var/lib/nixos-deploy/known_hosts` after
  reinstalling `edge`.

## Security

The repository is public, and GitHub warns against self-hosted runners on
public repositories. Keep **Require approval for all outside collaborators**
enabled and do not approve workflows from untrusted pull requests: an approved
job runs as `github-runner` on `neko-sphere`. The runner is ephemeral, the
secret is hidden from job processes, and the only privileged action is the
polkit-authorized start of the two deployment units, which can deploy `main`
but cannot supply a flake.
