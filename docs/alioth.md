# Alioth

The Xiaomi POCO F3, Redmi K40, and Mi 11X are one handset with three names: a
Qualcomm SM8250 (Snapdragon 870) phone whose codename is `alioth`. This
repository runs headless NixOS on it. The device support is in
`modules/devices/alioth` — the kernel, the device tree patch, the kernel
configuration, the firmware, and the images the phone boots from — and
`modules/machines/alioth.nix` composes it into a machine.

The port does not use [mobile-nixos](https://github.com/NixOS/mobile-nixos):
that project is unmaintained, and it carries its own bootloader plumbing for
platforms this device does not share. What this device needs instead is a
kernel with its device tree, an Android boot image, and a root filesystem on a
partition the vendor bootloader will not touch on its own.

## Boot chain

The Qualcomm ABL bootloader is the only bootloader involved, and it boots
NixOS the way it boots an Android system:

1. ABL reads a boot image with header version 3 from the `boot_b` partition,
   which carries the kernel (`Image`) and the NixOS initramfs in its ramdisk
   section, and a second image from `vendor_boot_b`, which carries the device
   tree and the kernel command line. This is the layout the vendor images use.
   A header version 0 boot image with the device tree appended to the kernel,
   which postmarketOS's port documents, is rejected here without a word.
2. ABL appends its own `androidboot.*` arguments after the command line from
   the vendor boot image and passes `init=/init`; the device tree it fixes up
   with memory and initrd information is the one from the vendor boot image,
   and it applies the overlays from `dtbo` on top of it. Those overlays belong
   to the vendor kernel's device tree, so `dtbo_b` is erased and the port's
   device tree carries the `qcom,msm-id` and `qcom,board-id` ABL matches on.
3. The kernel runs the initramfs's `/init`, which is systemd from the
   initramfs — NixOS stage 1. That is also the program ABL's `init=` argument
   names, and stage 1 resolves it inside the new root to learn which closure
   to hand over to.
4. Stage 1 mounts `/dev/disk/by-label/alioth`, the ext4 filesystem written
   directly onto the `userdata` partition, and runs the activation inside it.
   The root filesystem's `/init` is a symlink to the closure's `init` program,
   because stage 1 takes the parent directory of what that symlink resolves to
   as the closure.
5. The image's filesystem is grown to the partition as it is mounted. Its first
   boot registers the store paths in `/nix-path-registration` and marks the A/B
   slot that booted as successful, without which ABL would fall back to the
   vendor system on slot A after a few boots.

The root filesystem is written whole by `just alioth-flash`, and the boot
partitions can be rewritten afterwards from the running system with
`just alioth-write-boot`. Everything is built by the machine that cross-compiles
the kernel, so a phone that fetches nothing keeps its progress verifiable from
one place.

## Flashing

The recipes are grouped as `alioth` in the `Justfile`:

| Recipe | What it does |
| --- | --- |
| `just alioth-flash` | Flashes a phone that has no system on it, from fastboot mode: erases `dtbo_b`, writes the root filesystem to `userdata` through fastbootd, flashes the boot, vendor boot and vbmeta images to slot B, and makes slot B active. Erases the phone's data. |
| `just alioth-write-boot` | Builds the boot and vendor boot images, keeps the ones the phone boots today on the workstation, and writes the new ones onto `boot_b` and `vendor_boot_b` over SSH. |

The two fastboot modes are not interchangeable here, and the order in
`alioth-flash` follows from that. The bootloader's fastboot refuses the chunked
write a multi-gigabyte root filesystem needs — the first sparse chunk fails
with `unknown command` — while fastbootd takes it. fastbootd belongs to the
vendor system's boot image, which is on slot A, so the root filesystem is
written with slot A active; slot B's boot image is this port's kernel, and
booting that instead leaves no fastbootd to write to. The bootloader is the
only place that can switch slots, so the slot is switched there afterwards,
and the slot B images are flashed then.

The boot image is unsigned, and the bootloader only starts an unverified image
on a slot whose verification is switched off: `aliothVbmeta` is an empty
vbmeta with both AVB flags cleared, written to slot B only. Slot A keeps the
vendor system's own vbmeta, and with it the vendor system stays bootable as
long as its `userdata` contents do not matter to it — this port's root
filesystem replaces them, so returning to Android means wiping or restoring
that partition. To boot the vendor system again, switch the slot back in the
bootloader with `fastboot set_active a`.

## Updating

The phone runs NixOS, so `just rdeploy alioth root@172.16.42.1` is the whole
update, kernel, device tree and command line included.

There is no bootloader to install: ABL only starts the Android boot image in
`boot_b` and the vendor boot image in `vendor_boot_b`, and looks at no boot
sectors, extlinux, or UEFI. Those partitions are block devices the running
system can write, so the two things a bootloader would otherwise decide are
decided elsewhere:

- Which userspace boots: the image's `/init` points at the system profile, so
  the next boot runs whatever `switch-to-configuration` last installed. Before
  that, a reboot silently went back to the image's system.
- Which kernel runs: `boot.loader.external.installHook` points the activation
  step that makes a configuration bootable at the boot partitions, so the same
  switch writes this build's boot image and vendor boot image onto `boot_b` and
  `vendor_boot_b`. A boot image that does not start leaves the phone needing a
  fastboot session; ABL's A/B retry counter falling back to slot A after a few
  failed boots is the recovery that does not. `just alioth-write-boot` performs
  the same write explicitly, from images the workstation keeps.

Three things about that path are worth knowing:

- `/nix/store` is a read-only bind mount on every NixOS by default. It comes
  from `boot.nixStoreMountOpts`, which stage 2's `prepare-root` applies to keep
  the store immutable, and the option's own description says it affects
  everything except the Nix daemon, which undoes the bind mount for an update.
  It does not stand in the way of a remote switch, and nothing here changes it.
- The image's `/init` points at the system profile rather than at the image's
  own closure, so the next boot runs whatever `switch-to-configuration` last
  installed. Before that, a reboot silently went back to the image's system.
- A flash replaces the whole root filesystem with the image, which resets the
  profile with it, and `switch-to-configuration` warns that it cannot make the
  configuration bootable because this device has no bootloader by design. The
  image is the baseline; updates accumulate on the phone's own filesystem in
  between.

## Cross-compilation

The machine is `aarch64-linux` and this repository has no aarch64 builder, so
`modules/devices/alioth` sets `nixpkgs.buildPlatform = "x86_64-linux"` against
`nixpkgs.hostPlatform = "aarch64-linux"` and the workstation builds the whole
system. Two consequences are worth knowing before touching that module:

- `pkgs.selfPackages` resolves to the aarch64-native package set inside this
  machine, which nothing here can build. Device-specific packages therefore
  live in the module that uses them instead of `modules/packages`, and nothing
  this machine imports may reach for `pkgs.selfPackages`.
- Every derivation that only assembles an image — the boot image, the vendor
  boot image, the firmware, the root filesystem — has to come from
  `pkgs.buildPackages`, because its tools run on the workstation. The reverse
  mistake is silent: a cross-compiled assembler builds fine and needed a phone
  to run.

## Access

The phone has one USB connection, and this port uses it for both a console and
a network link. The gadget is configured from the initramfs, so boot output is
visible before anything is loaded from the root filesystem:

- A serial console on `ttyGS0`, which prints kernel and initramfs messages and
  carries a login prompt. On the workstation it appears as
  `/dev/ttyACM0`; the node belongs to `root:dialout`, so reading it needs
  either group membership or `sudo chmod 666 /dev/ttyACM0`, and then
  `socat - /dev/ttyACM0,raw,echo=0` or `screen /dev/ttyACM0` gives the prompt.
  Writing to the port blocks while nothing on the phone reads it, so a client
  that opens it for writing without a reader should be treated as hanging.
- A framebuffer console on the display, which carries the same boot messages
  and its own login prompt. The device has no keyboard, so the display is
  output only.
- An ethernet link with the static address `172.16.42.1/24` on the phone. The
  host side needs an address in the same network; with NetworkManager,
  `nmcli con add type ethernet ifname <interface> con-name alioth ip4
  172.16.42.2/24` and bring it up.
- `sshd` on that link, where root is reachable with the maintainer's key or
  their password. The same password opens the serial console: the login is
  `root`.

## Network

The phone's own network is its WiFi; the USB link needs a host at the far end of
it, which is what made the phone a peripheral of whichever machine it was
plugged into. `networking.wireless` associates the QCA6390 with the SSID named
in the module and networkd takes an address over DHCP, so the phone is a node on
the local network with a route of its own. The USB link stays as a console and a
fallback, and its static address does not change.

What the radio needs:

- Its firmware is not what `hardware.enableRedistributableFirmware` would bring
  in. `alioth-radio-firmware` takes the QCA6390 blobs and the Bluetooth patch and
  NVM image out of `linux-firmware`, and `networking.wireless` adds
  `wireless-regdb` for `regulatory.db`. Without the first, `ath11k_pci` fails
  its firmware load with `-2` and gives up with `-110`; without the second,
  cfg80211 logs `failed to load regulatory.db` and downgrades what the access
  point advertised.
- Power save is off because the kernel is built without
  `CONFIG_CFG80211_DEFAULT_PS`: that symbol is what makes cfg80211 set
  `WIPHY_FLAG_PS_ON_BY_DEFAULT`, which turns power save on for every wireless
  interface as it is created. It is not reachable any other way — the `.network`
  format has no option for it, this kernel's modules take no parameter for it,
  and wpa_supplicant has no setting for it — and it is worth a factor of about
  four in latency on this link. Measured on the phone against the gateway, 200
  pings at five per second each way:

  | power save | round trip min/avg/max, mdev | loss |
  | --- | --- | --- |
  | on | 2.95 / 14.79 / 73.18 ms, 6.90 | 0% |
  | off | 2.75 / 3.97 / 15.99 ms, 1.91 | 0% |

  The same run against `1.1.1.1` shows the internet path's own latency
  dominating: 68.7 / 79.7 / 106.8 ms with power save against 68.8 / 71.0 /
  88.9 ms without it. Neither run lost a packet.

The passphrase is a sops secret: `modules/secrets/alioth-wifi.yaml` names this
host and the maintainer, the phone decrypts it with the SSH host key NixOS
generates into its root filesystem, and wpa_supplicant reads the rendered file
through its `ext:` password backend — with the file owned by the user the
wireless module's hardening runs the daemon as, or the daemon logs
`EXT PW FILE: ... Permission denied` and finds no key at all. The SSID is not a
secret, being in every beacon the access point sends, so it stays in the module
where the association can be read by anyone looking at the configuration.

The radio's board file carries no MAC address, so the firmware invents one at
every boot and the network hands the phone a new address with it. The
`10-wireless.link` file pins a locally-administered address to the interface
before anything brings it up, which is what keeps one lease and one address
across boots.

Two consequences of that arrangement are worth knowing:

- A full flash replaces the root filesystem and with it the SSH host key, so the
  phone's age recipient changes with it. The document keeps the maintainer as a
  recipient so it can be re-keyed, and the new key has to be enrolled before the
  phone reads the document again.
- The firewall runs on the nftables backend with reverse-path filtering off.
  This kernel carries no `pkttype` match for the iptables backend and no
  `nft_fib_inet` for the nftables one: with the filter on, the generated
  `fib saddr . mark . iif oif exists` rule fails with `Could not process rule:
  No such file or directory`, which fails the unit and every remote
  `nixos-rebuild switch` with it. The phone forwards nothing, so the filter
  protects little here; getting it back means `CONFIG_NFT_FIB_INET=m` in the
  kernel configuration and a new boot image.

## Storage

The storage is a UFS device behind `ufshcd-qcom`, and one thing about it is
worth knowing before trusting it with an uninterrupted write: the host
controller took the device down during the largest write of a session.

The error was `ufshcd_enable_vreg: vcc enable failed, err = -110` — the
controller failing to bring its `vcc` rail (PM8150L L17) up within its timeout
as it returned from runtime suspend. Nothing else faltered: WiFi, the USB link
and a shell all stayed up, but the device served no further IO, `/proc/pressure/io`
pinned at 99% and the load average at 30, and a reboot never completed because
systemd could not sync. A power cycle recovered it, and the boot after it was
clean.

The failure left nothing in the journal — no `ufshcd_enable_vreg` line at all,
because the storage stopped completing writes before the message reached the
disk, and the kernel's ring buffer died with the power cycle. What follows is
inference from the sequence, not a log.

Two candidates fit that one error:

- The host controller's runtime suspend, which is the only path that re-enables
  the rail while the phone is running and which `power/control = auto` left
  enabled.
- The supply. The port is an SDP, and the typec driver of a PMIC on the same
  SPMI bus as the ones that carry the rails (PM8150B, while the rails come from
  PM8150 and PM8150L) sustains a warning storm — `unexpected snk status 01`,
  about three times a second — through which a regulator transaction can time
  out as well.

The controller is kept out of runtime suspend, which removes the re-enable
instead of hoping it succeeds:

```nix
services.udev.extraRules = ''
  ACTION=="add", SUBSYSTEM=="platform", DRIVERS=="ufshcd-qcom", ATTR{power/control}="on"
'';
```

It costs nothing: the rails stay powered, which a phone on an adapter does not
notice. The rule is in effect from a cold boot — within seconds of the system
starting, `/sys/bus/platform/devices/1d84000.ufshc/power/control` reads `on`,
and a manual write cannot have put it there.

The charge window is not part of this: the measurements under
[Battery](#battery) show the adapter powers the phone whether or not the cell
charging, so holding the window neither gives nor takes supply.

A repeat would want the rail's own reporting, `/sys/kernel/debug/regulator/regulator_summary`
under load, and the same write with the phone on a Power Delivery source, which
is the only lever that changes what the port can give.

## Cluster

`k3s` runs a single-node server, and the tailnet is the way in: the API answers
to `alioth.dwelf-hoki.ts.net` and to `alioth`, the two names its certificate
carries, and a client takes `/etc/rancher/k3s/k3s.yaml` off the phone and points
that file's `server:` at the name. With one node there is no peer to agree with,
so nothing about the fabric needed deciding, and the address the node advertises
is whatever the default route gives it, which is the radio.

Two properties of this host's network cost real failures, both handled in the
modules now:

- **The phone's network does not reach Docker Hub.** A pull from it fails on
  both address families: the sandbox image never arrived, and every pod sat in
  `ContainerCreating` while the pull was reset. `services.k3s.images` supplies
  the images the node's own components need from the store the workstation
  fills — the airgap archive of the k3s package in use, 175 MB — so the cluster
  comes up without reaching a registry at all. Anything the cluster should run
  later wants the same treatment: a `dockerTools.pullImage` on the workstation
  and an entry in that list.
- **This host's firewall is a different nftables table from k3s's.** k3s writes
  the proxy and flannel rules into tables of its own, and flannel flips that
  table's FORWARD policy to ACCEPT, which says nothing about the table carrying
  this host's policy: pod traffic and the ClusterIP path were dropped there, so
  a service VIP timed out inside every pod. Trusting `cni0` and `flannel.1`
  admits pod traffic and leaves everything else as it was. Turning the firewall
  off instead would have exposed the API, the kubelet and the ingress to the
  local network and gained nothing: `tailscale0` is a trusted interface, so the
  tailnet is the boundary either way.

Verified on the running cluster: the node reports `Ready`; `kubectl` from
another host in the tailnet reaches the API by name; every packaged component
runs — `coredns`, `local-path-provisioner`, `metrics-server`, and `traefik`
with an `svclb-traefik` in front of it; `kubectl top nodes` reports the node's
usage; and traefik answers on the tailnet address. One consequence is worth
knowing: the kernel carries no `br_netfilter`, so
`net.bridge.bridge-nf-call-iptables` stays unset and same-node pod-to-pod
traffic never reaches iptables, which leaves a NetworkPolicy unenforced there.

## Verified

On the handset this was written against, a boot reaches `Multi-User System` in
about sixteen seconds: the serial console and the display both get a login
prompt, the ethernet link comes up at its static address and answers pings,
`sshd` accepts connections on it with the maintainer's key, and `qbootctl -m`
reports the slot as successfully booted. That was the whole of the verification
at the time: one flash of slot B and one boot watched, not a test that runs in
this repository.

A later pass over a deployed system, cold-booted on the kernel this repository
builds, added:

- `net.ipv4.tcp_congestion_control` reads `bbr`, `net.core.default_qdisc` reads
  `fq`, and `bbr` appears in `tcp_available_congestion_control`: the kernel
  configuration's congestion control and the `server` role's sysctls in effect
  together.
- systemd is armed on the hardware watchdog — `WatchdogDevice=/dev/watchdog0`,
  `RuntimeWatchdogUSec=20s`, and `qcom_wdt` reported during the boot.
- `systemctl --failed` lists nothing, and the controller's `power/control`
  reads `on` from the rule in [Storage](#storage).
- `tailscale status` reports `Running` and the node is reachable from another
  host in the tailnet as `alioth.dwelf-hoki.ts.net`. Enrolling it needed the
  tailnet's admin to approve the machine, which its auth key did not do.
- The activation that installs a configuration wrote `boot_b` and
  `vendor_boot_b` from the images the configuration carries, from the running
  system; the boot after it came up with `bbr` available, which the kernel it
  replaced did not have.

## Battery

This pack's design charge voltage is 4.46 V, and a phone that lives plugged in
would otherwise spend its life held there. `alioth-charge-window` keeps it
inside a 50-60% window: below the low mark it charges, and at the high mark it
switches the charge off, which leaves the adapter powering the phone while the
battery sits still.

What this charger actually does was measured on the handset, one variable at a
time, with the cell voltage as the reference:

| write | cell voltage | conclusion |
| --- | --- | --- |
| `charging_enabled = 1` | rising 100-200 mV/h | charging |
| `charging_enabled = 0` | step down, then nearly flat | charge stopped, phone still on the adapter |
| `current_max = 0` while charging | rising as before | no effect |
| `current_max = 900000` | clamped to the port's 500 mA | no effect |
| `port_type = sink` | no change | no effect |

So nothing writable removes this charger's input: a plugged-in phone cannot be
made to run off its battery. Bringing the pack down means unplugging it — with
a four-core load it fell at about 0.9 A and reached 4.00 V from full in two
hours, pausing the load above 43 C.

Two properties of the reporting make the window rough rather than exact:

- `capacity` sits clamped at 99% near full charge and only starts tracking
  lower down, where it read 44% at 3.83 V.
- `current_now` disagrees with the cell voltage often enough to be useless on
  its own: a battery reporting `Discharging` at +170 mA while its voltage climbs
  is charging. `voltage_now` is the signal that never contradicted itself —
  about 4.00 V at 60%, 4.46 V at full, and a few hundred millivolts lower under
  load.

Read the sysfs bracket as the value in effect: `power_role = source [sink]`
means the port is a sink, `data_role = host [device]` means it is a device, and
`usb_type = Unknown [SDP] DCP CDP` means the charger is an SDP.

The port itself is a USB-C one with Power Delivery behind it: it exposes a `pd0`
device at revision 3.0 and reports a `3.0A` power operation mode. A PD source is
therefore what provides more than the 500 mA a computer's SDP port gives — the
charging currents measured above are that SDP case.

Removing the battery and running the phone from the adapter is the only way to
take the pack out of the picture altogether; whether this handset boots without
one is untested.

## What is not here yet

There is no graphical session, and the modem and the sensors are not brought
up, nor does anything render on the GPU. The sensor DSP crashes while loading
its firmware and is restarted; the firmware for the ADSP, CDSP, SLPI, and Venus
blocks is installed, and the GPU's is too — `qcom/a650_sqe.fw` and
`qcom/a650_gmu.bin` come out of `linux-firmware` the way the radio blobs in
[Network](#network) do, and the zap shader is the phone's own
`qcom/sm8250/xiaomi/alioth/a650_zap.mbn` from the vendor extraction. `msm` loads
the GPU on the first open of its DRM device rather than at boot, and nothing on
the phone opens it by itself. Opened by hand on an installed system, both files
load and the GMU comes up — `[drm] Loaded GMU firmware v2.1.8` — which is as far
as this has been checked: no client has rendered with it yet.

Bluetooth has its firmware now — `qca/htbtfw20.tlv` and its NVM image come from
`linux-firmware` the way the WiFi blobs in [Network](#network) do — but nothing
runs a Bluetooth stack, so that radio is up and unused.

The kernel is a downstream fork with the device tree, panel, and touchscreen
drivers this port needs; upstream carries no device tree for the phone.

Two netfilter gaps are known and unclosed, each one `=m` line in
`modules/devices/alioth/kernel-config.aarch64` away from closing at the price of
a kernel build and a new boot image. The kernel carries no `br_netfilter`, so
`net.bridge.bridge-nf-call-iptables` cannot be set at all, and no `xt_CONNMARK`,
which leaves tailscale's connmark rules in its health warnings.
