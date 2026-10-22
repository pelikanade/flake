# Repository guidance

Optimize for safe operation of personal NixOS infrastructure. Avoid turning this repository into a general-purpose framework.

A **host** is a physical or virtual machine; a **machine** is the repository composition assigned to it; a **NixOS configuration** is its operational output. An **aspect** is reusable policy contributing to NixOS, Home Manager, or both. A **role** composes aspects for a machine purpose. Use these terms consistently.

## Scope and safety

- Preserve unrelated work. Commit each completed logical change at its natural atomic point instead of waiting for a request; do not fold unrelated edits or unfinished work into one commit. Use a concise, lowercase, imperative subject: `<scope>: <description>`.
- Inspect a Justfile recipe before invoking it. Bare `just` only lists recipes. Remote, privileged, machine-mutating, disk, deployment, garbage-collection, and key-rewrite operations require explicit authorization, including `deploy`, `boot`, `dryrun`, `install`, `rdeploy`, `collect-machine-info`, `generate-luks-password`, `gc`, `rewrap-secret`, and `updatekeys`.
- Treat `modules/secrets/`, `.sops.yaml`, password hashes, key material, and personal identity constants as sensitive. Do not decrypt, print, rotate, or edit secret payloads unless the task explicitly requires it. Never create plaintext secret files; edit encrypted documents with `sops`.
- Keep changes in the existing feature categories. Before adding a new category under `modules/`, propose its boundary and obtain approval.

## Design rules

- Follow the [dendritic pattern](https://raw.githubusercontent.com/mightyiam/dendritic/refs/heads/master/README.md). Read its upstream documentation before changing architecture, introducing a module pattern, changing how values cross module boundaries, or adding module-level `enable` options. Ordinary value edits do not need that lookup.
- Organize modules by cohesive feature, with descriptive names. Keep a feature's NixOS and Home Manager contributions together. Export reusable modules through `flake.modules.nixos`, `flake.modules.homeManager`, or `flake.modules.generic`, and compose policy through `flake.modules.aspects`.
- Importing a project module should normally enable its feature. Add a project-level `enable` option only when the module genuinely needs to be imported while inactive. Let `import-tree` discover top-level modules; do not duplicate its work with manual import lists.
- Never introduce `specialArgs` or `extraSpecialArgs`. Declare shared values as top-level options and consume them through module configuration or `inputs.self`.
- Define machines through `machines.<name>`. Every machine must import `base`; preserve the `nixos-configurations-import-base` check. Limit machine definitions to identity, hardware facts, disk selection, and role/aspect composition; reserve `nixosModule` and `homeModule` for manual interventions. Keep host-specific details out of reusable aspects.
- Put packages in `modules/packages/`, follow the [nixpkgs packaging guidelines](https://github.com/NixOS/nixpkgs/blob/master/pkgs/README.md), and use [nix-init](https://github.com/nix-community/nix-init) for an initial expression when applicable. Adapt it to local conventions. Consume these packages through `pkgs.selfPackages.<package>` in NixOS and Home Manager modules.
- Use the `nixos` MCP as the primary reference for NixOS and Home Manager options, packages, and documentation. Consult upstream documentation when the MCP does not cover the capability or repository guidance requires it.

## Secrets

- Provision every consumer's secrets through NixOS activation, including Home Manager consumers. Keep decrypted values out of Nix evaluation and the store; encrypted documents may be committed and stored there.
- Declare secrets beside the consuming feature. Keep shared sops setup limited to integration and key discovery. Consumers must read runtime paths, with `owner`, `group`, and `mode` no more permissive than necessary. Publish Home Manager consumers' paths through `constants.resources.userSecretPaths`; do not give them a separate decryption key or Home Manager sops module.
- Give each encrypted document its own disjoint creation rule, without catch-alls, naming only hosts whose activation reads it and the maintainer when it must remain editable. A host recipient grants access to the entire document. The first matching rule is the only one sops applies; an unmatched document needs a rule before encryption.
- Recipient changes must also update the affected ciphertext with `sops updatekeys`, with explicit authorization for that rewrite. A document without a maintainer recipient needs a host that already decrypts it to re-key it; recreating it from plaintext is a separate, explicitly authorized operation.

## Dependencies and compatibility

- Never edit generated `flake.nix` directly. Declare feature-owned inputs beside their feature with `flake-file.inputs`; keep shared foundational inputs in `modules/default.nix`. Regenerate with `nix run .#write-flake` when declarations change.
- Keep dependency updates targeted and include the resulting `flake.lock` change. Do not run a blanket `nix flake update` unless explicitly requested.
- Keep NixOS and Home Manager release lines aligned. Moving either independently requires an explicitly requested migration. Change `system.stateVersion` or `home.stateVersion` only for an explicitly requested, reviewed compatibility migration.

## Environment and validation

- Use the development shell (`nix develop`) for repository tools. If required tools are missing, ask the user to activate it first.
- Stage every new file with `git add` so Nix sees it. If Nix reports a missing file that exists locally, check that it is staged before retrying.
- Format changed Nix files with `nixfmt`. Keep formatting and lint rules in `nixfmt` and `statix`; encode objective repository-wide invariants as flake checks when practical.
- Choose checks proportionate to the change. Documentation-only work needs document and skill validation. Report the checks actually performed, affected machines where relevant, and outstanding manual or hardware verification; do not treat past test records as new results.

Last updated at: `aecc22771234f637947b5fc330583404413abe20`.
