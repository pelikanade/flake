# sing-box

The proxy platform every host runs. The configuration is declared in
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

Everything else — ports, tun addresses, DNS server addresses, Wi-Fi names, rule
sets, routing rules and the Clash API listener — is declared in Nix and visible in
git. The sing-box document is shared by every host that runs sing-box, because each
one needs the same proxy credentials.

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

`sing-box check` reads the rendered configuration, so render it the same way the
service does:

```sh
nix develop
sing-box check -c <(jq --slurpfile s <(sops -d --output-type json modules/secrets/sing-box.yaml) \
  --slurpfile t <(sops -d --output-type json modules/secrets/tailscale.yaml) \
  '($s[0] + $t[0] | with_entries(.key = "/run/secrets/\(.key)")) as $m
   | walk(if type == "object" and has("_secret") then $m[.["_secret"]] else . end)' \
  <(nix eval --json .#nixosConfigurations.MACHINE.config.services.sing-box.settings))
```

That substitution is what the pre-start hook does, so a passing check covers the
rendered file rather than only the declared settings.
