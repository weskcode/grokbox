#!/bin/bash
# Swap the app icon to another candidate, then rebuild.
#   ./design/swap-icon.sh 05-monogram
set -e
[ -z "$1" ] && { echo "usage: $0 <candidate>   (see design/icon-candidates/)"; exit 1; }
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MASTER="$ROOT/design/icon-candidates/$1.png"
[ -f "$MASTER" ] || { echo "no such candidate: $1"; ls "$ROOT/design/icon-candidates"; exit 1; }
SET="$ROOT/Grokbox/Assets.xcassets/AppIcon.appiconset"
find "$SET" -name '*.png' -delete
for px in 16 32 64 128 256 512 1024; do
  sips -z $px $px "$MASTER" --out "$SET/icon_${px}.png" >/dev/null
done
echo "icon set to $1 — rebuild to see it"
