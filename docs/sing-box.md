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
`sing-box.service` then reads only that runtime file as user `sing-box`. No secret
reaches Nix evaluation, the store or git, and no secret file is readable by the
service user.

`modules/services/sing-box.nix` declares one `sops.secrets.<name>` per encrypted
value with `owner = "root"`, `mode = "0400"` and
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

The certificate API credential lives separately in
[modules/secrets/sing-box-api.yaml](../modules/secrets/sing-box-api.yaml). Only
`neko-sphere` consumes it; its recipients are the maintainer `noa` and that host.
The key is generated randomly and encrypted before it reaches disk.

Everything else — ports, tun addresses, DNS server addresses, Wi-Fi names, rule
sets, routing rules and API listeners — is declared in Nix and visible in git.
The proxy document is shared by every host that runs sing-box, because each one
needs the same proxy credentials.

## Open SWE certificate API

`neko-sphere` imports the `openswe-tailnet-api` aspect from
[modules/services/openswe-tailnet-api.nix](../modules/services/openswe-tailnet-api.nix).
It adds the authenticated [sing-box API service](https://sing-box.sagernet.org/configuration/service/api/)
at `http://127.0.0.1:9090` to the existing instance. This requires sing-box 1.14 or
newer. The API uses the existing Tailscale endpoint `tailnet`, including its node
identity and state. The Clash listener does not provide certificate RPCs.

NixOS activation provisions the document's `api_key` as
`/run/secrets/openswe-tailnet-api-key`, owned by `paseo:paseo` with mode `0400`.
The root pre-start renderer reads that same path into the runtime configuration.
The API key grants control of the entire sing-box instance, including certificate
private-key export; it is not restricted to certificate operations. Root and
processes running as `paseo` can read it. Other users and sandbox containers must
not receive the file or its environment variable. Authentication remains required
on loopback because the userspace Tailscale endpoint can forward local ports.

Build the configuration before an administrator activates it:

```sh
nix build .#nixosConfigurations.neko-sphere.config.system.build.toplevel
sudo nixos-rebuild switch --flake .#neko-sphere
```

Activation provisions the credential and restarts sing-box, briefly interrupting
its proxy and tailnet connections. Changes to this secret also restart sing-box.
No new Tailscale login, state copy, firewall opening or privilege-policy change
is needed.

After activation, run the following as `paseo` from the Open SWE project directory
using the host's sing-box 1.14+ binary. Enable HTTPS certificates in the Tailscale
admin console if the domain list is empty. Use the domain returned by this node;
do not derive it from the machine name or assume an old MagicDNS suffix.

```sh
(
  set +x
  export BOX_API_SECRET="$(cat /run/secrets/openswe-tailnet-api-key)"
  umask 077
  mkdir -p .devenv/state/tls
  sing-box api --url http://127.0.0.1:9090 tailscale certificate list \
    --endpoint tailnet
  read -r -p 'Certificate domain from the list: ' certificate_domain
  sing-box api --url http://127.0.0.1:9090 tailscale certificate export \
    "$certificate_domain" --endpoint tailnet \
    --cert-file .devenv/state/tls/tailscale.pem \
    --key-file .devenv/state/tls/tailscale-key.pem --min-validity 720h
)
```

The subshell confines `BOX_API_SECRET` to the API commands without placing it in
command arguments. Never enable shell tracing around credential reads. Keep the
exported private key in project runtime state, outside git. The `720h` threshold
renews a certificate with less than 30 days remaining; repeat the export before
expiry and reload the application's TLS listener after a successful renewal.
The host module only exposes the authenticated API; certificate export and the
native HTTPS listener belong to the Open SWE project.

## NetBird

On a host that runs a NetBird client, the module adds a `direct` outbound bound to
the client's interface and a rule sending NetBird's own ranges
(`100.69.0.0/16`, `100.79.0.0/16`, `fd2b:a214:7af1:40d2::/64`,
`fdd3:c8c7:a7e5:d757::/64`) to it, because that traffic does not survive being
proxied. Both are present only on a host that configures a NetBird client, and no
cgroup measurement or packet mark is involved any more.

## Docker bridge traffic

When Docker and sing-box run together, the Docker module permits TCP traffic
from `docker0` that the kernel has already marked as destination-NATed. This
lets `auto_redirect` deliver container egress to sing-box's local proxy listener;
otherwise the NixOS input firewall drops the redirected connection even though
container DNS and ordinary LAN forwarding work. The rule neither trusts the
whole bridge nor opens a fixed host port. It is enabled only with sing-box and
the nftables firewall backend.

Validate this path with an HTTPS request and a real repository clone from a
bridge-networked container, in addition to the sandbox's local execution checks.

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

The root pre-start hook has already resolved every `_secret` in this file,
including the optional Open SWE API credential. Check certificate listing and
export separately as `paseo` using the commands above.
