# omp and its providers

omp is the coding agent harness the desktop hosts run, and the standalone
[Paseo daemon](paseo-daemon.md) runs it for remote clients. The `omp` aspect
declares direct providers in `models.yml`. Its Home Manager contribution also
installs the optional Magpie gateway plugin. The workstation role already
composes the aspect.

## Providers

The `omp` aspect writes `~/.omp/agent/models.yml` with two key-based providers:

- `deepseek`, the default provider
- `openrouter`

Both resolve their key through omp's command form (`apiKey: "!cat <path>"`), so no
key value enters Nix evaluation, the Nix store, or the shell environment. omp runs
the command when a request or a credential probe needs the key, and caches the
output for the process lifetime.

Codex and Cursor are OAuth providers omp owns: a user runs `omp /login` per host,
and the credential lives in omp's own auth store. That keeps a rotating OAuth
token out of Nix and the store. The declared `settings.modelRoles` assignment
puts the session default and the cheap roles (`smol`, `tiny`, `commit`, `memory`,
`task`, `vision`) on the key-authenticated `deepseek/deepseek-flash`, while
`plan` and `advisor` select Cursor's `cursor/claude-sonnet-5-5:high` and `slow`
selects Codex's `openai-codex/gpt-6-astra:xhigh`. Those three OAuth-backed
selectors resolve only on a host that ran the matching `omp /login`; the
DeepSeek-backed roles always resolve. Search is omp's own tool set; the aspect
adds nothing to a request.

`programs.omp.settings` writes `config.yml` as a writable copy, because omp flocks
and atomically rewrites it. `models.yml` is read-only user configuration, so the
aspect installs it as an ordinary Home Manager file.

### Magpie gateway plugin

`modules/apps/agents/omp-magpie/` is an installable omp plugin. Home Manager
places it in `~/.omp/agent/extensions/magpie`, where omp discovers it automatically.
It adds the `magpie` provider without changing any model-role assignments.

Inside an interactive omp session, run `/login magpie` (or choose **Magpie**
from `/login`):

1. Enter the Magpie endpoint, or submit an empty answer for
   `http://127.0.0.1:3425`. A trailing `/v1` is accepted; reverse-proxy path
   prefixes are preserved.
2. Enter the gateway API key (`sk-magpie-key-...`). The in-session prompt masks
   the key. Use a gateway key, not Magpie's web UI sign-in key.
3. Select a discovered model with `/model`; selectors have the form
   `magpie/<provider>/<model>` or `magpie/group/<group>`.

The endpoint and key live together in omp's auth store, never in Nix or
`models.yml`. Repeating `/login magpie` replaces the connection; cancelling
leaves the previous login intact. Choose Magpie from `/logout` to remove it.
The plugin uses omp's login interface for a non-expiring gateway key, not a
browser OAuth flow.

Discovery reads the gateway's `/v1/models` with that key. It preserves model
IDs, context/output limits, image input and supported reasoning levels, and
uses native Responses or Anthropic Messages endpoints when advertised;
other models use Chat Completions. Anthropic requests use budget thinking,
which Magpie adapts for models requiring adaptive thinking. Missing token
limits use omp's defaults (128,000 context and 16,384 output tokens); the
gateway does not advertise prices, so cost is unreported.

Run `omp models refresh magpie` after changing the gateway's model catalog.
Login stores the connection; discovery and inference surface gateway
availability or authorization failures. Magpie's loopback access policy may
accept any key, so successful local discovery does not validate a remote key.
See the [upstream gateway reference](https://github.com/yetone/magpie/blob/v0.1.1092/docs/reference.md#providers-and-the-gateway).

To load the plugin directly from this checkout without a NixOS switch:

```sh
omp -e ./modules/apps/agents/omp-magpie
# Then run /login magpie inside omp.
```

The Home Manager installation applies to Asymmetry and Parallax, not the
standalone Paseo service account or named omp profiles. Those can load the
same plugin explicitly through their own omp extension configuration.


## Credentials

`modules/secrets/omp-providers.yaml` holds the two provider keys:

| Encrypted document key | Use |
| --- | --- |
| `deepseek_api_key` | DeepSeek authentication |
| `openrouter_api_key` | OpenRouter authentication |

Every host that runs omp reads this document: neko-sphere, Asymmetry and Parallax. Its
`.sops.yaml` rule names exactly those hosts plus the maintainer, and no catch-all
matches it.

The aspect decrypts a copy for the desktop user at
`/run/secrets/omp-deepseek-api-key` and `/run/secrets/omp-openrouter-api-key`,
owner `nvirellia` with mode `0400`, and publishes those paths through
`constants.resources.userSecretPaths`; `models.yml` reads them by path. It declares
the secrets only on a host that has that user, so a server host provisions its own
copy instead. No plaintext secret file is created; edit the document with `sops`.

The Paseo daemon cannot log in interactively, so it declares its own copies owned
by the `paseo` service account and a read-only `models.yml` bound into its home.
See [Paseo daemon](paseo-daemon.md#systemd-lifecycle-and-execution-account).

## Verification

From a desktop host:

```sh
omp models deepseek
omp models openrouter
omp models openai-codex   # after omp /login openai-codex
omp models cursor         # after omp /login cursor
omp models magpie         # after in-session /login magpie
```

Confirm `models.yml` resolves its keys (`omp models deepseek` lists models rather
than reporting the provider unauthenticated), start a session and complete a
tool-calling turn, and confirm a `!cat` failure surfaces as an unauthenticated
provider rather than a crash. On neko-sphere, confirm the daemon's own `models.yml` is
present and that Paseo can dispatch through a DeepSeek or OpenRouter model.
Configuration evaluation and package builds alone cannot prove these behaviors.
