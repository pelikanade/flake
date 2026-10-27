# flake

![Annotated desktop screenshot: the nvirellia.im status page with Gatus uptime checks and per-host probes beside a fastfetch report of parallax running NixOS 26.05, Hyprland and the NVIDIA stack](https://gist.githubusercontent.com/pelikanade/24093549b4e95f9ed5f140b83efc4df7/raw/cover.webp)

A personal NixOS configuration written as one [dendritic](https://github.com/mightyiam/dendritic) `flake-parts` module tree. 

## Highlights 

- [`avalanche`](https://github.com/pelikanade/flake/actions/workflows/deploy.yml): push `main` to automatically deploy all managed machines.
- [`update-packages`](https://github.com/pelikanade/flake/actions/workflows/update-packages.yml): a daily run that bumps, builds and commits packages maintained in this repository. now with agentic repair.
- [`freezer`](modules/packages/freezer): a single-binary service that spins an s3-backed Nix binary cache and auto-builder.
