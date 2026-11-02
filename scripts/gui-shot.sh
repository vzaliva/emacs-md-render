#!/usr/bin/env bash
# Screenshot FILE rendered by mdview in a GRAPHICAL Emacs.  Emacs runs on a
# private X virtual framebuffer (xvfb-run picks a free display of its own, so
# neither the desktop nor the user's X server is ever touched) and only the
# Emacs frame window is captured.
#
# Usage: scripts/gui-shot.sh FILE OUT.png [COLUMNS] [ROWS] [THEME] [SECTION]
#   THEME    the name of any theme Emacs can `load-theme' (default
#            modus-operandi)
#   SECTION  the title of a heading to scroll to (default: the top)
# Environment:
#   SHOT_SETUP        an Emacs Lisp file loaded before the theme, for example
#                     one that adds a theme's directory to
#                     `custom-theme-load-path'
#   SHOT_FONT         the default font family (default DejaVu Sans Mono)
#   SHOT_FONT_HEIGHT  its height in 1/10 pt (default 170)
#   EMACS_BIN         the Emacs binary (default emacs); must be a build with
#                     X support
# Needs xvfb-run (package xvfb) and import (ImageMagick).
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
file=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
out=$(cd "$(dirname "$2")" && pwd)/$(basename "$2")
cols=${3:-100}
rows=${4:-40}
theme=${5:-modus-operandi}
section=${6:-}
for tool in xvfb-run import; do
  command -v "$tool" >/dev/null || { echo "gui-shot.sh: $tool not found" >&2; exit 1; }
done
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export SHOT_WORK=$work SHOT_HERE=$here SHOT_FILE=$file SHOT_OUT=$out \
       SHOT_COLS=$cols SHOT_ROWS=$rows SHOT_THEME=$theme SHOT_SECTION=$section \
       SHOT_FONT="${SHOT_FONT:-DejaVu Sans Mono}" \
       SHOT_FONT_HEIGHT="${SHOT_FONT_HEIGHT:-170}" \
       SHOT_EMACS="${EMACS_BIN:-emacs}" SHOT_SETUP="${SHOT_SETUP:-}"

# Runs inside xvfb-run, with DISPLAY pointing at the private server.
inner='
set -euo pipefail
unset WAYLAND_DISPLAY
setup=(); [ -n "$SHOT_SETUP" ] && setup=(-l "$SHOT_SETUP")
section=nil; [ -n "$SHOT_SECTION" ] && section=$(printf "\"%s\"" "$SHOT_SECTION")
"$SHOT_EMACS" -Q --eval "(setq load-prefer-newer t)" -L "$SHOT_HERE" \
  -l "$SHOT_HERE/scripts/shot-gui.el" "${setup[@]}" \
  --eval "(mdview-gui-shot \"$SHOT_FILE\" \"$SHOT_WORK/ready\" $SHOT_COLS $SHOT_ROWS (quote $SHOT_THEME) \"$SHOT_FONT\" $SHOT_FONT_HEIGHT $section)" \
  >"$SHOT_WORK/emacs.log" 2>&1 &
emacs_pid=$!
for _ in $(seq 1 120); do [ -s "$SHOT_WORK/ready" ] && break; sleep 0.5; done
if [ ! -s "$SHOT_WORK/ready" ]; then
  echo "gui-shot.sh: Emacs did not become ready; its log:" >&2
  cat "$SHOT_WORK/emacs.log" >&2
  kill "$emacs_pid" 2>/dev/null || true
  exit 1
fi
import -window "$(cat "$SHOT_WORK/ready")" "$SHOT_OUT"
kill "$emacs_pid" 2>/dev/null || true
'
xvfb-run -a -s "-screen 0 3200x2400x24 -nolisten tcp" bash -c "$inner"
echo "wrote $out"
