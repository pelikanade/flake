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
                           │    └─ avalanche-server.service (avalanche-server serve)
                           │         ├─ NDJSON stream: phase / log / done
                           │         └─ avalanche-deploy.path
                           │              └─ avalanche-deploy.service
                           │                   └─ transient avalanche-deploy-transient-<nonce>
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
workflow needs the `actions: write` permission. The update workflow runs on the
`update-packages` runner described below, separate from the deploy runner, so a
nightly update never occupies the deploy queue.

## Runners

Two repository-level runners run on `neko-sphere`, each ephemeral: a runner
registers, processes one job, deregisters, and systemd registers it again for
the next job.

- `modules/services/avalanche-runner.nix` registers `avalanche` with the
  labels `self-hosted` and `avalanche`. `deploy.yml` targets it, and the
  matrix jobs run one after another.
- `modules/services/update-packages-runner.nix` registers `update-packages`
  with the labels `self-hosted` and `update-packages`. `update-packages.yml`
  targets it. Its `extraPackages` put python3, jq, gh, ripgrep, openssh,
  nix-update, and nixfmt on the job `PATH`, so the workflow calls them
  directly instead of entering a Nix shell.

The `avalanche` runner service runs as the static `avalanche-runner` user. It
has no root, no SSH key, and no deployment unit of its own. The
`avalanche-runner` module installs the `avalanche` package and gives the runner
service the `avalanche` group, so the client reads
`/run/secrets/avalanche_token` directly. The client is a command, not a
service; the workflow carries no trigger token.

The `update-packages` runner service runs as the static
`update-packages-runner` user. It has no root, no SSH key, and no deployment
unit; its only repository credential is the registration PAT. The workflow
pushes with the job's `GITHUB_TOKEN`.

Each matrix job invokes:

```sh
avalanche-client --target <machine>
```

The client:

1. reads `AVALANCHE_CLIENT_*` environment variables; the trigger token comes
   from `client.token_file`, defaulting to `/run/secrets/avalanche_token`; an
   optional `/etc/avalanche/client.yaml` or `AVALANCHE_CONFIG` file is also
   read, with environment variables taking precedence;
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
The NixOS modules therefore read a long-lived fine-grained PAT:
`modules/services/avalanche-runner.nix` installs it at
`/run/secrets/avalanche_runner_pat`, and
`modules/services/update-packages-runner.nix` installs the same document key at
`/run/secrets/update_packages_runner_pat`.

Create a fine-grained PAT with:

- **Repository access:** only `pelikanade/flake`;
- **Repository permissions:** `Administration: Read and write`;
  `Metadata: Read` is added automatically;
- an expiry you are prepared to rotate.

The value lives in `modules/secrets/avalanche.yaml` as `pat`, encrypted to the
maintainer, `neko-sphere`, and `edge`. Rotation: update the encrypted document,
switch `neko-sphere` (or restart `github-runner-avalanche`); the next job
registers with the new value.

## Targets

A machine is a deployment target when it imports the `avalanche-server` aspect.
Importing it always enables the trigger; there is no separate enable toggle.
Currently `neko-sphere` and `edge` import it; `asymmetry`, `parallax`, and the
installer do not.

The workflow matrix in `deploy.yml` is the source of target names. Keep it in
sync with the machines that import `avalanche-server`; currently that is `edge` and
`neko-sphere`.

The workflow passes the client configuration through the environment:

```yaml
env:
  AVALANCHE_CLIENT_TAILNET: <tailnetDnsName>
  AVALANCHE_CLIENT_PORT: "28250"
  AVALANCHE_CLIENT_FLAKE: "."
  AVALANCHE_CLIENT_TIMEOUT: 2h
```

There is no generated client YAML. Viper still accepts an optional
`/etc/avalanche/client.yaml` for manual use; the workflow does not create one.
The trigger token is not an environment value: the client reads the default
`/run/secrets/avalanche_token` file.

The generated server configuration on each target is:

```yaml
server:
  hostname: <hostname>
  token_file: /run/secrets/avalanche_token
  dir: /run/avalanche
  port: 28250
  timeout: 2h
```

Viper maps `client.*` / `server.*` to `AVALANCHE_CLIENT_*` /
`AVALANCHE_SERVER_*`; environment variables win over file values. The client
file is optional, so an environment-only deployment still works.

## Deploy trigger

Each target runs `avalanche-server.service` as the non-root `avalanche`
user. It runs `avalanche-server serve`, which listens on `127.0.0.1:28250`;
`tailscale-serve-deploy.service` publishes that port with:

```sh
tailscale serve --bg --http=28250 28250
```

The client calls `http://<machine>.<tailnetDnsName>:28250/deploy`, so this uses
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

A `systemd.path` unit starts `avalanche-deploy.service`, which starts a
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

`modules/secrets/avalanche.yaml` holds both avalanche secrets, encrypted to
the maintainer, `neko-sphere`, and `edge`:

- `token`: the shared trigger token, provisioned as `root:avalanche` with mode
  `0440`. The runner service has `avalanche` as a supplementary group, so the
  client reads this file directly;
- `pat`: the runner registration PAT, provisioned twice with mode `0400`:
  `avalanche-runner:avalanche-runner` and
  `update-packages-runner:update-packages-runner`.

No Actions secret carries the trigger token. The `avalanche` server user's
primary group is `avalanche`.

Rotation: replace the affected value with `sops`, then switch the targets (or
restart `avalanche-server.service`, `github-runner-avalanche`, or
`github-runner-update-packages`). The next job uses the new value.

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
   systemctl status avalanche-server tailscale-serve-deploy avalanche-deploy.path
   tailscale serve status
   ```
   On `neko-sphere`, also check `systemctl status github-runner-avalanche
   github-runner-update-packages`.
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

- **Runner is offline:** `systemctl status github-runner-avalanche` and
  `journalctl -u github-runner-avalanche` for deploys;
  `github-runner-update-packages` for updates. A missing or expired PAT fails
  during runner registration.
- **Trigger refused:** check `journalctl -u avalanche-server`, the token file's
  group, and `tailscale serve status`. The tailnet policy must allow `tcp:28250`
  from the runner to the target if it is not already open.
- **Deployment fails:** `journalctl -u avalanche-deploy` shows the request; the
  transient unit is `avalanche-deploy-transient-<nonce>`. Check that the target can reach
  `nsphere-cache` and that the store path is present there. The client's
  `target=<name>` lines include the activation output up to the failure.
- **Local job is lost:** the `neko-sphere` switch can restart the runner before
  the HTTP response arrives, canceling the local matrix job. The transient unit
  still completes; check it with `journalctl -u avalanche-deploy-transient-<nonce>`.
  Rerun the failed matrix job from the workflow run if needed.

## Security

The repository is public, and GitHub warns against self-hosted runners on
public repositories. Keep **Require approval for all outside collaborators**
enabled and do not approve workflows from untrusted pull requests: an approved
job runs as `avalanche-runner` on `neko-sphere`.

The runner is ephemeral and unprivileged; it cannot SSH to a target. The
target trigger is non-root and bound to loopback, its only public surface is
`tailscale serve` with the bearer token read from sops by the runner, and the
root work happens in a transient unit that validates the store path and only
substitutes signed paths from Harmonia.