# Updates

The `Update packages` workflow runs daily at 02:00 Asia/Shanghai. It updates
the flake lock, updates every locally packaged tool that pins an upstream
revision, builds them, repairs failures with an omp agent, reviews the repairs
with a second omp agent, and then commits. There is no separate repair workflow
and no pull request.

It runs on the `update-packages` self-hosted runner on `neko-sphere`.
`modules/services/github-runners/update-packages-runner.nix` puts the tools its
steps call (bun, jq, gh, ripgrep, openssh, nix-update, nixfmt, awk, curl,
util-linux, and omp) on the job `PATH`, so the steps invoke the scripts and `gh`
directly, and the repair and review agents run with the installed omp instead of
building `.#omp`. The same module renders the Magpie endpoint and key into the
runner's `~/.omp/agent/magpie.yaml`.

Both agents run through `pelikanade/omp-action@v1`: a composite action whose
TypeScript (`bun`, standard library only, no build step) builds the omp
invocation, asks for the thinking (`--print-thoughts`), and lets the agent write
straight into the step log — that log is the transcript. The prompts themselves
are in the workflow, next to the steps that run them: an agent reads the failure
data, the logs and the build summary from the files those steps have already
written.

## Sequence

The workflow has one step per phase, and every phase decides its own outcome.
Each phase publishes that decision as [step
outputs](https://docs.github.com/en/actions/using-jobs/defining-outputs-for-jobs)
that the next phase's condition and the publish step read:

| Output | Meaning |
| --- | --- |
| `gate` | the reason this phase rejected the run: `update`, `build`, `repair`, `outside`, or `review` |
| `ok` | this phase verified everything it owns; a run with no `ok` from any phase is never published |
| `clean-tip` | the commit the clean update pins ended at; a rejected run resets to it |
| `changed` | whether the repair left files in `modules/packages` for the reviewer |

An agent phase is the agent step plus the checks around it, all in the
workflow: the step's condition decides whether the agent runs, the shell check
after it turns what the agent did into that phase's `gate` or `ok`, and the
Python it calls is only the per-package rebuild loop and the verdict check.

A phase that publishes `gate` never publishes `ok`, so the two together decide
whether `main` receives the repairs.

1. **Flake inputs.** `nix flake update` runs for every input, then every
   machine's `system.build.toplevel.drvPath` is evaluated. The lock is
   committed as `flake: update`; a failed evaluation reverts it and stops.
2. **Package updates.** Every exported package with `passthru.update` metadata
   is updated. Nothing is committed yet. An update command that fails before
   changing the version is treated as a blocking update failure.
3. **Build updated packages.** Every updated package is built, with its
   `passthru.update.verify` targets. A build failure is recorded in
   `failures.json` and marks the pin in `updates.json`; it is a repair, not an
   error. `commit-updates.ts --phase clean` then commits each package that
   built, separately:

   ```
   strata: update 1.0.0 -> 1.1.0
   ```

   records the commit after them as `clean-tip`, publishes the gate if the
   build did not complete or an update command failed, and publishes `ok` when
   nothing needs repair or review. `--phase failed` commits the version/hash
   changes of the packages that need repair on top, with the same
   `<label>: update <old> -> <new>` message.
4. **Repair failed updates.** The first omp agent reads the failure logs and
   package expressions, adapts the local patches and substitutions, and rebuilds
   every failed package. It has no git credentials and cannot commit. The check
   after it stages the repair, then builds every updated package — the repaired
   pins included — from the final working tree; that
   `.ci/build-summary.json` is the build the reviewer reads.
   `verify-packages.ts` refuses a pin whose repair reverted the update instead
   of adapting to it. The step publishes the gate for an agent that never
   started, an updated package that does not build, or a change outside
   `modules/packages`. A repair that changed nothing has nothing to review, so
   the step publishes `ok`; one that did change something records the working
   tree in `.review/tree.sha` and publishes `changed`. The phase does not run
   when the build phase already rejected the run.
5. **Review changes.** If the repair changed files, a second, independent omp
   agent reviews the repair diff, the update manifest, `failures.json`, and the
   build summary. It writes `.review/verdict.json` with:

   ```json
   {
     "approve": true,
     "summary": "...",
     "security_findings": []
   }
   ```

   Any security finding forces a rejection. The `jq` check after the agent
   rejects a verdict that is missing or unusable, a non-empty
   `security_findings`, an agent that did not finish, an agent that changed
   files outside `modules/packages`, and a tree that does not match the recorded
   one. It publishes `ok` on approval, and the gate otherwise.
6. **Push updates.** Every commit is pushed to `main`. With a gate, or without
   `ok`, the working tree resets to `clean-tip` first, so the failed pins and
   the repairs are dropped and only the clean update commits land; the run
   fails, and a package that could not be repaired keeps its previous version
   on `main`. Otherwise the repair is committed:

   ```
   packages: adapt updates (strata)
   ```
7. **Dispatch deployment.** The workflow dispatches the `Deploy` workflow for
   the revision it just pushed: a push made with `GITHUB_TOKEN` does not trigger
   a `push` workflow by itself. See [deployment](deployment.md).
8. **Report.** The job summary lists every update, the failed pins the repair
   worked on, the review, and the gate. `.update-agent/`, `.ci/`, and `.review/` are uploaded
   as the `update-agent` artifact either way.

The agent steps run `pelikanade/omp-action@v1`, which asks for the thinking
(`--print-thoughts`), echoes the prompt the workflow gave it, and lets the agent
write into the step log as it works. That log is the transcript: the agent writes
no transcript file and no session directory inside the workspace.

## Commit separation

The history contains three kinds of commits:

| Commit | Contents |
| --- | --- |
| `flake: update` | `flake.lock` |
| `<label>: update <old> -> <new>` | version, source hash, dependency hash |
| `packages: adapt updates (<labels>)` | patch and substitution changes |

The update commits are created before the repair; the repair commit is created
only after the review approves. A failed-pin commit may not build on its own.
It is pushed only together with the repair commit, or after the final build
confirms that the pin now builds without a repair.

## Credentials

Both agents run omp against the Magpie gateway on `neko-sphere` through the
`omp-magpie` extension, using Magpie's `deepseek/deepseek-flash` model. The
update runner installs omp, exports `PI_CONFIG_FILES` for the extension, and
renders the gateway endpoint and key into the runner's persistent
`~/.omp/agent/magpie.yaml`. No provider secret is stored in GitHub Actions.

`OMP_MODEL` and `OMP_REVIEW_MODEL` are optional repository variables for
overriding the repair and review models; both default to
`magpie/deepseek/deepseek-flash`.

Neither agent receives a git token. The workflow pushes only after both agents
have exited.

## Coverage

- The flake lock is evaluated, not fully built. A nixpkgs change that
  evaluates but fails to build an unchanged package can still reach `main`.
- The build gate covers every package in the update manifest, not every
  machine toplevel.
- Packages that arrive through flake inputs, and vendored packages without
  `passthru.update` metadata such as `freezer` and `nvirellia-im`, are not
  updated by this workflow.

## Local use

Work from the repository's development shell (`nix develop`), which provides
`bun` for the scripts and the Justfile entry point.

```sh
just update-packages --build
```

Add `--keep-failed` to leave a failed pin in the working tree and write
`.update-agent/updates.json` and `.update-agent/failures.json`. Then:

```sh
bun scripts/verify-packages.ts --updates .update-agent/updates.json --log-dir .ci
bun scripts/commit-updates.ts --phase clean
bun scripts/commit-updates.ts --phase failed

# the repair agent; its prompt is the `prompt:` block of the workflow's
# "Repair failed updates" step — copy it into a file to reuse it here. The
# agent script is the checkout of pelikanade/omp-action, run with bun.
bun /path/to/omp-action/omp_agent.ts \
  --prompt "$(cat /tmp/repair-prompt.md)" --cwd "$PWD" \
  --model magpie/deepseek/deepseek-flash --max-time 45m --approval-mode yolo

# Nix's git source only sees staged content, and this is the build the reviewer
# reads; it refuses a pin whose repair reverted the update.
git add --all -- modules/packages
bun scripts/verify-packages.ts --updates .update-agent/updates.json --log-dir .ci

# the review agent, then the verdict check; the diff against HEAD is the repair
mkdir -p .review
{ git diff HEAD --binary; git status --porcelain --untracked-files=all; } |
  sha256sum | cut -d' ' -f1 > .review/tree.sha
bun /path/to/omp-action/omp_agent.ts \
  --prompt "$(cat /tmp/review-prompt.md)" --cwd "$PWD" \
  --model magpie/deepseek/deepseek-flash --max-time 20m --approval-mode yolo
jq -e '.approve == true and (.security_findings | length == 0)' .review/verdict.json
```

The checks the workflow runs around the agents are in the workflow itself, so a
local run follows the same steps rather than a second implementation. Outside
GitHub Actions the step outputs go nowhere; the shell blocks print what they
decided.

Both agents load the omp-magpie extension through `PI_CONFIG_FILES` and read
`~/.omp/agent/magpie.yaml`, so run them — directly, or through
`omp-action`'s `omp_agent.ts` — from the desktop session, where Home Manager
provides both.
