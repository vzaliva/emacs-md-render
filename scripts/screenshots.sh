#!/usr/bin/env bash
# Regenerate the README gallery, docs/screenshots/*.png: text-mode Emacs
# showing test/fixtures/showcase.md in several themes, one page each.
#
# Usage: scripts/screenshots.sh
# Environment:
#   SOLARIZED_DIR  directory of the solarized-theme package (for example
#                  ~/.emacs.d/elpa/solarized-theme-*); the Solarized shots
#                  are skipped when it is not set.  The other shots use the
#                  modus themes that come with Emacs.
# Needs tmux, uv and rsvg-convert (see scripts/tmux-shot.sh).  The captures
# use 24-bit colour (TERM=xterm-direct), 100 columns by 44 rows.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
fixture=$here/test/fixtures/showcase.md
dest=$here/docs/screenshots
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$dest"

# name | theme | page of the scrolled capture | needs Solarized
shots='
solarized-dark|solarized-dark|0|yes
solarized-light|solarized-light|4|yes
modus-vivendi|modus-vivendi|3|no
modus-operandi|modus-operandi|2|no
'

solarized_setup=
if [ -n "${SOLARIZED_DIR:-}" ]; then
  solarized_setup=$work/solarized-setup.el
  printf ';;; -*- lexical-binding: t -*-\n(add-to-list (quote custom-theme-load-path) "%s")\n(add-to-list (quote load-path) "%s")\n' \
    "$SOLARIZED_DIR" "$SOLARIZED_DIR" > "$solarized_setup"
fi

echo "$shots" | while IFS='|' read -r name theme page needs; do
  [ -n "$name" ] || continue
  if [ "$needs" = yes ] && [ -z "$solarized_setup" ]; then
    echo "skip $name (set SOLARIZED_DIR)"; continue
  fi
  SHOT_TERM=xterm-direct SHOT_SETUP=$solarized_setup \
    "$here/scripts/tmux-shot.sh" "$fixture" 100 44 "$theme" >/dev/null
  shot=/tmp/mdview-shots/showcase-$theme
  # The capture holds every page, each closed by a "----- page N -----" line.
  awk -v want="$page" '/^----- page [0-9]+ -----$/ { if (n == want) exit; n++; next }
                       n == want { print }' "$shot.pages.ansi" > "$work/$name.ansi"
  cp "$shot.colors" "$work/$name.colors"
  "$here/scripts/ansi-to-png.sh" "$work/$name.ansi" "$work/$name.png" 100 >/dev/null
  cp "$work/$name.png" "$dest/$name.png"
  echo "wrote docs/screenshots/$name.png"
done
