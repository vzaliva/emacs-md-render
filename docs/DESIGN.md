# mdview — design and style specification

This document is the contract between the parts of `mdview` and the source
of truth for how a rendering must look.  The look is a port of
[Frogmouth](https://github.com/Textualize/frogmouth) 0.9.1, i.e. of the
`Markdown` widget of Textual 0.43 with Textual's default dark/light design
and the Pygments "material" code theme.  Reference renderings of
`test/fixtures/showcase.md` produced by Frogmouth itself live in
`test/reference/` (`showcase-dark.svg`, `showcase-light.svg`, and the
character grid `showcase.frogmouth.txt`); regenerate them with
`scripts/frogmouth-reference.sh`.

Where this document says "faithful", match Frogmouth.  Where it says
"improvement", we knowingly do better than Frogmouth (it ignores table
alignment, task lists, footnotes, images and list start numbers).

## 1. Goals and non-goals

Goals: a read-only, beautiful rendering of a Markdown buffer in the
Frogmouth style; images (GUI) and tables are first-class; works in
graphical and text-mode Emacs (Emacs 29.1+); zero external dependencies;
one-key toggle from `markdown-mode`/`gfm-mode`/`md-mode`.

Non-goals: editing in the rendered view, file browsing, bookmarks/history
panes, remote document fetching, math rendering, Mermaid/PlantUML diagrams,
HTML rendering beyond simple tag stripping and `<img>` extraction.

## 2. Package layout

Elisp prefix is `mdview` (the obvious `md-render` is already taken by the
rendering half of yibie's `md-mode`, which the author has installed; a
feature or file-name clash would break both).  All files use
`lexical-binding: t`, require only what they use, and must byte-compile
with `byte-compile-error-on-warn` on Emacs 29 and 30.

| File | Responsibility | Requires |
|---|---|---|
| `mdview-ast.el` | AST node constructors/accessors, slugs, shared helpers | — |
| `mdview-inline.el` | Inline parser: string + refmap → inline nodes | ast |
| `mdview-parse.el` | Block parser: buffer/string → `document` AST (calls inline) | ast, inline |
| `mdview-faces.el` | Faces, palette, adaptive colour derivation | — |
| `mdview-code.el` | Fenced/indented code: major-mode fontification, Material face mapping, indent guides | faces |
| `mdview-image.el` | Image loading (local/remote, async), scaling, placeholders, cache | faces |
| `mdview-table.el` | Table layout: column widths, cell wrapping, alignment → lines | faces, render helpers |
| `mdview-render.el` | Layout engine (contexts, margins, wrapping, boxes) and block/inline rendering | ast, faces, code, image, table |
| `mdview.el` | Commands, `mdview-mode`, keymap, link following, history, refit, source sync, integration | everything |

Dependency direction is strictly downward in that table (render may call
table/code/image; nothing calls back into `mdview.el`).  `mdview-table.el`
needs the inline renderer and the line wrapper; those live in
`mdview-render.el`, so `mdview-render.el` *provides* the generic helpers
(`mdview-render-inlines`, `mdview-wrap`) before requiring `mdview-table`,
or `mdview-table.el` receives already-rendered propertized cell strings.
Chosen contract: **the table module receives cells as propertized strings
and a wrap function**; it does not require `mdview-render`.

## 3. AST contract

A node is `(TYPE PLIST . CHILDREN)`; a plain string is a text node (already
backslash-unescaped and entity-decoded).  Helpers in `mdview-ast.el`:

```elisp
(mdview-node TYPE PLIST &rest CHILDREN)   ; constructor
(mdview-node-type NODE)                   ; symbol, or `text' for strings
(mdview-node-props NODE)                  ; plist
(mdview-node-prop NODE KEY)               ; (plist-get props KEY)
(mdview-node-children NODE)               ; list
(mdview-node-text NODE)                   ; plain-text content, recursively
(mdview-slug STRING)                      ; GitHub-style anchor slug
```

Block node types and their properties:

| Type | Props | Children |
|---|---|---|
| `document` | `:refs` hash (normalized label → `(URL . TITLE)`), `:footnotes` list of `footnote-definition` nodes in order of first reference | blocks |
| `heading` | `:level` 1–6, `:id` unique slug (`-1`, `-2` suffixes on duplicates), `:line` | inlines |
| `paragraph` | `:line` | inlines |
| `blockquote` | `:line` | blocks |
| `list` | `:ordered` bool, `:start` int (ordered only), `:tight` bool, `:marker` char (`?-` `?*` `?+` `?.` `?\)`), `:line` | `item` nodes |
| `item` | `:task` nil / `checked` / `unchecked`, `:line` | blocks |
| `code-block` | `:lang` first word of info string or nil, `:info` full info string or nil, `:fenced` bool, `:line` | one string (no trailing newline) |
| `html-block` | `:line` | one string (raw HTML) |
| `thematic-break` | `:line` | — |
| `table` | `:align` list per column of `left`/`center`/`right`/nil, `:line` | `table-row` nodes; first has `:header t` |
| `table-row` | `:header` bool | `table-cell` nodes |
| `table-cell` | — | inlines |
| `footnote-definition` | `:label`, `:index` 1-based, `:line` | blocks |

Inline node types:

| Type | Props | Children |
|---|---|---|
| text | — | (a string) |
| `emphasis`, `strong`, `strikethrough` | — | inlines |
| `code` | — | one string |
| `link` | `:url`, `:title` or nil, `:autolink` bool | inlines |
| `image` | `:url`, `:title` or nil, `:alt` plain text | inlines (description) |
| `hard-break`, `soft-break` | — | — |
| `html-inline` | — | one string (raw tag) |
| `footnote-reference` | `:label`, `:index` | — |

`:line` is the 1-based source line where the block starts; the renderer
stores it on the first rendered line of each block as the text property
`mdview-source-line` so the view and the source can be kept in sync.

Public parser API:

```elisp
(mdview-parse-string STRING) → document
(mdview-parse-buffer &optional BUFFER) → document      ; whole accessible portion
(mdview-inline-parse STRING REFS) → list of inline nodes
```

## 4. Parser requirements

Target: CommonMark 0.31 block and inline structure plus the GFM
extensions: pipe tables, strikethrough (`~~x~~` and `~x~`), task list
items, autolinks for bare `http(s)://` and `www.` URLs, and footnotes
(`[^label]` references, `[^label]: text` definitions with indented
continuation).  Front matter (`---` YAML block at the very start) is
skipped.

Must handle: ATX and setext headings; paragraphs with lazy continuation;
thematic breaks; fenced code (backtick and tilde, info string, indented
fences, unclosed fence runs to end of container) and indented code;
block quotes with lazy continuation and nesting; bullet and ordered lists
with correct content-indent rules, nesting, loose/tight detection, start
numbers, marker changes starting new lists; HTML blocks (the seven
CommonMark kinds, kept raw); link reference definitions (removed from
output, case-folded labels); tables with header/delimiter rows, alignment
colons, escaped pipes, inline content in cells, missing/extra cells.

Inline: backslash escapes; HTML entities and numeric character references
(use `mdview-ast.el`'s table of the common named entities plus a numeric
decoder — the full HTML5 list is not required); code spans (backtick run
matching, space stripping); emphasis and strong with the CommonMark
delimiter-run algorithm (left/right flanking, `*` vs `_` intraword rules,
multiple-of-3 rule); links and images (inline, reference full/collapsed/
shortcut, titles in `"`, `'`, `(...)`, angle-bracket destinations, nested
brackets, no links inside links); autolinks `<http://…>` and `<mail@…>`;
raw inline HTML tags kept as `html-inline`; hard breaks (two spaces or
backslash before newline); soft breaks.

Conformance is measured by `make commonmark`: `test/commonmark/run-spec.el`
loads `spec.json` (CommonMark 0.31.2), parses each example, serializes the
AST to HTML with a small serializer (`test/commonmark/mdview-html.el`) that
follows the spec's HTML conventions, normalizes whitespace, and compares.
It prints pass/fail per section and the total, and fails if the total
drops below `test/commonmark/baseline` (an integer in a file; update it
deliberately when the parser improves).  Target at least 85% overall and
100% of the "Tabs", "Thematic breaks", "ATX headings", "Setext headings",
"Fenced code blocks", "Indented code blocks", "Block quotes", "Lists",
"List items", "Code spans", "Emphasis and strong emphasis", "Links",
"Images", "Autolinks", "Hard line breaks", "Soft line breaks" sections
pass or come very close.  Raw HTML sections may be weaker.

Robustness: the parser must never signal on any input (fuzz with random
slices of the fixtures), must be linear-ish in practice (a 1 MB file
parses in well under 2 s on a laptop), and must not use regexps prone to
catastrophic backtracking on long lines.

## 5. Layout model

The renderer writes into the current buffer (the caller erases it first)
with `mdview-render-document`:

```elisp
(mdview-render-document DOC &key width base-dir)
```

`width` is the content width in columns (the caller computes it from the
window, margins and `mdview-max-width`).  `base-dir` resolves relative
image and link paths.  Everything is laid out in **columns of the
`default` face**: text is hard-wrapped at render time, boxes are padded
with spaces to exactly `width`, and backgrounds come from faces on those
characters — never from `:extend`-dependent behaviour alone — so GUI and
terminal agree and the result is independent of `visual-line-mode`.
`string-width` (not `length`) measures text; `truncate-lines` is `t` in
the view so code lines never wrap.

### 5.1 Rendering context

Blocks render recursively with a context carrying:

- `width`: columns available for content at this nesting level;
- `prefix`: propertized string prepended to every line (quote bars,
  list indentation), and `first-prefix` for the first line of a list item
  (the bullet) — equal width;
- `bg`: face (or nil) painting the padding to the right edge, so nested
  quote backgrounds extend to the block's right edge;
- `tight`: whether paragraphs inside the current list item drop their
  bottom margin.

`(mdview-render--emit-line STRING CTX)` inserts prefix + string + padding
spaces to `width` (padding gets `bg`) + newline.  A blank line inside a
container is `(mdview-render--emit-line "" CTX)` so that quote bars and
backgrounds continue through it (Frogmouth draws the bar on blank lines).

### 5.2 Vertical margins

Each block has a top and bottom margin in lines; between two consecutive
siblings the blank lines emitted are `max(bottom(A), top(B))` (Textual
collapses margins).  No blank lines before the first child of a container
or after the last one (the container's own margins/padding apply).  No
blank lines at the top of the document; exactly one newline ends it.

| Block | top | bottom | Notes |
|---|---|---|---|
| heading 1, 2 | 0 | 0 | the box's frame rows provide separation (faithful: two boxes in a row touch) |
| heading 3 | 0 | 0 | text row + rule row |
| heading 4, 5, 6 | 1 | 1 | |
| paragraph | 0 | 1 | bottom 0 inside a tight list item |
| blockquote | 1 | 1 | nested quote: top 1, left margin 2 |
| list (top level) | 0 | 1 | nested list: 0/0 |
| code block | 1 | 1 | |
| table | 1 | 1 | |
| thematic break | 0 | 1 | always preceded by one blank padding line (part of the block) |
| html block | 0 | 1 | |
| footnotes section | 1 | 0 | |

Between items of a loose list: 1 blank line; tight list: none
(improvement over Frogmouth, which never separates items).

### 5.3 Wrapping

`(mdview-wrap STRING WIDTH)` → list of propertized lines.  Greedy
word-wrap on spaces; a token longer than `width` is broken at `width`
(Frogmouth breaks mid-word, see "Pneumonoultra…" in the reference).
`hard-break` forces a new line; `soft-break` is a single space.  Leading
and trailing spaces of each output line are trimmed.  Inline images that
are displayed as real images count as a token of width
`ceil(pixel-width / frame-char-width)`; in text mode their placeholder text
counts as ordinary text.  Text properties survive wrapping (slice with
`substring`, never rebuild strings from `char`s).

## 6. Block styles (what it must look like)

Column numbers below are relative to the content area (after the left
margin).  `W` is the content width.  Glyphs are customizable via
`mdview-glyphs` (alist) with an ASCII profile for terminals that cannot
display them (`mdview-ascii-glyphs`, auto-selected when
`char-displayable-p` fails for `●`).

### Boxes (H1, H2, tables)

A box spans the full `W` and has Textual's "wide" border drawn in the
*buffer background colour* over the box colour, which reads as a thin
inset frame:

```
▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁   top row: W × ▁  (face: fg = frame colour, bg = box colour)
▎                           ▊   body rows: ▎ + (W-2) cols + ▊  (same frame face on the glyphs)
▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔   bottom row: W × ▔
```

The frame colour is the buffer's `default` background (computed at render
time and face-remapped buffer-locally, `mdview-box-frame`).  Inside the
frame, body text has one column of padding on each side (so text starts
at column 2).  `mdview-box-frame-style` = `wide` (default) | `none`
(plain padded box, 1 blank row top and bottom instead of the frame rows).

### Headings

- **H1**: box, background `accent-darken-2` (#0053AA), 5 rows: frame,
  blank, text, blank, frame.  Text bold, colour `text` (87 % white on
  blue in both themes, i.e. #DDE8F3), **centered** within W.  Inline
  markup inside headings is rendered (code, emphasis, links).
- **H2**: box, background `panel` (#24292F dark / #DCE3E8 light), same 5
  rows, text bold, **left-aligned** at column 2 (faithful: Textual's
  `text-align: center` is not what Frogmouth shows; the reference has it
  flush left).
- **H3**: bold text on `surface` background (dark #1E1E1E, which equals the
  app background, so effectively no background), followed by a rule row of
  `▔` exactly as wide as the text, face fg `foreground` (#EDEDED dark /
  #101010 light).
- **H4**: underlined text.  **H5**: bold.  **H6**: bold, `text-muted`
  colour (#A5A5A5 dark / #666666 light).
- Setext headings render as H1/H2.
- Every heading line carries text properties `mdview-heading-level` and
  `mdview-heading-id` (for `n`/`p`, imenu and anchor links).

### Paragraph

Wrapped at W, `default` face for text.

### Thematic break

One blank line, then W × `━` in `mdview-rule` (fg `primary` #004578 in
both themes — a dark navy line; this is faithful, not a bug), then the
bottom margin.

### Block quote

Faithful to Textual's `background: $boost; border-left: outer $success;
padding: 0 1`:

```
▌ quoted text wrapped to W-3 columns ....... (padding to W, boost bg)
▌                                            (blank lines keep the bar)
▌   ▌ nested quote: 2 extra columns of margin, its own bar and a
▌   ▌ second boost layer
```

- Bar glyph `▌` (left half block) in `mdview-quote-border` (fg `success`
  #4EBF71), followed by one space of padding; inner width = W − 3 (bar,
  pad, right pad).
- Background `mdview-quote` level 1 = default background blended 4 %
  towards white (dark theme) or black (light theme); level n applies the
  blend n times.  Derived at render time from the actual `default` face
  and face-remapped buffer-locally, so it harmonizes with any theme.
- Nested quote: top margin 1, left margin 2 inside the parent's content.
- Lists, code blocks and tables inside quotes render with the reduced
  width; code blocks keep their own background.

### Lists

```
● First bullet item
● Second bullet item with a long line that wraps neatly under the text of
  the item rather than under the marker
  ▪ Nested bullet, level two
    ‣ Level three
      • Level four
        ⭑ Level five
```

- Bullet glyph by *bullet-list nesting depth* (ordered lists do not
  advance the depth): `●`, `▪`, `‣`, `•`, `⭑`, cycling; face
  `mdview-bullet` (fg `success` #4EBF71, bold).  Marker is glyph + one
  space; continuation lines and nested blocks indent by the marker width
  (2).
- Ordered: numbers right-aligned to the widest number in the list,
  followed by `. ` (or `) ` if that delimiter was used), same face;
  numbering starts at `:start` (improvement: Frogmouth restarts at 1).
  Content indents by the marker width.
- Task items: the bullet is replaced by `☐` (unchecked, face
  `mdview-task-unchecked`, muted) or `☑` (checked, face
  `mdview-task-checked`, `success`) — improvement; Frogmouth prints `[ ]`.
- Tight lists: no blank lines between items; paragraphs inside items have
  no bottom margin.  Loose lists: one blank line between items and between
  blocks inside an item.  Code blocks and quotes inside items keep their
  margins (reference: the `echo` fence inside the loose item has a blank
  line before it).
- A list directly after a paragraph inside a quote or item: no blank
  line between them (paragraph bottom margin 1 vs list top 0 gives 1 in
  normal flow; this is fine — only the tight-item case drops it).

### Code blocks

Faithful to Rich `Syntax(theme="material", indent_guides=True,
padding=(1, 2))` in a full-width block:

```
                                              ← blank row, code bg
  import sys                                  ← 2 columns padding
  │   x: float                                ← indent guide at col 0 of code
  │   │   return x                            ← guides at cols 0 and 4
                                              ← blank row
```

- Background `mdview-code-block` #263238 in **both** themes (faithful),
  default text #EEFFFF; the whole block (including the blank padding rows
  and the 2-column left padding) has the background; lines are padded to
  W but never wrapped (`truncate-lines`), so long lines simply run past W
  without background — acceptable.
- Indent guides: within the leading whitespace of a line, columns 0, 4, 8,
  … that are strictly less than the indentation get `│` in
  `mdview-code-indent-guide` (fg #4A5A63); `mdview-code-indent-guide-width`
  default 4; tabs count as 4.
- Syntax highlighting via the major mode for the language (see §8);
  unknown language or highlighting failure → plain #EEFFFF text.
- Indented code blocks render identically, without a language.
- Optional: `mdview-code-show-language` (default nil) draws the language
  name right-aligned in the top padding row in muted colour.

### Tables

Faithful to Textual's `MarkdownTable` (panel background, wide frame) with
Rich `Table(expand=True, box=SIMPLE_HEAVY, padding=0, collapse_padding=True)`:

```
▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁
▎                                                            ▊
▎ Column A                      Column B          Column C   ▊   ← header, bold
▎ ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ ▊   ← rule, fg primary-lighten-1
▎ left                          center            right      ▊
▎ a longer cell value           x                 12345.67   ▊
▎                                                            ▊
▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔
```

- Box background `mdview-table` = `panel` (#24292F dark / #DCE3E8 light);
  frame rows as in "Boxes"; one blank body row at top and bottom (the
  SIMPLE_HEAVY blank edge rows), one column padding at each side, so cell
  text starts at column 2 and the rule spans columns 2 … W−3.
- Header cells bold (`mdview-table-header`); rule `━` in
  `mdview-table-rule` (fg `primary-lighten-1` #23568B in both themes).
- Column separator: one space (Rich's SIMPLE box has a blank vertical).
- Column widths: natural width = max `string-width` of the column's cells
  (header included).  If the sum of natural widths plus separators fits in
  the inner width (W − 4), distribute the extra width to the columns
  proportionally to their natural widths (Rich `expand=True`) — the table
  always fills W.  If it does not fit, shrink the widest columns first
  (Rich's collapse strategy) down to each column's minimum (its longest
  word, at least 3), and wrap cell contents with `mdview-wrap`; a row then
  spans several lines, cells top-aligned.
- Alignment (improvement): honor `:align` — `center` and `right` pad on the
  left; nil/`left` pad on the right.  Header cells follow the same
  alignment.
- Cell inlines render with the normal inline faces (code, bold, links,
  images as placeholders inside tables — real images inside table cells
  are not displayed, to keep rows rectangular).
- `mdview-table-expand` (default t): nil keeps natural widths.

### HTML blocks

`mdview-html-renderer`: `strip` (default) renders the text content with
tags removed as a paragraph, except that `<img src=… alt=…>` elements
become image nodes (and when the enclosing element has `align="center"`
the image is centered), `<br>` is a hard break, `<hr>` a thematic break,
and comments / `<script>` / `<style>` contents are dropped.  `shr` uses
`shr-insert-document` on `libxml-parse-html-region` when available.  Inline
HTML (`html-inline`) in paragraphs is handled by the same stripping rules.

### Images (see §7 for loading)

Block image = a paragraph whose only content is one image, optionally
wrapped in a link.  Rendered on its own line at column 0 (not centered,
unless from an HTML block with `align=center`), scaled to fit W columns of
pixels and `mdview-image-max-height`.  Optional caption below (alt text,
`mdview-image-caption` face, muted italic; `mdview-image-captions` default
nil).  Inline images (badges) are displayed inline and count as a wrapped
token.  Whenever an image is not displayed (text mode, `mdview-display-
images` nil, remote disabled, load failure, inside tables) the placeholder
is `🖼 ALT` (or `🖼 basename-of-url` when alt is empty) in `mdview-link`
styling; `mdview-image-placeholder-format` controls it.  Placeholders and
images carry `mdview-link` (the image URL) so `RET` opens them.

### Footnotes (improvement)

References render as `[n]` in `mdview-footnote-ref` (fg `accent` #0178D4),
superscript-raised in GUI via a `display` `(raise 0.3)` with smaller
height; definitions are gathered at the end of the document after a thin
rule (W × `─` in `mdview-rule`) as `[n] text…` with continuation indented
by the marker width.  `RET` on a reference jumps to its definition and
vice versa.

## 7. Inline styles

| Node | Face | Spec |
|---|---|---|
| text | `default` | |
| `emphasis` | `mdview-emphasis` | italic |
| `strong` | `mdview-strong` | bold |
| `strikethrough` | `mdview-strikethrough` | `:strike-through t` |
| `code` | `mdview-inline-code` | bold, fg #939393 (dark) / #6E6E6E (light) — Rich "bold dim" |
| `link` | `mdview-link` | underline, fg inherits text; `mouse-face` `highlight`; `help-echo` URL; text properties `mdview-link` URL, `mdview-link-title` |
| `image` | see §6 | |
| `html-inline` | — | stripped (`<br>` → hard break, `<img>` → image) |
| `footnote-reference` | `mdview-footnote-ref` | |
| `hard-break` | — | newline inside the paragraph |
| `soft-break` | — | one space |

Link targets are rendered as text properties, not buttons, so that `TAB`
can use `text-property-search-forward` and the text stays copyable.

## 8. Code highlighting (`mdview-code.el`)

```elisp
(mdview-code-fontify CODE LANG) → propertized string
```

1. Resolve a major mode: `mdview-code-lang-modes` alist first (ship a
   sensible default table: `elisp`/`emacs-lisp` → `emacs-lisp-mode`,
   `sh`/`bash`/`shell`/`zsh` → `sh-mode`, `js`/`javascript` → `js-mode`,
   `ts` → `typescript-ts-mode` if available, `py` → `python-mode`, `c++`
   → `c++-mode`, `yaml`/`yml`, `json`, `toml`, `html`, `xml`, `css`,
   `lean`/`lean4` → `lean4-mode` if available, `coq` → `coq-mode` if
   available, `ocaml`, `rust`, `go`, `haskell`, `latex`/`tex`, `makefile`,
   `diff`, `dockerfile`, `sql`, …), then `LANG-ts-mode` if that mode's
   grammar is available (`treesit-ready-p`), then `LANG-mode` if `fboundp`.
   Never autoload-trigger a download or prompt.
2. In a temporary buffer: insert code, set the mode with
   `delay-mode-hooks` and all hooks suppressed, `font-lock-ensure`, wrap in
   `condition-case` + `with-demoted-errors`; on any error return plain
   text.  Skip highlighting entirely above
   `mdview-code-highlight-max-chars` (default 100 000).
3. When `mdview-code-material-theme` is t (default), replace faces: walk
   the `face` property and map each standard `font-lock-*-face` to the
   corresponding `mdview-code-*` face with Material colours; unknown
   faces → `mdview-code-block` (#EEFFFF).  When nil, keep the mode's faces
   and only add the block background.

Material mapping (fg on #263238):

| font-lock face | mdview face | colour |
|---|---|---|
| keyword | `mdview-code-keyword` | #BB80B3 |
| builtin | `mdview-code-builtin` | #82AAFF |
| function-name | `mdview-code-function` | #82AAFF |
| variable-name, variable-use | `mdview-code-variable` | #89DDFF |
| type | `mdview-code-type` | #FFCB6B |
| constant | `mdview-code-constant` | #89DDFF |
| string | `mdview-code-string` | #C3E88D |
| doc, doc-markup | `mdview-code-doc` | #546E7A italic |
| comment, comment-delimiter | `mdview-code-comment` | #546E7A italic |
| preprocessor | `mdview-code-preprocessor` | #89DDFF italic |
| number | `mdview-code-number` | #F78C6C |
| operator | `mdview-code-operator` | #89DDFF |
| bracket, punctuation, delimiter | `mdview-code-punctuation` | #89DDFF |
| property-name, property-use | `mdview-code-property` | #FFCB6B |
| escape, regexp-grouping-* | `mdview-code-escape` | #89DDFF |
| warning | `mdview-code-error` | #FF5370 |
| negation-char, misc-punctuation | `mdview-code-operator` | #89DDFF |

Faces may appear as lists or anonymous plists; handle `(face1 face2)`,
`(:inherit …)` and `nil`.

## 9. Images (`mdview-image.el`)

```elisp
(mdview-image-insert URL ALT &key base-dir max-width-px max-height-px inline)
```

- Display only when `(display-graphic-p)` and `(image-type-available-p)`
  for the file's type (detect via `image-type-from-file-name` /
  `image-type-from-data`); otherwise insert the placeholder.
- Local paths resolve against `base-dir` (the Markdown file's directory,
  or `default-directory`); `file://` URLs are local.  Absolute paths and
  `~` work.
- Scaling: `create-image` with `:max-width` = min(content width in
  pixels, `mdview-image-max-width` if set) and `:max-height` =
  `mdview-image-max-height` (default: 60 % of `frame-pixel-height`), using
  Emacs's native scaling (no ImageMagick).  SVG via the `svg` image type;
  for SVG pass `:width` when the intrinsic size is unavailable.
- Remote (`http(s)`) images: when `mdview-display-remote-images` (default
  t), insert the placeholder immediately and fetch asynchronously with
  `url-retrieve` (`url-queue-retrieve`), replacing the placeholder — found
  via a marker/overlay stored on it — when data arrives, if the buffer is
  still live and the placeholder still present.  Cache decoded data per
  URL in a session hash table (`mdview-image-cache`), limit concurrent
  fetches, time out after `mdview-image-timeout` (default 10 s), and treat
  any error as "keep the placeholder".  Never block the UI.
- `mdview-toggle-images` re-renders with display inverted.
- Image text carries `help-echo` (alt / url), `mdview-link` URL, and
  `keymap` so `RET` opens the image (`mdview-open-image`: local → `find-
  file`, remote → `browse-url`).

## 10. Commands, modes, integration (`mdview.el`)

- `mdview-mode`: derived from `special-mode`; `truncate-lines t`,
  `buffer-read-only t`, `cursor-type` as default (users navigate), imenu
  index from heading properties, `left-margin-width`/`right-margin-width`
  = `mdview-margin` (default 4) with `mdview-center-content` (default nil)
  enlarging the left margin to center the content when the window is wider
  than `mdview-max-width` + margins.
- Buffer-local state: source buffer, source file, base dir, last render
  width, history (list of `(file-or-buffer . point)`), images-enabled flag.
- Commands: `mdview` (render current buffer → `*mdview: NAME*`, display with
  `mdview-display-action`, default same window), `mdview-file`,
  `mdview-toggle`, `mdview-refresh` (`g`), `mdview-quit` (`q`: `quit-window`,
  or switch back to the source buffer if the view was opened from it in
  the same window), `mdview-next-link`/`mdview-previous-link` (`TAB`/`S-
  TAB`), `mdview-follow-link` (`RET`, also `mouse-1`/`mouse-2`),
  `mdview-next-heading`/`mdview-previous-heading` (`n`/`p`),
  `mdview-toc` (`t`, `imenu`), `mdview-history-back`/`-forward` (`l`/`r`),
  `mdview-toggle-images` (`i`), `mdview-visit-source` (`e`),
  `mdview-copy-link` (`w`), `SPC`/`DEL`/`S-SPC` scroll.  `C-c C-v` in the
  view runs `mdview-toggle` too.
- Link following: `#anchor` → heading with that `mdview-heading-id`
  (also try the slug of the raw anchor); `path.md[#anchor]` relative to
  base dir → render that file in the *same* view buffer (push history);
  other local files → `find-file-other-window`; `http(s)`/`mailto` →
  `browse-url`; images → `mdview-open-image`.
- Source sync: `mdview-toggle` from the source places point in the view at
  the first rendered block whose `mdview-source-line` ≥ the source line;
  `mdview-visit-source` and `mdview-toggle` from the view do the reverse
  using the nearest preceding `mdview-source-line`.
- Refit: `mdview-auto-refit` (default t) re-renders via a 0.2 s idle timer
  from `window-size-change-functions` when the effective width changed,
  preserving the current source line.  `mdview-refresh-on-save` (default t)
  re-renders when the source buffer is saved (hook installed in the source
  buffer; removed when the view is killed).
- Width: `W = min(window-body-width − 2·margin − 1, mdview-max-width or ∞)`,
  at least 20.
- Integration: `mdview-install-keybinding KEY` binds KEY to `mdview-toggle`
  in `markdown-mode-map`, `gfm-mode-map` and `md-mode-map` (each via
  `with-eval-after-load`).  Autoload cookies on `mdview`, `mdview-file`,
  `mdview-toggle`, `mdview-mode`, `mdview-install-keybinding`.
- Everything that touches the display (face remapping, `display-graphic-p`
  checks, image sizes) must degrade gracefully in `--batch` so that tests
  run headless.

## 11. Faces and palette (`mdview-faces.el`)

Textual default design, resolved:

| Variable | dark | light | Used for |
|---|---|---|---|
| background (app) | #1E1E1E | #F5F5F5 | *not applied* — the user's theme background is used |
| text | #E1E1E1 | #202020 | default text — inherits `default` |
| text-muted | #A5A5A5 | #666666 | H6, captions |
| foreground | #EDEDED | #101010 | H3 rule |
| panel | #24292F | #DCE3E8 | H2 box, table box |
| boost | +4 % white | +4 % black | quote background (derived) |
| primary | #004578 | #004578 | thematic break |
| primary-lighten-1 | #23568B | #23568B | table header rule |
| accent-darken-2 | #0053AA | #0053AA | H1 box |
| accent | #0178D4 | #0178D4 | footnote refs |
| success | #4EBF71 | #4EBF71 | bullets, numbers, quote bar, checked task |
| code background | #263238 | #263238 | code blocks |
| code text | #EEFFFF | #EEFFFF | code blocks |
| inline code | #939393 | #6E6E6E | bold |

Define every face with `defface` using `((((background dark)) …)
(((background light)) …))` specs; `mdview-faces-remap` installs the
derived faces (`mdview-quote` levels, `mdview-box-frame`) buffer-locally
with `face-remap-add-relative`, computing from `(face-background 'default
nil t)` with `color-name-to-rgb` blending; fall back to the static spec
when colours are unavailable (`--batch`, `-nw` without truecolor).  In a
256-colour terminal Emacs approximates colours automatically; nothing
special is required, but faces must not rely on `:extend`.

## 12. Text-mode (emacs -nw) requirements

Everything must render without a graphical display: no image display,
placeholders instead; all glyphs are single-width in `char-width` terms
(the five bullets, `▌ ▎ ▊ ▁ ▔ ━ ─ │ ☐ ☑`), and `mdview-ascii-glyphs` is
used automatically when `(char-displayable-p ?●)` is nil (`*`, `-`, `+`,
`|`, `-`, `=`, `[ ]`, `[x]`).  Verify with `make shot` (tmux-based
capture) in both `modus-vivendi` and `modus-operandi`.

## 13. Testing and tooling

- ERT files `test/mdview-*-test.el`, run by `make test` (headless).  Unit
  tests per module: AST helpers/slugs, inline parser (each construct and
  the tricky emphasis cases), block parser (each block type, nesting,
  loose/tight, tables, refs, footnotes, `:line`), wrapping, margins
  (exact blank-line counts), table layout (widths, expansion, wrapping,
  alignment), code fontification (mapping, guides, unknown language),
  image module (placeholders in batch, path resolution, cache), commands
  (toggle round-trip, link navigation, anchors, history, refresh).
- Golden tests: `test/mdview-golden-test.el` renders every
  `test/fixtures/*.md` at width 80 in batch (images → placeholders) and
  compares the plain text to `test/golden/<name>.txt`; `make golden`
  regenerates.  Golden files are reviewed by eye against
  `test/reference/showcase.frogmouth.txt` (the Frogmouth grid at width 100
  content / 110 terminal).
- CommonMark conformance: §4.
- Visual checks: `make render FILE=… WIDTH=…` (plain text),
  `make render-faces` (text with `{face}` markers), `make render-ansi`
  (24-bit ANSI), `make shot FILE=…` (real text-mode Emacs in tmux →
  `/tmp/mdview-shots/*.png` via Rich + rsvg-convert).  For GUI image
  checks without screenshots, `scripts/gui-check.el` (to be written)
  renders a fixture in a graphical Emacs started in the background and
  writes a report of every `display` image property and its size.

## 14. Reference materials

- `test/reference/showcase.frogmouth.txt` — Frogmouth's exact character
  grid for `test/fixtures/showcase.md` at 110 columns (content width 100).
- `test/reference/showcase-{dark,light}.svg` — Frogmouth screenshots;
  convert with `rsvg-convert` and crop with `scripts/crop-png.py` to view.
- Textual 0.43 `textual/widgets/_markdown.py` (DEFAULT_CSS per block) and
  Rich `box.SIMPLE_HEAVY`; Pygments `material` style; Textual's "wide" and
  "outer" border glyph sets — all summarized above so the sources are not
  needed, but they are installed at
  `~/.local/share/uv/tools/frogmouth/lib/python3.11/site-packages/` on the
  author's machine.

## 15. Module API summary (the exact signatures modules agree on)

```elisp
;; mdview-ast.el
(mdview-node TYPE PLIST &rest CHILDREN)
(mdview-node-type NODE) (mdview-node-props NODE) (mdview-node-prop NODE KEY)
(mdview-node-children NODE) (mdview-node-text NODE) (mdview-slug STRING)
(mdview-ast-decode-entities STRING)        ; &amp; &#123; &#x1F; … → text

;; mdview-inline.el
(mdview-inline-parse STRING REFS)          ; REFS: hash label→(URL . TITLE), may be nil → list of inline nodes

;; mdview-parse.el
(mdview-parse-string STRING) (mdview-parse-buffer &optional BUFFER)   ; → document node

;; mdview-faces.el
(mdview-faces-remap)                       ; install derived faces buffer-locally; safe in batch
(mdview-glyph KEY)                         ; KEY ∈ bullet-1..5, quote-bar, box-top, box-bottom, box-left,
                                           ; box-right, rule, thin-rule, guide, task-checked, task-unchecked,
                                           ; table-rule, h3-rule, image  → string (ASCII profile when needed)

;; mdview-code.el
(mdview-code-fontify CODE LANG)            ; → propertized string, no trailing newline, no background yet
(mdview-code-indent-guides LINE)           ; → LINE with guide glyphs substituted in leading whitespace

;; mdview-image.el
(mdview-image-displayable-p URL &optional BASE-DIR)   ; nil in batch / text mode
(mdview-image-insert URL ALT &key base-dir max-width-px max-height-px inline)
                                           ; inserts image or placeholder at point, returns (COLUMNS . KIND)
                                           ; KIND ∈ image, placeholder, pending
(mdview-image-placeholder URL ALT)         ; → propertized placeholder string
(mdview-image-clear-cache)

;; mdview-table.el
(mdview-table-layout TABLE-NODE INNER-WIDTH RENDER-CELL-FN WRAP-FN &key expand)
   ;; RENDER-CELL-FN: (lambda (TABLE-CELL-NODE) → propertized string)
   ;; WRAP-FN: (lambda (STRING WIDTH) → list of propertized lines)
   ;; → list of propertized lines, each exactly INNER-WIDTH columns, in order:
   ;;    header line(s) (bold), rule line, body lines; no frame, no blank edge rows

;; mdview-render.el
(mdview-render-document DOC &key width base-dir)   ; insert at point in current buffer
(mdview-render-inlines INLINES &optional CTX)      ; → propertized string (images → placeholder/inline)
(mdview-wrap STRING WIDTH)                         ; → list of propertized lines
```

Text properties the renderer must set: `mdview-source-line` (first line of
each block), `mdview-heading-level` + `mdview-heading-id` (heading text),
`mdview-link` (URL on links, images, placeholders), `mdview-link-title`,
`mdview-footnote-ref` / `mdview-footnote-def` (index), `help-echo` and
`mouse-face` on links.
