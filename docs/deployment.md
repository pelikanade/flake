# Deployment

A push to `main` starts one matrix job per deployment target. Each job builds
its target and asks it to activate the closure. No host pulls the repository on
a timer, and the runners never get SSH access.

```text
push main ──> Deploy workflow (self-hosted runner on neko-sphere)
                 └─ serial matrix: edge, neko-sphere
                      └─ avalanche-client --target <target>
                           ├─ nix build <target> toplevel
                           ├─ POST store path + bearer token
                           │    └─ deploy-trigger.service (avalanche-server serve)
                           │         ├─ NDJSON stream: phase / log / done
                           │         └─ nixos-deploy.path
                           │              └─ nixos-deploy.service
                           │                   └─ transient avalanche-deploy-<nonce>
                           │                        └─ avalanche-server activate
                           │                             ├─ nix-store --realise <path>   # from Harmonia
                           │                             ├─ nix-env -p /nix/var/nix/profiles/system --set <path>
                           │                             └─ switch-to-configuration switch
                           └─ stream phase / log / done back to the job
```

## Trigger

[`deploy.yml`](../.github/workflows/deploy.yml) runs on:

- a push to `main`;
- `workflow_dispatch` from `main`.

A dispatch from another ref is skipped. The matrix runs with
`fail-fast: false`; the single runner processes one target at a time. Each job
builds its own closure and sends its own trigger; a build failure leaves that
target on its current generation while the other matrix jobs continue.

The update workflow pushes its commits with `GITHUB_TOKEN`. GitHub does not
start a new `push` workflow for that token, so
[`update-packages.yml`](../.github/workflows/update-packages.yml) explicitly
runs `gh workflow run deploy.yml --ref main` after a push. This is why that
workflow needs the `actions: write` permission.

## Runner

`modules/services/github-runner.nix` registers one repository-level runner,
named `neko-sphere`, with the labels `self-hosted` and `neko-sphere`. It is
ephemeral: it registers, processes one job, deregisters, and is registered
again by systemd for the next job. With one runner, the matrix jobs run one
after another.

The runner service runs as the static `github-runner` user. It has no root, no
SSH key, and no deployment unit of its own. The `avalanche` aspect, imported by
`neko-sphere`, installs the `avalanche` package and writes
`/etc/avalanche/client.yaml` only because a GitHub runner is present; the
client is a command, not a service. The runner service has the `deploy` group
as a supplementary group so that command can read the shared token.

Each matrix job invokes:

```sh
avalanche-client --target <machine>
```

The client:

1. reads `/etc/avalanche/client.yaml` with Viper and the shared trigger token
   from sops; every `AVALANCHE_CLIENT_*` environment variable overrides the
   YAML value, and `AVALANCHE_CONFIG` selects a different file;
2. builds only its target with
   `nix build --no-link --print-out-paths .#nixosConfigurations.<target>.config.system.build.toplevel`;
3. sends the store path to that target;
4. streams the target's phase and log events to the matrix job log, and fails
   the job if the target reports a failed deployment.

The matrix includes `neko-sphere` itself. Activating it can restart the runner
and cancel the running job; the transient activation unit is independent of the
client and continues. The client has no local-target special case: a failed or
lost connection fails that matrix job. The other matrix entry is queued behind
the single runner, so it normally runs after the runner re-registers.

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

A machine is a deployment target when it imports the `avalanche` aspect.
Importing it always enables the trigger; there is no separate enable toggle.
Currently `neko-sphere` and `edge` import it; `asymmetry`, `parallax`, and the
installer do not.

The workflow matrix in `deploy.yml` is the source of target names. Keep it in
sync with the machines that import `avalanche`; currently that is `edge` and
`neko-sphere`.

The generated client configuration is:

```yaml
client:
  tailnet: <tailnetDnsName>
  token_file: /run/secrets/deploy_trigger_token
  port: 8080
  flake: "."
  timeout: 2h
```

The generated server configuration on each target is:

```yaml
server:
  hostname: <hostname>
  token_file: /run/secrets/deploy_trigger_token
  dir: /run/deploy-trigger
  port: 8080
  timeout: 2h
```

Viper loads the YAML file and automatically maps `client.*` / `server.*` to
`AVALANCHE_CLIENT_*` / `AVALANCHE_SERVER_*`; environment variables win over
file values. The file is optional, so an environment-only deployment still
works.

## Deploy trigger

Each target runs `deploy-trigger.service` as the non-root `deploy-trigger` user.
It runs `avalanche-server serve`, which listens on `127.0.0.1:8080`;
`tailscale-serve-deploy.service` publishes that port with:

```sh
tailscale serve --bg --http=8080 8080
```

The client calls `http://<machine>.<tailnetDnsName>:8080/deploy`, so this uses
the node's own MagicDNS name. No Tailscale Service is needed in the admin
console, and Tailscale SSH is not used.

The request carries `Authorization: Bearer <token>` and a toplevel store path.
The handler validates both, writes a request file, and streams the deployment
as newline-delimited JSON:

```json
{"type":"phase","phase":"queued"}
{"type":"log","line":"$ nix-store --realise /nix/store/… --option max-jobs 0"}
{"type":"phase","phase":"switch"}
{"type":"done","ok":true}
```

Phases are `queued`, `realise`, `profile`, `switch`, and `done` (or `failed`).
A failed activation ends with `{"type":"done","error":"deployment failed"}`.
The client logs each event with `target=<name>`; matrix job logs remain
distinguishable in the workflow run.

A `systemd.path` unit starts `nixos-deploy.service`, which starts a
**transient** `systemd-run` unit. That unit runs:

```sh
avalanche-server activate
```

with `AVALANCHE_SERVER_NONCE` and `AVALANCHE_SERVER_STORE_PATH` passed through
`systemd-run --setenv`, and performs:

```sh
nix-store --realise <store-path> --option max-jobs 0
nix-env -p /nix/var/nix/profiles/system --set <store-path>
<store-path>/bin/switch-to-configuration switch
```

`activate` tees stdout and stderr into `log-<nonce>` and publishes
`status-<nonce>` and `result-<nonce>`; `serve` tails those files for the
requesting client. The transient unit is outside the NixOS configuration, so
the switch cannot restart it mid-activation. If the local switch restarts a
runner, the transient unit keeps going; the workflow may report the job as
lost.

## Cache

Harmonia on `neko-sphere` serves the host's Nix store and signs with the
`freezer-cache-1` key. Every tailnet host already trusts
`http://nsphere-cache…` through `modules/system/nix/default.nix`. Each matrix
job builds on `neko-sphere`, so the closure is already in that cache; there is
no separate upload step.

`max-jobs 0` on the target makes the activation fail rather than build if the
cache does not have a required path.

## Token

`modules/secrets/deploy-trigger.yaml` holds one shared value,
`deploy_trigger_token`, encrypted to the maintainer and every target. The
module provisions it as `root:deploy` with mode `0440`; the runner service has
`deploy` as a supplementary group, and the `deploy-trigger` user is in it.

Rotation: replace the value with `sops`, then switch the targets (or restart
`deploy-trigger.service`). The client reads the new value on its next job.

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

A partial deployment is possible: matrix jobs are serial, and the local switch
can cancel its own job by restarting the runner. Every target remains on its
last successfully activated revision after the next run.

## Troubleshooting

- **Runner is offline:** `systemctl status github-runner-neko-sphere` and
  `journalctl -u github-runner-neko-sphere`. A missing or expired PAT fails
  during runner registration.
- **Trigger refused:** check `journalctl -u deploy-trigger`, the token file's
  group, and `tailscale serve status`. The tailnet policy must allow `tcp:8080`
  from the runner to the target if it is not already open.
- **Deployment fails:** `journalctl -u nixos-deploy` shows the request; the
  transient unit is `avalanche-deploy-<nonce>`. Check that the target can reach
  `nsphere-cache` and that the store path is present there. The client's
  `target=<name>` lines include the activation output up to the failure.
- **Local job is lost:** the `neko-sphere` switch can restart the runner before
  the HTTP response arrives, canceling the local matrix job. The transient unit
  still completes; check it with `journalctl -u avalanche-deploy-<nonce>`.
  Rerun the failed matrix job from the workflow run if needed.

## Security

The repository is public, and GitHub warns against self-hosted runners on
public repositories. Keep **Require approval for all outside collaborators**
enabled and do not approve workflows from untrusted pull requests: an approved
job runs as `github-runner` on `neko-sphere`.

The runner is ephemeral and unprivileged; it cannot SSH to a target. The
target trigger is non-root and bound to loopback, its only public surface is
`tailscale serve` with a bearer token, and the root work happens in a transient
unit that validates the store path and only substitutes signed paths from
Harmonia.