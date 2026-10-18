#!/usr/bin/env bash
set -euo pipefail

# Export GITHUB_PAT (a GitHub personal access token) to authenticate GitHub
# REST / raw requests and `git ls-remote`. GITHUB_TOKEN is honoured as fallback.
gh_auth=()
gh_git_auth=()
if [ -n "${GITHUB_PAT:-}" ] || [ -n "${GITHUB_TOKEN:-}" ]; then
  gh_token="${GITHUB_PAT:-${GITHUB_TOKEN:-}}"
  gh_auth=(-H "Authorization: Bearer $gh_token")
  # GitHub's git smart-HTTP endpoint (info/refs) rejects "Authorization: Bearer"
  # with 401 even for a valid PAT; it only accepts Basic auth with the PAT as
  # the password. Scope the header to github.com so it is never sent elsewhere.
  gh_git_auth=(-c "http.https://github.com/.extraHeader=Authorization: Basic $(printf 'x-access-token:%s' "$gh_token" | base64 | tr -d '\n')")
fi

# Update script for the `deepseek-harness-git` (dsh, built from git release
# tags) package. Copied from Mooling0602/nix-packages (pkgs/by-name/de/
# deepseek-harness-git) by Mooling0602: https://github.com/Mooling0602/nix-packages

usage() {
  echo "Usage: $(basename "$0") [version]" >&2
  echo "       $(basename "$0") -f|--force <version>" >&2
}

force=false
repo_url="https://github.com/deepseek-ai/deepseek-harness"

latest_tag() {
  local tags
  tags="$(mktemp)"
  git "${gh_git_auth[@]}" ls-remote --tags "$repo_url" 'refs/tags/dsh-v*' > "$tags"
  local best_tag
  best_tag="$(grep -v '\^{}$' "$tags" | awk '{print substr($2, 11)}' | sort -V | tail -1)"
  if [ -z "$best_tag" ]; then
    rm -f "$tags"
    return 1
  fi
  # Prefer the peeled ^{} line so annotated tags yield the commit hash.
  local rev
  rev="$(awk -v t="refs/tags/$best_tag^{}" '$2 == t { print $1 }' "$tags")"
  [ -n "$rev" ] || rev="$(awk -v t="refs/tags/$best_tag" '$2 == t { print $1 }' "$tags")"
  rm -f "$tags"
  echo "${best_tag#dsh-v} $rev"
}

resolve_tag() {
  local want="$1" out rev
  out="$(git "${gh_git_auth[@]}" ls-remote "$repo_url" "refs/tags/dsh-v$want^{}" "refs/tags/dsh-v$want" || true)"
  rev="$(printf '%s\n' "$out" | awk '$2 ~ /\^/ { print $1; exit }')"
  [ -n "$rev" ] || rev="$(printf '%s\n' "$out" | awk '$2 !~ /\^/ { print $1; exit }')"
  [ -n "$rev" ] || return 1
  echo "$rev"
}

case "$#" in
  0)
    entry="$(latest_tag)" || { echo "Error: no dsh-v* tags found" >&2; exit 1; }
    version="${entry%% *}"
    ;;
  1)
    case "$1" in
      -f|--force)
        usage
        exit 1
        ;;
      *)
        version="$1"
        ;;
    esac
    ;;
  2)
    case "$1" in
      -f|--force)
        force=true
        version="$2"
        ;;
      *)
        usage
        exit 1
        ;;
    esac
    ;;
  *)
    usage
    exit 1
    ;;
esac

case "$version" in
  ''|*[!0-9A-Za-z._-]*)
    echo "Error: version must only contain letters, numbers, dots, underscores, or hyphens" >&2
    exit 1
    ;;
esac

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
hashes_json="$script_dir/hashes.json"
current_version="$(sed -n 's/.*"version": *"\([^"]*\)",/\1/p' "$hashes_json")"
repo_root="$(cd -- "$script_dir" && git rev-parse --show-toplevel 2>/dev/null || echo "$script_dir/../../..")"

if [ "$force" = false ] && [ "$current_version" = "$version" ]; then
  echo "deepseek-harness-git is already at $version"
  exit 0
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

echo "Resolving tag dsh-v$version..."
rev="$(resolve_tag "$version" || true)"
if [ -z "$rev" ]; then
  echo "Error: tag dsh-v$version not found in $repo_url" >&2
  exit 1
fi
echo "rev: $rev"

echo "Prefetching source tarball hash..."
# --unpack: package.nix fetches the source via fetchFromGitHub, which hashes the
# UNPACKED source tree (a nar hash), not the raw tar.gz bytes. Without
# --unpack the prefetched hash would never match the build.
src_hash="$(nix --extra-experimental-features 'nix-command flakes' store prefetch-file --unpack --json \
    "https://codeload.github.com/deepseek-ai/deepseek-harness/tar.gz/$rev" \
    | sed -n 's/.*"hash": *"\([^"]*\)".*/\1/p')"
if [ -z "$src_hash" ]; then
  echo "Error: failed to extract srcHash" >&2
  exit 1
fi

pnpm_version="$(sed -n 's/.*"pnpmVersion": *"\([^"]*\)".*/\1/p' "$hashes_json")"
upstream_pnpm="$(curl -fsSL "${gh_auth[@]}" "https://raw.githubusercontent.com/deepseek-ai/deepseek-harness/$rev/package.json" \
    | sed -n 's/.*"packageManager": *"pnpm@\([^"]*\)".*/\1/p')"
if [ -z "$upstream_pnpm" ]; then
  echo "Error: could not read packageManager from upstream package.json" >&2
  exit 1
fi
if [ "$upstream_pnpm" != "$pnpm_version" ]; then
  echo "Upstream pinned pnpm changed: $pnpm_version -> $upstream_pnpm; prefetching new hash..."
  pnpm_hash="$(nix --extra-experimental-features 'nix-command flakes' store prefetch-file --json \
      "https://registry.npmjs.org/pnpm/-/pnpm-$upstream_pnpm.tgz" \
      | sed -n 's/.*"hash": *"\([^"]*\)".*/\1/p')"
  if [ -z "$pnpm_hash" ]; then
    echo "Error: failed to prefetch pnpm-$upstream_pnpm.tgz" >&2
    exit 1
  fi
  pnpm_version="$upstream_pnpm"
else
  pnpm_hash="$(sed -n 's/.*"pnpmHash": *"\([^"]*\)".*/\1/p' "$hashes_json")"
fi

echo "Syncing pnpm-lock.yaml from upstream..."
curl -fsSL "${gh_auth[@]}" "https://raw.githubusercontent.com/deepseek-ai/deepseek-harness/$rev/pnpm-lock.yaml" \
    > "$script_dir/pnpm-lock.yaml"

cat > "$hashes_json" <<EOF
{
  "version": "$version",
  "rev": "$rev",
  "srcHash": "$src_hash",
  "pnpmVersion": "$pnpm_version",
  "pnpmHash": "$pnpm_hash"
}
EOF

echo "Updated deepseek-harness-git to $version ($rev)"
echo "srcHash: $src_hash"
echo "pnpm-lock.yaml synced from upstream"
echo
echo "Build with: nix build '.#deepseek-harness-git'"
