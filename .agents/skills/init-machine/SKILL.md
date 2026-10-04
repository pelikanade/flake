---
name: init-machine
description: Prepare a new machine for installation from this flake's installer ISO by connecting to the target, enrolling its host age recipient when it consumes sops secrets, collecting hardware facts, and committing the result. Use as the step before install-machine, not to run the installation.
---

# Initialize a machine from the installer ISO

Bring the repository to the state the install step expects: a committed machine
definition with the target's hardware facts and, when the machine consumes sops
secrets, the target's host age recipient enrolled in `.sops.yaml`. Nothing here
touches the target's disks; the destructive work belongs to that install step.

## 1. Connect to the target

The target boots this repository's installer ISO (`just build-installer-iso`).
Bring its network up with `nmtui`, then from the workstation:

```bash
ssh root@<ip> true
```

The ISO trusts the maintainer's public key for root, so this needs no password.
Use `root` unless the user names another SSH user; stop and report if the key is
refused rather than improvising credentials.

The ISO generates its SSH host keys at boot, so they hold only for the current
boot of this target. The install step runs with `--copy-host-keys`, which carries
those same keys into the installation, so a recipient collected now stays valid
only while that boot continues. If the target reboots before it is installed,
collect again.

## 2. Define or confirm the machine

Work in `modules/machines/<machine>.nix`. Define `machines.<machine>` as an
`aspects`-class submodule with its `system`, importing `base` and the other roles
and aspects it needs from `inputs.self.modules.aspects`. Set `diskoConfig` to the
chosen layout and keep detected facts in `hardware`; reserve `nixosModule` and
`homeModule` for manual interventions. The machine definition generates
`flake.nixosConfigurations.<machine>`.

Native NixOS and Home Manager modules with the same feature name are paired
automatically into an aspect. Declare `flake.modules.aspects.<feature>` directly
when adding dependencies or other contributions. Keep host-specific identity,
hardware facts, and disk selection in the machine file.

Read the target disk on the target, and prefer its stable by-id path:

```bash
ssh root@<ip> ls -l /dev/disk/by-id/
```

Point the layout at it with `hardware.disko.devices.disk.main.device`. A layout
that already carries its own device path, such as the `ext4-server-efi`
placeholder, must be reconciled with the target disk before installing.

Stage a new machine file with `git add` so Nix can see it, then confirm it
evaluates:

```bash
nix eval --raw .#nixosConfigurations.<machine>.config.system.build.toplevel.drvPath
```

## 3. Collect the target's facts

```bash
just collect-machine-info root@<ip>
```

One read-only pass prints both inputs for the steps below: the age recipient
derived from the target's SSH host key, and the hardware configuration, which
`nixos-generate-config` reports with `--no-filesystems` because disko owns
partitioning, filesystems, and swap. The hardware half shells out to the target,
so the target's network must already be up.

## 4. Enroll the host age recipient when the machine consumes secrets

The `base` role imports the `secrets` aspect for every machine, so sops-nix
being present says nothing about whether a recipient is needed. Ask what the
machine actually consumes:

```bash
nix eval .#nixosConfigurations.<machine>.config.sops.secrets --apply builtins.attrNames
```

An empty list means this machine has nothing to decrypt and can be installed
without enrolling anything. The list covers every secret NixOS activation
decrypts, including the ones a Home Manager program reads from
`constants.resources.userSecretPaths`, so those need the host recipient too.
Otherwise:

1. Require exactly one plausible `age1...` recipient in the collected output.
2. In `.sops.yaml`, add or update a key anchor named for the hostname, then add
   that anchor to the effective creation rule of every document this machine
   reads: the first rule whose `path_regex` matches that document, which is the
   only rule sops applies. A host recipient decrypts the whole document, so
   never enroll the host in a rule that also matches documents it never reads.
   Every document needs a rule of its own: there is no catch-all, so a document
   that matches no rule cannot be encrypted until one names exactly who decrypts
   it. An anchor alone enrolls nothing.
3. Stop and ask before replacing an existing anchor whose recipient differs for
   the same hostname.
4. Update the encrypted documents, most restricted first. A document that no
   longer names the maintainer cannot be refreshed from here, because rewriting
   it needs a key that already decrypts it: do that work on a host that reads
   it, with `just rewrap-secret <document> --add-age <recipient>` (add
   `--rm-age <recipient>` when retiring a key). The recipe uses that host's SSH
   key and asks for sudo only to read it, and it wants this checkout, so prefer
   a workstation you work on. Run `hostname` to see where you are: when this
   machine already reads the document, do the work here; otherwise carry the
   document and the tooling to a host that does and bring the rewritten file
   back. Then refresh the remaining
   documents with `just updatekeys` and inspect the diff: stop if plaintext
   appears or files outside the expected encrypted documents changed. Stop when
   no host that already decrypts the document is reachable, because the
   maintainer cannot re-key it alone.

Never decrypt, print, or edit a secret payload for the steps above; recreating a
document from its plaintext is a separate, explicitly authorized operation.

## 5. Fold in the hardware facts

Fold the collected configuration into the machine's `hardware` block, keeping the
shape the other machines use: the `not-detected.nix` import, kernel module lists,
and CPU microcode and firmware flags. Drop the generated `nixpkgs.hostPlatform`
line: the machine's own `system` selects the platform. Set
`networking.hostName` and `domain` to the machine's own identity, since the
generated facts carry the installer environment's hostname.

## 6. Verify and commit

- Format the changed Nix files with `nixfmt`, and confirm every new file is
  staged.
- Confirm the layout resolves as intended:
  `nix eval .#nixosConfigurations.<machine>.config.disko.devices.disk.main.device`
  must name the target disk.
- Commit in the repository's history format, a concise lowercase imperative
  subject such as `machines: add <machine>`. Keep the recipient enrollment in
  its own focused commit with `.sops.yaml` and the documents `just updatekeys`
  rewrote.
- Preserve unrelated work; never fold unrelated changes into these commits and
  never create an empty commit.
- Report the machine name, target, layout, disk device, and recipient status,
  then hand off to the install step.

## Stopping conditions

- Stop if the scan returns anything other than one plausible recipient, if an
  existing hostname anchor disagrees with the live target, or if the hostname is
  not exported as a machine in the flake.
- Stop if `just updatekeys` shows plaintext or rewrites files outside the
  encrypted secret documents.
- Re-collect rather than reuse a recipient or hardware facts from an earlier
  boot of the target.
