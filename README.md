# Personal NixOS flake

This repository manages personal NixOS workstations and servers, including their Home Manager environments. The workstation setup combines Hyprland with the Noctalia desktop shell, development tools, and coding agents. Disk layouts and an installer ISO support provisioning over SSH; sops-nix provides secrets at activation time.

The desktop retains the Rose Pine Moon theme and uses Sway-style window controls. See [desktop bindings and migration notes](docs/hyprland.md).

The [Magpie gateway](docs/magpie.md) on box owns the coding agents' encrypted credentials, and client hosts run Pi against it over the tailnet. Machines can also host coding agents for remote desktop and phone clients with the standalone [Paseo daemon](docs/paseo-daemon.md).

Asymmetry and Parallax have a [Tailscale pilot](docs/tailscale.md) using sing-box's native endpoint, declared with the rest of the proxy configuration in [the sing-box module](docs/sing-box.md) and kept in the encrypted document only where it is secret. NetBird's desktop UI and its local daemon remain for workplace login.

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

## Install a new host

Build the installer from the workstation checkout:

```sh
just build-installer-iso
```

Boot the target from the resulting ISO and connect it to the network with `nmtui`. The ISO trusts the configured maintainer's SSH key; adapt that key before building an ISO for your own machines. Installation runs from the workstation, and requires network access; the ISO carries no repository checkout.

Follow [machine preparation](.agents/skills/init-machine/SKILL.md), then the [installation procedure](.agents/skills/install-machine/SKILL.md). Preparation records hardware facts, selects the disk layout, and enrolls secret recipients when needed. Installation erases the selected disk; confirm the target and device before proceeding. The procedure also covers encrypted disks and Secure Boot.

Last updated at: `136561779218aa596ce6ce51ecddde36492f40c1`.
