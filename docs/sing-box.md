# sing-box

The proxy platform these machines run. It is the proxy and nothing else: the
tailnet is [its own feature](tailscale.md), with its own daemon, interface and key,
and this module declares nothing of it. The configuration is declared in
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

The tailnet auth key is not sing-box's and is not part of this document: it belongs
to [the tailnet's own module](tailscale.md), which reads it from
[modules/secrets/tailscale.yaml](../modules/secrets/tailscale.yaml).

Nothing here exposes a management API: sing-box is transport only. Everything else
— ports, tun addresses, DNS server addresses, Wi-Fi names, rule sets and routing
rules — is declared in Nix and visible in git.
The proxy document is shared by every host that runs sing-box, because each one
needs the same proxy credentials.

## What the tun leaves alone

The tun captures every locally generated connection except two things, and both
exclusions exist so that a network the host owns in the kernel stays out of the
proxy.

**The carrier-grade NAT range.** `100.64.0.0/10` and `fd7a:115c:a1e0::/48` are in
`route_exclude_address`, which keeps them out of the tun's routes and out of the
redirect that carries local traffic into it. That range is where the tailnet's
`tailscale0` and NetBird's `wt0` live: the tailnet's peers and its resolver, and
NetBird's peers and accepted routes, keep whatever the kernel routes for them.
NetBird's own ranges are inside that block, so the module no longer needs an
outbound bound to `wt0` and a rule sending its ranges there — the kernel's routes
through the interface do that, and only NetBird's management and relay traffic (on
public addresses) still goes through the proxy.

**Traffic that carries the bypass mark.** `services.sing-box.tunBypassMark` is the
mark this tun treats as its own: `auto_redirect` skips any packet that carries it,
and sing-box puts it on every connection it dials itself. A feature whose own
transport must not be proxied declares its sockets with the same value — the
tailnet's daemon does, through a unit that matches its cgroup — and then that
transport keeps the route the kernel gave it. The value is declared as a constant
because it is a contract between the tun and whoever needs it, and the tun sets
`auto_redirect_output_mark` from it rather than relying on the default.

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
```

Then build the affected machines and authorize deployment separately. Adding a new
proxy secret means adding the key to `singBoxSecrets` in the module, referencing it
with `secret "<name>"`, and encrypting the value in the document.

## Validate a change

Build the affected NixOS configuration before activation — it renders the settings
and checks the ruleset — and check the rendered configuration itself, which the
settings JSON is, once its `_secret` markers are replaced:

```sh
nix build --no-link --impure --expr 'let f = builtins.getFlake (toString ./.); pkgs = import f.inputs.nixpkgs { system = "x86_64-linux"; }; in (pkgs.formats.json {}).generate "config.json" f.nixosConfigurations.neko-sphere.config.services.sing-box.settings'
```

After activation, an administrator can check the actual runtime configuration
without decrypting credentials into shell output or temporary files:

```sh
sudo sing-box check -c /run/sing-box/config.json
```

The root pre-start hook has already resolved every `_secret` in this file into the
runtime configuration.
