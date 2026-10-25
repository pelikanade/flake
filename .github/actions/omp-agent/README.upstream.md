# omp-agent

Run an [omp](https://github.com/can1357/oh-my-pi) agent unattended, with its
thinking streamed into the job log.

`omp -p` prints the agent's final message and drops thinking blocks unless
`--print-thoughts` is passed, and an unattended run has no other view of what
the agent did. This repository is one command that asks for the thinking and
writes every line to the job log as it arrives, plus the two ways to call it:

- **`action.yml`** — a composite action, for a workflow step that runs one
  agent.
- **`omp-agent`** — the same command as a flake package, for a pipeline that
  needs the agent *inside* a phase of its own: build a prompt from data it just
  collected, run the agent, then verify the result against its own gates.

Either way the whole transcript is in the log file, so the job artifact keeps
what the log scrolled past.

## As an action

```yaml
- name: Repair the failed updates
  id: repair
  uses: pelikanade/omp-agent@main
  with:
    prompt: .update-agent/prompt.md
    model: ${{ vars.OMP_MODEL }}
    log: .update-agent/logs/omp.log
```

| Input | Default | Meaning |
| --- | --- | --- |
| `prompt` | — | prompt file the agent starts from (required) |
| `log` | `omp-agent.log` | file the whole transcript is written to |
| `model` | | model to run; empty uses omp's own default |
| `omp` | | omp binary; empty uses `$OMP_AGENT_BIN`, then `omp` on `PATH` |
| `cwd` | | directory the agent works in; empty uses the job's working directory |
| `session-dir` | `<log dir>/sessions` | where omp keeps the session |
| `max-time` | `45m` | omp's own session limit |
| `timeout` | `3600` | kill the agent after this many seconds |
| `approval-mode` | `yolo` | an unattended step cannot answer approval prompts |
| `thoughts` | `true` | include thinking blocks in the log |
| `no-skills` | `true` | do not load skills |
| `no-pty` | `true` | do not give bash a PTY |
| `no-lsp` | `true` | do not load LSP tools |
| `no-title` | `true` | do not generate a session title |
| `extra-args` | | extra arguments for the omp command, split on spaces |

| Output | Meaning |
| --- | --- |
| `log` | path of the transcript |
| `session-dir` | path of omp's session directory |
| `exit-code` | the agent's status; `124` means the timeout killed it |

The step fails when the agent exits non-zero. Add `continue-on-error: true`
when the caller wants to read `steps.<id>.outputs.exit-code` itself, which is
what a phase that verifies the agent's result does.

## Inside a phase of your own

`nix run`:

```sh
nix run github:pelikanade/omp-agent -- --prompt prompt.md --log .ci/omp.log \
  --model magpie/deepseek/deepseek-flash --cwd "$PWD" --max-time 45m \
  --approval-mode yolo --no-skills --no-pty --no-lsp --no-title
```

or as a flake input, so machines and CI run the same locked command:

```nix
inputs.omp-agent = {
  url = "github:pelikanade/omp-agent";
  inputs.nixpkgs.follows = "nixpkgs";
};

environment.systemPackages = [ inputs.omp-agent.packages.${system}.default ];
```

`--help` lists every option, including the pass-through switches `--no-skills`,
`--no-pty`, `--no-lsp` and `--no-title`, `--extra-arg` for anything else, and
`--dry-run` to print the command without running it.

## Provider configuration

The command passes no credentials. omp reads its extensions from
`PI_CONFIG_FILES`, and those extensions read their own settings — a Magpie
gateway, for example, comes from the `omp-magpie` extension plus
`~/.omp/agent/magpie.yaml` with the endpoint and key, which a runner can render
from its own secret store. Nothing provider-specific is stored in the workflow.

## Exit status

| Status | Meaning |
| --- | --- |
| *the agent's own* | the agent ran to completion and exited with this status |
| `124` | `--timeout` killed the agent; the log says so |
| `127` | the omp binary is missing |
| `2` | the command line is wrong, for example a prompt file that does not exist |

## Where the transcript goes

Every line the agent writes goes to the log file *first*, then to the job log.
The order matters: a console that cannot take bytes (`sys.stdout` without a
`.buffer`, as a captured or embedded run may have) would otherwise raise before
the file write and cost the whole transcript. The test suite runs that case.

## Development

```sh
nix flake check                 # the suite, in a sandbox
python3 -m unittest discover -s tests -v   # the suite, directly
```

`tests/test_omp_agent.py` runs the command against a fake `omp` that records
its arguments, and runs `action.sh` with the same `INPUT_` variables a workflow
sets, so the action's input mapping is verified without a workflow run.
