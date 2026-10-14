# sing-box

The proxy platform the tailnet hosts run; a host that should join the tailnet
without it needs its own `tailscaled` module, which does not exist yet. The
configuration is declared in
[modules/services/sing-box.nix](../modules/services/sing-box.nix) as
`services.sing-box.settings`; only values that must stay encrypted live in
[modules/secrets/sing-box.yaml](../modules/secrets/sing-box.yaml).

## How the configuration is assembled

The nixpkgs module renders the settings to JSON, and its pre-start hook replaces
each `{ _secret = "<path>"; }` with the contents of that file, writing the result
to `/run/sing-box/config.json`. The hook runs as root before the service starts;
`sing-box.service` then reads that runtime file as user `sing-box`. No secret
reaches Nix evaluation, the store or git. Every credential file stays root-only.

`modules/services/sing-box.nix` declares one `sops.secrets.<name>` per encrypted
value with `owner = "root"`, mode `0400` and
`restartUnits = [ "sing-box.service" ]`, so changing a value restarts the service.

## What stays encrypted

[modules/secrets/sing-box.yaml](../modules/secrets/sing-box.yaml) holds the proxy
endpoints and their credentials:

| Group | Keys |
| --- | --- |
| Each vless node | `<node>_server`, `<node>_uuid`, `<node>_server_name` |
| Each hysteria2 node | `<node>_server`, `<node>_password`, `<node>_server_name` |

The tailnet auth key is not sing-box's: it lives in
[modules/secrets/tailscale.yaml](../modules/secrets/tailscale.yaml), because a host
that joins the tailnet through a `tailscaled` module instead of this endpoint needs
the same key.

Nothing here exposes a management API: sing-box is transport only, and the tailnet
endpoint above is a connection path rather than a certificate provider.

Everything else — ports, tun addresses, DNS server addresses, Wi-Fi names, rule
sets and routing rules — is declared in Nix and visible in git.
The proxy document is shared by every host that runs sing-box, because each one
needs the same proxy credentials.

## NetBird

On a host that runs a NetBird client, the module adds a `direct` outbound bound to
the client's interface and a rule sending NetBird's own ranges
(`100.69.0.0/16`, `100.79.0.0/16`, `fd2b:a214:7af1:40d2::/64`,
`fdd3:c8c7:a7e5:d757::/64`) to it, because that traffic does not survive being
proxied. Both are present only on a host that configures a NetBird client, and no
cgroup measurement or packet mark is involved any more.

## Container egress

Nothing here trusts a container bridge: containers run rootless under the account
that starts them, and Podman forwards their traffic with a userspace process that
the account owns, so it leaves the host as ordinary host traffic and the tun
captures it like any other connection. The Docker-daemon rule that admitted
destination-NATed flows from `docker0` retired with the Docker aspect.

## Change a value

```sh
nix develop
sops modules/secrets/sing-box.yaml   # proxy credentials and endpoints
sops modules/secrets/tailscale.yaml  # the tailnet auth key
```

Then build the affected machines and authorize deployment separately. Adding a new
proxy secret means adding the key to `singBoxSecrets` in the module, referencing it
with `secret "<name>"`, and encrypting the value in the document.

## Validate a change

Build the affected NixOS configuration before activation. After activation, an
administrator can check the actual runtime configuration without decrypting
credentials into shell output or temporary files:

```sh
sudo sing-box check -c /run/sing-box/config.json
```

The root pre-start hook has already resolved every `_secret` in this file into the
runtime configuration.
