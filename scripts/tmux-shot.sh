#!/usr/bin/env bash
# Capture how text-mode Emacs renders FILE with mdview, using a private tmux
# server so the user's own tmux sessions are untouched.
#
# Usage: scripts/tmux-shot.sh FILE [COLUMNS] [ROWS] [THEME]
#   THEME: "dark" (default, modus-vivendi) or "light" (modus-operandi), or the
#          name of any theme Emacs can `load-theme'
# Environment:
#   SHOT_TERM   the TERM Emacs runs under (default xterm-256color; use
#               xterm-direct for 24-bit colour)
#   SHOT_SETUP  an Emacs Lisp file loaded before the theme, for example one
#               that adds a theme's directory to `custom-theme-load-path'
#   EMACS_BIN   the Emacs binary (default emacs)
# Output: /tmp/mdview-shots/<name>-<theme>.txt  (plain text, full buffer)
#         /tmp/mdview-shots/<name>-<theme>.ansi (tmux capture with colours)
#         /tmp/mdview-shots/<name>-<theme>.colors (default face colours)
#         /tmp/mdview-shots/<name>-<theme>.png  (if uv + rsvg-convert exist)
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
file=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
cols=${2:-110}
rows=${3:-60}
theme=${4:-dark}
case $theme in dark) emtheme=modus-vivendi;; light) emtheme=modus-operandi;; *) emtheme=$theme;; esac
name=$(basename "$file" .md)
out=/tmp/mdview-shots
mkdir -p "$out"
sock=mdview-shot-$$
emacs_bin=${EMACS_BIN:-emacs}
term=${SHOT_TERM:-xterm-256color}
setup_args=""
if [ -n "${SHOT_SETUP:-}" ]; then setup_args="-l '$SHOT_SETUP'"; fi
# COLORTERM would make Emacs use 24-bit colour whatever TERM says.
tmux -L "$sock" new-session -d -s shot -x "$cols" -y "$rows" \
  "unset COLORTERM; TERM=$term $emacs_bin -nw -Q --eval '(setq load-prefer-newer t)' -L '$here' -l '$here/scripts/shot-colors.el' $setup_args --eval \"(progn (load-theme '$emtheme t) (mdview-shot-record-colors \\\"$out/$name-$theme.colors\\\") (mdview-shot-tidy) (require 'mdview) (setq mdview-auto-refit nil) (mdview-file \\\"$file\\\"))\""
sleep 4
tmux -L "$sock" capture-pane -t shot -p -e -S 0 -E "$((rows-1))" > "$out/$name-$theme.ansi"
tmux -L "$sock" capture-pane -t shot -p > "$out/$name-$theme.screen.txt"
# Scroll through the whole document, capturing each page.
page=0
: > "$out/$name-$theme.pages.ansi"
while [ $page -lt 40 ]; do
  tmux -L "$sock" capture-pane -t shot -p -e >> "$out/$name-$theme.pages.ansi"
  echo "----- page $page -----" >> "$out/$name-$theme.pages.ansi"
  before=$(tmux -L "$sock" capture-pane -t shot -p | cksum)
  tmux -L "$sock" send-keys -t shot C-v
  sleep 0.5
  after=$(tmux -L "$sock" capture-pane -t shot -p | cksum)
  [ "$before" = "$after" ] && break
  page=$((page+1))
done
tmux -L "$sock" kill-server 2>/dev/null || true
if command -v uv >/dev/null && command -v rsvg-convert >/dev/null; then
  "$here/scripts/ansi-to-png.sh" "$out/$name-$theme.ansi" "$out/$name-$theme.png" "$cols" || true
fi
echo "captured $out/$name-$theme.{ansi,screen.txt,pages.ansi,colors}"
