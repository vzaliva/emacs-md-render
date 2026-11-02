#!/usr/bin/env bash
# Render an ANSI-coloured text capture (e.g. from tmux capture-pane -e) to PNG
# so it can be inspected visually.  Uses Rich via uv, then rsvg-convert.
# Usage: scripts/ansi-to-png.sh IN.ansi OUT.png [COLUMNS]
set -euo pipefail
in=$1; out=$2; cols=${3:-110}
svg=${out%.png}.svg
uv run --quiet --with rich python -I - "$in" "$svg" "$cols" <<'PY'
import re
import sys
from rich.console import Console
from rich.terminal_theme import TerminalTheme
from rich.text import Text
src, dst, cols = sys.argv[1], sys.argv[2], int(sys.argv[3])
data = open(src, encoding="utf-8", errors="replace").read()
# Cells in the default face carry no colour of their own, so the page colour
# must come from Emacs: scripts/tmux-shot.sh records it next to the capture
# (IN.colors).  Without that file Emacs is assumed to paint its default face
# with the terminal's ANSI black (dark themes) or white (light themes); give
# those exact colours so padding and the frame background match the real
# terminal instead of Rich's grey theme colours.
import os
def hexrgb(text):
    ok = len(text) == 7 and text[0] == "#"
    return tuple(int(text[i:i + 2], 16) for i in (1, 3, 5)) if ok else None
dark = (data.count("[40m") + data.count("48;2;0;0;0m")
        >= data.count("[47m") + data.count("[107m") + data.count("48;2;255;255;255m"))
page = (0, 0, 0) if dark else (255, 255, 255)
text = (255, 255, 255) if dark else (0, 0, 0)
colors = os.path.splitext(src)[0] + ".colors"
if os.path.exists(colors):
    recorded = open(colors).read().split()
    if len(recorded) == 2:
        page = hexrgb(recorded[0]) or page
        text = hexrgb(recorded[1]) or text
theme = TerminalTheme(
    page,
    text,
    [(0, 0, 0), (205, 0, 0), (0, 205, 0), (205, 205, 0),
     (0, 0, 238), (205, 0, 205), (0, 205, 205), (229, 229, 229)],
    [(127, 127, 127), (255, 0, 0), (0, 255, 0), (255, 255, 0),
     (92, 92, 255), (255, 0, 255), (0, 255, 255), (255, 255, 255)])
console = Console(record=True, width=cols, file=open("/dev/null", "w"), force_terminal=True, color_system="truecolor")
console.print(Text.from_ansi(data), end="", no_wrap=True, overflow="ignore", crop=False)
console.save_svg(dst, title="mdview", theme=theme)
# Rich writes spaces as &#160;, which rsvg-convert advances with a fallback
# font of a different width, shifting text off the grid; plain spaces with
# xml:space="preserve" keep the terminal's column positions.
svg = open(dst, encoding="utf-8").read()
svg = svg.replace("&#160;", " ")
svg = re.sub(r"<text ", '<text xml:space="preserve" ', svg)
open(dst, "w", encoding="utf-8").write(svg)
PY
rsvg-convert "$svg" -o "$out"
echo "wrote $out"
