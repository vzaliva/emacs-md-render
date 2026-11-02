#!/usr/bin/env bash
# Regenerate the README gallery, docs/screenshots/*.png, from docs/gallery.md:
# four shots of a graphical Emacs (on a private X virtual framebuffer, see
# scripts/gui-shot.sh) and one of Emacs in a terminal (scripts/tmux-shot.sh).
#
# Usage: scripts/screenshots.sh
# Environment:
#   SOLARIZED_DIR  directory of the solarized-theme package (for example
#                  ~/.emacs.d/elpa/solarized-theme-*); the shots in the
#                  Solarized themes are skipped when it is not set.  The
#                  other shots use the modus themes that come with Emacs.
# Needs xvfb-run and import for the graphical shots, tmux, uv and
# rsvg-convert for the terminal one.  Each section of the gallery is scrolled
# to by the title of its heading, so the shots survive edits of the document;
# the number of rows is the one that shows the whole section.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
gallery=$here/docs/gallery.md
dest=$here/docs/screenshots
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$dest"

solarized_setup=
if [ -n "${SOLARIZED_DIR:-}" ]; then
  solarized_setup=$work/solarized-setup.el
  printf ';;; -*- lexical-binding: t -*-\n(add-to-list (quote custom-theme-load-path) "%s")\n(add-to-list (quote load-path) "%s")\n' \
    "$SOLARIZED_DIR" "$SOLARIZED_DIR" > "$solarized_setup"
fi

# name | kind | theme | section (gui; empty = top) or text on the page (tty) | rows
shots='
typography|gui|solarized-dark||38
code|gui|modus-vivendi|Code|31
tables|gui|solarized-light|Tables|32
images|gui|modus-operandi|Images|33
terminal|tty|solarized-dark|Element|44
'

echo "$shots" | while IFS='|' read -r name kind theme where rows; do
  [ -n "$name" ] || continue
  case $theme in solarized-*)
    if [ -z "$solarized_setup" ]; then echo "skip $name (set SOLARIZED_DIR)"; continue; fi;;
  esac
  if [ "$kind" = gui ]; then
    SHOT_SETUP=$solarized_setup "$here/scripts/gui-shot.sh" "$gallery" \
      "$dest/$name.png" 100 "$rows" "$theme" "$where" >/dev/null
  else
    SHOT_TERM=xterm-direct SHOT_SETUP=$solarized_setup \
      "$here/scripts/tmux-shot.sh" "$gallery" 100 "$rows" "$theme" >/dev/null
    shot=/tmp/mdview-shots/gallery-$theme
    # The capture holds every page, each closed by a "----- page N -----"
    # line; take the first page that shows WHERE.
    awk -v want="$where" '/^----- page [0-9]+ -----$/ { if (index(page, want)) { printf "%s", page; exit }
                                                         page = ""; next }
                          { page = page $0 "\n" }' "$shot.pages.ansi" > "$work/$name.ansi"
    [ -s "$work/$name.ansi" ] || { echo "no page of the terminal capture shows '$where'" >&2; exit 1; }
    cp "$shot.colors" "$work/$name.colors"
    "$here/scripts/ansi-to-png.sh" "$work/$name.ansi" "$work/$name.png" 100 >/dev/null
    cp "$work/$name.png" "$dest/$name.png"
  fi
  echo "wrote docs/screenshots/$name.png"
done
