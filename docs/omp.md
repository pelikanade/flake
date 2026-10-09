# omp and its providers

omp is the coding agent harness the desktop hosts run, and the standalone
[Paseo daemon](paseo-daemon.md) runs it for remote clients. The `omp` aspect
installs upstream omp and configures the packaged Magpie gateway extension.
The workstation role already composes the aspect.

## Providers

The `omp` aspect does not bundle DeepSeek or OpenRouter credentials or generate
`~/.omp/agent/models.yml`. Magpie reads runtime YAML credentials; Codex and Cursor
use omp's per-host login flow.

Codex and Cursor are OAuth providers omp owns: a user runs `omp /login` per host,
and the credential lives in omp's own auth store. The declared
`settings.modelRoles` assigns `plan` and `advisor` to
`cursor/claude-sonnet-5-5:high` and `slow` to
`openai-codex/gpt-6-astra:xhigh`. These selectors require the matching login.
The aspect leaves the default and other roles unassigned; it no longer pins
them to DeepSeek. Search is omp's own tool set.

`programs.omp.settings` writes `config.yml` as a writable copy, because omp flocks
and atomically rewrites it. A runtime settings change is overwritten on the next
switch; declare persistent model-role assignments in the aspect.

### Magpie gateway plugin

`modules/packages/omp-magpie/` contains the plugin and its Nix package definition.
`packages.omp-magpie` installs the extension. NixOS and Home Manager use the
upstream omp package without a local wrapper. Home Manager sets `PI_CONFIG_FILES`
at login, and the Paseo systemd service sets it in its own environment, pointing
to a generated overlay that loads Magpie. Named profiles inherit the overlay.

The plugin always reads `~/.omp/agent/magpie.yaml`, including in named profiles.
It requires `endpoint` and `api_key`, registers the provider without an interactive
login, and uses the key for discovery and inference. A trailing `/v1` is accepted
on the endpoint; reverse-proxy path prefixes are preserved.

Select a discovered model with `/model`; selectors have the form
`magpie/<provider>/<model>` or `magpie/group/<group>`. The package does not change
model-role assignments. Magpie credentials come from the YAML file, so an old
`/login magpie` entry does not override them.

Discovery reads the gateway's `/v1/models` with that key. It preserves model
IDs, context/output limits, image input and supported reasoning levels, and
uses native Responses or Anthropic Messages endpoints when advertised;
other models use Chat Completions. Anthropic requests use budget thinking,
which Magpie adapts for models requiring adaptive thinking. Missing token
limits use omp's defaults (128,000 context and 16,384 output tokens); the
gateway does not advertise prices, so cost is unreported.

Run `omp models refresh magpie` after changing the gateway's model catalog or
endpoint. Restart omp after changing its credentials. Failed discovery emits a
warning with the connection error code or HTTP status and a pointer to the runtime
configuration. Interactive omp shows the warning once its UI is ready; CLI commands
write it to stderr. Warnings omit the endpoint and API key, and discovery still fails
normally rather than treating the failure as an empty catalog. Inference errors
remain handled by omp. Magpie's loopback access policy may accept any key, so local
discovery does not validate a remote key.
See the [upstream gateway reference](https://github.com/yetone/magpie/blob/v0.1.1092/docs/reference.md#providers-and-the-gateway).

To load the extension directly from this checkout after credentials have been
provisioned at `~/.omp/agent/magpie.yaml`, use:

```sh
omp models magpie -e ./modules/packages/omp-magpie
```

The environment overlay supplies the `extensions` setting. Replacing
`PI_CONFIG_FILES` or loading a later `--config` overlay can replace that list;
include the Magpie extension when overriding it.

## Credentials

Edit the shared encrypted Magpie document with:

```sh
nix develop --command sops modules/secrets/magpie.yaml
```

The existing `magpie_web_key` is preserved. Two new fields contain placeholders:

```yaml
endpoint: https://magpie.example.invalid
api_key: REPLACE_WITH_MAGPIE_GATEWAY_API_KEY
```

Replace both values before deployment. Use a Magpie gateway API key for
`api_key`; `magpie_web_key` remains the browser UI sign-in key.

NixOS activation extracts the endpoint and API key into root-owned files and
uses `sops.templates` to render only those two fields for omp. Asymmetry and
Parallax expose the template at `~/.omp/agent/magpie.yaml`, owned by the desktop
user with mode `0400`. neko-sphere exposes it at
`/var/lib/paseo/.omp/agent/magpie.yaml`, owned by `paseo` with mode `0400`.
Template changes restart the daemon. The gateway service still receives only
`magpie_web_key`.

Systemd tmpfiles creates each user's `.omp` and `.omp/agent` directories with
mode `0700` before sops runs at boot or switch. sops links the rendered runtime
file at the configured home path; Home Manager does not manage that link.

The document's access rule names these three reader hosts and the maintainer.
Each host recipient can decrypt all three fields; the runtime client files omit
the UI key. Decrypted values never enter Nix evaluation or the store.

After switching, start a new login session so desktop applications inherit
`PI_CONFIG_FILES`. No credential-path environment variable is required. The
explicit extension command above also works from an existing terminal.

## Verification

From a desktop host:

```sh
omp models openai-codex   # after omp /login openai-codex
omp models cursor         # after omp /login cursor
omp models magpie          # after filling the placeholders and switching
```

After switching, select an authenticated model and complete a tool-calling turn.
On neko-sphere, verify Paseo can dispatch through Magpie. Local smoke checks use
an isolated home and a test gateway to exercise packaged discovery, authentication
and inference; they do not prove live credentials or remote gateway reachability.
