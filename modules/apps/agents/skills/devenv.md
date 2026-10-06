---
name: devenv
description: Set up pinned development environments with devenv. Use when initializing a project, choosing packages or options, or updating dependency pins.
---

# devenv

## Set up a project

In the project root, run `devenv init` if it does not already have a `devenv.nix`. Define tools in `devenv.nix` using `packages`, language options, and any needed services. Preserve existing project configuration when adding devenv.

For automatic activation with direnv, ensure its shell hook is installed, then create a project `.envrc` containing:

```sh
eval "$(devenv direnvrc)"
use devenv
```

`devenv init` does not create `.envrc` by default. After reviewing the file, run `direnv allow` in the project. On devenv versions that support it, `devenv init --include-envrc` can create the file during initialization.

## Find the right dependency

Run `devenv search <term>` in the project to search packages and configuration options against its pinned inputs. For an assistant with a configured MCP client, `devenv mcp` starts a stdio server exposing `search_packages` and `search_options`. Use these to check exact option names and available packages before editing `devenv.nix`; see https://devenv.sh/mcp/.

## Keep the environment pinned

`devenv.yaml` declares external inputs and `devenv.lock` records their resolved revisions. Commit the project configuration and lock file together so other developers get the same input revisions. Use `devenv update <input-name>` for a targeted refresh; inspect the lock diff before keeping it. If a specific package version is required independently of the main nixpkgs revision, consult https://devenv.sh/packages/ for version pinning with `nixpkgs-multiverse`.

Verify the environment with `devenv shell` or `devenv shell -- <command>` and run any relevant project checks inside it.
