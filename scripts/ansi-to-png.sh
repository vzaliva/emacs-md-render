#!/usr/bin/env bash
# Render an ANSI-coloured text capture (e.g. from tmux capture-pane -e) to PNG
# so it can be inspected visually.  Uses Rich via uv, then rsvg-convert.
# Usage: scripts/ansi-to-png.sh IN.ansi OUT.png [COLUMNS]
set -euo pipefail
in=$1; out=$2; cols=${3:-110}
svg=${out%.png}.svg
uv run --quiet --with rich python -I - "$in" "$svg" "$cols" <<'PY'
import sys
from rich.console import Console
from rich.text import Text
src, dst, cols = sys.argv[1], sys.argv[2], int(sys.argv[3])
data = open(src, encoding="utf-8", errors="replace").read()
console = Console(record=True, width=cols, file=open("/dev/null", "w"), force_terminal=True, color_system="truecolor")
console.print(Text.from_ansi(data), end="")
console.save_svg(dst, title="mdview")
PY
rsvg-convert "$svg" -o "$out"
echo "wrote $out"
