#!/bin/bash
set -e
cd "$(dirname "$0")"

# usage: ./release.sh [major|minor|patch]   (default: patch)
# Bumps VERSION, builds + tests, tags, and publishes a GitHub release with the
# zipped app. The in-app update check reads the latest release of this repo,
# which must stay PUBLIC for the unauthenticated API call to work.

[ -z "$(git status --porcelain 2>/dev/null)" ] || { echo "commit or stash your changes first"; exit 1; }

IFS=. read -r MA MI PA < VERSION
case "${1:-patch}" in
  major) MA=$((MA+1)); MI=0; PA=0 ;;
  minor) MI=$((MI+1)); PA=0 ;;
  patch) PA=$((PA+1)) ;;
  *) echo "usage: ./release.sh [major|minor|patch]"; exit 1 ;;
esac
V="$MA.$MI.$PA"
echo "$V" > VERSION

./build.sh   # runs --test; a failing self-test aborts the release here

ZIP="CrabBar-$V.zip"
ditto -c -k --keepParent CrabBar.app "$ZIP"

git add VERSION
git commit -m "release v$V"
git tag "v$V"

# first release: create the (public) repo the in-app update check points at
gh repo view dorfurman/claude-top-bar >/dev/null 2>&1 \
  || gh repo create dorfurman/claude-top-bar --public --source=. --remote=origin
git push origin HEAD "v$V"

gh release create "v$V" "$ZIP" --title "CrabBar $V" --generate-notes
rm "$ZIP"
echo "released v$V"
