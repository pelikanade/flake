# Personal NixOS flake

This repository manages personal NixOS workstations and servers, including their Home Manager environments. The workstation setup combines Hyprland with the Noctalia desktop shell, development tools, and coding agents. Disk layouts and an installer ISO support provisioning over SSH; sops-nix provides secrets at activation time.

The desktop retains the Rose Pine Moon theme and uses Sway-style window controls. See [desktop bindings and migration notes](docs/hyprland.md).

Desktop hosts run [omp](docs/omp.md) with per-host Codex and Cursor logins and a preloaded Magpie gateway provider. Fill the encrypted Magpie endpoint and API-key placeholders before deployment. Machines can also host coding agents for remote desktop and phone clients with the standalone [Paseo daemon](docs/paseo-daemon.md), which uses the same packaged provider with credentials owned by its service account. A host that runs that daemon can give its account a [deployment broker](docs/paseo-deploy.md): the daemon's sandbox leaves setuid helpers, `sudo`, and polkit unusable, so a root service fetches the published flake's newest revision and switches to it on request instead of an interactive login.

Asymmetry, Parallax and neko-sphere each join the tailnet through [the tailnet module](docs/tailscale.md), which runs `tailscaled` beside the proxy rather than inside it, so the daemon's own interface, CLI and `serve` all work. NetBird's desktop UI and its local daemon remain for workplace login.

neko-sphere's own services answer under a wildcard subdomain of the maintainer's domain with a Let's Encrypt certificate, through [the HTTPS ingress](docs/ingress.md), so a client that joins the tailnet — a home device included — uses a browser-trusted name instead of a per-service certificate and a port number. That host also runs a NetBird client in [userspace mode](docs/netbird-userspace.md), which serves a service from another network on a loopback port without touching its routing, DNS or firewall.

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

## Open SWE for local development

The `open-swe` package provides the native backend and bundled web dashboard, pinned together to an upstream revision. Build it or inspect its launch options with:

```sh
nix build .#open-swe
nix run .#open-swe -- --help
```

Follow the upstream [local development setup](https://github.com/langchain-ai/open-swe/blob/7755cc730c860c2d6803d8c01d550981c4263977/docs/DEVELOPMENT.md) for PostgreSQL, GitHub login, model credentials, and sandbox configuration. Export these settings before running `nix run .#open-swe`; the launcher reads the process environment rather than a checkout's `.env`. It requires `POSTGRES_URI` and a login allowlist (`ALLOWED_GITHUB_USERS` or `ALLOWED_GITHUB_ORGS`), and includes `gh` for upstream's local login flow. Startup applies Open SWE's migrations to the selected database.

The dashboard is served at `http://127.0.0.1:2024/` by default; `--port` changes the listener, and `LANGGRAPH_URL` should match it. For persistent state, launch from a dedicated writable directory with `nix run /absolute/path/to/flake#open-swe`; LangGraph writes `.langgraph_api` there. The package includes the default LangSmith and local sandbox providers; the optional third-party provider extras are not installed.

This uses LangGraph's Elastic-2.0 development runtime: keep it local, since the LangGraph API has no authentication. Production deployments use upstream's separately licensed container runtime. Building this package does not enable a NixOS service.

## Install a new host

Build the installer from the workstation checkout:

```sh
just build-installer-iso
```

Boot the target from the resulting ISO and connect it to the network with `nmtui`. The ISO trusts the configured maintainer's SSH key; adapt that key before building an ISO for your own machines. Installation runs from the workstation, and requires network access; the ISO carries no repository checkout.

Follow [machine preparation](.agents/skills/init-machine/SKILL.md), then the [installation procedure](.agents/skills/install-machine/SKILL.md). Preparation records hardware facts, selects the disk layout, and enrolls secret recipients when needed. Installation erases the selected disk; confirm the target and device before proceeding. The procedure also covers encrypted disks and Secure Boot.

Last updated at: `7891c28b06da258a3e4f9324b65a919e12e3fbdd`.
