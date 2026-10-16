# Portainer

[Portainer](https://docs.portainer.io/) is a web UI for container runtimes.
`neko-sphere` runs it to inspect and operate containers the host creates, both
its own and the ones hosted coding agents create.

Portainer publishes no nixpkgs package and no NixOS module, so this aspect runs
the vendor's image under NixOS-managed lifecycle, storage, exposure, and sockets.
It manages two rootless Podman runtimes and needs the `paseo` account, which
comes from [the Paseo daemon aspect](paseo-daemon.md).

## Machine composition

Add `portainer` to the selected machine's aspect imports, preserving `base`. The
aspect brings in `podman`, so no separate runtime import is needed:

```nix
imports = with inputs.self.modules.aspects; [
  base
  server
  sing-box
  podman
  portainer
  paseo-daemon
];
```

Build that machine's NixOS configuration before separately authorizing
deployment, as [the daemon documentation](paseo-daemon.md) describes.

## Runtimes and their sockets

Containers here run rootless: each account drives Podman under its own uid, and
Podman serves its Docker-compatible API on a socket inside that account's private
runtime directory. A container running under one account cannot open another
account's socket, because inside a rootless user namespace neither the socket's
owner nor its group maps, which leaves only the "other" permission bits — that
is, the whole local host. Publishing a runtime as a world-reachable socket would
hand it to every local process.

The `podman` aspect owns `virtualisation.podman.runtimeApis` for exactly this
case. A runtime's own module declares an entry for it, and the account whose
containers drive runtimes names itself once in
`virtualisation.podman.runtimeApiClient`. Systemd then holds each published socket
with `SocketMode=0660`, the runtime's own account as `SocketUser` and that client
as `SocketGroup`. The client's container matches the group bits, because the
client account's gid maps into that container as container gid 0; the runtime's
own account matches the owner bits, which is what lets its own processes — the
ones inside the Paseo daemon's sandbox included — drive the runtime it serves. No
other account matches either class. Each entry also publishes its path in
`socketPath`, outside the runtime account's private runtime directory, so a
container can mount it; an entry may still name a different `client` of its own.

This aspect names itself as that client and declares its own runtime, so no module
names another:

| Declared by | Runtime | Socket | Owner | Group |
| --- | --- | --- | --- | --- |
| `paseo-daemon` | the `paseo` account's, where agents work | `/run/podman-api-paseo/podman.sock` | `paseo` | `portainer` |
| this aspect | the `portainer` account's own | `/run/podman-api-portainer/podman.sock` | `portainer` | `portainer` |

Each runtime keeps its own API server, named for it, running as that runtime's
account and started by its socket only when a client connects. Podman answers on
the descriptor systemd hands it, which is why a published socket never has to be
the path the account's own runtime uses. Both accounts have a subordinate ID range
and a lingering user manager, which is what rootless Podman needs; agents and the
UI are the only users of the runtimes. Containers the UI creates outlive a reboot
only if the creation form gave them a restart policy, which is the boot path the
[daemon documentation](paseo-daemon.md#containers-for-agents) describes.

## The container

`podman-portainer.service` runs `portainer/portainer-ce:2.45.2` in the `portainer`
account's rootless Podman. It mounts the runtime it runs in at
`/var/run/docker.sock`, which Portainer adopts as its local environment, every
other published runtime at `/run/podman-<runtime>.sock`, and
`/var/lib/portainer/data` at `/data`:

- `/run/podman-api-portainer/podman.sock` at `/var/run/docker.sock` — the local
  environment;
- `/run/podman-api-paseo/podman.sock` at `/run/podman-paseo.sock` — the agents'
  runtime, and not an environment until you add it;
- `/var/lib/portainer/data` at `/data` — the database, the certificate Portainer
  generates for its own HTTPS listener, and any settings you make in the UI. The
  account owns its home directory mode `0700`; keep backups of `/data` if the
  environment list matters to you.

Adding a runtime to `runtimeApis` therefore gives the UI a mount for it on the
next switch; the environment itself is still yours to add.

The image is pinned. Updating means editing `image` in
`modules/services/portainer.nix`; the change rewrites the unit, so the next
`switch` recreates the container and pulls the new tag. `lts` and `sts` tags
exist upstream if you prefer a moving reference.

Only `9443` is published. Rootless Podman forwards that port with a userspace
process running as the account, so it is an ordinary host socket, and nothing in
the firewall admits it by port: a tailnet peer's connection arrives on
`tailscale0`, which is a trusted interface, so Portainer's own login is what bounds
it. The image's HTTP listener
and edge tunnel stay unpublished and unreachable. Portainer serves HTTPS with a
self-signed certificate it generates into `/data`, so browsers warn until you
accept it. Reach it through [the ingress](ingress.md), which terminates the
trusted certificate and republishes this listener as
`https://portainer.neko-sphere.nvirellia.im/`; the direct
`https://neko-sphere.leaffish-halfmoon.ts.net:9443/` address is then only for
diagnosing the container itself.

## First start

Portainer refuses to create the administrator account until a setup token from
its log is pasted into the setup screen:

```sh
ssh root@neko-sphere 'journalctl -u podman-portainer.service | grep -i setup_token'
```

The token is a one-time credential: keep it out of logs you share. If the setup
window lapses before you finish, restart the service
(`ssh root@neko-sphere systemctl restart podman-portainer.service`) and read a
fresh token. Pass `--admin-password-file` in the container's `cmd` to provision
the password instead, which needs a secret document this repository does not
have yet; the UI path keeps no password in Nix.

Then add the agents' runtime once: **Environments → Add environment → Podman**,
enable **Override default socket path**, and enter `/run/podman-paseo.sock`. The
setting lives in `/data`, so it survives restarts and rebuilds. Only `9443` is
open, so keep the tailnet as the boundary: anything that reaches the UI can also
drive both runtimes through Portainer.

## Verification

Configuration evaluation and a build only prove that the units are generated.
After deploying, check on the host:

```sh
systemctl status podman-api-portainer.socket podman-api-paseo.socket podman-portainer.service
curl --insecure --fail https://127.0.0.1:9443/api/status
sudo -u portainer podman info
sudo -u paseo podman info
ls -l /run/podman-api-paseo/podman.sock
```

`/api/status` answers without authentication and names the version. The two
`podman info` runs exercise each runtime as its own account on the host; the Paseo
daemon's agents reach the `paseo` runtime through the published socket instead,
whose owner and group the `ls` line checks. Then confirm
in the UI that the local environment lists containers and that the second
environment, once added, lists the containers agents create. Both runtimes need
`/etc/subuid` entries, which only activation writes, so a configuration that
evaluates and builds does not prove either runtime works.
