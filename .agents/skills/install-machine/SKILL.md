---
name: install-machine
description: Install a machine from this flake onto a target booted from this flake's installer ISO using nixos-anywhere. Use after init-machine has committed the machine definition, its hardware facts, and any host age recipient; not for ordinary deploys of a machine that is already running.
disable-model-invocation: true
---

# Install a machine from the installer ISO

This erases the target's disks. Confirm the machine name, IP address, disk device, and layout before running nixos-anywhere.

## Prerequisites

The `init-machine` skill prepares a new target: SSH access to the running ISO, the machine definition in `modules/machines/<machine>.nix` with the target's hardware facts, and the host age recipient when the machine consumes sops secrets. Confirm all of it is committed before starting. Preparation from an earlier boot of the target is stale; redo it from the current boot instead of installing against it.

- Ask the user for the target's IP address and whether the target is a workstation or a server. Use `root` as the SSH user unless they say otherwise.
- Take the layout from the machine's `diskoConfig`, and confirm the name is exported with `nix eval .#diskoConfigurations --apply builtins.attrNames`. Workstations and servers are expected to differ — `xfs-workstation` has an ESP, 32G swap, and a LUKS root, `ext4-server-efi` has an ESP and a plain ext4 root — but do not assume that from the machine's role alone: layouts move between machines and a server layout may not be exported yet.
- When moving a machine from `workstation-legacy` to `xfs-workstation`, delete its machine-local `swapDevices` swapfile and any `systemd.sleep.settings.Sleep.AllowHibernation = false` override. `xfs-workstation` already supplies a 32G `resumeDevice` swap partition; keeping both duplicates swap and disables the hibernation the new layout enables.

## Environment facts

- The target boots this repository's installer ISO (`just build-installer-iso`). It ships `sbctl` and an SSH daemon with `PermitRootLogin = yes` and the maintainer's public key in root's `authorizedKeys`, so `ssh root@<ip>` works without a password.
- The target never carries a checkout of this repository, and it does not need one. Every repo command runs on the workstation; only target-local tools such as `sbctl` run on the target.
- Installs are normally driven from one of the workstations, currently asymmetry and parallax. Run `hostname` first: the machine you are on decides whether this checkout, the enrolled host identities, and the LUKS and Secure Boot material are at hand, and only a machine that already reads a secret document can re-key one that has no maintainer recipient.
- `nixos-anywhere` skips its kexec phase against a target whose `/etc/os-release` reports `VARIANT_ID=installer`, which this ISO does. Then the target's `/run` survives and a passphrase written there before the run is still readable when disko formats. Against any other target kexec replaces the live environment and `/run` with it, so the passphrase must arrive through `--disk-encryption-keys <remote-path> <local-source>`, which is uploaded after kexec and before disko.
- With `--disko-mode disko`, disko formats `disko.devices.disk.main.device` from the machine's `hardware` block, so that path must already point at the target disk.
- The flake is evaluated on the workstation, so new machine and layout files must be staged with `git add` before Nix can see them.
- The installed machine has no repository checkout and is not expected to grow one. Later changes are pushed from a workstation with `just rdeploy <machine> <target>`, or `just install` for another full installation.

## Workflow

1. Confirm the machine name and the target disk, then ask the user to confirm both before anything destructive runs.
   - Enumerate the exported configurations; never infer a machine from a similar-sounding name or from its hardware:
     ```bash
     nix eval .#nixosConfigurations --apply builtins.attrNames
     ```
   - Read the target's physical disks and the configured stable path:
     ```bash
     ssh -o StrictHostKeyChecking=accept-new root@<ip> true
     ssh root@<ip> lsblk -dno NAME,MODEL,SERIAL,SIZE
     ssh root@<ip> ls -l /dev/disk/by-id/ | grep nvme
     nix eval --raw .#nixosConfigurations.<machine>.config.disko.devices.disk.main.device
     ssh root@<ip> test -e "$(nix eval --raw .#nixosConfigurations.<machine>.config.disko.devices.disk.main.device)"
     ```
   - Stop if the configured path is absent: that is a disk replacement or the wrong machine. Update `hardware.disko.devices.disk.main.device` to the target's stable by-id path, commit it, and re-run this check. Never infer a disk from capacity alone; report the model, serial, and size together.
   - If the machine is not defined, not staged, or still carries placeholder hardware facts, run `init-machine` first.
   - State the machine, IP address, disk device, model/serial/size, and layout, and get the user's confirmation immediately before step 5.
2. If the layout has a LUKS root, get a passphrase file on the workstation and never let an unread passphrase reach disko:
   - Interactive: `just prompt-luks-password <machine>` in the development shell, which provides the graphical pinentry. It opens a dialog, writes a fresh user-owned 0600 file, and prints its path.
   - New machine: `just generate-luks-password <machine>` creates a random passphrase and stores `NixOS <machine> LUKS root` in the `NixOS` vault. Check `op account list` first: with no signed-in account the recipe cannot store anything, so use `prompt-luks-password` and store the result once the CLI is signed in.
   - Store a passphrase that already exists in a file without exposing it in argv:
     ```bash
     op item template get Password --format json \
       | jq --rawfile p "$dest" '.title = "NixOS <machine> LUKS root" | .fields = ((.fields // []) | map(if .id == "password" then .value = ($p | rtrimstr("\n")) else . end))' \
       | op item create --vault NixOS -
     ```
     Verify it without printing the secret by comparing `sha256sum <(tr -d '\n' < "$dest")` with the revealed vault value, then delete the file after the installation. If the item already exists, compare before replacing it; overwriting is only safe when the disk is being wiped and the old passphrase can no longer matter.
   - In either case, read the passphrase from the vault into a fresh 0600 file and prove the read worked before installing, because a process substitution like `<(op read …)` hides an expired session or a missing item, and disko destroys filesystems before it starts formatting:
     ```
     umask 077
     dest=$(mktemp --tmpdir="${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}" "nixos-<machine>-luks-password.XXXXXXXX")
     op read 'op://NixOS/NixOS <machine> LUKS root/password' > "$dest"
     test -s "$dest"
     ```
     A machine whose passphrase only exists in someone's head skips the vault step; `prompt-luks-password` already wrote the file. Pass `"$dest"` as the third argument to `install`, and delete it when the installation is done.
3. Verify the host identity and sops enrollment before disko runs, because the enrolled recipients follow the host keys the installation will carry.
   - `--copy-host-keys` carries the live ISO's keys into the installation. Derive the recipient and list what the machine decrypts:
     ```bash
     ssh root@<ip> cat /etc/ssh/ssh_host_ed25519_key.pub | ssh-to-age
     nix eval .#nixosConfigurations.<machine>.config.sops.secrets --apply builtins.attrNames
     grep -n '<machine>' .sops.yaml
     ```
   - An empty `sops.secrets` list means no enrollment is needed. Otherwise the recipient from the current boot must match the machine's anchor in `.sops.yaml`; a target reboot regenerates the keys and invalidates the enrollment.
   - To keep a machine's existing identity, save its `ssh_host_*_key` and `.pub` files before wiping and pass them through `--extra-files`: nixos-anywhere copies extra files first and does not overwrite an existing host key with the ISO's, so the preserved key wins and the enrolled recipient must be the one derived from it. `just install` cannot forward `--extra-files`, so a preserved identity means the direct nixos-anywhere invocation.
   - If the recipient and enrollment disagree and the old keys are gone (disk replaced or already wiped), stop and ask. The fix rewrites ciphertext: update the host's anchor in `.sops.yaml`, then run `sops updatekeys` on every document the machine reads, most restricted first. That rewrite needs explicit authorization and a key that already decrypts each document — the maintainer key at `~/.config/sops/age/keys.txt`, or a host that reads it. Re-keying the repository does not change the closure already built for this install; plan a `just rdeploy` after the machine boots to deliver the new documents.
   - Stop when the identity the installation will carry and the enrolled recipient still disagree.
4. Machines that import the `secure-boot` aspect (currently asymmetry) need their `sbctl` keys before the bootloader is installed, because lanzaboote signs the files it installs. The ISO ships `sbctl`, and enrollment writes firmware variables, so run it on the target and then carry the bundle to the workstation:
   - On the target, with firmware in setup mode: `sbctl create-keys`, then `sbctl enroll-keys -m`. Never run this on the workstation; it would enroll keys into the wrong machine's firmware.
   - Copy the bundle into the shape `--extra-files` expects, so the local directory mirrors the installation root: `mkdir -p <local-dir>/var/lib && ssh root@<ip> tar -C /var/lib -cf - sbctl | tar -C <local-dir>/var/lib -xf -`.
   - Install with a nixos-anywhere invocation that carries it: `--extra-files <local-dir>`. `just install` cannot forward that option.
5. Install the machine. For a server layout: `just install <machine> root@<ip>`. For a LUKS layout: `just install <machine> root@<ip> <passphrase-file>`, where the file came from step 2; the recipe uploads it to `/run/luks-password` in the installer environment before disko runs. Never put the passphrase itself in the command line. Redirect the run's output to a log file, and watch it in a Herdr pane when the session is Herdr-managed.
6. Verify from the installed machine, which has no checkout: it boots, and with a LUKS root it prompts for the passphrase. A `xfs-workstation` machine also reports the 32G partition in `swapon --show` and carries `resume=/dev/disk/by-partlabel/disk-main-swap` in `/proc/cmdline`; a plain ext4 server layout has neither.

## Report progress and watch the network

An install spends most of its time uploading the system closure; `copying path` lines alone do not show how far it has to go. Report percentages and throughput at each check, especially during the copy phase.

Measure against the closure built on the workstation:

```bash
top=$(nix build --print-out-paths --no-link .#nixosConfigurations.<machine>.config.system.build.toplevel)
nix path-info -S "$top"          # total NAR bytes
nix path-info -r "$top" | wc -l  # total paths
```

On the target, count what is registered under the installation root:

```bash
ssh root@<ip> '
  find /mnt/nix/store -mindepth 1 -maxdepth 1 -name "????????????????????????????????-*" | wc -l
  du -scb /mnt/nix/store/????????????????????????????????-* 2>/dev/null | tail -1
'
```

Report both byte and path percentages; bytes are the meaningful progress and paths run ahead because large paths land last. Identify the phase:

- `### Uploading the system closure ###` — copy phase, the bulk of the time.
- `copying N paths...` — the remaining paths the target could not substitute and that are being transferred from the workstation.
- `nixos-install` in `ps` — install phase; the copy is complete.
- Partitions mounted under `/mnt/boot` and `/mnt` — disko is done.

Sample throughput instead of guessing, and warn on a sustained value:

```bash
ssh root@<ip> '
  r0=$(cat /sys/class/net/<iface>/statistics/rx_bytes); sleep 5
  r1=$(cat /sys/class/net/<iface>/statistics/rx_bytes)
  awk -v r=$((r1-r0)) "BEGIN{printf \"%.2f MB/s\\n\", r/5242880}"
'
```

Treat sustained <10 MB/s as a warning; >30 MB/s is typical on a healthy CN mirror. List the sockets and map them to caches:

```bash
ssh root@<ip> "ss -tnpi state established '( dport = :443 )'"
getent ahosts cache.nixos.org mirrors4.tuna.tsinghua.edu.cn ipv4.mirrors.ustc.edu.cn
```

The target's `nix-store --serve` decides which cache serves a path. It uses the installer's `/etc/nix/nix.conf` plus the `extra-substituters` nixos-anywhere appends from the machine's evaluated `nix.settings.substituters`; the workstation's `--option` list does not fully apply to it. A stale ISO can keep using `cache.nixos.org` even when the command line names CN mirrors. A `does not exist in binary cache` warning means that mirror lacks the NAR and nix falls back, not that the path failed. Do not restart a running upload to change substituters: finish it, then fix the machine's `nix.settings.substituters` or rebuild the ISO for the next install. `substituter-cn` merges with the default `cache.nixos.org`; use `lib.mkForce` if it must be excluded.

## Watch the log in a Herdr pane

An install runs for tens of minutes, so when this session is Herdr-managed (`HERDR_ENV=1`), give the log its own pane and let the install keep running in the original one. Follow the `herdr` skill for the current CLI; the shape is:

```bash
herdr pane split --current --direction right --cwd "$PWD" --no-focus
herdr pane run <pane-id> "tail -f /tmp/install-<machine>.log"
```

Write the install's output to that same log file, read the pane ID from the split response (`.result.pane.pane_id`), and split `down` instead of `right` when the pane is tall or narrow rather than wide. Keep `--no-focus` so the user's focus stays where it was, and close the pane once the install finishes. Without a Herdr session, the log file alone is enough.

## Stopping conditions

- State the machine, IP address, disk device, and layout, and get confirmation, immediately before nixos-anywhere runs.
- Do not re-run an install that failed at or after the disko phase. The disk is already destroyed; inspect what exists and ask before acting.
- Treat a target that rebooted since `init-machine` as unprepared. Its hardware facts may still hold, but its host keys and enrolled recipient do not.
