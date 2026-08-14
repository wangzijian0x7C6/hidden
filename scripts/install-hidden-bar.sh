#!/usr/bin/env bash
# Replace /Applications/Hidden Bar.app, then reset TCC so the new ad hoc
# signature can prompt again. Pass a .app, a .zip, or nothing to download
# the latest green CI artifact for this branch.
set -euo pipefail

BUNDLE_ID="com.dwarvesv.minimalbar"
DEST="/Applications/Hidden Bar.app"
ARTIFACT="${HIDDEN_BAR_ARTIFACT:-Hidden-Bar-icon-manager}"
source="${1:-}"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

if [[ -z "$source" ]]; then
  branch=$(git rev-parse --abbrev-ref HEAD)
  run_id=$(gh run list --branch "$branch" --status success --limit 1 --json databaseId --jq '.[0].databaseId')
  [[ -n "$run_id" ]] || { echo "no successful CI run on $branch" >&2; exit 1; }
  gh run download "$run_id" --name "$ARTIFACT" --dir "$work"
  source=$(find "$work" -name '*.zip' | head -1)
fi

if [[ "$source" == *.zip ]]; then
  unzip -qo "$source" -d "$work/unpacked"
  source=$(find "$work/unpacked" -name 'Hidden Bar.app' | head -1)
fi

[[ -d "$source" ]] || { echo "app not found: $source" >&2; exit 1; }

osascript -e 'tell application "Hidden Bar" to quit' >/dev/null 2>&1 || true
killall "Hidden Bar" >/dev/null 2>&1 || true
sleep 0.4
rm -rf "$DEST"
ditto "$source" "$DEST"
xattr -cr "$DEST"
tccutil reset ScreenCapture "$BUNDLE_ID"
tccutil reset Accessibility "$BUNDLE_ID"
open "$DEST"
echo "installed $DEST"
