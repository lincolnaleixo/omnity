#!/bin/sh
# Omnity: build and publish a GitHub release for every new commit of
# feat/remote-drop. Omnity installs new releases by itself (OmnityUpdater).
#
# Run every 10 minutes by launchd on robots-mac-server
# (~/Library/LaunchAgents/com.lincolnaleixo.omnity-release.plist),
# logging to ~/Library/Logs/omnity-release.log.
set -eu
cd "$(dirname "$0")"
export PATH="/opt/homebrew/bin:$PATH"
repo=lincolnaleixo/omnity
branch=feat/remote-drop

lock=/tmp/omnity-release.lock
mkdir "$lock" 2>/dev/null || exit 0
trap 'rmdir "$lock"' EXIT

git fetch -q origin "$branch"
head=$(git rev-parse --short "origin/$branch")
last=$(gh release view --repo "$repo" --json tagName --jq .tagName 2>/dev/null || true)
case "$last" in *-"$head") exit 0 ;; esac

# Never release uncommitted work in progress; try again next round.
if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "$(date): working tree has changes, skipping"
    exit 0
fi
git merge -q --ff-only "origin/$branch"

tag="v$(date -u +%Y%m%d%H%M)-$head"
echo "$(date): building $tag"
OMNITY_RELEASE="$tag" ./omnity-build.sh
rm -f zig-out/Omnity.zip
ditto -c -k --keepParent zig-out/Omnity.app zig-out/Omnity.zip
gh release create "$tag" zig-out/Omnity.zip --repo "$repo" \
    --target "$(git rev-parse HEAD)" --title "Omnity $tag" --notes "$(git log -1 --format=%s)"

# Keep the newest 5 releases.
gh release list --repo "$repo" --limit 100 --json tagName --jq '.[5:][].tagName' |
    while read -r old; do gh release delete "$old" --repo "$repo" --yes --cleanup-tag; done
echo "$(date): released $tag"
