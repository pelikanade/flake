---
name: deploy
description: Apply this checkout to the running machine by switching the local NixOS configuration with a privileged `nixos-rebuild switch --flake .`. Use when the user explicitly asks to deploy, or when a completed configuration change (package, version, or setting) needs to be applied and the user confirms it.
---

# Deploy the local machine

Build and activate this checkout on the machine you are running on. Elevate through `pkexec`; never use `nh`, and never target a remote host from this skill.

## When to run

Deploy only with one of these triggers:

- The user explicitly asks to deploy, apply, or switch to the current configuration. That request is the authorization; still state the machine and command before running it.
- A task the user requested is finished and only takes effect after activation — a package version bump, a new package, a configuration change. Ask the user whether to deploy it now and wait for agreement.

Do not deploy on your own initiative, for a remote machine (use `just rdeploy <machine> <target>` or the [install-machine](../install-machine/SKILL.md) skill), while the change is incomplete or fails to evaluate, or as a way to reach unrelated privileged operations such as `boot`, `gc`, or secret rewrites.

## Prepare

1. `hostname` must match the machine this checkout configures; the command builds and activates the local system only.
2. Stage new files with `git add`. Nix evaluates a flake from the git tree and ignores untracked files, so an unstaged new module would silently not apply.
3. Format with `nixfmt`, lint with `statix`, and evaluate the local configuration. Never switch to a configuration that does not evaluate.
4. Commit the completed change at its atomic point (see [AGENTS.md](../../../AGENTS.md)) so the deployed revision is identifiable; `nixos-rebuild` otherwise warns about a dirty tree.

## Switch

```sh
pkexec --keep-cwd /run/current-system/sw/bin/env PATH="$PATH" nixos-rebuild switch --flake .
```

- Run it from the repository root. `--keep-cwd` is required: without it `pkexec` changes to the target user's home directory (`/root`) and `.` is no longer the checkout.
- Pass the session `PATH` through `env`. `pkexec` replaces the environment with a safe list that contains no `git`, and Nix resolves `git` from `PATH` to fetch flake inputs that are not yet in the privileged fetcher cache. Without this the switch aborts with `executing "git": No such file or directory` while fetching a transitive input such as `smithay`.
- Elevate with `pkexec`, not `sudo` or `nixos-rebuild --sudo`, and do not substitute `nh` or the `just deploy` recipe, which runs `nh`.
- Expect the polkit authentication dialog; the whole command then runs as root. The `nixos-rebuild-ng` wrapper supplies its own tools, so the rest of the reduced privileged environment is sufficient.
- If the command reports `pkexec must be setuid root`, a sandbox is blocking setuid escalation; rerun it unsandboxed.

## From a Paseo workspace

A terminal that Paseo hosts cannot elevate at all: the daemon keeps
`NoNewPrivileges=true`, so `sudo` refuses, `pkexec` never reaches its setuid step,
and a setuid helper would be ignored the same way. Ask the host's deploy broker
instead — a root service that fetches the flake this machine follows and switches
to its newest revision:

```sh
paseo-deploy
```

Starting the `deploy` workspace script that `paseo.json` declares runs exactly
that client, which is the one-click route for an agent or its user. The client is
installed by the `paseo-deploy` aspect, so a machine that has not deployed it once
from outside the account has no `paseo-deploy` command either.

- The broker deploys the published flake, never the working tree, so a change that
  has not landed is not what gets deployed. Land it first (see the
  [land skill](../land/SKILL.md)) or ask the user to; never report an unpublished
  revision as deployed.
- Report the machine and the flake reference before running it; this is the same
  operation as the `pkexec` switch and needs the same authorization.
- [Prepare](#prepare) still governs what you publish: format, lint and evaluate the
  revision before it lands, because the broker's switch only reports what the
  published revision does when it is activated here.
- The client exits with the deployment's status. The switch itself runs in a
  detached `flake-deploy-<pid>` unit, so a deployment that restarts Paseo kills
  the terminal without interrupting activation; when the terminal dies, follow the
  result with `journalctl -u 'flake-deploy-*'` instead.
- No socket at `/run/paseo-deploy.sock` means this machine's configuration does
  not import the `paseo-deploy` aspect yet. It cannot install itself, since
  installing it is what it does; report the missing privileged deployment instead
  of finding another way in. See [the deploy broker](../../../docs/paseo-deploy.md).

## Report

- Report the generation that was activated (`nixos-rebuild list-generations`) and which changes are now live.
- A successful switch proves evaluation and activation, not runtime behavior. State what still needs verification, especially services, drivers, hardware, and secrets.
