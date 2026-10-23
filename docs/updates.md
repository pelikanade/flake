# Updates

Three workflows keep packaged tools current without putting an unverified pin
on `main`.

## 1. Update packages

`Update packages` runs daily. It updates the flake lock, then discovers every
exported package that declares `passthru.update` and updates its version and
hashes. Each package is built before its commit:

- A package that builds is committed and pushed to `main`.
- A package that fails is left in the working tree. The updater writes
  `.update-agent/failures.json` and a log per failure, commits the failed pins
  to a pending branch `update/pending-<run-id>`, and uploads the failure report
  as the `update-agent` artifact.

The flake lock itself is only committed after every machine's toplevel
evaluates. The scheduled run never builds a package that did not change.

## 2. Repair package updates

`Repair package updates` is a separate workflow with `workflow_call` and
`workflow_dispatch` triggers. The update workflow calls it only when a package
build failed; it can also be dispatched by hand against a pending branch (pass
the branch and the update run id that uploaded the artifact).

The workflow checks out the pending branch, downloads the failure report, and
starts an omp agent. The agent reads the failing package expressions and their
patches, adapts the local patches and substitutions to the new upstream
revision, and runs the package build again. It cannot commit, push, or open a
pull request; the workflow does that after every failed package builds.

If the agent cannot make every package build, no pull request is opened. The
pending branch and the `repair-report` artifact remain for a human.

## 3. Package PR

`Package PR` runs on pull requests whose head branch starts with `update/`.

1. `scripts/verify-packages.py` selects the packages whose declared files
   changed, plus each package's `verify` targets, and builds them.
2. After that job passes, a second omp agent reviews the diff, the package
   comments, and the build summary. It writes an approval or rejection, a
   review comment, and a `security_findings` list. Any security finding --
   secrets, new downloads, weakened sandboxing, privilege escalation, unsafe
   shell execution, untrusted sources, or CI/permission changes -- blocks the
   merge even if the build passed.
3. The workflow posts the review. It merges the PR only when the review
   approves with no security findings; otherwise the PR stays open for a
   human.

The merge is queued with auto-merge when the repository allows it, so this
workflow's own check can finish first.

## Credentials

Both agents use omp's built-in DeepSeek provider and the model named
"DeepSeek V4.1 Flash 1017", selected as `deepseek/deepseek-flash`. omp reads
the key from `DEEPSEEK_API_KEY`; the workflows map the repository secret of
that name to it.

Create the secret once, either in the repository UI under **Settings >
Secrets and variables > Actions > New repository secret**, or with the
authenticated `gh` CLI:

```sh
gh secret set DEEPSEEK_API_KEY --repo pelikanade/flake
```

`gh` prompts for the value without echoing it. To pipe it from an existing
credential instead:

```sh
printf '%s' "$DEEPSEEK_API_KEY" |
  gh secret set DEEPSEEK_API_KEY --repo pelikanade/flake
```

Confirm the name is present (the value is never shown):

```sh
gh secret list --repo pelikanade/flake
```

`OMP_MODEL` and `OMP_REVIEW_MODEL` are optional repository variables for
overriding the repair and review models; both default to
`deepseek/deepseek-flash`. Do not store the key in a variable: variables are
plaintext.

The agents receive no git credentials. The workflows perform every push and PR
operation after the agent exits. Both workflows run only for branches in this
repository, never for fork pull requests.

## Local use

```sh
just update-packages --build
```

Add `--keep-failed` to leave a failed pin in the working tree and write
`.update-agent/failures.json`. Then run the repair script with the packaged
agent and the same key in the environment:

```sh
omp=$(nix build --no-link --print-out-paths .#omp)
DEEPSEEK_API_KEY=... python3 scripts/repair-updates.py --omp "$omp/bin/omp"
```

`--dry-run` writes the prompt and prints the command without calling the
agent.
