#!/usr/bin/env bash
# Regenerate the Frogmouth reference renderings under test/reference/.
#
# Requires: frogmouth installed as a uv tool (uv tool install frogmouth),
# rsvg-convert (brew install librsvg) for PNGs, and uv for the crop step.
#
# Usage: scripts/frogmouth-reference.sh [FIXTURE.md] [COLUMNS] [ROWS]
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
fixture=${1:-$here/test/fixtures/showcase.md}
cols=${2:-110}
rows=${3:-230}
out=$here/test/reference
name=$(basename "$fixture" .md)
py=$HOME/.local/share/uv/tools/frogmouth/bin/python
[ -x "$py" ] || { echo "frogmouth uv tool not found at $py" >&2; exit 1; }
mkdir -p "$out" /tmp/frogshots
for theme in dark light; do
  "$py" -I "$here/scripts/frogmouth-shot.py" "$fixture" "$out/$name-$theme.svg" "$cols" "$rows" "$theme"
  if command -v rsvg-convert >/dev/null; then
    rsvg-convert "$out/$name-$theme.svg" -o "/tmp/frogshots/$name-$theme.png"
    # PNG chunks small enough to view: /tmp/frogshots/<name>-<theme>-N.png
    uv run --quiet --with pillow python -I "$here/scripts/crop-png.py" \
      "/tmp/frogshots/$name-$theme.png" "/tmp/frogshots/$name-$theme" 1140 || true
  fi
done
python3 -I "$here/scripts/svg-to-text.py" "$out/$name-dark.svg" > "$out/$name.frogmouth.txt"
echo "wrote $out/$name-{dark,light}.svg and $out/$name.frogmouth.txt; PNGs in /tmp/frogshots"
