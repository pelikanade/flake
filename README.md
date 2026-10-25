# flake

![Annotated desktop screenshot: the nvirellia.im status page with Gatus uptime checks and per-host probes beside a fastfetch report of parallax running NixOS 26.05, Hyprland and the NVIDIA stack](https://gist.githubusercontent.com/pelikanade/24093549b4e95f9ed5f140b83efc4df7/raw/cover.webp)

A personal NixOS configuration for five machines, written as one [dendritic](https://github.com/mightyiam/dendritic) `flake-parts` module tree. Each feature is a single aspect file that configures NixOS, Home Manager and flake inputs together, so adding a host or toggling a service touches one place instead of separate `nixos/`, `hm/` and `overlays/` trees.

- **One tree.** `import-tree` loads everything under `modules/`; `flake-file` generates the root `flake.nix` from module declarations.
- **Machines are import lists.** `asymmetry` and `parallax` (workstations), `neko-sphere` and `edge` (servers), and `installer` (live ISO), all on NixOS 26.05.
- **Secrets stay out of the store.** sops-nix decrypts with host SSH-derived age keys at activation, and each secret is declared beside its consumer.
- **Push to deploy.** A push to `main` builds `edge` and `neko-sphere` and activates them through `avalanche`; no host polls git.
- **Self-maintaining packages.** 14 custom packages ship as `pkgs.selfPackages`; a daily `02:00 Asia/Shanghai` run bumps, builds and commits each one that declares `passthru.update` metadata.
