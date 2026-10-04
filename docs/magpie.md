# Magpie and its clients

The mode has two sides. `box` runs the one `magpie.service`, which holds every
provider credential and can refresh it. Every other host that imports
`inputs.self.modules.aspects.omp` installs omp and an omp extension,
and reaches the gateway over the tailnet. The workstation role already composes
the client aspects. The normal workflow is Paseo → omp → Magpie on
box → Codex, Cursor, DeepSeek, or OpenRouter. OpenCode is not provisioned.

The machine that runs `magpie.service` must be an authorized recipient of
`agent-providers.yaml`, and it is the only one: today that is box. The maintainer
can edit the whole document; adding a reader requires enrolling its host
recipient and an explicitly authorized ciphertext rewrite, following
[secret guidance](../AGENTS.md).

## Credentials

Every provider credential belongs to `magpie.service` alone:

| Encrypted document key | Use |
| --- | --- |
| `deepseek_api_key` | Magpie's DeepSeek authentication |
| `openrouter_api_key` | Magpie's OpenRouter authentication |
| `codex_auth_json` | JSON string containing the Codex account login cache |
| `cursor_auth_json` | JSON string containing the Linux Cursor Agent login cache |
| `magpie_web_key` | The browser UI's stable sign-in key |

`modules/services/magpie.nix` declares these secrets, so only the gateway host
provisions them. Activation decrypts them to `/run/secrets/<key>` owned by `root`
with mode `0400`, and `magpie.service` is the only consumer: systemd
`LoadCredential` hands the dynamic service the two login JSONs, the rendered
provider template and the UI key, and Magpie's own declarative tmpfiles `f^` rules
create its
writable Codex and Cursor caches under `/var/lib/magpie` from those credentials,
only when missing. No agent account, no omp process, and no Paseo service can open
the files or inherits a copy. No token enters Nix evaluation or the store, and no
initializer script renders credentials into a user's home.

The encrypted login JSON is a bootstrap snapshot. Magpie keeps locally refreshed
tokens across restarts, and changing the SOPS snapshot does not replace an
existing cache. To apply a different account or recover a revoked session, stop
`magpie.service`, remove the relevant `auth.json` under its `StateDirectory`, and
start it again to copy the new seed. Do not link a mutable login cache to a
read-only secret or a Nix store file. See
[systemd tmpfiles](https://www.freedesktop.org/software/systemd/man/latest/tmpfiles.d.html)
and [Codex authentication](https://developers.openai.com/codex/auth).

## Magpie on box

`magpie.service` uses systemd `DynamicUser=true`, with a private persistent
`StateDirectory=magpie` and HOME `/var/lib/magpie`. The UID is temporary; token
refresh caches, plugin installation, and gateway settings survive restarts.
`ProtectHome=true` hides the personal and root homes. Both listeners bind every
interface so tailnet peers reach them on box's tailnet address, and this module
admits 3425 and 3430 on `tailnet0` only, so loopback keeps working: the gateway on
`0.0.0.0:3425` and the browser UI on `0.0.0.0:3430`, which no desktop session is
needed for. The UI's only credential is the private sign-in link from the
service's journal: keep it out of logs you share and restrict 3430 with tailnet
grants. `magpie_web_key` pins that link across restarts, so read it once and store
it like a password; replace the key in the document to revoke it.

Nix declares the provider policy. `sops.templates.magpie-providers` renders the
DeepSeek and OpenRouter keys at activation; `LoadCredential` gives the dynamic
service that template and the Codex/Cursor login seeds. Standard systemd pre-start
file installation applies the managed JSON configurations on every startup.

The managed providers are Codex's discovered account models, Cursor `auto`,
DeepSeek `deepseek-flash` / `deepseek-v4-pro`, and OpenRouter with its
catalog-driven model list. Narrow a provider's list with its `models` field in
`modules/services/magpie.nix` when the picker has more than you want. Cursor uses
`@magpie-community/opencode-cursor-auth@latest`, installed on first startup
with Magpie's Nix-managed Bun. Its auth binding references `cursor-agent`,
which reads the gateway's seeded Linux CLI cache. Startup does not perform an
interactive login. The plugin may require reauthentication if the account
session is revoked or expires; `@latest` does not guarantee perpetual login.
The first plugin installation needs network access. Later restarts reuse it.

The browser UI edits runtime state in the service home. Restart reapplies the
managed provider/plugin/auth declarations. Change managed policy in Nix and
credentials with SOPS. Do not launch a second gateway on port 3425 anywhere.

## omp on the client hosts

The `omp` aspect installs omp with the tools it needs and imports upstream's
`programs.omp`, which owns the agent directory: it installs the package, takes
`settings` (written to `config.yml` as a writable copy, because omp flocks and
rewrites it) and enables the program. The aspect adds only what upstream does not
manage: it installs the `magpie` extension under `<configDir>/extensions`, sets
`modelRoles.default = "magpie/cursor/auto"`, and leaves skills and stored logins
alone.

That extension registers `magpie` from the gateway's public `/v1/models`
catalog, including native Chat/Responses/Messages APIs, context windows, output
limits, and thinking levels. It is the only model provider the installed omp has:
no API key is provisioned for omp itself.

The extension reaches the gateway at `PI_MAGPIE_URL`, which the `omp` module sets to
`http://box.<tailnetDnsName>:3425` from
[the tailnet constant](../modules/constants/tailnet.nix): MagicDNS answers fully
qualified names, and the resolver does not expand the bare name. The tailnet must
have MagicDNS enabled, but the gateway need not be reachable when omp loads: the
extension registers the provider immediately, omp discovers and caches the catalog
when the gateway answers, and a session start warns if it still cannot. A host that
runs its own gateway sets `PI_MAGPIE_URL` to its local address instead; the Paseo
daemon does that automatically when `magpie.service` is present on the same
machine. Select a Magpie model in Paseo's model picker, or start omp directly:

```sh
omp --model magpie/cursor/auto
omp models magpie
```

Client hosts install omp only. `codex` and `cursor-agent`
belong to the gateway host, where Magpie refreshes their logins, so Paseo has no
second harness to offer. The extension also offers web search on Magpie requests,
preserving omp's other tools. Magpie performs search itself or delegates it to a
configured search-capable account (such as Codex), or a search API. Search
consumes that account's allowance. A search offer alone does not establish that
the available accounts can perform it. omp's displayed cost metadata is zero
because this public catalog does not publish billing rates; it is not a statement
that the upstream request is free.

## Paseo

Paseo holds no provider credentials and depends on no local gateway. Paseo
Desktop launches tools as the desktop user and uses the `magpie` extension
installed in that user's home. The standalone [Paseo daemon](paseo-daemon.md)
runs as `paseo`, with a separate home, and receives only the `magpie` extension
bound read-only into its omp extensions directory. Both talk to box's gateway over
the tailnet.

Paseo v0.10.2 ships omp as a built-in provider, off by default, and drives it over
RPC rather than ACP. The daemon turns it on for its own home, so omp is Paseo's
provider there, and Cursor reaches Paseo through omp's `magpie` provider even
though Paseo registers no Cursor harness of its own.

## Verification

After separately authorized deployment, check the gateway on box and discovery
from a client host:

```sh
systemctl status magpie.service          # on box
curl --fail --silent http://box.leaffish-halfmoon.ts.net:3425/v1/models | head   # from a tailnet peer
omp models magpie                        # on a client host
```

`/v1/models` lists what the configured providers expose; it does not prove that an
upstream account still accepts requests. Use `journalctl -u magpie.service` for
startup and login failures, and keep its browser sign-in link and any credential
output out of shared logs. Model availability can also be inspected through
Paseo's omp provider, whose RPC discovery reads the same catalog.
