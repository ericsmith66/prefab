#!/bin/sh
# FR-A1: writes prefab/PrefabBuildInfo.plist (GitSHA, GitDirty, BuiltAt) before Copy Bundle Resources ships it.
# GitDirty is captured BEFORE the plist is written; the plist is gitignored so it never dirties the tree.
set -eu
ROOT="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
SHA="$(git -C "$ROOT" rev-parse HEAD)"
if [ -z "$(git -C "$ROOT" status --porcelain)" ]; then DIRTY=false; else DIRTY=true; fi
BUILT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
OUT="$ROOT/prefab/PrefabBuildInfo.plist"
cat > "$OUT" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
	<key>GitSHA</key><string>$SHA</string>
	<key>GitDirty</key><$DIRTY/>
	<key>BuiltAt</key><string>$BUILT</string>
</dict></plist>
EOF
echo "PrefabBuildInfo: $SHA dirty=$DIRTY $BUILT"
