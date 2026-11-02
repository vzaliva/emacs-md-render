# Changelog

Notable changes to mdview.  The package has not been released yet; this
file starts with the review of the view keys (issue #1).  Earlier history
is in `git log`.

## Unreleased

### Changed

- The keys of the rendered view are now the `C-c` chords that
  outline-mode, org-mode and markdown-mode use for the same action:
  `C-c C-n` / `C-c C-p` headings, `C-c C-j` table of contents, `C-c C-o`
  follow link, `C-c C-l` copy link, `C-c <left>` / `C-c <right>` (and
  `C-c &`) history, `C-c C-x C-v` (and `C-c C-x C-i`) images, `C-c C-r`
  re-render.  The letter keys `g`, `n`, `p`, `t`, `l`, `r`, `i`, `w` and
  `<` / `>` are gone.  `TAB`, `RET`, `SPC`, `DEL`, the width keys and
  `C-c C-v` are unchanged.  (Issue #1; docs/DESIGN.md section 10.3.)
- Switching between the source and the rendering, and re-rendering,
  keep point on the same character, not only on the same block: the
  parser records where every character of the text comes from and the
  rendering carries it (`mdview-pos`; docs/DESIGN.md section 3).

### Added

- Typing into the rendering switches to the source at the character at point
  and inserts the text there, so editing needs no explicit switch
  (`mdview-self-insert`; option `mdview-edit-on-typing`).
- `C-c C-f` / `C-c C-b` / `C-c C-u`: next and previous heading of the
  same level, and the parent heading, with outline-mode's semantics.
