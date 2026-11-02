;;; mdview-render.el --- Layout engine and renderer for mdview  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Vadim Zaliva

;; Author: Vadim Zaliva
;; Keywords: text, docs
;; Package-Requires: ((emacs "29.1"))

;; This file is part of mdview, distributed under the MIT license; see
;; LICENSE in the repository root.

;;; Commentary:

;; The layout engine and the block/inline renderer of mdview
;; (docs/DESIGN.md sections 5, 6 and 7).  `mdview-render-document' walks
;; a document AST and inserts propertized lines into the current buffer.
;; Everything is laid out in columns of the `default' face: text is
;; hard-wrapped at render time (`mdview-wrap'), every line is padded with
;; spaces to the content width and backgrounds come from faces on those
;; characters, so graphical and text-mode frames agree.
;;
;; Rendering is driven by a context (`mdview-render-ctx') carrying the
;; content width, the line prefix (quote bars, list indentation), the
;; prefix of the next line only (a list bullet), a suffix (the right
;; padding of block quotes), the background face painting the padding and
;; the nesting state.  `mdview-render--emit-line' is the only place that
;; writes a line: PREFIX + STRING + padding + SUFFIX + newline, so the
;; width of every line is the width of the prefix plus the context width
;; plus the width of the suffix (code lines wider than the width are the
;; one exception; they run past the edge without background).
;;
;; Vertical spacing follows Textual's margin collapsing: each block type
;; has a top and a bottom margin (`mdview-render--margins'); between two
;; siblings the larger of the two is emitted as blank lines, never before
;; the first or after the last child of a container.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'mdview-ast)
(require 'mdview-faces)
(require 'mdview-code)
(require 'mdview-image)
(require 'mdview-table)

(declare-function libxml-parse-html-region "xml.c"
                  (start end &optional base-url discard-comments))
(declare-function shr-insert-document "shr" (dom))
(defvar shr-width)
(defvar shr-use-fonts)
(defvar shr-inhibit-images)

;;;; Options

(defcustom mdview-html-renderer 'strip
  "How HTML blocks are rendered.
`strip' removes the tags and renders the text content as paragraphs:
<img> elements become images, <br> a hard break, <hr> a thematic break,
and comments, <script> and <style> contents are dropped.  `shr' renders
the block with the `shr' library when Emacs has libxml support and falls
back to `strip' otherwise.  Inline HTML inside paragraphs is always
stripped."
  :type '(choice (const :tag "Strip tags" strip)
                 (const :tag "Render with shr" shr))
  :group 'mdview)

(defcustom mdview-min-content-width 10
  "Fewest columns a nested container may leave for its content.
A block quote or list item nested inside another container gets its own
bar or indentation only while at least this many columns remain for the
text; deeper containers are rendered flat in the enclosing context, so
the output never degenerates into one character per line, however deep
the source nests.  Top-level containers always nest, whatever the width."
  :type 'natnum
  :group 'mdview)

;;;; Rendering context

(cl-defstruct (mdview-render-ctx
               (:constructor mdview-render--ctx-make)
               (:copier nil))
  "The state threaded through the renderer (docs/DESIGN.md section 5.1).
Lines are PREFIX (or FIRST-PREFIX once) + content padded to WIDTH +
SUFFIX; BG paints the padding."
  (width 80 :documentation "Columns available for content at this level.")
  (prefix "" :documentation "Propertized string starting every line.")
  (first-prefix nil :documentation "Prefix of the next line only, or nil.")
  (suffix "" :documentation "Propertized string ending every line.")
  (bg nil :documentation "Face painting the padding, or nil.")
  (tight nil :documentation "Non-nil inside a tight list item.")
  (quote-level 0 :documentation "Number of enclosing block quotes.")
  (bullet-depth 0 :documentation "Number of enclosing bullet lists.")
  (in-list nil :documentation "Non-nil inside a list item.")
  (images t :documentation "Whether real images may be produced.")
  (base-dir nil :documentation "Directory resolving relative paths, or nil.")
  (parent nil :documentation "The enclosing context, or nil."))

(cl-defun mdview-render--ctx-child (ctx &key (addition "") (first-addition addition)
                                        (suffix-addition "")
                                        (bg (mdview-render-ctx-bg ctx))
                                        (tight (mdview-render-ctx-tight ctx))
                                        (quote-level (mdview-render-ctx-quote-level ctx))
                                        (bullet-depth (mdview-render-ctx-bullet-depth ctx))
                                        (in-list (mdview-render-ctx-in-list ctx)))
  "Return a context nested inside CTX.
ADDITION is appended to the prefix of CTX and FIRST-ADDITION (default
ADDITION) to the prefix of the first line; SUFFIX-ADDITION is prepended
to the suffix.  The width shrinks by the widths of ADDITION and
SUFFIX-ADDITION.  BG, TIGHT, QUOTE-LEVEL, BULLET-DEPTH and IN-LIST
default to the values of CTX; images and base-dir are inherited."
  (let ((parent-first (mdview-render-ctx-first-prefix ctx))
        (prefix (mdview-render-ctx-prefix ctx)))
    (mdview-render--ctx-make
     :width (max 1 (- (mdview-render-ctx-width ctx)
                      (string-width addition)
                      (string-width suffix-addition)))
     :prefix (concat prefix addition)
     :first-prefix (cond (parent-first (concat parent-first first-addition))
                         ((not (eq first-addition addition))
                          (concat prefix first-addition))
                         (t nil))
     :suffix (concat suffix-addition (mdview-render-ctx-suffix ctx))
     :bg bg :tight tight :quote-level quote-level :bullet-depth bullet-depth
     :in-list in-list
     :images (mdview-render-ctx-images ctx)
     :base-dir (mdview-render-ctx-base-dir ctx)
     :parent ctx)))

(defun mdview-render--with-bg (string bg)
  "Append face BG below the faces of STRING and return STRING.
Nothing happens when BG is nil.  STRING is modified in place, so pass a
fresh string."
  (when (and bg (> (length string) 0))
    (add-face-text-property 0 (length string) bg t string))
  string)

;;;; Line emission

(defun mdview-render--take-prefix (ctx)
  "Return the prefix for the next line of CTX.
A pending first-line prefix is returned once and then cleared in CTX and
in every enclosing context, so a list bullet appears exactly once."
  (let ((first (mdview-render-ctx-first-prefix ctx)))
    (if (null first)
        (mdview-render-ctx-prefix ctx)
      (let ((c ctx))
        (while c
          (setf (mdview-render-ctx-first-prefix c) nil)
          (setq c (mdview-render-ctx-parent c))))
      first)))

(defun mdview-render--string-width (string)
  "Return the display width of STRING in columns.
Like `string-width', except that a span carrying the text property
`mdview-columns' (an inline image) counts as that many columns."
  (let ((n (length string)))
    (if (not (text-property-not-all 0 n 'mdview-columns nil string))
        (string-width string)
      (let ((pos 0) (width 0))
        (while (< pos n)
          (let ((cols (get-text-property pos 'mdview-columns string))
                (next (or (next-single-property-change pos 'mdview-columns string)
                          n)))
            (setq width (+ width (or cols (string-width string pos next)))
                  pos next)))
        width))))

(defun mdview-render--emit-line-1 (prefix string ctx)
  "Insert PREFIX, then STRING as the content of one line of CTX, at point.
The content is padded with spaces to the width of CTX and followed by
the suffix of CTX and a newline; the background face of CTX is added
below the faces of STRING, the padding and the suffix."
  (let ((bg (mdview-render-ctx-bg ctx))
        (pad (- (mdview-render-ctx-width ctx)
                (mdview-render--string-width string))))
    (insert prefix)
    (let ((start (point)))
      (insert string)
      (when (> pad 0)
        (insert (make-string pad ?\s)))
      (insert (mdview-render-ctx-suffix ctx))
      (when bg
        (add-face-text-property start (point) bg t)))
    (insert "\n")))

(defun mdview-render--emit-line (string ctx)
  "Insert STRING as one line of CTX at point.
The line is the prefix of CTX (its first-line prefix when one is
pending), STRING, spaces padding the content to the width of CTX, the
suffix of CTX and a newline.  The background face of CTX is added below
the faces of STRING, the padding and the suffix; prefixes carry their
own background (see `mdview-render--with-bg'), so nested backgrounds
stay distinct."
  (mdview-render--emit-line-1 (mdview-render--take-prefix ctx) string ctx))

(defun mdview-render--emit-blank-lines (count ctx)
  "Insert COUNT blank lines of CTX (prefix, padding and suffix included)."
  (dotimes (_ count)
    (mdview-render--emit-line "" ctx)))

;;;; Wrapping

(defun mdview-render--plain-space-p (string pos atoms)
  "Return non-nil when STRING has a breakable space at POS.
ATOMS non-nil means STRING carries `mdview-columns' spans (inline
images), whose characters are never treated as spaces."
  (and (eq (aref string pos) ?\s)
       (not (and atoms (get-text-property pos 'mdview-columns string)))))

(defun mdview-render--wrap-segment (string start end width lines)
  "Wrap STRING between START and END (no newlines) at WIDTH columns.
Push each resulting line onto LINES and return the new list.  A span
with the text property `mdview-columns' (an inline image) counts as
that many columns and is never split.  A span with the text property
`mdview-nobreak' (an image placeholder) moves to the next line as a
whole when it does not fit; it is broken at its inner spaces only when
it is wider than WIDTH by itself."
  (let ((pos start)
        (atoms (text-property-not-all start end 'mdview-columns nil string))
        (nobreak (text-property-not-all start end 'mdview-nobreak nil string))
        (count 0))
    (while (< pos end)
      (while (and (< pos end) (mdview-render--plain-space-p string pos atoms))
        (setq pos (1+ pos)))
      (when (< pos end)
        (let ((line-start pos) (cur pos) (w 0)
              (last-space nil) (inner-space nil) (line-end nil))
          (while (and (null line-end) (< cur end))
            (let* ((c (aref string cur))
                   (cols (and atoms (get-text-property cur 'mdview-columns string)))
                   (unit-end (if cols
                                 (min end (or (next-single-property-change
                                               cur 'mdview-columns string)
                                              end))
                               (1+ cur)))
                   (uw (or cols (char-width c))))
              (when (and (null cols) (eq c ?\s))
                (if (and nobreak (get-text-property cur 'mdview-nobreak string))
                    (setq inner-space cur)
                  (setq last-space cur)))
              (if (<= (+ w uw) width)
                  (setq w (+ w uw) cur unit-end)
                (setq line-end (cond (last-space last-space)
                                     (inner-space inner-space)
                                     ((> cur line-start) cur)
                                     (t unit-end))))))
          (unless line-end (setq line-end end))
          (let ((e line-end))
            (while (and (> e line-start)
                        (mdview-render--plain-space-p string (1- e) atoms))
              (setq e (1- e)))
            (push (substring string line-start e) lines)
            (setq count (1+ count)))
          (setq pos line-end))))
    (if (zerop count) (cons "" lines) lines)))

(defun mdview-wrap (string width)
  "Wrap STRING into a list of lines at most WIDTH columns wide.
Lines break greedily at spaces; a token longer than WIDTH is broken at
WIDTH.  A newline character in STRING forces a line break and a tab
counts as a space (its display width depends on the column, which the
layout cannot know).  Leading and trailing spaces of every line are
removed.  Widths are measured with `string-width', except that a span
with the text property `mdview-columns' (an inline image) counts as that
many columns and is never split; a span with `mdview-nobreak' (an image
placeholder) is kept on one line unless it is wider than WIDTH.  Text
properties are preserved because lines are substrings of STRING."
  (let ((width (max 1 width))
        (string (if (string-search "\t" string)
                    (subst-char-in-string ?\t ?\s string)
                  string))
        (n (length string))
        (pos 0)
        (lines nil))
    (while (<= pos n)
      (let ((nl (or (string-search "\n" string pos) n)))
        (setq lines (mdview-render--wrap-segment string pos nl width lines)
              pos (1+ nl))))
    (nreverse lines)))

;;;; Glyph and box helpers

(defun mdview-render--repeat-glyph (glyph width)
  "Return a string of WIDTH columns made of GLYPH repeated."
  (let ((width (max 0 width))
        (glyph (if (string-empty-p glyph) "-" glyph)))
    (if (= (length glyph) 1)
        (make-string width (aref glyph 0))
      (truncate-string-to-width
       (apply #'concat (make-list (ceiling width (max 1 (string-width glyph)))
                                  glyph))
       width nil ?\s))))

(defun mdview-render--rule (glyph-key face width)
  "Return a rule of WIDTH columns of the glyph GLYPH-KEY in FACE."
  (propertize (mdview-render--repeat-glyph (mdview-glyph glyph-key) width)
              'face face))

(defun mdview-render--box-frame-row (glyph-key box-face width)
  "Return the top or bottom row of a box of WIDTH columns.
GLYPH-KEY is `box-top' or `box-bottom'; the glyphs get `mdview-box-frame'
over BOX-FACE.  With `mdview-box-frame-style' `none' the row is blank."
  (if (eq mdview-box-frame-style 'none)
      (propertize (make-string width ?\s) 'face box-face)
    (propertize (mdview-render--repeat-glyph (mdview-glyph glyph-key) width)
                'face (list 'mdview-box-frame box-face))))

(defun mdview-render--box-body-row (content box-face width)
  "Return a body row of a box of WIDTH columns holding CONTENT.
CONTENT is at most WIDTH - 4 columns wide; the row is the left frame
glyph, one column of padding, CONTENT padded to WIDTH - 4, one column of
padding and the right frame glyph, all on BOX-FACE."
  (let* ((none (eq mdview-box-frame-style 'none))
         (fill (max 0 (- width 4 (mdview-render--string-width content))))
         (row (concat (if none " "
                        (propertize (mdview-glyph 'box-left) 'face 'mdview-box-frame))
                      " " content (make-string fill ?\s) " "
                      (if none " "
                        (propertize (mdview-glyph 'box-right) 'face 'mdview-box-frame)))))
    (add-face-text-property 0 (length row) box-face t row)
    row))

(defun mdview-render--emit-box (lines box-face ctx)
  "Emit a box on BOX-FACE around LINES in CTX.
The box is a frame row, a blank row, one body row per line, a blank row
and a frame row (docs/DESIGN.md section 6, \"Boxes\")."
  (let ((width (mdview-render-ctx-width ctx)))
    (mdview-render--emit-line
     (mdview-render--box-frame-row 'box-top box-face width) ctx)
    (mdview-render--emit-line (mdview-render--box-body-row "" box-face width) ctx)
    (dolist (line lines)
      (mdview-render--emit-line
       (mdview-render--box-body-row line box-face width) ctx))
    (mdview-render--emit-line (mdview-render--box-body-row "" box-face width) ctx)
    (mdview-render--emit-line
     (mdview-render--box-frame-row 'box-bottom box-face width) ctx)))

(defun mdview-render--center (string width)
  "Return STRING preceded by the spaces that center it in WIDTH columns."
  (let ((left (/ (- width (mdview-render--string-width string)) 2)))
    (if (> left 0) (concat (make-string left ?\s) string) string)))

(defun mdview-render--max-width-px (width)
  "Return the pixel width of WIDTH columns on a graphical display, else nil."
  (when (display-graphic-p)
    (* width (frame-char-width))))

;;;; Inline rendering

(defun mdview-render--link-properties (url title)
  "Return the text properties marking a link to URL with TITLE (or nil)."
  (append (list 'mdview-link url 'help-echo url
                'mouse-face 'highlight 'follow-link t)
          (when title (list 'mdview-link-title title))))

(defvar mdview-render--inline-depth 0
  "Nesting depth of the inline node being rendered.")

(defconst mdview-render--max-inline-depth 100
  "Deepest inline nesting rendered structurally.
Below this depth container nodes are rendered as their plain text, so
that pathological input (thousands of nested emphasis delimiters) cannot
exhaust `max-lisp-eval-depth'; the enclosing faces still apply.")

(defun mdview-render--inline-faced (node face ctx)
  "Render the children of NODE in CTX and add FACE below their faces."
  (let ((text (let ((mdview-render--inline-depth (1+ mdview-render--inline-depth)))
                (mdview-render-inlines (mdview-node-children node) ctx))))
    (add-face-text-property 0 (length text) face t text)
    text))

(defun mdview-render--inline-link (node ctx)
  "Render the link NODE in CTX: underlined text carrying the link properties."
  (let* ((url (or (mdview-node-prop node :url) ""))
         (title (mdview-node-prop node :title))
         (text (let ((mdview-render--inline-depth (1+ mdview-render--inline-depth)))
                 (mdview-render-inlines (mdview-node-children node) ctx))))
    (when (string-empty-p text)
      (setq text (copy-sequence url)))
    (add-face-text-property 0 (length text) 'mdview-link t text)
    (add-text-properties 0 (length text)
                         (mdview-render--link-properties url title) text)
    text))

(defun mdview-render--image-alt (node)
  "Return the alt text of the image NODE."
  (or (mdview-node-prop node :alt) (mdview-node-text node)))

(defun mdview-render--nobreak (string)
  "Mark STRING, modified in place, as a span that `mdview-wrap' does not split."
  (when (> (length string) 0)
    (put-text-property 0 (length string) 'mdview-nobreak t string))
  string)

(defun mdview-render--inline-image (node ctx)
  "Render the image NODE inline in CTX.
Return the placeholder when CTX forbids real images; otherwise let
`mdview-image-insert' produce the token in a temporary buffer and mark
it with `mdview-columns' when it is a real image, so that `mdview-wrap'
treats it as one token of the right width.  Placeholders are marked
with `mdview-nobreak' so that a badge's text is not split over lines."
  (let ((url (or (mdview-node-prop node :url) ""))
        (alt (mdview-render--image-alt node)))
    (if (not (mdview-render-ctx-images ctx))
        (mdview-render--nobreak (mdview-image-placeholder url alt))
      (with-temp-buffer
        (let* ((result (mdview-image-insert
                        url alt
                        :base-dir (mdview-render-ctx-base-dir ctx)
                        :max-width-px (mdview-render--max-width-px
                                       (mdview-render-ctx-width ctx))
                        :inline t))
               (token (buffer-string))
               (cols (car-safe result)))
          (cond
           ((and (natnump cols) (> (length token) 0)
                 (or (eq (cdr-safe result) 'image)
                     (/= cols (string-width token))))
            (put-text-property 0 (length token) 'mdview-columns cols token))
           ((not (eq (cdr-safe result) 'image))
            (mdview-render--nobreak token)))
          token)))))

(defun mdview-render--footnote-ref (node)
  "Render the footnote reference NODE as a raised [n] marker."
  (let* ((index (or (mdview-node-prop node :index) 0))
         (text (propertize (format "[%d]" index)
                           'face 'mdview-footnote-ref
                           'mdview-footnote-ref index
                           'help-echo (format "Footnote %d" index))))
    (when (display-graphic-p)
      (put-text-property 0 (length text) 'display '((raise 0.3) (height 0.8))
                         text))
    text))

(defun mdview-render--html-attr (tag name)
  "Return the entity-decoded value of attribute NAME in the HTML TAG, or nil."
  (let ((case-fold-search t))
    (when (string-match
           (concat "[[:space:]]" (regexp-quote name)
                   "[[:space:]]*=[[:space:]]*"
                   "\\(?:\"\\([^\"]*\\)\"\\|'\\([^']*\\)'\\|\\([^[:space:]\"'>]+\\)\\)")
           tag)
      (mdview-ast-decode-entities
       (or (match-string 1 tag) (match-string 2 tag) (match-string 3 tag))))))

(defun mdview-render--html-spacer-p (tag src)
  "Return non-nil when the <img> TAG with source SRC is a layout spacer.
Spacers are at most two pixels wide or high, or named after \"spacer\";
they only contribute vertical space on GitHub, so nothing is shown."
  (or (seq-some (lambda (name)
                  (let ((value (mdview-render--html-attr tag name)))
                    (and value
                         (string-match-p "\\`[[:space:]]*[0-9]+\\(?:px\\)?[[:space:]]*\\'"
                                         value)
                         (<= (string-to-number value) 2))))
                '("width" "height"))
      (string-match-p "spacer" (file-name-nondirectory
                                (car (split-string src "[?#]"))))))

(defun mdview-render--html-image-node (tag)
  "Return an `image' node for the HTML <img> TAG, or nil.
Nil is returned without a src attribute and for spacer images (see
`mdview-render--html-spacer-p')."
  (let ((src (mdview-render--html-attr tag "src")))
    (when (and src (not (mdview-render--html-spacer-p tag src)))
      (mdview-node 'image (list :url src
                                :alt (or (mdview-render--html-attr tag "alt") "")
                                :title (mdview-render--html-attr tag "title"))))))

(defun mdview-render--html-tag-name (node)
  "Return (NAME . CLOSING) for the `html-inline' NODE holding a tag, else nil.
NAME is the lower-case element name; CLOSING is non-nil for an end tag."
  (let ((tag (car (mdview-node-children node))))
    (when (and (stringp tag)
               (string-match "\\`<\\(/?\\)\\([A-Za-z][A-Za-z0-9-]*\\)" tag))
      (cons (downcase (match-string 2 tag))
            (not (string-empty-p (match-string 1 tag)))))))

(defun mdview-render--inline-html (node ctx)
  "Render the raw inline HTML NODE in CTX by stripping it.
<br> becomes a newline and <img> an inline image; anything else vanishes."
  (let ((tag (or (car (mdview-node-children node)) ""))
        (case-fold-search t))
    (cond
     ((string-match-p "\\`<br[[:space:]/>]" tag) "\n")
     ((string-match-p "\\`<img[[:space:]/>]" tag)
      (let ((image (mdview-render--html-image-node tag)))
        (if image (mdview-render--inline-image image ctx) "")))
     (t ""))))

(defun mdview-render--flat-text (node)
  "Return the plain text of the inline NODE and its descendants.
Unlike `mdview-node-text' this does not recurse, so it copes with trees
of any depth; breaks become a space or a newline."
  (let ((stack (list node)) (parts nil))
    (while stack
      (let ((n (pop stack)))
        (cond
         ((stringp n) (push n parts))
         ((not (consp n)) nil)
         ((eq (mdview-node-type n) 'soft-break) (push " " parts))
         ((eq (mdview-node-type n) 'hard-break) (push "\n" parts))
         (t (setq stack (append (mdview-node-children n) stack))))))
    (apply #'concat (nreverse parts))))

(defun mdview-render--inline (node ctx)
  "Render the inline NODE in CTX to a propertized string.
Container nodes nested deeper than `mdview-render--max-inline-depth'
are rendered as their plain text."
  (cond
   ((stringp node) node)
   ((and (> mdview-render--inline-depth mdview-render--max-inline-depth)
         (memq (mdview-node-type node) '(emphasis strong strikethrough link)))
    (mdview-render--flat-text node))
   (t
    (pcase (mdview-node-type node)
      ('emphasis (mdview-render--inline-faced node 'mdview-emphasis ctx))
      ('strong (mdview-render--inline-faced node 'mdview-strong ctx))
      ('strikethrough (mdview-render--inline-faced node 'mdview-strikethrough ctx))
      ('code (propertize (mdview-node-text node) 'face 'mdview-inline-code))
      ('link (mdview-render--inline-link node ctx))
      ('image (mdview-render--inline-image node ctx))
      ('hard-break "\n")
      ('soft-break " ")
      ('html-inline (mdview-render--inline-html node ctx))
      ('footnote-reference (mdview-render--footnote-ref node))
      (_ (mdview-render-inlines (mdview-node-children node) ctx))))))

(defun mdview-render-inlines (inlines &optional ctx)
  "Render the list of inline nodes INLINES into one propertized string.
CTX is a `mdview-render-ctx' (default: a fresh top-level context)
supplying the base directory and whether real images may be produced.
Faces follow docs/DESIGN.md section 7; links carry the `mdview-link',
`mdview-link-title', `help-echo' and `mouse-face' properties; hard
breaks become newlines, which `mdview-wrap' turns into line breaks.
Text between <kbd> and </kbd> tags gets the `mdview-inline-code' face."
  (let ((ctx (or ctx (mdview-render--ctx-make)))
        (kbd nil))
    (mapconcat (lambda (node)
                 (let ((tag (and (consp node)
                                 (eq (mdview-node-type node) 'html-inline)
                                 (mdview-render--html-tag-name node))))
                   (cond
                    ((and tag (string= (car tag) "kbd"))
                     (setq kbd (not (cdr tag)))
                     "")
                    ((and kbd (stringp node))
                     (propertize node 'face 'mdview-inline-code))
                    (t (mdview-render--inline node ctx)))))
               inlines "")))

;;;; Margins

(defun mdview-render--margins (node ctx)
  "Return the vertical margins of block NODE in CTX as (TOP . BOTTOM).
The values are the table of docs/DESIGN.md section 5.2."
  (pcase (mdview-node-type node)
    ('heading (if (<= (or (mdview-node-prop node :level) 1) 3) '(0 . 0) '(1 . 1)))
    ('paragraph (if (mdview-render-ctx-tight ctx) '(0 . 0) '(0 . 1)))
    ('blockquote '(1 . 1))
    ;; A nested list has no margins (Textual), except that inside a
    ;; loose item a block following it is separated by one line, as
    ;; the blank line in the source suggests (improvement).
    ('list (cond ((not (mdview-render-ctx-in-list ctx)) '(0 . 1))
                 ((mdview-render-ctx-tight ctx) '(0 . 0))
                 (t '(0 . 1))))
    ('code-block '(1 . 1))
    ('table '(1 . 1))
    ('thematic-break '(0 . 1))
    ('html-block '(0 . 1))
    (_ '(0 . 0))))

(defun mdview-render--blank-inline-p (node)
  "Return non-nil when the inline NODE renders to nothing visible.
Blank strings, breaks and raw HTML tags other than <br> and <img> are
blank."
  (cond
   ((stringp node) (string-blank-p node))
   (t (pcase (mdview-node-type node)
        ((or 'hard-break 'soft-break) t)
        ('html-inline
         (let ((case-fold-search t))
           (not (string-match-p "\\`<\\(?:br\\|img\\)[[:space:]/>]"
                                (or (car (mdview-node-children node)) "")))))
        (_ nil)))))

(defun mdview-render--empty-block-p (node)
  "Return non-nil when block NODE would render as nothing.
A paragraph made only of blank inlines (typically a stripped anchor such
as <a name=\"x\"></a>) is skipped altogether, margins included."
  (and (eq (mdview-node-type node) 'paragraph)
       (seq-every-p #'mdview-render--blank-inline-p (mdview-node-children node))))

(defun mdview-render--blocks (blocks ctx)
  "Render the sibling BLOCKS in CTX with collapsed margins.
Between two siblings the larger of the first's bottom margin and the
second's top margin is emitted as blank lines; nothing is emitted before
the first or after the last.  Blocks that render as nothing are skipped
as if absent.  Return the bottom margin of the last block, or nil when
nothing was rendered."
  (let ((previous nil))
    (dolist (block blocks)
      (unless (mdview-render--empty-block-p block)
        (let ((margins (mdview-render--margins block ctx)))
          (when previous
            (mdview-render--emit-blank-lines (max previous (car margins)) ctx))
          (mdview-render--block block ctx)
          (setq previous (cdr margins)))))
    previous))

(defun mdview-render--container (blocks ctx)
  "Render BLOCKS as the content of a container in CTX.
A container that renders nothing still produces one blank line so that
its prefix (a bullet or a quote bar) is visible."
  (unless (mdview-render--blocks blocks ctx)
    (mdview-render--emit-line "" ctx)))

;;;; Blocks

(defconst mdview-render--heading-faces
  [mdview-h1 mdview-h2 mdview-h3 mdview-h4 mdview-h5 mdview-h6]
  "Faces of heading levels 1 to 6.")

(defun mdview-render--heading (node ctx)
  "Render the heading NODE in CTX (docs/DESIGN.md section 6, \"Headings\")."
  (let* ((level (max 1 (min 6 (or (mdview-node-prop node :level) 1))))
         (width (mdview-render-ctx-width ctx))
         (boxed (<= level 2))
         (text-width (max 1 (if boxed (- width 4) width)))
         (text (string-trim-right
                (mdview-render-inlines (mdview-node-children node) ctx) "\n+"))
         (id (or (mdview-node-prop node :id)
                 (mdview-slug (mdview-node-text node))))
         (face (aref mdview-render--heading-faces (1- level))))
    (add-text-properties 0 (length text)
                         (list 'mdview-heading-level level 'mdview-heading-id id)
                         text)
    (unless boxed
      (add-face-text-property 0 (length text) face t text))
    (let ((lines (mdview-wrap text text-width)))
      (pcase level
        ((or 1 2)
         ;; Both boxes centre their text (Textual: `text-align: center';
         ;; see the reference grid).
         (mdview-render--emit-box
          (mapcar (lambda (line) (mdview-render--center line text-width)) lines)
          (if (= level 1) 'mdview-h1 'mdview-h2) ctx))
        (3 (dolist (line lines) (mdview-render--emit-line line ctx))
           (mdview-render--emit-line
            (mdview-render--rule 'h3-rule 'mdview-h3-rule
                                 (apply #'max (mapcar #'mdview-render--string-width
                                                      lines)))
            ctx))
        (_ (dolist (line lines) (mdview-render--emit-line line ctx)))))))

(defun mdview-render--significant-children (node)
  "Return the children of NODE that are neither blank strings nor breaks."
  (seq-remove (lambda (child)
                (if (stringp child)
                    (string-blank-p child)
                  (memq (mdview-node-type child) '(hard-break soft-break))))
              (mdview-node-children node)))

(defun mdview-render--block-image-p (node)
  "Return (IMAGE . LINK) when paragraph NODE is a block image, else nil.
A block image is a paragraph whose only content is one image, possibly
the sole content of a link; LINK is that link node or nil.  Line breaks
around the image (an <img> followed by <br>) do not count."
  (let ((children (mdview-render--significant-children node)))
    (when (and children (null (cdr children)))
      (let ((child (car children)))
        (pcase (mdview-node-type child)
          ('image (cons child nil))
          ('link (let ((inner (mdview-render--significant-children child)))
                   (when (and inner (null (cdr inner))
                              (eq (mdview-node-type (car inner)) 'image))
                     (cons (car inner) child))))
          (_ nil))))))

(defun mdview-render--truncate-pending (start width)
  "Truncate the pending placeholder between START and point to WIDTH columns.
Characters are deleted from the end, so the text property locating the
placeholder stays on what remains, and an ellipsis marks the cut."
  (let* ((token (buffer-substring start (point)))
         (ellipsis (if (char-displayable-p ?…) "…" "..."))
         (kept (truncate-string-to-width
                token (max 0 (- width (string-width ellipsis)))))
         (props (text-properties-at (1- (length token)) token)))
    (delete-region (+ start (length kept)) (point))
    (insert (apply #'propertize ellipsis props))))

(defun mdview-render--block-image (image link ctx center)
  "Render IMAGE on its own line in CTX, wrapped in LINK when non-nil.
The image is inserted directly into the buffer by `mdview-image-insert'
so that asynchronous replacement of remote placeholders works.  With
CENTER non-nil the image is centered in the content width.  A caption
follows when `mdview-image-captions' is set.

A placeholder (text mode, images disabled, missing file) is wrapped to
the content width like a paragraph; a placeholder awaiting a remote
image must stay on one line and is truncated instead."
  (let* ((url (or (mdview-node-prop image :url) ""))
         (alt (mdview-render--image-alt image))
         (width (mdview-render-ctx-width ctx))
         (bg (mdview-render-ctx-bg ctx))
         (link-props (when link
                       (mdview-render--link-properties
                        (or (mdview-node-prop link :url) "")
                        (mdview-node-prop link :title))))
         (prefix (mdview-render--take-prefix ctx)))
    (insert prefix)
    (let* ((content-start (point))
           (result (if (mdview-render-ctx-images ctx)
                       (mdview-image-insert
                        url alt
                        :base-dir (mdview-render-ctx-base-dir ctx)
                        :max-width-px (mdview-render--max-width-px width)
                        :inline nil)
                     (insert (mdview-image-placeholder url alt))
                     (cons nil 'placeholder)))
           (kind (cdr-safe result)))
      (when link-props
        (add-text-properties content-start (point) link-props))
      (if (and (eq kind 'placeholder)
               (> (string-width (buffer-substring content-start (point))) width))
          ;; Too wide for one line: lay it out as wrapped text instead
          ;; (the prefix already inserted serves the first line).
          (let ((text (mdview-render--nobreak
                       (buffer-substring content-start (point))))
                (first t))
            (delete-region content-start (point))
            (dolist (line (mdview-wrap text width))
              (mdview-render--emit-line-1
               (if first "" (mdview-render-ctx-prefix ctx))
               (if center (mdview-render--center line width) line)
               ctx)
              (setq first nil)))
        (when (and (eq kind 'pending)
                   (> (string-width (buffer-substring content-start (point))) width))
          (mdview-render--truncate-pending content-start width))
        (let* ((cols (if (and (eq kind 'image) (natnump (car-safe result)))
                         (car result)
                       (string-width (buffer-substring content-start (point)))))
               (left (if (and center (< cols width)) (/ (- width cols) 2) 0))
               (pad (max 0 (- width cols left))))
          (when (> left 0)
            (save-excursion
              (goto-char content-start)
              (insert-before-markers (make-string left ?\s))))
          (when (> pad 0)
            (insert (make-string pad ?\s)))
          (insert (mdview-render-ctx-suffix ctx))
          (when bg
            (add-face-text-property content-start (point) bg t))
          (insert "\n"))))
    (when (and mdview-image-captions (not (string-empty-p alt)))
      (dolist (line (mdview-wrap (propertize alt 'face 'mdview-image-caption)
                                 width))
        (mdview-render--emit-line line ctx)))))

(defun mdview-render--paragraph (node ctx)
  "Render the paragraph NODE in CTX: wrapped text or a block image.
Trailing line breaks are dropped (a block-final <br> adds nothing).  A
paragraph with the `:center' property (from an HTML element with
align=\"center\") has every line centered; one with `:summary' (an HTML
<summary>) is set in `mdview-summary' after the `summary' glyph."
  (let ((image (mdview-render--block-image-p node))
        (width (mdview-render-ctx-width ctx))
        (center (mdview-node-prop node :center)))
    (if image
        (mdview-render--block-image (car image) (cdr image) ctx center)
      (let ((text (string-trim-right
                   (mdview-render-inlines (mdview-node-children node) ctx)
                   "\n+")))
        (when (mdview-node-prop node :summary)
          (setq text (string-trim text))
          (add-face-text-property 0 (length text) 'mdview-summary t text)
          (setq text (concat (propertize (mdview-glyph 'summary)
                                         'face 'mdview-summary)
                             " " text)))
        (dolist (line (mdview-wrap text width))
          (mdview-render--emit-line
           (if center (mdview-render--center line width) line) ctx))))))

(defun mdview-render--thematic-break (ctx)
  "Render a thematic break in CTX: a blank padding line and a full rule."
  (mdview-render--emit-line "" ctx)
  (mdview-render--emit-line
   (mdview-render--rule 'rule 'mdview-rule (mdview-render-ctx-width ctx)) ctx))

(defun mdview-render--quote-face (level)
  "Return the background face of a block quote nested LEVEL deep (1-based)."
  (pcase level
    (1 'mdview-quote)
    (2 'mdview-quote-2)
    (_ 'mdview-quote-3)))

(defun mdview-render--nest-p (ctx addition suffix-addition)
  "Return non-nil when a container may nest in CTX.
ADDITION and SUFFIX-ADDITION are what the container would add to the
prefix and suffix.  A top-level container always nests; a container
inside another one nests only while `mdview-min-content-width' columns
remain for its content."
  (or (null (mdview-render-ctx-parent ctx))
      (>= (- (mdview-render-ctx-width ctx)
             (string-width addition)
             (string-width suffix-addition))
          mdview-min-content-width)))

(defconst mdview-render--alert-kinds
  '(("note" "Note" alert-note mdview-alert-note)
    ("tip" "Tip" alert-tip mdview-alert-tip)
    ("important" "Important" alert-important mdview-alert-important)
    ("warning" "Warning" alert-warning mdview-alert-warning)
    ("caution" "Caution" alert-caution mdview-alert-caution))
  "GitHub alert kinds: (KEYWORD TITLE GLYPH-KEY FACE).")

(defun mdview-render--alert (node)
  "Return (KIND . BLOCKS) when the block quote NODE is a GitHub alert.
An alert starts with a paragraph whose first line is only [!KIND] with
KIND one of note, tip, important, warning or caution (any case).  KIND
is the entry of `mdview-render--alert-kinds' and BLOCKS the children of
NODE with the marker removed.  Return nil for an ordinary quote."
  (let* ((blocks (mdview-node-children node))
         (first (car blocks))
         (inlines (and first (eq (mdview-node-type first) 'paragraph)
                       (mdview-node-children first)))
         (head (car inlines))
         (case-fold-search t))
    (when (and (stringp head)
               (string-match "\\`\\[!\\([A-Za-z]+\\)\\][ \t]*\\(?:\n\\|\\'\\)" head))
      (let ((kind (assoc (downcase (match-string 1 head))
                         mdview-render--alert-kinds))
            (rest (substring head (match-end 0)))
            (tail (cdr inlines)))
        (when kind
          (when (and (string-empty-p rest) tail
                     (memq (mdview-node-type (car tail)) '(soft-break hard-break)))
            (setq tail (cdr tail)))
          (let ((body (if (string-empty-p rest) tail (cons rest tail))))
            (cons kind
                  (if (seq-every-p #'mdview-render--blank-inline-p body)
                      (cdr blocks)
                    (cons (apply #'mdview-node 'paragraph
                                 (mdview-node-props first) body)
                          (cdr blocks))))))))))

(defun mdview-render--blockquote (node ctx)
  "Render the block quote NODE in CTX (docs/DESIGN.md section 6).
The bar and one space prefix every line, one column pads the right edge,
and the boost background of the nesting level paints the whole line.  A
nested quote gets two extra columns of left margin; a quote nested too
deep to leave `mdview-min-content-width' columns is rendered flat.  A
GitHub alert (see `mdview-render--alert') paints the bar in the alert's
colour and starts with a bold title line."
  (let* ((alert (mdview-render--alert node))
         (blocks (mdview-render--expand-blocks
                  (if alert (cdr alert) (mdview-node-children node))))
         (level (1+ (mdview-render-ctx-quote-level ctx)))
         (bg (mdview-render--quote-face level))
         (bar-face (if alert (nth 3 (car alert)) 'mdview-quote-border))
         (margin (if (> (mdview-render-ctx-quote-level ctx) 0)
                     (mdview-render--with-bg (make-string 2 ?\s)
                                             (mdview-render-ctx-bg ctx))
                   ""))
         (addition (concat margin
                           (propertize (mdview-glyph 'quote-bar)
                                       'face (list bar-face bg))
                           (propertize " " 'face bg)))
         (suffix-addition (propertize " " 'face bg)))
    (if (not (mdview-render--nest-p ctx addition suffix-addition))
        (mdview-render--container blocks ctx)
      (let ((child (mdview-render--ctx-child
                    ctx :addition addition
                    :suffix-addition suffix-addition
                    :bg bg :tight nil :quote-level level)))
        (when alert
          (pcase-let ((`(,_ ,title ,glyph-key ,face) (car alert)))
            (mdview-render--emit-line
             (concat (propertize (mdview-glyph glyph-key) 'face face)
                     " "
                     (propertize title 'face (list 'mdview-strong face)))
             child)))
        (if blocks
            (mdview-render--container blocks child)
          (unless alert (mdview-render--emit-line "" child)))))))

(defun mdview-render--bullet-glyph (depth)
  "Return the bullet glyph for a bullet list nested DEPTH deep (0-based)."
  (mdview-glyph (intern (format "bullet-%d" (1+ (mod depth 5))))))

(defun mdview-render--list-marker (item ordered number number-width delimiter depth)
  "Return the propertized marker (with trailing space) of list ITEM.
ORDERED selects NUMBER right-aligned to NUMBER-WIDTH plus one leading
column, followed by DELIMITER (Textual pads the widest \"N. \" by one
space, so the markers read \" 1. \"); otherwise the bullet glyph for
DEPTH.  Task items replace the bullet by a check box (after the number
in an ordered list)."
  (let* ((task (mdview-node-prop item :task))
         (box (when task
                (if (eq task 'checked)
                    (propertize (mdview-glyph 'task-checked)
                                'face 'mdview-task-checked)
                  (propertize (mdview-glyph 'task-unchecked)
                              'face 'mdview-task-unchecked)))))
    (cond
     (ordered
      (concat (propertize (format (format "%%%dd%s" (1+ number-width) delimiter) number)
                          'face 'mdview-bullet)
              " " (and box (concat box " "))))
     (box (concat box " "))
     (t (concat (propertize (mdview-render--bullet-glyph depth)
                            'face 'mdview-bullet)
                " ")))))

(defun mdview-render--list-item (item marker ctx tight ordered)
  "Render list ITEM in CTX with MARKER on its first line.
Continuation lines indent by the width of MARKER.  TIGHT marks the
paragraphs of the item as having no bottom margin; ORDERED keeps the
bullet depth unchanged.  An item nested too deep to leave
`mdview-min-content-width' columns is rendered flat, without marker."
  (let* ((bg (mdview-render-ctx-bg ctx))
         (depth (mdview-render-ctx-bullet-depth ctx))
         (indent (mdview-render--with-bg (make-string (string-width marker) ?\s) bg))
         (child (if (mdview-render--nest-p ctx indent "")
                    (mdview-render--ctx-child
                     ctx :addition indent
                     :first-addition (mdview-render--with-bg marker bg)
                     :tight tight :in-list t
                     :bullet-depth (if ordered depth (1+ depth)))
                  ctx))
         (start (point)))
    (mdview-render--container (mdview-render--expand-blocks
                               (mdview-node-children item))
                              child)
    (mdview-render--mark-source-line item start)))

(defun mdview-render--pad-marker (marker width)
  "Return MARKER padded with spaces on the right to WIDTH columns."
  (let ((pad (- width (string-width marker))))
    (if (> pad 0) (concat marker (make-string pad ?\s)) marker)))

(defun mdview-render--list (node ctx)
  "Render the list NODE in CTX (docs/DESIGN.md section 6, \"Lists\").
All items share one content column: markers narrower than the widest
one of the list (an ASCII task box next to a plain bullet) are padded."
  (let* ((ordered (mdview-node-prop node :ordered))
         (tight (mdview-node-prop node :tight))
         (items (mdview-node-children node))
         (start (or (mdview-node-prop node :start) 1))
         (delimiter (if (eq (mdview-node-prop node :marker) ?\)) ")" "."))
         (number-width (max (length (number-to-string start))
                            (length (number-to-string
                                     (+ start (max 0 (1- (length items))))))))
         (depth (mdview-render-ctx-bullet-depth ctx))
         (number start)
         (markers (mapcar (lambda (item)
                            (prog1 (mdview-render--list-marker
                                    item ordered number number-width delimiter depth)
                              (setq number (1+ number))))
                          items))
         (marker-width (apply #'max 0 (mapcar #'string-width markers)))
         (first t))
    (cl-mapc (lambda (item marker)
               (unless first
                 (mdview-render--emit-blank-lines (if tight 0 1) ctx))
               (setq first nil)
               (mdview-render--list-item
                item (mdview-render--pad-marker marker marker-width)
                ctx tight ordered))
             items markers)))

(defun mdview-render--expand-tabs (line)
  "Return LINE with every tab replaced by `mdview-code-tab-width' spaces."
  (if (string-search "\t" line)
      (replace-regexp-in-string "\t" (make-string mdview-code-tab-width ?\s) line t t)
    line))

(defun mdview-render--code-row (line width)
  "Return LINE as a code block row: two columns of padding, padded to WIDTH.
The `mdview-code-block' face is added below the token faces so that the
background shows under them.  Rows wider than WIDTH are not truncated."
  (let* ((row (concat "  " line))
         (pad (- width (string-width row))))
    (when (> pad 0)
      (setq row (concat row (make-string pad ?\s))))
    (add-face-text-property 0 (length row) 'mdview-code-block t row)
    row))

(defun mdview-render--code-block (node ctx)
  "Render the code block NODE in CTX (docs/DESIGN.md section 6, \"Code blocks\")."
  (let* ((code (or (car (mdview-node-children node)) ""))
         (lang (mdview-node-prop node :lang))
         (width (mdview-render-ctx-width ctx))
         (text (condition-case nil
                   (mdview-code-fontify code lang)
                 (error (substring-no-properties code))))
         (lines (split-string (if (stringp text) text code) "\n")))
    (mdview-render--emit-line (mdview-render--code-row "" width) ctx)
    (dolist (line (mdview-code-indent-guides-lines
                   (mapcar #'mdview-render--expand-tabs lines)))
      (mdview-render--emit-line (mdview-render--code-row line width) ctx))
    (mdview-render--emit-line (mdview-render--code-row "" width) ctx)))

(defun mdview-render--table (node ctx)
  "Render the table NODE in CTX (docs/DESIGN.md section 6, \"Tables\").
The table module lays out the rows at the inner width W - 4; cells are
rendered with `mdview-render-inlines' in a context that never produces
real images, and wrapped with `mdview-wrap'."
  (let* ((width (mdview-render-ctx-width ctx))
         (inner (max 1 (- width 4)))
         (cell-ctx (mdview-render--ctx-make
                    :width inner :images nil
                    :base-dir (mdview-render-ctx-base-dir ctx)))
         (lines (mdview-table-layout
                 node inner
                 (lambda (cell)
                   (mdview-render-inlines (mdview-node-children cell) cell-ctx))
                 #'mdview-wrap)))
    (mdview-render--emit-box lines 'mdview-table ctx)))

(defun mdview-render--footnote-definition (node ctx)
  "Render the footnote definition NODE in CTX as [n] followed by its blocks."
  (let* ((index (or (mdview-node-prop node :index) 0))
         (bg (mdview-render-ctx-bg ctx))
         (marker (mdview-render--with-bg
                  (concat (propertize (format "[%d]" index)
                                      'face 'mdview-footnote-ref
                                      'mdview-footnote-def index)
                          " ")
                  bg))
         (indent (mdview-render--with-bg (make-string (string-width marker) ?\s) bg))
         (child (mdview-render--ctx-child ctx :addition indent
                                          :first-addition marker :tight nil)))
    (mdview-render--container (mdview-render--expand-blocks
                               (mdview-node-children node))
                              child)))

(defun mdview-render--footnotes (definitions ctx)
  "Render the footnotes section: a thin rule, then DEFINITIONS in CTX."
  (mdview-render--emit-line
   (mdview-render--rule 'thin-rule 'mdview-rule (mdview-render-ctx-width ctx)) ctx)
  (mdview-render--blocks definitions ctx))

(defun mdview-render--mark-source-line (node start)
  "Record the `:line' of NODE on the character at START, the block's first."
  (let ((line (mdview-node-prop node :line)))
    (when (and line (< start (point)))
      (put-text-property start (1+ start) 'mdview-source-line line))))

(defun mdview-render--block (node ctx)
  "Render the block NODE in CTX and mark its source line."
  (let ((start (point)))
    (pcase (mdview-node-type node)
      ('heading (mdview-render--heading node ctx))
      ('paragraph (mdview-render--paragraph node ctx))
      ('blockquote (mdview-render--blockquote node ctx))
      ('list (mdview-render--list node ctx))
      ('code-block (mdview-render--code-block node ctx))
      ('thematic-break (mdview-render--thematic-break ctx))
      ('table (mdview-render--table node ctx))
      ('html-block (mdview-render--html-shr node ctx))
      ('footnote-definition (mdview-render--footnote-definition node ctx))
      (_ (dolist (line (mdview-wrap (mdview-node-text node)
                                    (mdview-render-ctx-width ctx)))
           (mdview-render--emit-line line ctx))))
    (mdview-render--mark-source-line node start)))

;;;; HTML blocks

(defconst mdview-render--html-block-tags
  '("p" "div" "li" "ul" "ol" "tr" "table" "thead" "tbody" "tfoot"
    "h1" "h2" "h3" "h4" "h5" "h6" "blockquote" "pre" "section" "article"
    "header" "footer" "nav" "aside" "dl" "dt" "dd" "figure" "figcaption"
    "center" "details" "summary" "main" "form" "fieldset")
  "HTML elements whose start and end tags end the current paragraph.")

(defconst mdview-render--html-space-tags '("td" "th")
  "HTML elements whose tags separate words without ending the paragraph.")

(defun mdview-render--html-shr-p ()
  "Return non-nil when HTML blocks should be rendered with `shr'."
  (and (eq mdview-html-renderer 'shr)
       (fboundp 'libxml-parse-html-region)))

(defun mdview-render--html-at-p (html pos literal)
  "Return non-nil when the text of HTML at POS is LITERAL, ignoring case."
  (eq t (compare-strings literal nil nil html pos (+ pos (length literal)) t)))

(defun mdview-render--html-after (html from terminator)
  "Return the position in HTML just after TERMINATOR found at or after FROM.
Return the length of HTML when TERMINATOR does not occur."
  (let ((hit (let ((case-fold-search t))
               (string-match (regexp-quote terminator) html from))))
    (if hit (+ hit (length terminator)) (length html))))

(defun mdview-render--html-tag-pieces (tag centered)
  "Return (PIECES . CENTERED) for the HTML TAG string.
PIECES is a list of pieces for `mdview-render--html-blocks-from-pieces':
strings, (break), (hr), (image NODE), (block) at the boundary of a
block-level element, (heading LEVEL) and (heading-end) around <h1> ..
<h6>, (summary) and (summary-end) around <summary>, (kbd) and (kbd-end)
around <kbd>, and (center FLAG) when the innermost open element with
align=\"center\" changes.  CENTERED is the updated stack of such open
elements."
  (if (not (string-match "\\`<\\(/?\\)\\([A-Za-z][A-Za-z0-9-]*\\)" tag))
      (cons nil centered)
    (let* ((closing (not (string-empty-p (match-string 1 tag))))
           (name (downcase (match-string 2 tag)))
           (block (member name mdview-render--html-block-tags))
           (was-centered (and centered t))
           (pieces nil))
      (cond
       ((and (not closing) (string= name "img"))
        (let ((image (mdview-render--html-image-node tag)))
          (when image (push (list 'image image) pieces))))
       ((and (not closing) (string= name "br")) (push '(break) pieces))
       ((and (not closing) (string= name "hr")) (push '(hr) pieces))
       (t
        (when block (push '(block) pieces))
        (cond
         ((and (not closing)
               (let ((align (mdview-render--html-attr tag "align")))
                 (and align (string= (downcase align) "center"))))
          (push name centered))
         ((and closing (member name centered))
          (setq centered (delete name centered))))
        (unless (eq (and centered t) was-centered)
          (push (list 'center (and centered t)) pieces))
        (cond
         ((string-match-p "\\`h[1-6]\\'" name)
          (push (if closing '(heading-end) (list 'heading (- (aref name 1) ?0)))
                pieces))
         ((string= name "summary")
          (push (if closing '(summary-end) '(summary)) pieces))
         ((string= name "kbd")
          (push (if closing '(kbd-end) '(kbd)) pieces))
         ((member name mdview-render--html-space-tags)
          (push " " pieces)))))
      (cons (nreverse pieces) centered))))

(defun mdview-render--html-pieces (html)
  "Split the raw HTML into pieces: strings and tag markers.
Markers are those of `mdview-render--html-tag-pieces'; comments,
<script> and <style> elements are dropped."
  (let ((pos 0) (n (length html)) (pieces nil) (centered nil))
    (while (< pos n)
      (let ((lt (string-search "<" html pos)))
        (cond
         ((null lt)
          (push (substring html pos) pieces)
          (setq pos n))
         (t
          (when (> lt pos) (push (substring html pos lt) pieces))
          (cond
           ((mdview-render--html-at-p html lt "<!--")
            (setq pos (mdview-render--html-after html (+ lt 4) "-->")))
           ((or (mdview-render--html-at-p html lt "<script")
                (mdview-render--html-at-p html lt "<style"))
            (let ((name (if (mdview-render--html-at-p html lt "<script")
                            "script" "style")))
              (setq pos (mdview-render--html-after
                         html (mdview-render--html-after html lt (concat "</" name))
                         ">"))))
           (t
            (let ((gt (string-search ">" html lt)))
              (if (null gt)
                  (progn (push (substring html lt) pieces) (setq pos n))
                (pcase-let ((`(,tag-pieces . ,stack)
                             (mdview-render--html-tag-pieces
                              (substring html lt (1+ gt)) centered)))
                  (setq centered stack)
                  (dolist (piece tag-pieces) (push piece pieces))
                  (setq pos (1+ gt)))))))))))
    (nreverse pieces)))

(defun mdview-render--collapse-space (text)
  "Return TEXT with every run of whitespace replaced by one space."
  (replace-regexp-in-string "[ \t\n\r]+" " " text t t))

(defun mdview-render--html-paragraph (inlines line center summary)
  "Return a paragraph node at LINE for INLINES, or nil when they are blank.
CENTER marks the paragraph for centering and SUMMARY as a <summary>."
  (unless (seq-every-p #'mdview-render--blank-inline-p inlines)
    (apply #'mdview-node 'paragraph
           (append (list :line line)
                   (when center (list :center t))
                   (when summary (list :summary t)))
           inlines)))

(defun mdview-render--html-heading (inlines line level)
  "Return a heading node of LEVEL at LINE for INLINES, or nil when blank."
  (unless (seq-every-p #'mdview-render--blank-inline-p inlines)
    (let ((text (string-trim (mapconcat #'mdview-node-text inlines ""))))
      (apply #'mdview-node 'heading
             (list :level level :id (mdview-slug text) :line line)
             inlines))))

(defun mdview-render--html-blocks-from-pieces (pieces line)
  "Turn PIECES of `mdview-render--html-pieces' into blocks at source LINE.
Block-level tags end the paragraph being collected, <h1> .. <h6> become
headings, <summary> a paragraph with `:summary', text inside <kbd> a
`code' node, and paragraphs collected inside an element with
align=\"center\" get `:center'."
  (let ((blocks nil) (inlines nil) (text nil)
        (center nil) (heading nil) (summary nil) (kbd nil))
    (cl-flet* ((flush-text ()
                 (when text
                   (let ((string (mdview-ast-decode-entities
                                  (mdview-render--collapse-space
                                   (apply #'concat (nreverse text))))))
                     (push (if (and kbd (not (string-blank-p string)))
                               (mdview-node 'code nil (string-trim string))
                             string)
                           inlines))
                   (setq text nil)))
               (flush-paragraph ()
                 (flush-text)
                 (let ((block (if heading
                                  (mdview-render--html-heading
                                   (nreverse inlines) line heading)
                                (mdview-render--html-paragraph
                                 (nreverse inlines) line center summary))))
                   (when block (push block blocks)))
                 (setq inlines nil)))
      (dolist (piece pieces)
        (pcase piece
          ((pred stringp) (push piece text))
          (`(break) (flush-text) (push (mdview-node 'hard-break nil) inlines))
          (`(image ,node) (flush-text) (push node inlines))
          (`(hr) (flush-paragraph)
           (push (mdview-node 'thematic-break (list :line line)) blocks))
          (`(block) (flush-paragraph))
          (`(center ,flag) (setq center flag))
          (`(heading ,level) (flush-paragraph) (setq heading level))
          (`(heading-end) (flush-paragraph) (setq heading nil))
          (`(summary) (flush-paragraph) (setq summary t))
          (`(summary-end) (flush-paragraph) (setq summary nil))
          (`(kbd) (flush-text) (setq kbd t))
          (`(kbd-end) (flush-text) (setq kbd nil))))
      (flush-paragraph))
    (nreverse blocks)))

(defun mdview-render--html-block-blocks (node)
  "Return the blocks replacing the `html-block' NODE under the strip renderer."
  (mdview-render--html-blocks-from-pieces
   (mdview-render--html-pieces (or (car (mdview-node-children node)) ""))
   (mdview-node-prop node :line)))

(defun mdview-render--expand-blocks (blocks)
  "Return BLOCKS with every `html-block' replaced by its stripped blocks.
HTML blocks are kept when `mdview-html-renderer' selects `shr'."
  (if (mdview-render--html-shr-p)
      blocks
    (let ((result nil))
      (dolist (block blocks)
        (if (eq (mdview-node-type block) 'html-block)
            (dolist (replacement (mdview-render--html-block-blocks block))
              (push replacement result))
          (push block result)))
      (nreverse result))))

(defun mdview-render--html-shr (node ctx)
  "Render the `html-block' NODE in CTX with `shr'.
Falls back to the stripped rendering when libxml is unavailable."
  (if (not (mdview-render--html-shr-p))
      (mdview-render--container (mdview-render--html-block-blocks node) ctx)
    (require 'shr)
    (let* ((html (or (car (mdview-node-children node)) ""))
           (width (mdview-render-ctx-width ctx))
           (dom (with-temp-buffer
                  (insert html)
                  (libxml-parse-html-region (point-min) (point-max))))
           (text (with-temp-buffer
                   (let ((shr-width width)
                         (shr-use-fonts nil)
                         (shr-inhibit-images t))
                     (shr-insert-document dom))
                   (buffer-string))))
      (dolist (line (split-string (string-trim-right text "[\n ]+") "\n"))
        (if (> (string-width line) width)
            (dolist (piece (mdview-wrap line width))
              (mdview-render--emit-line piece ctx))
          (mdview-render--emit-line line ctx))))))

;;;; Document

(cl-defun mdview-render-document (doc &key (width 80) base-dir)
  "Insert the rendering of the document node DOC at point.
WIDTH is the content width in columns and BASE-DIR the directory against
which relative image paths are resolved.  The derived faces are
remapped in the current buffer first.  Footnote definitions listed in
the `:footnotes' property of DOC are rendered at the end after a thin
rule.  The output ends with exactly one newline (nothing is inserted for
an empty document)."
  (let* ((ctx (mdview-render--ctx-make :width (max 1 (or width 80))
                                       :base-dir base-dir))
         (blocks (mdview-render--expand-blocks (mdview-node-children doc)))
         (footnotes (mdview-node-prop doc :footnotes))
         ;; Resolve the glyph profile once rather than per glyph, and
         ;; give deeply nested documents (the parser allows 200 block
         ;; levels) the same headroom the parser takes.
         (mdview-faces--profile (mdview-faces-resolve-glyphs))
         (max-lisp-eval-depth (max max-lisp-eval-depth 6000)))
    (mdview-faces-remap)
    (let ((bottom (mdview-render--blocks blocks ctx)))
      (when footnotes
        (when bottom
          (mdview-render--emit-blank-lines (max bottom 1) ctx))
        (mdview-render--footnotes footnotes ctx)))))

(provide 'mdview-render)
;;; mdview-render.el ends here
