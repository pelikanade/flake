# flake

![Annotated desktop screenshot: the nvirellia.im status page with Gatus uptime checks and per-host probes beside a fastfetch report of parallax running NixOS 26.05, Hyprland and the NVIDIA stack](https://gist.githubusercontent.com/pelikanade/24093549b4e95f9ed5f140b83efc4df7/raw/cover.webp)

A declarative, single-tree NixOS configuration that manages personal workstations, home servers, and cloud edge nodes using the dendritic `flake-parts` pattern. Every feature—from disk layouts and Secure Boot to desktop apps and server daemons—lives in a self-contained aspect module that configures NixOS, Home Manager, and flake inputs in one place, so adding a machine or toggling a service takes a single import list rather than scattered cross-file edits.

- **Dendritic module tree.** `import-tree` loads every `.nix` file under `modules/` automatically, while `flake-file` generates the root `flake.nix` directly from module-level input declarations.
- **5 machine profiles.** Provisions 2 Hyprland workstations (`asymmetry`, `parallax`), 2 servers (`neko-sphere`, `edge`), and 1 bootable installer image (`installer`) on NixOS 26.05 (`x86_64-linux`).
- **One-command provisioning.** Combines Disko declarative partitioning (XFS/ext4 + LUKS), Lanzaboote Secure Boot (`v1.1.0`), `nixos-anywhere` SSH installation, and 1Password-backed LUKS key generation in `Justfile` recipes.
- **Encrypted runtime secrets.** Manages 8 service secret bundles with `sops-nix` and host SSH-derived `age` keys, decrypting credentials at activation time without touching the world-readable Nix store.
- **14 custom packages.** Bundles in-house and closed-beta software under `pkgs.selfPackages`: the `avalanche` deployment engine, `strata` GTK4 file manager, `open-design` (daemon and desktop app), `magpie`, `omp` with its `omp-magpie` extension, `paseo` (daemon and desktop app), `tern` (`v0.9.5`) with `tern-wayland-ime`, `herdr-reviewr`, and the `deepseek-harness` pair.
- **Automated CI/CD & binary cache.** Runs a daily `02:00 Asia/Shanghai` update pipeline, builds default branches via `freezer`, serves store paths from a Harmonia cache over Tailscale, and deploys pushes to `main` via `avalanche`.

```nix
# modules/machines/asymmetry.nix — compose a complete machine from reusable aspects
{ inputs, ... }:
{
  flake.nixosConfigurations.asymmetry = inputs.nixpkgs.lib.nixosSystem {
    modules = with inputs.self.modules.nixos; [
      base workstation efi secure-boot i18n substituter-cn
      inputs.self.diskoConfigurations.xfs-workstation
    ];
  };
}
```

## Getting started

Follow these steps to enter the development environment, build a host configuration, or provision a new machine from scratch.

### 1. Clone the repository and enter the dev shell

If you use `direnv`, allow the `.envrc` file; otherwise, launch the Nix development shell directly to get `just`, `sops`, `age`, `nixfmt-rfc-style`, and `statix` along with pre-commit hooks:

```bash
git clone https://github.com/pelikanade/flake.git
cd flake
nix develop
```

### 2. Build and preview a system switch locally

Test that the configuration evaluates and builds cleanly before activating any changes on your current machine:

```bash
# Build this machine's system closure without activating it
just build

# Show which systemd units and store paths would change on switch
just dryrun

# Activate the newly built configuration and set it as boot default
just deploy
```

### 3. Provision a new target machine over SSH

To install NixOS onto a fresh target machine booted into an installer or SSH-accessible Linux environment:

```bash
# 1. Inspect the target machine's SSH-derived age key and hardware config
just collect-machine-info root@203.0.113.10

# 2. Generate a 64-character LUKS passphrase in the 1Password "NixOS" vault
luks_key=$(just generate-luks-password parallax)

# 3. Partition disks with Disko and install the target NixOS configuration
just install parallax root@203.0.113.10 "$luks_key"
```

> **Note:** Never edit the root `flake.nix` by hand. Declare new flake inputs inside the relevant module under `modules/` using `flake-file.inputs`, then regenerate `flake.nix` by running:
> ```bash
> nix run .#write-flake
> ```

## Machines

Each host in `modules/machines/` combines a role (`workstation`, `server`, or `installer`) with hardware-specific aspects and a Disko layout:

| Machine | Role | Hardware & Graphics | Disko Layout | Key Services & Desktop |
| :--- | :--- | :--- | :--- | :--- |
| **`asymmetry`** | Workstation | Intel CPU + NPU, Intel iGPU (2880×1800@120Hz) | `xfs-workstation` (NVMe) | Hyprland (`uwsm`), Noctalia shell, Stylix (Nord), Lanzaboote Secure Boot |
| **`parallax`** | Workstation | AMD CPU, NVIDIA discrete GPU (`x86_64-linux`) | `xfs-workstation` | Hyprland (`uwsm`), NVIDIA proprietary stack, gaming tools, HMCL |
| **`neko-sphere`** | Home Server | Physical NVMe server (`x86_64-linux`) | `workstation-legacy` | Harmonia cache, Freezer builder, Magpie AI gateway, Paseo daemon, Tailscale ingress, NetBird userspace, Podman |
| **`edge`** | Cloud Edge | QEMU/KVM VM (`virtio`, `x86_64-linux`) | `ext4-server-bios`, BIOS/GRUB | Caddy (auto-HTTPS), `nvirellia.im`, Gatus status page, Prometheus (`probe-hub`), Avalanche server |
| **`installer`** | Live ISO | Generic `x86_64-linux` | ISO image | Minimal bootable NixOS installer image (`just build-installer-iso`) |

## Architecture

Instead of splitting configurations across separate `nixos/`, `hm/`, and `overlays/` directories, this repository uses the **dendritic pattern** with `flake-parts` and `import-tree`:

- **`modules/machines/`** — Host compositions that wire together roles, hardware profiles, and Disko layouts.
- **`modules/roles/`** — High-level machine archetypes (`base.nix`, `workstation.nix`, `server.nix`, `installer.nix`).
- **`modules/system/`** — Bootloaders (`lanzaboote`), Disko partition layouts (`xfs-workstation`, `ext4-server-efi`, `ext4-server-bios`, `workstation-legacy`), NVIDIA drivers, Plymouth, U2F, Zswap, and internationalization.
- **`modules/apps/`** — Desktop environments and user applications (`hyprland`, `ghostty`, `neovim` via Nixvim, `zed`, `firefox`, `obsidian`, `1password`, `fcitx5`, `fish`, `starship`, `flatpak`).
- **`modules/services/`** — System and network daemons (`avalanche-server`, `caddy`, `freezer`, `gatus`, `harmonia`, `magpie`, `netbird-userspace`, `nvirellia-im`, `paseo-daemon`, `podman`, `sing-box`, `tailscale`, `tailscale-ingress`, `stylix`).
- **`modules/packages/`** — Custom derivations exposed across all hosts via the `pkgs.selfPackages` overlay (`self-packages.nix`).
- **`modules/secrets/`** — SOPS-encrypted YAML secret bundles and `.sops.yaml` recipient rules.
- **`scripts/`** — TypeScript automation scripts (`update-packages.ts`, `verify-packages.ts`, `commit-updates.ts`) for dependency and package maintenance.

## Common operations

Running `just` with no arguments lists all available operational recipes from `Justfile`:

```bash
# Push a freshly built configuration to a remote host over SSH
just rdeploy edge root@edge.example.com

# Build a bootable NixOS installer ISO for new hardware
just build-installer-iso

# Update flake inputs and locally packaged tools
just update-packages

# Remove system generations older than 7 days and garbage-collect the Nix store
just gc
```

## Secrets management

Secrets are encrypted with `sops-nix` using `age` keys derived from host SSH Ed25519 keys (`.sops.yaml`) and stored under `modules/secrets/` (`avalanche.yaml`, `beszel.yaml`, `freezer.yaml`, `magpie.yaml`, `netbird-userspace.yaml`, `paseo.yaml`, `sing-box.yaml`, `tailscale.yaml`).

```bash
# Edit an encrypted secret bundle in-place
sops modules/secrets/tailscale.yaml

# Re-encrypt all secret files after updating recipients in .sops.yaml
just updatekeys

# Add or remove an age recipient from a machine that can already decrypt the file
just rewrap-secret tailscale.yaml --add-age age1...
```

## Custom packages & documentation

Every custom package in `modules/packages/` and service integration in `modules/services/` is documented in detail under [`docs/`](docs):

- **Workstation & UI tools:** [docs/hyprland.md](docs/hyprland.md) (uwsm + Noctalia + Stylix), [docs/tern.md](docs/tern.md) (Tern `v0.9.5` terminal workspace with `requireFile`), [docs/strata.md](docs/strata.md) (keyboard-first GTK4 file manager), [docs/open-design.md](docs/open-design.md) (`od` daemon & desktop app), [docs/delta.md](docs/delta.md) (Zed Delta client).
- **AI & coding agent harnesses:** [docs/omp.md](docs/omp.md) (oh-my-pi agent harness), [docs/paseo-daemon.md](docs/paseo-daemon.md) (remote coding agent & terminal daemon), [docs/magpie.md](docs/magpie.md) (GTK3 UI & model gateway on ports `3430`/`3425`).
- **Infrastructure, networking & CI/CD:** [docs/deployment.md](docs/deployment.md) (Avalanche push-to-`main` continuous deployment), [docs/freezer.md](docs/freezer.md) (automated flake builder & Harmonia cache), [docs/updates.md](docs/updates.md) (daily `02:00 Asia/Shanghai` package updater), [docs/tailscale.md](docs/tailscale.md), [docs/tailscale-ingress.md](docs/tailscale-ingress.md), [docs/netbird-userspace.md](docs/netbird-userspace.md), [docs/sing-box.md](docs/sing-box.md), [docs/caddy.md](docs/caddy.md), [docs/gatus.md](docs/gatus.md), [docs/probe.md](docs/probe.md) (Prometheus + `node_exporter`), and [docs/nvirellia-im.md](docs/nvirellia-im.md).

Last updated at: `0b97675ae038e80d06f6f55b68f6ee2fcc951db9`.
