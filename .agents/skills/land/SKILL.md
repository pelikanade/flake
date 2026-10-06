---
name: land
description: >-
  Land changes in pelikanade/flake on origin/main with linear history.
  Invoke only when the user explicitly requests landing, including /land,
  not for review, preparation, passing checks, or skill installation.
disable-model-invocation: true
metadata:
  delta-action: land
---

# Land changes

An explicit landing request authorizes this workflow, including its normal
push to `origin/main`. Proceed without asking for the same permission again.
Installation of this skill alone does not authorize landing.

## Establish scope and destination

1. Read applicable repository guidance and inspect the working tree, current
   branch, recent commits, and configured remotes. Identify the requested
   changes, including any intended uncommitted work. Preserve unrelated work;
   pause if its separation is ambiguous.
2. Verify that `origin` identifies `pelikanade/flake` on GitHub and the intended
   destination remains `main`. Use the authenticated `gh` CLI to inspect branch
   protections, applicable rulesets, required checks, and review requirements.
   Missing access or unverifiable requirements are blockers, not permission to
   assume there are none. If requirements now prevent direct push, report the
   blocker rather than bypassing them or inventing a PR workflow.
3. Inspect tools and authentication without printing credentials. Repository
   tools run through `nix develop`; if required tools are missing, ask the user
   to activate the development environment. Preserve configured commit signing.
   Stop on signing failure rather than disabling it.

`origin/main` is the publication destination. Never push through the `local`
remote or edit another checkout to accomplish landing.

## Prepare a linear candidate

1. Stage only intended files, including new files needed for Nix evaluation.
   Complete necessary preparation and commit logical changes separately using
   concise, lowercase, imperative `<scope>: <description>` subjects. Inspect
   the staged diff before committing. Honor applicable contribution requirements
   and permissions from `AGENTS.md`; use `GIT_EDITOR=true` for commits and other
   editor-capable Git commands.
2. Fetch `main` from `origin` and record its exact tip. Create a uniquely named
   local landing branch from that tip. Keep the original source branch intact.
   Determine the requested source-only commits from their ancestry and the
   request, excluding unrelated or already-landed changes.
3. Replay those commits in order using non-interactive cherry-picks onto the
   landing branch. This creates a linear candidate without rewriting the source
   branch or any published history. If the source contains merge commits, pause
   to establish the intended linear patch sequence rather than guessing a
   mainline parent or copying a merge commit.
4. Resolve replay conflicts automatically when the intended result is clear.
   Preserve both the requested behavior and unrelated destination changes.
   Stage resolutions and continue with `GIT_EDITOR=true git cherry-pick --continue`.
   Pause and explain genuinely ambiguous conflicts or unsafe changes.
5. Inspect the complete candidate diff against the recorded destination tip.
   Confirm that only the requested changes remain and that the new commit range
   contains no merge commits. Run verification on this candidate, not merely
   on the source branch before replay.

Use a clean attached workspace for replay. If unrelated dirty work prevents
switching branches, pause rather than discarding, committing, or automatically
stashing it.

## Verify before publishing

Choose checks proportionate to the actual diff, as required by `AGENTS.md`.
Inspect current definitions before selecting additional targets; the following
commands are tied to their repository sources:

- For Nix changes, run
  `nix develop -c nix build --no-link .#checks.x86_64-linux.pre-commit-check`.
  This builds the configured nixfmt/statix check
  (`modules/dev-shell.nix`, `checks.pre-commit-check`). Its source is scoped
  to that module directory, so also run
  `nix develop -c pre-commit run --files <changed-nix-files>` for changed Nix
  files elsewhere, using explicit paths. Hook definitions and development-shell
  hook installation are in `modules/dev-shell.nix`.
- For machine composition or shared configuration changes, run
  `nix develop -c nix build --no-link .#checks.x86_64-linux.nixos-configurations-import-base`
  (`modules/checks.nix`, `checks.nixos-configurations-import-base`).
  Select further affected configuration builds from their current definitions;
  do not substitute a successful package build for configuration validation.
- For Magpie package changes, run
  `nix develop -c nix build --no-link .#magpie`.
  The output and its upstream build/install checks are defined in
  `modules/packages/magpie.nix`, `perSystem.packages.magpie`.
  For other packages, verify their actual output definitions before selecting
  the equivalent build target.
- Documentation-only changes need document and skill validation rather than
  Nix builds. Check links, applicability, source references, and skill
  frontmatter. A newly created Land skill must have
  `metadata.delta-action: land` and `disable-model-invocation: true`.
- Run `git diff --check` for pending changes and
  `git diff --check <recorded-destination-tip> HEAD` for the full landing diff.

Review the change against the request and applicable repository policies.
Keep fixes within scope; after any fix or conflict resolution, rerun affected
checks on the resulting candidate. Do not disable checks to make landing pass.
Required checks must all have passed for the candidate being published.
Pending, failing, missing, or unverifiable required checks block landing.
If destination rules require remote checks or reviews that cannot be satisfied
by this direct-push workflow, stop and report that the changes have not landed.

Record actual verification results and any outstanding manual or hardware
verification. Builds do not prove desktop behavior or hardware operation.
Do not present earlier verification of a different candidate as current evidence.

## Publish and confirm

1. Recheck the remote destination tip and applicable requirements before pushing.
   If `origin/main` advanced, fetch it, rebuild the linear candidate on its new
   tip, and repeat affected verification. Never force-push to overcome a race.
2. Once all requirements pass, publish with
   `git push origin HEAD:refs/heads/main`. A non-fast-forward rejection means
   the candidate must be updated and checked again, not that force is allowed.
3. Read the remote `main` tip back from GitHub. Confirm that the published
   candidate is the tip or an ancestor of it if another change has already
   followed. Verify that the requested commits are present at the destination.
   A local commit, published topic branch, or successful check alone is not
   successful landing.
4. Report the destination, landed commit IDs, checks performed, and remaining
   manual verification. On any blocker, explicitly report that the changes
   have not landed. Preserve source branches and unrelated work; avoid automatic
   branch deletion or cleanup that could discard useful state.

Landing does not authorize deployment, privileged commands, secret rewrites,
garbage collection, or destructive operations. Follow the separate permission
gates in `AGENTS.md` and inspect any `Justfile` recipe before invoking it.
