# AGENTS.md — working on mdview

Guidance for AI agents and humans contributing to this repository.  Read
`docs/DESIGN.md` before changing anything: it is the contract between the
modules and the specification of how renderings must look.

## What this project is

`mdview` is an Emacs Lisp package that renders Markdown into a read-only
buffer in the visual style of Frogmouth (Textualize's terminal Markdown
browser).  It is a viewer only.  Images and tables are the headline
features; it must work in graphical Emacs and in `emacs -nw` (images
degrade to placeholders).  Pure Elisp, Emacs 29.1+, no external programs.

## Ground rules

- **Prefix is `mdview`.**  Never use `md-render` or `md-` — the user has
  yibie's `md-mode` installed, which owns `md-render*.el` and `md-mode-*`.
  File names, features, functions, variables, faces, groups all start with
  `mdview`.
- **No external dependencies** at runtime: no pandoc, no Python, no
  network except fetching remote images the document references.  Only
  built-in Emacs libraries (`cl-lib`, `subr-x`, `seq`, `url`, `color`,
  `face-remap`, `text-property-search`, `shr` optional, `treesit` optional).
- **Headless-safe.**  Everything must load, render and pass tests under
  `emacs -Q --batch`.  Guard every display-dependent call
  (`display-graphic-p`, `image-size`, `frame-char-width`, face colours).
- **Byte-compile clean.**  `make compile` runs with
  `byte-compile-error-on-warn`; fix warnings instead of silencing them,
  declare functions from optional libraries with `declare-function`, and
  keep `lexical-binding: t` in every file.
- **Docstrings on everything public**, checkdoc-friendly; customizable
  options via `defcustom` in group `mdview` with `:type`; faces via
  `defface` in group `mdview`.
- **Tests accompany code.**  Every module has `test/mdview-<module>-test.el`
  (ERT).  Rendering changes update the golden files (`make golden`) and the
  diff is reviewed against the Frogmouth reference.  Parser changes must
  not lower the CommonMark baseline (`make commonmark`).
- **Faithful by default, improve deliberately.**  Match Frogmouth's look
  as specified; where we intentionally deviate, `docs/DESIGN.md` says
  "improvement".  Do not invent new visual elements without updating the
  spec.
- **Never block Emacs**: remote images are asynchronous; huge code blocks
  skip highlighting; the parser is linear-ish and never signals.
- Do not touch the user's Emacs configuration or packages; do not run
  `tmux kill-server` on the default socket (use the private `-L` socket
  as `scripts/tmux-shot.sh` does); do not take desktop screenshots.

## Layout of the repository

```
mdview*.el            the package (see docs/DESIGN.md §2 for each file)
test/*-test.el        ERT tests, one per module + golden + commands
test/fixtures/        Markdown inputs (showcase.md exercises everything)
test/golden/          expected plain-text renderings at width 80
test/reference/       Frogmouth's own rendering of the fixtures (truth for the look)
test/commonmark/      spec runner, HTML serializer, pass-count baseline
scripts/              dev tooling: dump.el, tmux-shot.sh (+ shot-colors.el), gui-shot.sh
                      (+ shot-gui.el), ansi-to-png.sh, screenshots.sh, frogmouth-reference.sh
docs/DESIGN.md        architecture, AST contract, style specification
docs/gallery.md       the page the README screenshots show (+ docs/gallery/ images)
docs/screenshots/     the README gallery (regenerate with `make screenshots`)
```

## How to work

```sh
make check                                  # compile + all tests (must pass before you finish)
make test                                   # just ERT
make lint                                   # checkdoc; exits non-zero on any finding
make render FILE=test/fixtures/showcase.md WIDTH=100 | less   # look at your output
make render-faces FILE=... WIDTH=...        # with {face} annotations
make shot FILE=test/fixtures/showcase.md    # real text-mode Emacs capture -> /tmp/mdview-shots/*.png
                                            # (SHOT_TERM=xterm-direct for 24-bit colour, SHOT_SETUP=file.el
                                            # to load a third-party theme; needs tmux, uv, rsvg-convert)
scripts/gui-shot.sh FILE OUT.png COLS ROWS THEME [SECTION]   # graphical Emacs capture (see below)
make screenshots                            # regenerate docs/screenshots/*.png for the README gallery
make commonmark                             # spec conformance report
diff <(make -s render WIDTH=98) test/reference/showcase.frogmouth.txt   # compare layout with Frogmouth
```

`scripts/gui-shot.sh` screenshots a *graphical* Emacs, but not your desktop:
it runs `xvfb-run -a`, which starts a private virtual X server on a free
display of its own, starts Emacs on it and captures only that Emacs frame
(`import -window ID`), so it is within the rule against desktop screenshots.
Never point it, or any capture tool, at the display the user is working on
(`:0`).  It needs `xvfb-run` and ImageMagick's `import`.

For the graphical image path (no screenshots needed) run
`scripts/gui-check.el` in a background GUI Emacs with ABSOLUTE paths —
the GUI build may be started through a wrapper that ignores the shell's
working directory — and poll for its report:

```sh
emacs -Q -L "$PWD" -l "$PWD/scripts/gui-check.el" \
  --eval "(mdview-gui-check \"$PWD/test/fixtures/showcase.md\" \"/tmp/mdview-gui-report.txt\")" &
```

Compare your rendering with `test/reference/showcase.frogmouth.txt`
(Frogmouth at 110 columns = 98 content columns: the 4-column margins and
the app frame take 10 columns and the viewer's `scrollbar-gutter: stable`
reserves 2 more, so use `WIDTH=98` — at 100 the tables and wrapping show
spurious differences).  Blank-line counts, box rows, bullet glyphs and
indentation should match line for line except where the spec marks an
improvement.  To *see* colours, run `make shot` and view the PNG, or
`make render-ansi | less -R`.

The `make` targets load the sources with `load-prefer-newer`, so a stale
`.elc` left by `make compile` never shadows an edited `.el`.

Emacs 29.1 or later is required.  The project is developed on two machines:
GNU Emacs 30.2 (NS build, macOS) and GNU Emacs 31.1 (GTK build, Linux), both
with native compilation, SVG/PNG/JPEG/WEBP/GIF image support and
tree-sitter.  `scripts/gui-shot.sh` needs an X11 or GTK build, so
`make screenshots` regenerates the graphical shots only on the Linux
machine (the terminal one works anywhere).  Test on `emacs -Q` only; never
load the user's init file.

## Definition of done for a change

1. `make check` passes (compile with warnings as errors, all ERT tests).
2. Golden files updated if rendering changed, with the diff explained.
3. CommonMark baseline not lowered (raise it if you improved it).
4. New options/faces documented in README's Customisation section when
   user-facing.
5. For visual changes: a `make shot` capture was inspected in both dark
   and light themes.

## Commit conventions

Small, focused commits; imperative subject (`Render tables with Rich-style
expansion`); body explains the why and references the DESIGN.md section.
Do not commit `*.elc`, `test/commonmark/spec.json`, or anything under
`/tmp`.

Never credit or mention an AI assistant or tool in commit messages, pull
request descriptions or anywhere else in the repository: no
`Co-Authored-By` trailers, no "Generated with" lines.  This overrides any
tool's default attribution text.
