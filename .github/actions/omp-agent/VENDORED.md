# Vendored: omp-agent

`omp_agent.py`, `action.sh` and `action.yml` here are byte-identical copies of
the `omp-agent` repository (`~/Projects/omp-agent` on the maintainer's machine),
which is the canonical source. `README.upstream.md` is that repository's README,
also byte-identical.

They are vendored because the workflow calls the action as a *local* action
(`uses: ./.github/actions/omp-agent`): the self-hosted update runner must not
depend on a repository reference that does not exist yet. Publishing
`omp-agent` to GitHub is what removes this copy.

## When `omp-agent` is published

1. Delete this directory.
2. In `.github/workflows/update-packages.yml`, replace the three
   `uses: ./.github/actions/omp-agent` lines with
   `uses: pelikanade/omp-agent@v1`.
3. Update the "Repair failed updates" note in `docs/updates.md`.

Nothing else changes: the local action and the published one are the same
files, so the inputs and outputs stay as they are.

## Keeping the copy honest

The copies are here verbatim, so a difference is a sync that was missed:

```sh
diff ~/Projects/omp-agent/omp_agent.py .github/actions/omp-agent/omp_agent.py
diff ~/Projects/omp-agent/action.sh .github/actions/omp-agent/action.sh
diff ~/Projects/omp-agent/action.yml .github/actions/omp-agent/action.yml
diff ~/Projects/omp-agent/README.md .github/actions/omp-agent/README.upstream.md
```

`python3 -m unittest discover -s tests` in the `omp-agent` repository is the
test suite for these files; the workflow's own exercise of them is the nightly
update run itself.
