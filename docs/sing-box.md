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
value with `owner = "root"` and `restartUnits = [ "sing-box.service" ]`, so changing
a value restarts the service. Proxy and tailnet credentials use mode `0400`;
the management API credential uses group `sing-box-api` and mode `0440`.

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

The management API credential lives separately in
[modules/secrets/sing-box-api.yaml](../modules/secrets/sing-box-api.yaml). Every
sing-box host consumes it: `asymmetry`, `neko-sphere` and `parallax`. The document
lists these hosts and the maintainer `noa` as recipients. They share the existing
random API key; access to that key grants management access to any of these
instances that the caller can reach.

Everything else — ports, tun addresses, DNS server addresses, Wi-Fi names, rule
sets, routing rules and API listeners — is declared in Nix and visible in git.
The proxy document is shared by every host that runs sing-box, because each one
needs the same proxy credentials.

## Management and Tailscale certificate API

The common `sing-box` aspect enables the authenticated
[sing-box API service](https://sing-box.sagernet.org/configuration/service/api/)
at `http://127.0.0.1:9090` on every importing machine. This requires sing-box
1.14 or newer. Certificate operations use the existing Tailscale endpoint
`tailnet`, including its node identity and state. The Clash listener does not
provide certificate RPCs.

NixOS activation provisions the document's `api_key` as
`/run/secrets/sing-box-api-key`, owned by `root:sing-box-api` with mode `0440`.
The root pre-start renderer reads that same path into the runtime configuration.
The API key grants control of the entire sing-box instance, including certificate
private-key export; it is not restricted to certificate operations. Authentication
remains required on loopback because the userspace Tailscale endpoint can forward
local ports. No API firewall port is opened.

The common module creates the `sing-box-api` group without assigning clients.
Each consumer module must explicitly grant its account membership and, for a
systemd service, add `SupplementaryGroups = [ "sing-box-api" ]`. The
[Paseo consumer](../modules/services/paseo-daemon.nix) does this when sing-box is
enabled, so host agents can obtain certificates. Other accounts have no access
by default. Keep the key file and `BOX_API_SECRET` out of application and sandbox
container environments; pass the variable only to the sing-box CLI subprocess.

Build the affected configurations before an administrator activates them:

```sh
nix build --no-link --print-out-paths \
  .#nixosConfigurations.asymmetry.config.system.build.toplevel \
  .#nixosConfigurations.neko-sphere.config.system.build.toplevel \
  .#nixosConfigurations.parallax.config.system.build.toplevel
```

On `neko-sphere`, use its resulting system store path from the build above.
Run the switch from the administrator's separate SSH session in a detached unit
so a tailnet interruption does not kill deployment. `--store-path` activates the
already-built system without evaluating the checkout as root or requiring root
to trust a Git repository owned by another user:

```sh
read -r -p 'Built neko-sphere system store path: ' system
sudo systemd-run --unit=sing-box-api-deploy --collect --no-block \
  --setenv=PATH=/run/current-system/sw/bin \
  /run/current-system/sw/bin/nixos-rebuild switch --store-path "$system"
sudo journalctl -u sing-box-api-deploy -f
```

Activation provisions the credential and restarts sing-box, briefly interrupting
its proxy and tailnet connections. The consumer's supplementary-group change
also restarts Paseo; reconnect afterward so new agents acquire access. Other
machines require their own authorized deployment. No new Tailscale login, state
copy, firewall opening or privilege-policy change is needed.

After activation, check that an unauthenticated request fails with an
authentication error (a connection failure is not proof):

```sh
env -u BOX_API_SECRET /run/current-system/sw/bin/sing-box api \
  --url http://127.0.0.1:9090 tailscale certificate list --endpoint tailnet
```

As root or an explicitly authorized client, list the actual certificate domains
and export to a private runtime directory. Enable MagicDNS and HTTPS certificates
in the Tailscale admin console if the domain list is empty. Use a domain returned
by this node, excluding the `DOMAIN` header; do not guess the hostname or suffix.

```sh
(
  set -eu
  set +x
  umask 077
  cert_dir="${XDG_STATE_HOME:-$HOME/.local/state}/tailnet-certificates"
  mkdir -p "$cert_dir"
  BOX_API_SECRET="$(cat /run/secrets/sing-box-api-key)" \
    /run/current-system/sw/bin/sing-box api --url http://127.0.0.1:9090 \
    tailscale certificate list --endpoint tailnet
  read -r -p 'Certificate domain from the list: ' certificate_domain
  BOX_API_SECRET="$(cat /run/secrets/sing-box-api-key)" \
    /run/current-system/sw/bin/sing-box api --url http://127.0.0.1:9090 \
    tailscale certificate export "$certificate_domain" --endpoint tailnet \
    --cert-file "$cert_dir/cert.pem" --key-file "$cert_dir/key.pem" \
    --min-validity 720h
  openssl verify -CAfile /etc/ssl/certs/ca-certificates.crt \
    -untrusted "$cert_dir/cert.pem" -purpose sslserver \
    -verify_hostname "$certificate_domain" "$cert_dir/cert.pem"
  openssl x509 -in "$cert_dir/cert.pem" -noout -dates -checkend 2592000
)
```

Never enable shell tracing around credential reads or send an exported key to
stdout. Keep private keys outside git with mode `0600`. The `720h` threshold
renews a certificate with less than 30 days remaining. Each client owns its
certificate storage, renewal schedule and TLS listener reload; the common host
module exposes only the authenticated API. Clients must use the generic key path
above; the previous application-specific aspect and secret path were never
activated and have no compatibility alias.

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
including the management API credential. Check certificate listing and export
separately as an authorized client using the commands above.
