# Updates

One workflow, `Update packages`, runs daily at 02:00 Asia/Shanghai. It updates
the flake lock, updates every locally packaged tool, builds them, repairs
failures with an omp agent, reviews the repairs with a second omp agent, and
then commits. There is no separate repair workflow and no pull request.

## Sequence

1. **Flake inputs.** `nix flake update` runs for every input, then every
   machine's `system.build.toplevel.drvPath` is evaluated. The lock is
   committed as `flake: update`; a failed evaluation reverts it and stops.
2. **Package updates.** Every exported package with `passthru.update` metadata
   is updated. Nothing is committed yet. An update command that fails before
   changing the version is treated as a blocking update failure.
3. **Build.** Every updated package is built, with its
   `passthru.update.verify` targets. A build failure is recorded in
   `failures.json` and marks the pin in `updates.json`.
4. **Clean update commits.** Each package that built is committed separately:

   ```
   strata: update 1.0.0 -> 1.1.0
   ```

   The commit after those is recorded as `clean-tip`.
5. **Failed pins.** The version/hash changes for packages that need repair are
   committed separately on top of `clean-tip`, with the same
   `<label>: update <old> -> <new>` message.
6. **Repair.** The first omp agent reads the failure logs and package
   expressions, adapts the local patches and substitutions, and rebuilds every
   failed package. It has no git credentials and cannot commit.
7. **Final build.** Every updated package is built again from the final
   working tree, including its verify targets. The result is written to
   `.ci/build-summary.json`.
8. **Review.** If the repair changed files, a second, independent omp agent
   reviews the repair diff, the update manifest, the repair report, and the
   final build. It writes `.review/verdict.json` with:

   ```json
   {
     "approve": true,
     "summary": "...",
     "security_findings": []
   }
   ```

   Any security finding forces a rejection. The workflow also checks the
   verdict and rejects a non-empty `security_findings` before committing.
9. **Repair commit.** The repair is committed separately:

   ```
   packages: adapt updates (strata)
   ```
10. **Publish.** All commits are pushed to `main`.

If the initial build does not complete, an update command fails, or any of the
repair, final build, review, or commit steps fails, the workflow resets to
`clean-tip`. The failed pins and repair changes are dropped, the clean update
commits still land, and the run fails. A package that cannot be repaired
therefore keeps its previous version on `main`.

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

Both agents use omp's built-in DeepSeek provider and the model named
"DeepSeek V4.1 Flash 1017", selected as `deepseek/deepseek-flash`. omp reads
the key from `DEEPSEEK_API_KEY`; the workflow maps the repository secret of
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
python3 scripts/commit-updates.py --phase clean --report .update-agent/updates.json
git rev-parse HEAD > .update-agent/clean-tip
python3 scripts/commit-updates.py --phase failed --report .update-agent/updates.json

omp=$(nix build --no-link --print-out-paths .#omp)
DEEPSEEK_API_KEY=... python3 scripts/repair-updates.py --omp "$omp/bin/omp"
python3 scripts/verify-packages.py --updates .update-agent/updates.json --log-dir .ci
python3 scripts/review-updates.py \
  --base "$(cat .update-agent/clean-tip)" --log-dir .review --omp "$omp/bin/omp"
python3 scripts/commit-updates.py --phase repair --report .update-agent/updates.json
```

`repair-updates.py` and `review-updates.py` support `--dry-run`, which writes
the prompt and prints the command without calling the agent.
