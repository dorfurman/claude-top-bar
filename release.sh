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

# Notarize when the one-time setup exists (Developer ID cert + notary profile);
# without it, ship unsigned-for-Gatekeeper and say so. Setup:
#   xcrun notarytool store-credentials crabbar --apple-id <you> --team-id <TEAM> --password <app-specific>
# -dvv, not -dv: the Authority lines only print at the second verbosity level, so -dv never
# matches and silently skips notarization (shipped unnotarized through v2.0.2 that way).
if codesign -dvv CrabBar.app 2>&1 | grep -q "Authority=Developer ID Application" \
   && xcrun notarytool history --keychain-profile crabbar >/dev/null 2>&1; then
  echo "notarizing (takes a few minutes)…"
  xcrun notarytool submit "$ZIP" --keychain-profile crabbar --wait | grep -q "status: Accepted" \
    || { echo "notarization failed — check: xcrun notarytool log <id> --keychain-profile crabbar"; exit 1; }
  # staple the ticket into the app so it opens offline, then re-zip the stapled app
  xcrun stapler staple CrabBar.app >/dev/null
  rm "$ZIP"; ditto -c -k --keepParent CrabBar.app "$ZIP"
else
  echo "warning: not notarized — Gatekeeper will block this zip on other Macs (see comment above)"
fi

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
