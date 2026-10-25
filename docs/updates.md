# Updates

The `Update packages` workflow runs daily at 02:00 Asia/Shanghai. It updates
the flake lock, updates every locally packaged tool, builds them, repairs
failures with an omp agent, reviews the repairs with a second omp agent, and
then commits. There is no separate repair workflow and no pull request.

It runs on the `update-packages` self-hosted runner on `neko-sphere`.
`modules/services/github-runners/update-packages-runner.nix` puts the tools its
steps call (python3, jq, gh, ripgrep, openssh, nix-update, nixfmt, awk, curl,
and omp) on the job `PATH`, so the steps invoke the scripts and `gh` directly,
and the repair and review agents run with the installed omp instead of
building `.#omp`. The same module renders the Magpie endpoint and key into the
runner's `~/.omp/agent/magpie.yaml`.

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
   error. `commit-updates.py --phase clean` then commits each package that
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
   package expressions, adapts the local patches and substitutions, and
   rebuilds every failed package. It has no git credentials and cannot commit.
   Then it builds every updated package again from the final working tree
   (including verify targets) as the build gate the reviewer reads, writing
   `.ci/build-summary.json`. It publishes the gate for a package it could not
   repair, for a change outside `modules/packages`, or for a failed final
   build; a repair that changed nothing has nothing to review, so it publishes
   `ok`. The phase does not run when the build phase already rejected the run.
5. **Review changes.** If the repair changed files, a second, independent omp
   agent reviews the repair diff, the update manifest, the repair report, and
   the final build summary. It writes `.review/verdict.json` with:

   ```json
   {
     "approve": true,
     "summary": "...",
     "security_findings": []
   }
   ```

   Any security finding forces a rejection, and the script rejects a non-empty
   `security_findings`, an agent that changed the working tree, and a changed
   tree of its own. It publishes `ok` on approval, and the gate otherwise.
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
8. **Report.** The job summary lists every update, the repair report, the
   review, and the gate. `.update-agent/`, `.ci/`, and `.review/` are uploaded
   as the `update-agent` artifact either way.

The repair and review agents print their thinking (`--print-thoughts`) and
their output is streamed into the workflow log as it arrives. Their full
transcripts are in the artifact, at `.update-agent/logs/omp.log` and
`.review/omp.log`.

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
- Packages that arrive through flake inputs are not individually built by this
  workflow.

## Local use

```sh
just update-packages --build
```

Add `--keep-failed` to leave a failed pin in the working tree and write
`.update-agent/updates.json` and `.update-agent/failures.json`. Then:

```sh
python3 scripts/verify-packages.py --updates .update-agent/updates.json --log-dir .ci
python3 scripts/commit-updates.py --phase clean

omp=$(nix build --no-link --print-out-paths .#omp)
python3 scripts/repair-updates.py --omp "$omp/bin/omp"
python3 scripts/review-updates.py \
  --log-dir .review --omp "$omp/bin/omp" \
  --base "$(git rev-parse HEAD)"   # the clean-tip the build phase published
python3 scripts/commit-updates.py --phase failed
python3 scripts/commit-updates.py --phase repair
```

`scripts/update_state.py` documents the outputs each phase publishes, and
`repair-updates.py` builds every updated package again before it finishes, so
the local sequence does not call `verify-packages.py` twice. Outside GitHub
Actions the outputs go nowhere: a phase prints its decision and the exit code
carries it, and `review-updates.py --base` is passed by hand as above.

`repair-updates.py` and `review-updates.py` load the omp-magpie extension
through `PI_CONFIG_FILES` and read `~/.omp/agent/magpie.yaml`, so run them from
the desktop session, where Home Manager provides both.

`repair-updates.py` and `review-updates.py` support `--dry-run`, which writes
the prompt and prints the command without calling the agent.
