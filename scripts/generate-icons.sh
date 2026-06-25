#!/usr/bin/env bash
# Renders images/icon.svg into the macOS AppIcon set.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SVG="$ROOT/images/icon.svg"
SET="$ROOT/SSH Drop/Assets.xcassets/AppIcon.appiconset"

[ -f "$SVG" ] || { echo "missing $SVG" >&2; exit 1; }
[ -d "$SET" ] || { echo "missing $SET" >&2; exit 1; }

if command -v rsvg-convert >/dev/null 2>&1; then
  render() { rsvg-convert -w "$1" -h "$1" "$SVG" -o "$2" >/dev/null; }
elif command -v cairosvg >/dev/null 2>&1; then
  render() { cairosvg "$SVG" -W "$1" -H "$1" -o "$2" >/dev/null; }
elif command -v inkscape >/dev/null 2>&1; then
  render() { inkscape "$SVG" -w "$1" -h "$1" -o "$2" >/dev/null 2>&1; }
else
  echo "need rsvg-convert, cairosvg, or inkscape (brew install librsvg)" >&2
  exit 1
fi

# size scale pixels
entries=(
  "16 1 16"   "16 2 32"
  "32 1 32"   "32 2 64"
  "128 1 128" "128 2 256"
  "256 1 256" "256 2 512"
  "512 1 512" "512 2 1024"
)

rm -f "$SET"/icon_*.png

{
  echo '{'
  echo '  "images" : ['
  first=1
  for e in "${entries[@]}"; do
    # shellcheck disable=SC2086
    set -- $e; size=$1; scale=$2; px=$3
    file="icon_${size}x${size}@${scale}x.png"
    render "$px" "$SET/$file"
    [ "$first" -eq 0 ] && echo '    },'
    first=0
    echo '    {'
    echo "      \"filename\" : \"$file\","
    echo '      "idiom" : "mac",'
    echo "      \"scale\" : \"${scale}x\","
    echo "      \"size\" : \"${size}x${size}\""
  done
  echo '    }'
  echo '  ],'
  echo '  "info" : {'
  echo '    "author" : "xcode",'
  echo '    "version" : 1'
  echo '  }'
  echo '}'
} > "$SET/Contents.json"

echo "generated ${#entries[@]} icons in $SET"
