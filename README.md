# Personal NixOS flake

This repository manages personal NixOS workstations and servers, including their Home Manager environments. The workstation setup combines Hyprland with the Noctalia desktop shell, development tools, and coding agents. Disk layouts and an installer ISO support provisioning over SSH; sops-nix provides secrets at activation time.

The desktop retains the Rose Pine Moon theme and uses Sway-style window controls. See [desktop bindings and migration notes](docs/hyprland.md).

Desktop hosts run [omp](docs/omp.md) with per-host Codex and Cursor logins and a preloaded Magpie gateway provider. Fill the encrypted Magpie endpoint and API-key placeholders before deployment. Machines can also host coding agents for remote desktop and phone clients with the standalone [Paseo daemon](docs/paseo-daemon.md), which uses the same packaged provider with credentials owned by its service account.

Asymmetry, Parallax and neko-sphere each join the tailnet through [the tailnet module](docs/tailscale.md), which runs `tailscaled` beside the proxy rather than inside it, so the daemon's own interface, CLI and `serve` all work. NetBird's desktop UI and its local daemon remain for workplace login.

neko-sphere's own services are advertised as [Tailscale Services](docs/tailscale-ingress.md), so a client that joins the tailnet — a home device included — reaches each one by a stable `*.dwelf-hoki.ts.net` name with a certificate the daemon issues and terminates, and the service keeps that name if it moves to another host. That host also runs [Freezer](docs/freezer.md), the flake build service that builds this repository's outputs, and a Harmonia cache that serves those store paths over the tailnet, plus a NetBird client in [userspace mode](docs/netbird-userspace.md), which serves a service from another network on a loopback port without touching its routing, DNS or firewall. [Gatus](docs/gatus.md) watches those services and the public sites from `edge`, which serves its status page at `status.nvirellia.im` through [Caddy](docs/caddy.md); the same host runs [Prometheus](docs/probe.md) to scrape node_exporter on both machines for the profile sheet's probe table.

It is intended for the maintainer's machines and for people comfortable adapting a NixOS configuration. The machine definitions target `x86_64-linux` and include personal accounts, hardware, disk paths, network settings, and trusted keys. Adopting the configuration requires replacing those values and supplying your own secrets and recipients.

## Get started

Clone or fork this repository, then enter the checkout on Linux with Nix installed and `nix-command` and `flakes` enabled:

```sh
nix develop
just
```

`just` lists the available operations. Read the relevant recipe in [Justfile](Justfile) before running it. For changes to the configuration, start with the [contributor guidance](AGENTS.md).

After adapting a [machine definition](modules/machines/), build its system without activating it. Replace `MACHINE` with its configuration name:

```sh
nix build .#nixosConfigurations.MACHINE.config.system.build.toplevel
```

On an already managed host, `just build` builds the local system and `just deploy` switches to it. A build alone does not verify runtime behavior on the target hardware.

## Automated updates

A scheduled workflow updates the flake lock and every exported package that declares `passthru.update` metadata, then builds every updated package. A package that fails is repaired by an omp agent; a second omp agent reviews the repair, including a security check. The workflow commits only after the repair builds and the review approves. Update commits and the repair commit are separate. If a gate fails, the clean updates still land and the failed package keeps its previous version. See [updates](docs/updates.md).

The agents use omp's built-in DeepSeek model. Set the `DEEPSEEK_API_KEY` repository secret as described in that document; without it, a failed build is not repaired and the run fails.

A push to `main`—including the update workflow's own commits—triggers the
`Deploy` workflow on the `neko-sphere` self-hosted runner. It runs one matrix
job per target serially, so each job builds and deploys its machine, then
streams the target's phase and log back to the workflow. The runner never gets
SSH or root access to a target. Workstations are not deployed automatically.
The switch never reboots on its own, so a kernel update waits for a reboot the
operator chooses. See [deployment](docs/deployment.md).

Run the same updater from `nix develop`; it leaves changes uncommitted for review:

```sh
just update-packages --build
```

`just update-packages --build` updates every discovered package. Pass `flake` to update every flake input instead, or name packages to update a subset. Add `--keep-failed` to leave a failed pin and its log for the repair script.

## Install a new host

Build the installer from the workstation checkout:

```sh
just build-installer-iso
```

Boot the target from the resulting ISO and connect it to the network with `nmtui`. The ISO trusts the configured maintainer's SSH key; adapt that key before building an ISO for your own machines. Installation runs from the workstation, and requires network access; the ISO carries no repository checkout.

Follow [machine preparation](.agents/skills/init-machine/SKILL.md), then the [installation procedure](.agents/skills/install-machine/SKILL.md). Preparation records hardware facts, selects the disk layout, and enrolls secret recipients when needed. Installation erases the selected disk; confirm the target and device before proceeding. The procedure also covers encrypted disks and Secure Boot.

Last updated at: `bb06fffbc7b686b0620a8ea97ea717a9e02c0c19`.
