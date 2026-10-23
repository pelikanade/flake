# Caddy

`modules/services/caddy.nix` turns on [Caddy](https://caddyserver.com) for a host
that serves names on the public internet. Automatic HTTPS derives both the
certificate and the HTTP-to-HTTPS redirect from the site names alone, so the
repository keeps no account key, challenge server or renewal timer: issuance
happens the first time a name that resolves to the host is requested.

## The service

The aspect enables `services.caddy` with `openFirewall = true`, which admits TCP
80 and 443 plus UDP 443 for HTTP/3. It declares no sites; the machine supplies
`services.caddy.virtualHosts`, and every upstream is expected on loopback.

## edge

| Name | Upstream | Purpose |
| --- | --- | --- |
| `status.nvirellia.im` | `http://127.0.0.1:3001` | [Gatus](gatus.md) status page |
| `nvirellia.im`, `www.nvirellia.im` | `http://127.0.0.1:8080` | The personal site |

The personal site listens there through [its own module](nvirellia-im.md); a 502 on
those names means that service is not running while Caddy still holds a valid
certificate.

## Certificate issuance

- The name's A and/or AAAA record must resolve to this host; Caddy answers the
  ACME HTTP-01 challenge on port 80.
- A Cloudflare proxy in front of the name intercepts both the challenge and the
  TLS handshake. Point the record at the host DNS-only (grey cloud) unless a
  DNS-01 solver is configured.
- Account keys and certificates live under `/var/lib/caddy`, not in the Nix
  store, so they survive a switch.

## Verification

```sh
systemctl status caddy
journalctl -u caddy -b --no-pager | tail -30
curl -sI -H 'Host: status.nvirellia.im' http://203.88.112.220/ | head -1   # 308
curl -sI https://status.nvirellia.im/ | head -1                          # after DNS points here
```
