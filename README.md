# mdview — a Frogmouth-style Markdown viewer for Emacs

`mdview` renders a Markdown buffer into a read-only, beautifully laid out
view inside Emacs, in the visual style of
[Frogmouth](https://github.com/Textualize/frogmouth), the terminal Markdown
browser by Dave Pearson and Textualize: boxed headings, green bullets,
bordered block quotes, dark syntax-highlighted code panels, and full-width
panel tables.  It works in both graphical and text-mode Emacs; graphical
Emacs additionally shows images inline.

It is a *viewer*, not an editor or a file browser: you keep editing in
`markdown-mode` or `md-mode`, press one key to see the rendered document,
and press it again to go back.  File management, bookmarks, history panes
and the other application features of Frogmouth are deliberately left to
Emacs itself.

> **Status:** under active development.  See [docs/DESIGN.md](docs/DESIGN.md)
> for the architecture and the style specification, and `AGENTS.md` for
> contributor conventions.

## Goals

- **Beautiful, faithful rendering** of CommonMark + GitHub-flavoured
  Markdown (tables, strikethrough, task lists, autolinks, footnotes) in the
  Frogmouth look, with a palette that adapts to light and dark Emacs themes.
- **Images and tables are first-class.**  Local and remote images are shown
  inline (scaled to the view width) in graphical Emacs, with a placeholder in
  text mode.  Tables get Frogmouth's panel style, with proper column layout,
  cell wrapping, and column alignment.
- **Code blocks** use Emacs's own major modes for syntax highlighting, mapped
  onto the Material palette Frogmouth uses, with indent guides.
- **Zero external dependencies.**  Pure Emacs Lisp (Emacs 29.1+): the parser,
  layout engine and renderer are all in this package.  No pandoc, no
  markdown-it, no browser.
- **Works everywhere Emacs runs**: GUI and `emacs -nw`, any terminal with a
  Unicode font (ASCII fallbacks are configurable).
- **Plays well with your Markdown mode.**  A single command,
  `mdview-toggle`, flips between the source buffer and the rendered view and
  keeps your position.  Bind it in `markdown-mode`, `gfm-mode`, `md-mode` or
  anywhere else.

## Installation

The package is not (yet) on MELPA.  With Emacs 29+ you can install it from
git:

```elisp
(unless (package-installed-p 'mdview)
  (package-vc-install "https://github.com/vzaliva/emacs-md-render"))

(use-package mdview
  :commands (mdview mdview-file mdview-toggle)
  :bind (:map markdown-mode-map ("C-c C-v" . mdview-toggle)))
```

If you use [md-mode](https://github.com/yibie/md-mode), which already binds
`C-c C-v` to its own in-place renderer, rebind it to `mdview-toggle`:

```elisp
(with-eval-after-load 'md-mode
  (define-key md-mode-map (kbd "C-c C-v") #'mdview-toggle))
```

Or let the package install the binding in all Markdown modes it knows about:

```elisp
(mdview-install-keybinding "C-c C-v")
```

## Usage

| Command | What it does |
|---|---|
| `M-x mdview` | Render the current buffer into a `*mdview: …*` buffer and show it. |
| `M-x mdview-file` | Render a Markdown file. |
| `M-x mdview-toggle` | In a Markdown buffer: show the rendered view.  In a rendered view: return to the source. |

Keys in the rendered view (`mdview-mode`):

| Key | Action |
|---|---|
| `q` | Quit the view (back to the source buffer if you came from one) |
| `g` | Re-render from the (possibly edited) source |
| `TAB` / `S-TAB` | Next / previous link |
| `RET` | Follow link at point: anchors scroll, Markdown files open in `mdview`, other files in Emacs, URLs in the browser; images open externally |
| `n` / `p` | Next / previous heading |
| `t` | Table of contents (via `imenu`) |
| `l` / `r` | Back / forward in the view history (when following links between files) |
| `i` | Toggle inline images |
| `e` | Visit the source at the corresponding line |
| `w` | Copy the link URL at point |
| `SPC` / `DEL` | Scroll |

The view re-flows automatically when the window width changes
(`mdview-auto-refit`), and re-renders when the source buffer is saved
(`mdview-refresh-on-save`).

## Customisation

`M-x customize-group RET mdview RET`.  The most useful options:

- `mdview-max-width` (default 100): maximum text width in columns; `nil`
  uses the full window.
- `mdview-margin` (default 4): left/right margin, as in Frogmouth.
- `mdview-display-images`, `mdview-display-remote-images`,
  `mdview-image-max-height`: image behaviour.
- `mdview-bullets`: bullet glyphs per nesting level
  (`●`, `▪`, `‣`, `•`, `⭑` by default, like Frogmouth).
- `mdview-code-lang-modes`: map fenced-code language names to major modes.
- `mdview-code-material-theme`: use Frogmouth's Material code palette
  (`t`), or keep your theme's `font-lock` faces (`nil`).
- Faces: everything is a face in the `mdview` group (`mdview-h1`,
  `mdview-quote`, `mdview-table`, `mdview-code-block`, …).

## Development

```sh
make check      # byte-compile with warnings as errors, then run all tests
make test       # ERT tests only
make render FILE=test/fixtures/showcase.md WIDTH=100   # dump a rendering as text
make shot  FILE=test/fixtures/showcase.md   # text-mode Emacs screenshot via tmux
make commonmark # CommonMark spec conformance report
```

See `AGENTS.md` for the contributor workflow and `docs/DESIGN.md` for the
architecture, the AST contract shared by the parser and renderer, and the
style specification derived from Frogmouth.

## Credits

- The visual design is a port of **Frogmouth** by Dave Pearson
  (davep) and **Textualize**, MIT licensed —
  <https://github.com/Textualize/frogmouth> — and of the
  `Markdown` widget in **Textual** <https://github.com/Textualize/textual>,
  whose default CSS defines the heading boxes, bullets, quote borders and
  table style reproduced here.  Code blocks follow the Pygments "material"
  theme that Frogmouth uses through **Rich**.
- Inspiration for the Emacs side: `markdown-mode` by Jason Blevins,
  `md-mode` by yibie, and Org mode's source-block fontification.
- No code is copied from these projects; `mdview` is a from-scratch
  implementation in Emacs Lisp.

## License

GPL-3.0-or-later.  See [LICENSE](LICENSE).
