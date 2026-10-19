#!/usr/bin/env bash
# Update the tools this repository packages itself and the flake inputs that
# track upstream projects. The scheduled GitHub Actions workflow runs this with
# --build --commit; interactively, run it from `nix develop`, inspect the diff,
# and commit selectively.
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: scripts/update-packages.sh [--build] [--commit] [package...]

Packages: dsh, magpie, strata, herdr-reviewr, paseo, omp, llm-agents, noctalia

Without package arguments every package is updated.

  --build   Build each locally packaged tool after updating it.
  --commit  Commit each successful update with a conventional message.
EOF
}

build=false
commit=false
requested=()
while (($#)); do
  case "$1" in
    --build) build=true ;;
    --commit) commit=true ;;
    -h | --help)
      usage
      exit 0
      ;;
    -*)
      echo "error: unknown option: $1" >&2
      usage
      exit 2
      ;;
    *) requested+=("$1") ;;
  esac
  shift
done

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

if ((${#requested[@]} == 0)); then
  requested=(dsh magpie strata herdr-reviewr paseo omp llm-agents noctalia)
fi

failed=()
updated=()

say() { printf '\n==> %s\n' "$*"; }

# Refuse to touch a file with local edits: a failed update restores it with
# `git restore`, which would otherwise discard that work.
require_clean() {
  local path
  for path in "$@"; do
    if [ -n "$(git status --porcelain -- "$path")" ]; then
      echo "error: $path has uncommitted changes; refusing to update it" >&2
      return 1
    fi
  done
}

restore() {
  git restore --worktree -- "$@" 2>/dev/null || git checkout -- "$@"
}

require_nix_update() {
  if ! command -v nix-update >/dev/null 2>&1; then
    echo "error: nix-update not found; run inside nix develop or nix shell nixpkgs#nix-update" >&2
    return 1
  fi
  if ! command -v nixfmt >/dev/null 2>&1; then
    echo "error: nixfmt not found; run inside nix develop or nix shell nixpkgs#nixfmt-rfc-style" >&2
    return 1
  fi
}

current_version() {
  sed -n 's/^[[:space:]]*version = "\([^"]*\)";/\1/p' "$1" | head -n 1
}

current_json_version() {
  sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' "$1" | head -n 1
}

# Latest stable, three-component tag of a GitHub repository, without the `v`.
latest_stable_version() {
  local repo="$1"
  git ls-remote --tags "https://github.com/$repo" 'refs/tags/v*' |
    sed -e 's|.*refs/tags/v||' -e 's|\^{}$||' |
    grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' |
    sort -uV |
    tail -n 1
}

# Commit a tag resolves to. Annotated tags are peeled so `rev` stays a commit.
resolve_tag() {
  local repo="$1" tag="$2" refs rev
  refs="$(git ls-remote "https://github.com/$repo" "refs/tags/$tag^{}" "refs/tags/$tag")" || return 1
  rev="$(printf '%s\n' "$refs" | awk '$2 ~ /\^/ { print $1; exit }')"
  [ -n "$rev" ] || rev="$(printf '%s\n' "$refs" | awk '$2 !~ /\^/ { print $1; exit }')"
  [ -n "$rev" ] || return 1
  printf '%s\n' "$rev"
}

commit_changes() {
  local message="$1"
  shift
  if ! $commit; then
    return 0
  fi
  git add -- "$@"
  if git diff --cached --quiet; then
    return 0
  fi
  git commit -m "$message"
  updated+=("$message")
}

update_flake_inputs() {
  local inputs=("$@") message
  say "flake inputs: ${inputs[*]}"
  require_clean flake.lock || return 1
  nix flake update "${inputs[@]}"
  if git diff --quiet -- flake.lock; then
    echo "already current"
    return 0
  fi
  message="flake: update ${inputs[*]}"
  commit_changes "$message" flake.lock
  $commit || echo "updated flake.lock (not committed)"
}

update_dsh() {
  local dir=modules/packages/deepseek-harness-git old new
  require_clean "$dir/hashes.json" "$dir/pnpm-lock.yaml" || return 1
  old="$(current_json_version "$dir/hashes.json")"
  say "dsh ($old)"
  bash "$dir/update.sh"
  if git diff --quiet -- "$dir/hashes.json" "$dir/pnpm-lock.yaml"; then
    echo "already current"
    return 0
  fi
  new="$(current_json_version "$dir/hashes.json")"
  if $build && ! nix build .#deepseek-harness-git --no-link; then
    echo "error: dsh $new failed to build; reverting" >&2
    restore "$dir/hashes.json" "$dir/pnpm-lock.yaml"
    return 1
  fi
  commit_changes "dsh: update $old -> $new" "$dir/hashes.json" "$dir/pnpm-lock.yaml"
  $commit || echo "updated dsh to $new (not committed)"
}

update_magpie() {
  local file=modules/packages/magpie.nix old new
  require_clean "$file" || return 1
  require_nix_update || return 1
  old="$(current_version "$file")"
  say "magpie ($old)"
  if $build; then
    nix-update --flake --format --build magpie || {
      echo "error: magpie update or build failed; reverting" >&2
      restore "$file"
      return 1
    }
  else
    nix-update --flake --format magpie || {
      echo "error: magpie update failed; reverting" >&2
      restore "$file"
      return 1
    }
  fi
  if git diff --quiet -- "$file"; then
    echo "already current"
    return 0
  fi
  new="$(current_version "$file")"
  commit_changes "magpie: update $old -> $new" "$file"
  $commit || echo "updated magpie to $new (not committed)"
}

# Upstreams that pin `src.rev` to a commit cannot be updated by nix-update
# alone: it would change `version` while leaving the old revision in place.
# Resolve the release tag to a commit first, then let nix-update recompute the
# source and dependency hashes from that revision.
update_rev_package() {
  local attr="$1" file="$2" repo="$3" old new rev
  require_clean "$file" || return 1
  require_nix_update || return 1
  old="$(current_version "$file")"
  say "$attr ($old)"
  if ! new="$(latest_stable_version "$repo")" || [ -z "$new" ]; then
    echo "error: could not determine the latest stable tag of $repo" >&2
    return 1
  fi
  if [ "$new" = "$old" ]; then
    echo "already current"
    return 0
  fi
  if ! rev="$(resolve_tag "$repo" "v$new")"; then
    echo "error: could not resolve v$new in $repo" >&2
    return 1
  fi
  echo "updating $old -> $new ($rev)"
  sed -i -E "0,/^([[:space:]]*)version = \"[^\"]*\";/s//\1version = \"$new\";/" "$file"
  sed -i -E "0,/^([[:space:]]*)rev = \"[^\"]*\";/s//\1rev = \"$rev\";/" "$file"
  if ! grep -Fq "version = \"$new\";" "$file" || ! grep -Fq "rev = \"$rev\";" "$file"; then
    echo "error: could not pin $attr to $new in $file; reverting" >&2
    restore "$file"
    return 1
  fi
  if $build; then
    nix-update --flake --version=skip --format --build "$attr" || {
      echo "error: $attr $new failed to update or build; reverting" >&2
      restore "$file"
      return 1
    }
  else
    nix-update --flake --version=skip --format "$attr" || {
      echo "error: $attr $new failed to update; reverting" >&2
      restore "$file"
      return 1
    }
  fi
  commit_changes "$attr: update $old -> $new" "$file"
  $commit || echo "updated $attr to $new (not committed)"
}

run_update() {
  local name="$1"
  shift
  if ! "$@"; then
    failed+=("$name")
  fi
}

flake_inputs=()
for package in "${requested[@]}"; do
  case "$package" in
    paseo | omp | llm-agents | noctalia) flake_inputs+=("$package") ;;
    dsh) run_update dsh update_dsh ;;
    magpie) run_update magpie update_magpie ;;
    strata) run_update strata update_rev_package strata modules/packages/strata/default.nix lgse/strata ;;
    herdr-reviewr) run_update herdr-reviewr update_rev_package herdr-reviewr modules/packages/herdr-reviewr.nix persiyanov/herdr-reviewr ;;
    *)
      echo "error: unknown package: $package" >&2
      usage
      exit 2
      ;;
  esac
done
if ((${#flake_inputs[@]})); then
  run_update "flake inputs" update_flake_inputs "${flake_inputs[@]}"
fi

if ((${#updated[@]})); then
  printf '\nUpdated:\n'
  printf '  %s\n' "${updated[@]}"
fi
if ! $commit; then
  echo
  echo "Updates were left uncommitted; pass --commit to create commits."
fi
if ((${#failed[@]})); then
  printf '\nFailed:\n' >&2
  printf '  %s\n' "${failed[@]}" >&2
  exit 1
fi
