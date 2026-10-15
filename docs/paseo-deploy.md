# Paseo deploy broker

The Paseo account hosts agents that change this machine's configuration, and a
change is only live after `nixos-rebuild switch`. That switch needs root, and the
daemon's sandbox keeps `NoNewPrivileges=true`, which the kernel applies to every
agent and terminal it starts. That flag closes every setuid route at once: `sudo`
refuses with "The 'no new privileges' flag is set", `pkexec` must be setuid root
to run at all, and a setuid helper of our own would be ignored by the same rule.
The only remaining route is a service that already runs as root and that the
account can ask for work, which is what this aspect adds — see
[the deploy skill](../../.agents/skills/deploy/SKILL.md) for when a deployment is
allowed to run.

## Two halves, one protocol

| Half | Where it runs | Who it is |
| --- | --- | --- |
| `paseo-deploy`, the client package | a Paseo terminal, or the `deploy` workspace script from `paseo.json` | the `paseo` account |
| `paseo-deploy-broker`, and `paseo-deploy.socket` with `paseo-deploy@.service` | this machine's system manager | root |

The client connects to `/run/paseo-deploy.sock` and sends nothing; the request is
the connection itself. The socket is `Accept=yes`, so systemd starts one instance
of `paseo-deploy@.service` per connection and hands it that connection on the
standard file descriptors. The broker takes its lock, starts
`nixos-rebuild switch --flake FLAKE -L` as a transient
`flake-deploy-<pid>.service`, streams its output back, and ends the stream with
`__paseo-deploy-exit__=<status>`. The client strips that marker and exits with the
number, since a socket stream carries no exit status of its own.

The switch runs in a transient unit outside the connection's cgroup. A client
that goes away — the usual case, because deploying a new Paseo package restarts
the daemon and with it the terminal that asked for the deployment — then loses
the output, not the activation.

## What it deploys

`services.paseo-deploy.flake`, resolved fresh on every request: nix fetches the
current tip of that reference's default branch and the machine switches to it.
Nothing local takes part, so a workspace's working tree, uncommitted files and
whatever checkout an agent happens to sit in are irrelevant — a change reaches
the machine only by landing in the published repository first. The flake
reference carries no attribute, so `nixos-rebuild` selects the configuration
matching the local hostname and cannot activate another machine's configuration.

Two requests cannot overlap: the broker holds `/run/paseo-deploy.lock` for the
duration of a deployment and answers a second request with status 3. `0` is a
completed switch, `2` a broker with no flake to deploy, `3` a deployment already
running, `4` a broker that could not start one, and anything else is
`nixos-rebuild`'s own exit status.

## Trust

The socket is the boundary: mode `0600`, owned by `paseo`, so only that account
asks for deployments. The account cannot choose what is deployed, but it can
start an activation, and an activation runs the flake's scripts as root — so the
grant is "rebuild from the published default branch", and whoever can write to
that branch, or to the hosting account, reaches root here on the next request.
That is the deliberate trade for letting the agents hosted here deploy their own
changes. A host that cannot grant it must not import the aspect; its maintainer
deploys from outside the account as described in [the Paseo daemon](paseo-daemon.md).

## First deployment

The broker cannot install itself, since installing it is what it does. One
privileged deployment has to happen from outside the account, either from the
maintainer's session or through the root SSH route that [the Paseo
daemon](paseo-daemon.md) documents. After that the aspect is live, and every
later deployment can come from the account:

```sh
paseo script start deploy --cwd /var/lib/paseo/Projects/flake
```

From a desktop session or any other shell, the same package runs the same
request; from a checkout, `nix run .#paseo-deploy` builds it first:

```sh
paseo-deploy
```

It takes no arguments: the broker decides what to deploy, and asking is the whole
request. `paseo-deploy --help` prints that usage without deploying anything, and
an argument it does not know is refused with status 2 rather than answered with a
deployment.

A workspace script whose command does not exist yet belongs to a machine that has
not imported the aspect: until that first privileged deployment, `paseo-deploy`
is not on any PATH either.

## Reading the result

The client streams the fetch, build and activation as they happen and exits with
the deployment's status. Two records survive a lost connection:

```sh
journalctl -u 'flake-deploy-*'    # one unit per deployment, with its result
journalctl -u 'paseo-deploy@*'    # one unit per request, with its exit status
```

The socket path is `/run/paseo-deploy.sock`; `PASEO_DEPLOY_SOCKET` points the
client somewhere else, which is what a test of the protocol uses.

A deployment proves evaluation and activation of that revision. It does not prove
runtime behavior: services, drivers, hardware, and secrets still need checking on
the machine that now runs the new generation.
