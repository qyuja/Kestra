#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

usage() {
  cat <<'EOF'
Usage:
  ./script/push_release.sh [--dry-run] <version>

Examples:
  ./script/push_release.sh 0.1.14
  ./script/push_release.sh --dry-run v0.1.14

The working tree must be clean. The script runs the local checks, pushes the
current branch, then pushes an annotated v* tag to trigger GitHub Actions.
Set PUSH_RELEASE_REMOTE to use a remote other than origin.
EOF
}

dry_run=false
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi
if [[ "${1:-}" == "--dry-run" ]]; then
  dry_run=true
  shift
fi

version="${1:-}"
if [[ -z "$version" ]]; then
  if [[ -t 0 ]]; then
    read -r -p "Release version (for example 0.1.14): " version
  else
    usage >&2
    exit 2
  fi
fi
if [[ -z "$version" ]]; then
  echo "Release version cannot be empty." >&2
  exit 2
fi
if [[ "$version" != v* ]]; then
  version="v$version"
fi
if ! [[ "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]]; then
  echo "Release version must use semver, for example 0.1.14 or v0.1.14." >&2
  exit 2
fi

remote="${PUSH_RELEASE_REMOTE:-origin}"
branch="$(git branch --show-current)"
if [[ -z "$branch" ]]; then
  echo "Cannot release from a detached HEAD; check out a branch first." >&2
  exit 1
fi
git remote get-url "$remote" >/dev/null

if ! git diff --quiet || ! git diff --cached --quiet || [[ -n "$(git ls-files --others --exclude-standard)" ]]; then
  echo "Working tree is not clean. Commit the intended changes before releasing." >&2
  git status --short >&2
  exit 1
fi

if git ls-remote --exit-code --refs "$remote" "refs/tags/$version" >/dev/null 2>&1; then
  echo "Remote tag $version already exists; refusing to overwrite it." >&2
  exit 1
fi

echo "Running Swift tests..."
swift test
echo "Running protocol adapter tests..."
node script/test_pi.mjs
node script/test_opencode.mjs
git diff --check

if [[ "$dry_run" == true ]]; then
  echo "Dry run: checking branch push without creating or pushing $version..."
  git push --dry-run "$remote" "HEAD:$branch"
  echo "Dry run passed for $branch -> $remote; tag $version was not created."
  exit 0
fi

echo "Pushing $branch to $remote..."
git push "$remote" "HEAD:$branch"

if existing_tag_commit="$(git rev-parse --verify --quiet "refs/tags/$version^{commit}")"; then
  current_commit="$(git rev-parse HEAD)"
  if [[ "$existing_tag_commit" != "$current_commit" ]]; then
    echo "Local tag $version points to $existing_tag_commit, not HEAD $current_commit." >&2
    exit 1
  fi
  echo "Reusing existing local tag $version at HEAD."
else
  git tag -a "$version" -m "Release $version"
fi

echo "Pushing $version to $remote..."
git push "$remote" "$version"
echo "Release $version pushed. GitHub Actions will build and publish the DMG."
