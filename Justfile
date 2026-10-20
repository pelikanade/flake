# Repository operations. Bare `just` lists every recipe.

default:
    @just --list

# Build this machine's system without activating it.
[group('machine')]
build:
    nh os build .

# Show what switching to the current build would change.
[group('machine')]
dryrun:
    nixos-rebuild dry-run --flake . --sudo -v -L

# Switch this machine to a freshly built system.
[group('machine')]
deploy:
    nh os switch .

# Make this machine's newest build the boot default.
[group('machine')]
boot:
    nh os boot .

# Push a freshly built system to a running machine over SSH.
[group('machine')]
rdeploy hostname target:
    nixos-rebuild --flake .#{{ hostname }} --target-host {{ target }} switch -L

# Run a command as root through polkit.
[group('machine')]
elevate command:
    pkexec /run/current-system/sw/bin/bash -c {{ quote(command) }}

# A target that is not a NixOS installer is kexec'd, which discards /run, so an
# encrypted layout needs its passphrase file passed as the third argument.
#
# Install a machine over SSH with nixos-anywhere.
[group('provisioning')]
install hostname target luks-key="":
    nixos-anywhere --flake .#{{ hostname }} \
      --target-host {{ target }} \
      --copy-host-keys \
      --disko-mode disko \
      {{ if luks-key == "" { "" } else { "--disk-encryption-keys /run/luks-password " + quote(luks-key) } }}

[group('provisioning')]
[doc("Print the age recipient and hardware facts needed to prepare a machine.")]
collect-machine-info target:
    #!/usr/bin/env bash
    set -euo pipefail

    echo "== age recipient =="
    ssh {{ target }} cat /etc/ssh/ssh_host_ed25519_key.pub | ssh-to-age

    echo
    echo "== hardware configuration =="
    ssh {{ target }} "nix shell nixpkgs#nixos-install-tools -c nixos-generate-config --show-hardware-config --no-filesystems"

# Build the installer ISO that boots new hardware.
[group('provisioning')]
build-installer-iso:
    nix build .#nixosConfigurations.installer.config.system.build.isoImage -L

[group('secrets')]
[doc("Create a machine's LUKS passphrase and store it in the vault.")]
generate-luks-password machine vault="NixOS":
    #!/usr/bin/env bash
    set -euo pipefail

    item_title="NixOS {{ machine }} LUKS root"
    dest=$(just _luks-password-file {{ quote(machine) }})

    if ! op item create \
      --category Password \
      --title "$item_title" \
      --vault {{ quote(vault) }} \
      --generate-password='letters,digits,symbols,64' \
      --format json \
      | op item get - --fields label=password --reveal \
      > "$dest"; then
      rm -f "$dest"
      exit 1
    fi

    if [[ ! -s $dest ]]; then
      rm -f "$dest"
      echo "1Password returned no passphrase for '$item_title'" >&2
      exit 1
    fi

    echo "$dest"

[group('secrets')]
[doc("Ask for a machine's LUKS passphrase in a graphical pinentry dialog.")]
prompt-luks-password machine:
    #!/usr/bin/env bash
    set -euo pipefail

    pinentry=${PINENTRY:-}
    if [[ -z $pinentry ]]; then
      for candidate in pinentry-gnome3 pinentry-gtk-3 pinentry-qt6 pinentry-qt5 pinentry-qt; do
        if command -v "$candidate" >/dev/null; then
          pinentry=$(command -v "$candidate")
          break
        fi
      done
    fi
    if [[ -z $pinentry ]]; then
      echo "no graphical pinentry found; run this from the development shell or set PINENTRY" >&2
      exit 1
    fi

    dest=$(just _luks-password-file {{ quote(machine) }})

    if ! reply=$(
      printf 'SETTITLE NixOS %s\nSETDESC LUKS passphrase for %s\nSETPROMPT Passphrase:\nSETREPEAT Repeat passphrase:\nGETPIN\nBYE\n' \
        {{ quote(machine) }} {{ quote(machine) }} | "$pinentry"
    ); then
      rm -f "$dest"
      exit 1
    fi

    passphrase=$(printf '%s\n' "$reply" | sed -n 's/^D //p' | sed -e 's/%0A/\n/g' -e 's/%25/%/g')
    if [[ -z $passphrase ]]; then
      rm -f "$dest"
      echo "pinentry returned no passphrase" >&2
      exit 1
    fi

    printf '%s\n' "$passphrase" > "$dest"
    echo "$dest"

# Re-encrypt every secret document for the recipients in `.sops.yaml`.
[group('secrets')]
updatekeys:
    find modules/secrets -maxdepth 1 -type f \( -name '*.yaml' -o -name '*.json' -o -name '*.env' -o -name '*.ini' \) -print0 \
      | xargs -0 -r -n1 sops updatekeys -y

[group('secrets')]
[doc("Re-key a secret document from a machine that already decrypts it.")]
[positional-arguments]
rewrap-secret file +args:
    #!/usr/bin/env bash
    set -euo pipefail

    file=$1
    shift

    case $file in
      */*) ;;
      *) file="modules/secrets/$file" ;;
    esac

    if [[ ! -f $file ]]; then
      echo "no such secret document: $file" >&2
      exit 1
    fi
    if [[ $# -eq 0 ]]; then
      echo "give sops a change to make: --add-age age1... or --rm-age age1..." >&2
      exit 1
    fi

    host_key=/etc/ssh/ssh_host_ed25519_key
    recipient=$(ssh-to-age < "$host_key.pub")
    if ! grep -q "$recipient" "$file"; then
      echo "$file does not list this host ($recipient) as a recipient," >&2
      echo "so this machine cannot unwrap its data key. Use a host that can." >&2
      exit 1
    fi

    identity=$(sudo cat "$host_key" | ssh-to-age -private-key)
    if [[ -z $identity ]]; then
      echo "could not derive an age identity from $host_key" >&2
      exit 1
    fi
    export SOPS_AGE_KEY="$identity"

    backup=$(mktemp --tmpdir="${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}" "$(basename "$file").XXXXXXXX.bak")
    cp -a "$file" "$backup"
    tmp=$(mktemp --tmpdir="$(dirname "$file")" ".$(basename "$file").XXXXXXXX")
    trap 'rm -f "$tmp"' EXIT
    sops -r "$@" --output "$tmp" "$file"
    mv "$tmp" "$file"

    echo "previous ciphertext kept at $backup"
    echo "recipients now:"
    grep -oE 'age1[0-9a-z]+' "$file" | sort -u

# Update flake inputs and locally packaged tools; pass --build or --commit.
[group('repository')]
update-packages *args:
    ./scripts/update-packages.sh {{ args }}

# Remove system generations older than a week and the store paths they kept.
[group('repository')]
gc:
    sudo nix profile wipe-history --profile /nix/var/nix/profiles/system --older-than 7d
    sudo nix store gc --debug

# Print the path of a fresh 0600 file for a LUKS passphrase.
_luks-password-file machine:
    @mktemp --tmpdir="${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}" "nixos-{{ machine }}-luks-password.XXXXXXXX"
