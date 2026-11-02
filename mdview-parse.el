;;; mdview-parse.el --- Block Markdown parser for mdview  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Vadim Zaliva

;; Author: Vadim Zaliva
;; Keywords: text, docs
;; Package-Requires: ((emacs "29.1"))

;; This file is part of mdview, distributed under the MIT license; see
;; LICENSE in the repository root.

;;; Commentary:

;; The block-structure parser of mdview (docs/DESIGN.md sections 3 and
;; 4).  It implements the two-phase strategy of the CommonMark 0.31
;; specification's appendix "A parsing strategy":
;;
;; Phase 1 (`mdview-parse--incorporate-line') consumes the input one line
;; at a time.  For every line the open container blocks are matched
;; (block quote markers, list item indentation, footnote definition
;; indentation), then new block starts are tried in the order the
;; specification mandates (block quote, ATX heading, fenced code, HTML
;; block, setext underline, thematic break, footnote definition, list
;; item, indented code, GFM table), and whatever remains is appended to
;; the current leaf block or starts a paragraph.  The result is a tree of
;; mutable `mdview-parse--block' structures holding raw lines.
;;
;; Phase 2 (`mdview-parse--to-node') converts that tree into the AST of
;; docs/DESIGN.md section 3.  Link reference definitions have been
;; collected into the `:refs' hash table by then, so every paragraph,
;; heading and table cell is handed to `mdview-inline-parse' with the
;; complete reference map.  Heading ids, task list markers, footnote
;; indices and the YAML front matter are handled here as well.
;;
;; Robustness: the parser never signals.  Regular expressions are only
;; applied to single lines and never contain unbounded repetition of a
;; group (Emacs's matcher overflows its stack on such patterns when a
;; line is hundreds of kilobytes long); runs of marker characters are
;; counted with plain loops instead.  Container nesting is capped by
;; `mdview-parse-max-depth' (and inline nesting by
;; `mdview-inline-max-depth') so that the recursive conversion, the
;; footnote and heading-id passes and the renderer stay within
;; `max-lisp-eval-depth'.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'mdview-ast)
(require 'mdview-inline)

;;;; Options

(defcustom mdview-parse-max-depth 200
  "Maximum nesting depth of container blocks.
Block quotes, list items and footnote definitions nested more deeply
than this are not recognized; their marker lines are parsed as
paragraph text instead.  The cap keeps the recursive tree conversion
and the renderer well inside `max-lisp-eval-depth' on adversarial
input such as a line of ten thousand `>' characters."
  :type 'natnum
  :group 'mdview)

(defcustom mdview-parse-front-matter t
  "When non-nil, skip a YAML front matter block at the very start.
Front matter is a line consisting of `---' as the first line of the
document, up to and including the next line consisting of `---' or
`...', provided the first line in between looks like a YAML mapping
entry (`key: value') or comment.  Otherwise, and when no closing line
exists, the opening line is parsed as Markdown (a thematic break), as
CommonMark requires."
  :type 'boolean
  :group 'mdview)

;;;; Data structures

(cl-defstruct (mdview-parse--block
               (:constructor mdview-parse--make-block)
               (:copier nil))
  "A block during phase 1: a node of the tree of open and closed blocks.
TYPE is one of `document', `paragraph', `heading', `blockquote', `list',
`item', `code-block', `html-block', `thematic-break', `table' or
`footnote-definition'.  CHILDREN and STRINGS are kept in reverse order
while parsing."
  type
  (open t)
  parent
  children
  line
  depth
  strings
  last-line-blank
  last-line-checked
  ;; heading
  level
  ;; code blocks
  fenced fence-char fence-length fence-offset info
  ;; HTML blocks
  html-kind
  ;; lists and items
  list-type bullet-char delimiter start padding marker-offset tight
  ;; footnote definitions
  label
  ;; tables: ALIGN is the alignment list, ROWS the reversed list of rows,
  ;; each a list of cell strings
  align rows)

(cl-defstruct (mdview-parse--state
               (:constructor mdview-parse--make-state)
               (:copier nil))
  "The parser state threaded through phase 1."
  doc tip oldtip
  (line "")
  (line-number 0)
  (offset 0)
  (column 0)
  (next-nonspace 0)
  (next-nonspace-column 0)
  (indent 0)
  indented blank partial
  all-closed last-matched
  refs)

;;;; Character and line utilities

(defsubst mdview-parse--peek (line pos)
  "Return the character of LINE at POS, or nil beyond the end."
  (and (< pos (length line)) (aref line pos)))

(defsubst mdview-parse--space-p (char)
  "Return non-nil when CHAR is a space or a tab."
  (or (eq char ?\s) (eq char ?\t)))

(defun mdview-parse--run-length (line pos char)
  "Return how many consecutive occurrences of CHAR start at POS in LINE."
  (let ((i pos) (len (length line)))
    (while (and (< i len) (eq (aref line i) char))
      (setq i (1+ i)))
    (- i pos)))

(defun mdview-parse--skip-spaces (line pos)
  "Return the index of the first non-blank character of LINE at or after POS.
Spaces and tabs are blank."
  (let ((len (length line)))
    (while (and (< pos len) (mdview-parse--space-p (aref line pos)))
      (setq pos (1+ pos)))
    pos))

(defun mdview-parse--blank-from-p (line pos)
  "Return non-nil when only spaces and tabs remain in LINE from POS onwards."
  (= (mdview-parse--skip-spaces line pos) (length line)))

(defun mdview-parse--trim-right (string)
  "Return STRING without trailing spaces, tabs and line breaks.
Unlike the regexp-based trimming functions, this runs in linear time on
a string holding a very long run of blanks followed by other text."
  (let ((end (length string)))
    (while (and (> end 0) (memq (aref string (1- end)) '(?\s ?\t ?\n ?\r)))
      (setq end (1- end)))
    (if (= end (length string)) string (substring string 0 end))))

(defun mdview-parse--trim (string)
  "Return STRING without leading and trailing whitespace, in linear time."
  (let* ((s (mdview-parse--trim-right string))
         (len (length s))
         (start 0))
    (while (and (< start len) (memq (aref s start) '(?\s ?\t ?\n ?\r)))
      (setq start (1+ start)))
    (if (= start 0) s (substring s start))))

(defsubst mdview-parse--match-at (regexp line start)
  "Return the end of a match of REGEXP in LINE starting exactly at START.
Return nil when REGEXP does not match there."
  (and (eq (string-match regexp line start) start) (match-end 0)))

(defun mdview-parse--normalize-newlines (string)
  "Return STRING with CRLF and CR line endings turned into LF and NUL replaced."
  (let ((s (if (string-search "\r" string)
               (replace-regexp-in-string "\r\n?" "\n" string t t)
             string)))
    (if (string-search "\0" s) (subst-char-in-string ?\0 #xFFFD s) s)))

;;;; Backslash escapes, entities, labels

(defconst mdview-parse--escape-regexp
  "\\\\\\([]!\"#$%&'()*+,./:;<=>?@[\\^_`{|}~-]\\)"
  "Regexp matching a backslash followed by an ASCII punctuation character.")

(defun mdview-parse--unescape (string)
  "Process backslash escapes and HTML entities in STRING.
Used for info strings, link destinations and titles (the inline parser
does the same for text).  A backslash before ASCII punctuation yields
the punctuation character; entities and numeric character references
between escapes are decoded with `mdview-ast-decode-entities'."
  (if (not (string-search "\\" string))
      (mdview-ast-decode-entities string)
    (let ((pos 0) (parts nil))
      (while (string-match mdview-parse--escape-regexp string pos)
        (push (mdview-ast-decode-entities
               (substring string pos (match-beginning 0)))
              parts)
        (push (match-string 1 string) parts)
        (setq pos (match-end 0)))
      (push (mdview-ast-decode-entities (substring string pos)) parts)
      (apply #'concat (nreverse parts)))))

(defun mdview-parse-normalize-label (label)
  "Return the normalized form of link or footnote LABEL.
Leading and trailing whitespace is removed, internal runs of whitespace
collapse to one space and the result is case folded, so that two labels
that CommonMark considers equal normalize to `equal' strings.  Keys of
the document's `:refs' table are normalized this way."
  (upcase (downcase (string-join (split-string label "[ \t\n\r]+" t) " "))))

;;;; Phase 1: parser state operations

(defun mdview-parse--find-next-nonspace (p)
  "Locate the first non-space character of the current line of P after the offset.
Sets the next-nonspace index and column, the indent relative to the
current column, the `indented' flag (indent of four or more columns)
and the `blank' flag (nothing but whitespace remains)."
  (let* ((line (mdview-parse--state-line p))
         (len (length line))
         (i (mdview-parse--state-offset p))
         (column (mdview-parse--state-column p))
         (cols column)
         (done nil))
    (while (and (not done) (< i len))
      (let ((c (aref line i)))
        (cond ((eq c ?\s) (setq i (1+ i) cols (1+ cols)))
              ((eq c ?\t) (setq i (1+ i) cols (+ cols (- 4 (% cols 4)))))
              (t (setq done t)))))
    (setf (mdview-parse--state-blank p) (>= i len)
          (mdview-parse--state-next-nonspace p) i
          (mdview-parse--state-next-nonspace-column p) cols
          (mdview-parse--state-indent p) (- cols column)
          (mdview-parse--state-indented p) (>= (- cols column) 4))))

(defun mdview-parse--advance-next-nonspace (p)
  "Move the offset of P to the first non-space character of the line."
  (setf (mdview-parse--state-offset p) (mdview-parse--state-next-nonspace p)
        (mdview-parse--state-column p) (mdview-parse--state-next-nonspace-column p)
        (mdview-parse--state-partial p) nil))

(defun mdview-parse--advance-offset (p count columns)
  "Advance the offset of P by COUNT characters, or by COUNT columns if COLUMNS.
Tabs expand to the next tab stop (every four columns).  When a tab is
only partially consumed in column mode the offset stays on it and the
`partial' flag records how much of it remains, as in the reference
implementation."
  (let* ((line (mdview-parse--state-line p))
         (len (length line))
         (offset (mdview-parse--state-offset p))
         (column (mdview-parse--state-column p))
         (partial nil))
    (while (and (> count 0) (< offset len))
      (if (eq (aref line offset) ?\t)
          (let ((to-tab (- 4 (% column 4))))
            (if columns
                (let ((step (min count to-tab)))
                  (setq partial (> to-tab count)
                        column (+ column step)
                        count (- count step))
                  (unless partial (setq offset (1+ offset))))
              (setq partial nil
                    column (+ column to-tab)
                    offset (1+ offset)
                    count (1- count))))
        (setq partial nil
              offset (1+ offset)
              column (1+ column)
              count (1- count))))
    (setf (mdview-parse--state-offset p) offset
          (mdview-parse--state-column p) column
          (mdview-parse--state-partial p) partial)))

(defun mdview-parse--rest-of-line (p)
  "Return the unconsumed remainder of the current line of P.
A partially consumed tab contributes the spaces still owed to the next
tab stop."
  (let ((line (mdview-parse--state-line p))
        (offset (mdview-parse--state-offset p)))
    (if (mdview-parse--state-partial p)
        (concat (make-string (- 4 (% (mdview-parse--state-column p) 4)) ?\s)
                (substring line (1+ offset)))
      (substring line offset))))

(defun mdview-parse--add-line (p)
  "Append the remainder of the current line of P to the tip block."
  (push (mdview-parse--rest-of-line p)
        (mdview-parse--block-strings (mdview-parse--state-tip p))))

(defun mdview-parse--content (block)
  "Return the raw text content of leaf BLOCK: its lines joined by newlines."
  (mapconcat #'identity (reverse (mdview-parse--block-strings block)) "\n"))

(defun mdview-parse--can-contain-p (parent-type child-type)
  "Return non-nil when a block of PARENT-TYPE may hold a child of CHILD-TYPE."
  (pcase parent-type
    ('list (eq child-type 'item))
    ((or 'document 'blockquote 'item 'footnote-definition)
     (not (eq child-type 'item)))
    (_ nil)))

(defun mdview-parse--accepts-lines-p (block)
  "Return non-nil when text lines may be appended to BLOCK."
  (memq (mdview-parse--block-type block) '(paragraph code-block html-block)))

(defun mdview-parse--add-child (p type)
  "Create a block of TYPE as a child of the tip of P and make it the tip.
Blocks that cannot contain TYPE are finalized first."
  (while (not (mdview-parse--can-contain-p
               (mdview-parse--block-type (mdview-parse--state-tip p)) type))
    (mdview-parse--finalize p (mdview-parse--state-tip p)))
  (let* ((tip (mdview-parse--state-tip p))
         (block (mdview-parse--make-block
                 :type type :parent tip
                 :line (mdview-parse--state-line-number p)
                 :depth (1+ (mdview-parse--block-depth tip)))))
    (push block (mdview-parse--block-children tip))
    (setf (mdview-parse--state-tip p) block)
    block))

(defun mdview-parse--remove-block (block)
  "Detach BLOCK from its parent."
  (let ((parent (mdview-parse--block-parent block)))
    (when parent
      (setf (mdview-parse--block-children parent)
            (delq block (mdview-parse--block-children parent))))))

(defun mdview-parse--finalize (p block)
  "Close BLOCK in parser P, run its type-specific finalization, pop the tip."
  (setf (mdview-parse--block-open block) nil)
  (pcase (mdview-parse--block-type block)
    ('paragraph (mdview-parse--finalize-paragraph p block))
    ('code-block
     (unless (mdview-parse--block-fenced block)
       ;; Indented code: trailing blank lines are not part of the block.
       (let ((strings (mdview-parse--block-strings block)))
         (while (and strings (mdview-parse--blank-from-p (car strings) 0))
           (setq strings (cdr strings)))
         (setf (mdview-parse--block-strings block) strings))))
    ('list (mdview-parse--finalize-list block)))
  (setf (mdview-parse--state-tip p) (mdview-parse--block-parent block)))

(defun mdview-parse--close-unmatched-blocks (p)
  "Finalize the blocks of P that the current line did not continue."
  (unless (mdview-parse--state-all-closed p)
    (while (not (eq (mdview-parse--state-oldtip p)
                    (mdview-parse--state-last-matched p)))
      (let ((parent (mdview-parse--block-parent (mdview-parse--state-oldtip p))))
        (mdview-parse--finalize p (mdview-parse--state-oldtip p))
        (setf (mdview-parse--state-oldtip p) parent)))
    (setf (mdview-parse--state-all-closed p) t)))

(defun mdview-parse--finalize-paragraph (p block)
  "Strip link reference definitions from paragraph BLOCK; drop it if empty.
P is the parser state whose reference map receives the definitions."
  (let ((rest (mdview-parse--strip-references
               (mdview-parse--content block)
               (mdview-parse--state-refs p))))
    (if (mdview-parse--blank-from-p rest 0)
        (mdview-parse--remove-block block)
      (setf (mdview-parse--block-strings block) (list rest)))))

(defun mdview-parse--ends-with-blank-line-p (block)
  "Return non-nil when BLOCK, or the last descendant of a list or item, ends blank.
Each block is examined once (`last-line-checked'), keeping the list
finalization linear."
  (let ((result nil) (b block))
    (while b
      (cond ((mdview-parse--block-last-line-blank b)
             (setq result t b nil))
            ((and (not (mdview-parse--block-last-line-checked b))
                  (memq (mdview-parse--block-type b) '(list item)))
             (setf (mdview-parse--block-last-line-checked b) t)
             (setq b (car (mdview-parse--block-children b))))
            (t (setf (mdview-parse--block-last-line-checked b) t)
               (setq b nil))))
    result))

(defun mdview-parse--finalize-list (block)
  "Decide whether list BLOCK is tight and record it in its `tight' slot.
A list is loose when a blank line separates two items or two direct
children of an item (except after the very last child of the list)."
  (let ((tight t)
        (items (reverse (mdview-parse--block-children block))))
    (while (and tight items)
      (let ((item (car items)) (more (cdr items)))
        (if (and more (mdview-parse--ends-with-blank-line-p item))
            (setq tight nil)
          (let ((subs (reverse (mdview-parse--block-children item))))
            (while (and tight subs)
              (when (and (or more (cdr subs))
                         (mdview-parse--ends-with-blank-line-p (car subs)))
                (setq tight nil))
              (setq subs (cdr subs)))))
        (setq items more)))
    (setf (mdview-parse--block-tight block) tight)))

;;;; Phase 1: continuing open containers

(defun mdview-parse--continue (p block)
  "Try to continue open BLOCK with the current line of parser state P.
Return 0 when the line continues BLOCK, 1 when it does not, and 2 when
the line was consumed entirely (a closing code fence)."
  (let ((line (mdview-parse--state-line p))
        (ns (mdview-parse--state-next-nonspace p))
        (indent (mdview-parse--state-indent p))
        (blank (mdview-parse--state-blank p)))
    (pcase (mdview-parse--block-type block)
      ((or 'document 'list) 0)
      ('blockquote
       (if (and (not (mdview-parse--state-indented p))
                (eq (mdview-parse--peek line ns) ?>))
           (progn
             (mdview-parse--advance-next-nonspace p)
             (mdview-parse--advance-offset p 1 nil)
             (when (mdview-parse--space-p
                    (mdview-parse--peek line (mdview-parse--state-offset p)))
               (mdview-parse--advance-offset p 1 t))
             0)
         1))
      ('item
       (let ((content-indent (+ (mdview-parse--block-marker-offset block)
                                (mdview-parse--block-padding block))))
         (cond (blank
                (if (null (mdview-parse--block-children block))
                    1               ; a blank line right after an empty item
                  (mdview-parse--advance-next-nonspace p)
                  0))
               ((>= indent content-indent)
                (mdview-parse--advance-offset p content-indent t)
                0)
               (t 1))))
      ('footnote-definition
       (cond ((>= indent 4) (mdview-parse--advance-offset p 4 t) 0)
             (blank (mdview-parse--advance-next-nonspace p) 0)
             (t 1)))
      ((or 'heading 'thematic-break) 1)
      ('code-block
       (if (mdview-parse--block-fenced block)
           (mdview-parse--continue-fenced p block)
         (cond ((>= indent 4) (mdview-parse--advance-offset p 4 t) 0)
               (blank (mdview-parse--advance-next-nonspace p) 0)
               (t 1))))
      ('html-block
       (if (and blank (memq (mdview-parse--block-html-kind block) '(6 7))) 1 0))
      ((or 'paragraph 'table) (if blank 1 0))
      (_ 1))))

(defun mdview-parse--continue-fenced (p block)
  "Continue fenced code BLOCK with the current line of parser state P.
Detect the closing fence or strip the indentation of the opening fence."
  (let* ((line (mdview-parse--state-line p))
         (ns (mdview-parse--state-next-nonspace p))
         (char (mdview-parse--block-fence-char block))
         (run (if (and (<= (mdview-parse--state-indent p) 3)
                       (eq (mdview-parse--peek line ns) char))
                  (mdview-parse--run-length line ns char)
                0)))
    (if (and (>= run (mdview-parse--block-fence-length block))
             (mdview-parse--blank-from-p line (+ ns run)))
        (progn (mdview-parse--finalize p block) 2)
      ;; Skip up to FENCE-OFFSET columns of indentation.
      (let ((i (mdview-parse--block-fence-offset block)))
        (while (and (> i 0)
                    (mdview-parse--space-p
                     (mdview-parse--peek line (mdview-parse--state-offset p))))
          (mdview-parse--advance-offset p 1 t)
          (setq i (1- i))))
      0)))

;;;; Phase 1: HTML block recognition

(defconst mdview-parse--html-block-tags
  '("address" "article" "aside" "base" "basefont" "blockquote" "body"
    "caption" "center" "col" "colgroup" "dd" "details" "dialog" "dir" "div"
    "dl" "dt" "fieldset" "figcaption" "figure" "footer" "form" "frame"
    "frameset" "h1" "h2" "h3" "h4" "h5" "h6" "head" "header" "hr" "html"
    "iframe" "legend" "li" "link" "main" "menu" "menuitem" "nav" "noframes"
    "ol" "optgroup" "option" "p" "param" "search" "section" "summary"
    "table" "tbody" "td" "tfoot" "th" "thead" "title" "tr" "track" "ul")
  "Tag names that start an HTML block of kind 6 (CommonMark 0.31).")

(defconst mdview-parse--html-kind-6-regexp
  (concat "</?" (regexp-opt mdview-parse--html-block-tags t)
          "\\(?:[ \t]\\|/?>\\|\\'\\)")
  "Regexp (case-insensitive) matching the start of an HTML block of kind 6.")

(defconst mdview-parse--html-kind-1-regexp
  "<\\(?:pre\\|script\\|style\\|textarea\\)\\(?:[ \t]\\|>\\|\\'\\)"
  "Regexp (case-insensitive) matching the start of an HTML block of kind 1.")

(defconst mdview-parse--html-kind-1-end-regexp
  "</\\(?:pre\\|script\\|style\\|textarea\\)>"
  "Regexp (case-insensitive) matching the end of an HTML block of kind 1.")

(defsubst mdview-parse--ascii-letter-p (char)
  "Return non-nil when CHAR is an ASCII letter."
  (and char (or (<= ?a char ?z) (<= ?A char ?Z))))

(defsubst mdview-parse--tag-name-char-p (char)
  "Return non-nil when CHAR may continue an HTML tag name."
  (and char (or (mdview-parse--ascii-letter-p char) (<= ?0 char ?9) (eq char ?-))))

(defsubst mdview-parse--attr-name-char-p (char)
  "Return non-nil when CHAR may continue an HTML attribute name."
  (and char (or (mdview-parse--ascii-letter-p char) (<= ?0 char ?9)
                (memq char '(?_ ?. ?: ?-)))))

(defun mdview-parse--scan-tag-name (line pos)
  "Return the end of an HTML tag name starting at POS in LINE, or nil."
  (when (mdview-parse--ascii-letter-p (mdview-parse--peek line pos))
    (let ((i (1+ pos)))
      (while (mdview-parse--tag-name-char-p (mdview-parse--peek line i))
        (setq i (1+ i)))
      i)))

(defun mdview-parse--scan-attribute-value (line pos)
  "Return the end of an attribute value starting at POS in LINE, or nil.
Handles double-quoted, single-quoted and unquoted values."
  (let ((c (mdview-parse--peek line pos)))
    (cond ((memq c '(?\" ?'))
           (let ((end (string-search (string c) line (1+ pos))))
             (and end (1+ end))))
          (t (let ((i pos))
               (while (let ((ch (mdview-parse--peek line i)))
                        (and ch (not (mdview-parse--space-p ch))
                             (not (memq ch '(?\" ?' ?= ?< ?> ?`)))))
                 (setq i (1+ i)))
               (and (> i pos) i))))))

(defun mdview-parse--scan-open-tag (line pos)
  "Return the end of a complete HTML open tag starting at POS in LINE, or nil.
The scan is a plain loop (no backtracking) over the grammar
<name (whitespace attribute (= value)?)* whitespace? /? >."
  (let ((i (and (eq (mdview-parse--peek line pos) ?<)
                (mdview-parse--scan-tag-name line (1+ pos)))))
    (when i
      (catch 'done
        (while t
          (let* ((j (mdview-parse--skip-spaces line i))
                 (c (mdview-parse--peek line j)))
            (cond
             ((null c) (throw 'done nil))
             ((eq c ?>) (throw 'done (1+ j)))
             ((and (eq c ?/) (eq (mdview-parse--peek line (1+ j)) ?>))
              (throw 'done (+ j 2)))
             ((and (> j i)
                   (or (mdview-parse--ascii-letter-p c) (memq c '(?_ ?:))))
              ;; attribute name
              (setq j (1+ j))
              (while (mdview-parse--attr-name-char-p (mdview-parse--peek line j))
                (setq j (1+ j)))
              ;; optional value specification
              (let ((k (mdview-parse--skip-spaces line j)))
                (if (eq (mdview-parse--peek line k) ?=)
                    (let ((end (mdview-parse--scan-attribute-value
                                line (mdview-parse--skip-spaces line (1+ k)))))
                      (unless end (throw 'done nil))
                      (setq i end))
                  (setq i j))))
             (t (throw 'done nil)))))))))

(defun mdview-parse--scan-closing-tag (line pos)
  "Return the end of a complete HTML closing tag starting at POS in LINE, or nil."
  (when (and (eq (mdview-parse--peek line pos) ?<)
             (eq (mdview-parse--peek line (1+ pos)) ?/))
    (let ((end (mdview-parse--scan-tag-name line (+ pos 2))))
      (when end
        (let ((j (mdview-parse--skip-spaces line end)))
          (and (eq (mdview-parse--peek line j) ?>) (1+ j)))))))

(defun mdview-parse--html-block-kind (line pos)
  "Return the HTML block kind (1-7) started by LINE at POS, or nil."
  (let ((case-fold-search t))
    (cond
     ((mdview-parse--match-at mdview-parse--html-kind-1-regexp line pos) 1)
     ((mdview-parse--match-at "<!--" line pos) 2)
     ((mdview-parse--match-at "<\\?" line pos) 3)
     ((mdview-parse--match-at "<![A-Za-z]" line pos) 4)
     ((mdview-parse--match-at "<!\\[CDATA\\[" line pos) 5)
     ((mdview-parse--match-at mdview-parse--html-kind-6-regexp line pos) 6)
     ((let ((end (or (mdview-parse--scan-open-tag line pos)
                     (mdview-parse--scan-closing-tag line pos))))
        (and end
             (mdview-parse--blank-from-p line end)
             (not (string-match-p
                   "\\`</?\\(?:pre\\|script\\|style\\|textarea\\)\\(?:[ \t/>]\\|\\'\\)"
                   (substring line pos end)))))
      7))))

(defun mdview-parse--html-block-ends-p (kind text)
  "Return non-nil when TEXT (the rest of a line) ends an HTML block of KIND 1-5."
  (let ((case-fold-search t))
    (pcase kind
      (1 (string-match-p mdview-parse--html-kind-1-end-regexp text))
      (2 (string-search "-->" text))
      (3 (string-search "?>" text))
      (4 (string-search ">" text))
      (5 (string-search "]]>" text)))))

;;;; Phase 1: block starts

(defun mdview-parse--depth-ok-p (container)
  "Return non-nil when a container may be opened inside CONTAINER."
  (< (mdview-parse--block-depth container) mdview-parse-max-depth))

(defun mdview-parse--start-blockquote (p container)
  "Try to start a block quote in parser state P inside CONTAINER.
Return 1 on success."
  (let ((line (mdview-parse--state-line p))
        (ns (mdview-parse--state-next-nonspace p)))
    (when (and (not (mdview-parse--state-indented p))
               (eq (mdview-parse--peek line ns) ?>)
               (mdview-parse--depth-ok-p container))
      (mdview-parse--advance-next-nonspace p)
      (mdview-parse--advance-offset p 1 nil)
      (when (mdview-parse--space-p
             (mdview-parse--peek line (mdview-parse--state-offset p)))
        (mdview-parse--advance-offset p 1 t))
      (mdview-parse--close-unmatched-blocks p)
      (mdview-parse--add-child p 'blockquote)
      1)))

(defun mdview-parse--atx-content (text)
  "Return the content of an ATX heading from TEXT, the part after the marker.
Trailing whitespace is removed, then an optional closing sequence of
`#' characters that is preceded by whitespace (or forms the whole text)."
  (let* ((s (mdview-parse--trim-right text))
         (end (length s))
         (i end))
    (while (and (> i 0) (eq (aref s (1- i)) ?#))
      (setq i (1- i)))
    (cond ((= i 0) "")
          ((and (< i end) (mdview-parse--space-p (aref s (1- i))))
           (mdview-parse--trim (substring s 0 i)))
          (t (mdview-parse--trim s)))))

(defun mdview-parse--start-atx-heading (p _container)
  "Try to start an ATX heading in parser state P; return 2 on success."
  (let* ((line (mdview-parse--state-line p))
         (ns (mdview-parse--state-next-nonspace p))
         (run (if (and (not (mdview-parse--state-indented p))
                       (eq (mdview-parse--peek line ns) ?#))
                  (mdview-parse--run-length line ns ?#)
                0)))
    (when (and (<= 1 run 6)
               (let ((c (mdview-parse--peek line (+ ns run))))
                 (or (null c) (mdview-parse--space-p c))))
      (mdview-parse--advance-next-nonspace p)
      (mdview-parse--advance-offset p run nil)
      (mdview-parse--close-unmatched-blocks p)
      (let ((block (mdview-parse--add-child p 'heading)))
        (setf (mdview-parse--block-level block) run
              (mdview-parse--block-strings block)
              (list (mdview-parse--atx-content
                     (substring line (mdview-parse--state-offset p))))))
      (mdview-parse--advance-offset p (length line) nil)
      2)))

(defun mdview-parse--start-fenced-code (p _container)
  "Try to start a fenced code block in parser state P.
Return 2 on success."
  (let* ((line (mdview-parse--state-line p))
         (ns (mdview-parse--state-next-nonspace p))
         (c (mdview-parse--peek line ns))
         (run (if (and (not (mdview-parse--state-indented p))
                       (memq c '(?` ?~)))
                  (mdview-parse--run-length line ns c)
                0)))
    (when (and (>= run 3)
               (or (eq c ?~) (not (string-search "`" line (+ ns run)))))
      (mdview-parse--close-unmatched-blocks p)
      (let ((block (mdview-parse--add-child p 'code-block)))
        (setf (mdview-parse--block-fenced block) t
              (mdview-parse--block-fence-char block) c
              (mdview-parse--block-fence-length block) run
              (mdview-parse--block-fence-offset block) (mdview-parse--state-indent p))
        (mdview-parse--advance-next-nonspace p)
        (mdview-parse--advance-offset p run nil)
        (setf (mdview-parse--block-info block)
              (mdview-parse--unescape
               (mdview-parse--trim
                (substring line (mdview-parse--state-offset p))))))
      (mdview-parse--advance-offset p (length line) nil)
      2)))

(defun mdview-parse--start-html-block (p container)
  "Try to start an HTML block in parser state P inside CONTAINER.
Return 2 on success."
  (let ((line (mdview-parse--state-line p))
        (ns (mdview-parse--state-next-nonspace p)))
    (when (and (not (mdview-parse--state-indented p))
               (eq (mdview-parse--peek line ns) ?<))
      (let ((kind (mdview-parse--html-block-kind line ns)))
        (when (and kind
                   (or (< kind 7)
                       ;; Kind 7 cannot interrupt a paragraph, not even
                       ;; lazily.
                       (and (not (eq (mdview-parse--block-type container) 'paragraph))
                            (not (and (not (mdview-parse--state-all-closed p))
                                      (not (mdview-parse--state-blank p))
                                      (eq (mdview-parse--block-type
                                           (mdview-parse--state-tip p))
                                          'paragraph))))))
          (mdview-parse--close-unmatched-blocks p)
          (let ((block (mdview-parse--add-child p 'html-block)))
            (setf (mdview-parse--block-html-kind block) kind))
          2)))))

(defun mdview-parse--start-setext-heading (p container)
  "Try to turn paragraph CONTAINER into a setext heading in parser state P.
Return 2 on success."
  (let* ((line (mdview-parse--state-line p))
         (ns (mdview-parse--state-next-nonspace p))
         (c (mdview-parse--peek line ns)))
    (when (and (not (mdview-parse--state-indented p))
               (eq (mdview-parse--block-type container) 'paragraph)
               (memq c '(?= ?-))
               (mdview-parse--blank-from-p
                line (+ ns (mdview-parse--run-length line ns c))))
      (mdview-parse--close-unmatched-blocks p)
      ;; Reference definitions at the start of the paragraph are not
      ;; heading text.
      (let ((content (mdview-parse--strip-references
                      (mdview-parse--content container)
                      (mdview-parse--state-refs p))))
        (setf (mdview-parse--block-strings container)
              (and (> (length content) 0) (list content)))
        (when (> (length content) 0)
          (setf (mdview-parse--block-type container) 'heading
                (mdview-parse--block-level container) (if (eq c ?=) 1 2))
          (mdview-parse--advance-offset p (length line) nil)
          2)))))

(defun mdview-parse--thematic-break-p (line pos)
  "Return non-nil when LINE from POS is a thematic break.
That is three or more `-', `*' or `_' of one kind, with optional blanks."
  (let ((c (mdview-parse--peek line pos)))
    (when (memq c '(?- ?* ?_))
      (let ((i pos) (count 0) (len (length line)) (ok t))
        (while (and ok (< i len))
          (let ((ch (aref line i)))
            (cond ((eq ch c) (setq count (1+ count)))
                  ((mdview-parse--space-p ch))
                  (t (setq ok nil))))
          (setq i (1+ i)))
        (and ok (>= count 3))))))

(defun mdview-parse--start-thematic-break (p _container)
  "Try to start a thematic break in parser state P; return 2 on success."
  (let ((line (mdview-parse--state-line p)))
    (when (and (not (mdview-parse--state-indented p))
               (mdview-parse--thematic-break-p
                line (mdview-parse--state-next-nonspace p)))
      (mdview-parse--close-unmatched-blocks p)
      (mdview-parse--add-child p 'thematic-break)
      (mdview-parse--advance-offset p (length line) nil)
      2)))

(defun mdview-parse--start-footnote-definition (p container)
  "Try to start a GFM footnote definition `[^label]:' in parser state P.
CONTAINER is the enclosing block.  Return 1 on success."
  (let ((line (mdview-parse--state-line p))
        (ns (mdview-parse--state-next-nonspace p)))
    (when (and (not (mdview-parse--state-indented p))
               (eq (mdview-parse--peek line ns) ?\[)
               (eq (mdview-parse--peek line (1+ ns)) ?^)
               (mdview-parse--depth-ok-p container))
      (let ((end (mdview-parse--match-at "\\[\\^\\([^]\t]+\\)\\]:" line ns)))
        (when (and end (string-match-p "[^ ]" (match-string 1 line)))
          (let ((label (match-string 1 line)))
            (mdview-parse--advance-next-nonspace p)
            (mdview-parse--advance-offset p (- end ns) nil)
            (mdview-parse--close-unmatched-blocks p)
            (setf (mdview-parse--block-label
                   (mdview-parse--add-child p 'footnote-definition))
                  label)
            1))))))

(defun mdview-parse--parse-list-marker (p container)
  "Parse a list marker at the next non-space position of P's line.
CONTAINER is the block the item would interrupt.  On success the offset
is advanced past the marker and its padding and a plist with `:type',
`:bullet', `:delimiter', `:start', `:padding' and `:marker-offset' is
returned; otherwise nil and the offset is unchanged."
  (let* ((line (mdview-parse--state-line p))
         (ns (mdview-parse--state-next-nonspace p))
         (c (mdview-parse--peek line ns))
         (in-paragraph (eq (mdview-parse--block-type container) 'paragraph))
         type bullet delimiter start marker-length)
    (cond
     ((>= (mdview-parse--state-indent p) 4) nil)
     ((memq c '(?* ?+ ?-))
      (setq type 'bullet bullet c marker-length 1))
     ((and c (<= ?0 c ?9))
      (let ((digits (mdview-parse--run-length-digits line ns)))
        (when (and (<= 1 digits 9)
                   (memq (mdview-parse--peek line (+ ns digits)) '(?. ?\)))
                   ;; Only a list starting at 1 may interrupt a paragraph.
                   (or (not in-paragraph)
                       (string= (substring line ns (+ ns digits)) "1")))
          (setq type 'ordered
                start (string-to-number (substring line ns (+ ns digits)))
                delimiter (aref line (+ ns digits))
                marker-length (1+ digits))))))
    (when (and type
               (let ((next (mdview-parse--peek line (+ ns marker-length))))
                 (or (null next) (mdview-parse--space-p next)))
               ;; An item interrupting a paragraph may not start blank.
               (not (and in-paragraph
                         (mdview-parse--blank-from-p line (+ ns marker-length)))))
      (let ((marker-offset (mdview-parse--state-indent p)))
        (mdview-parse--advance-next-nonspace p)
        (mdview-parse--advance-offset p marker-length t)
        (let ((spaces-start-col (mdview-parse--state-column p))
              (spaces-start-offset (mdview-parse--state-offset p))
              (continue t))
          (while continue
            (mdview-parse--advance-offset p 1 t)
            (setq continue
                  (and (< (- (mdview-parse--state-column p) spaces-start-col) 5)
                       (mdview-parse--space-p
                        (mdview-parse--peek line (mdview-parse--state-offset p))))))
          (let* ((blank-item (null (mdview-parse--peek
                                    line (mdview-parse--state-offset p))))
                 (spaces-after (- (mdview-parse--state-column p) spaces-start-col))
                 (padding
                  (if (or (>= spaces-after 5) (< spaces-after 1) blank-item)
                      ;; Too much, too little or nothing: content starts
                      ;; one column after the marker (the first space).
                      (progn
                        (setf (mdview-parse--state-column p) spaces-start-col
                              (mdview-parse--state-offset p) spaces-start-offset
                              (mdview-parse--state-partial p) nil)
                        (when (mdview-parse--space-p
                               (mdview-parse--peek line spaces-start-offset))
                          (mdview-parse--advance-offset p 1 t))
                        (1+ marker-length))
                    (+ marker-length spaces-after))))
            (list :type type :bullet bullet :delimiter delimiter :start start
                  :padding padding :marker-offset marker-offset)))))))

(defun mdview-parse--run-length-digits (line pos)
  "Return the number of consecutive ASCII digits starting at POS in LINE."
  (let ((i pos) (len (length line)))
    (while (and (< i len) (<= ?0 (aref line i) ?9))
      (setq i (1+ i)))
    (- i pos)))

(defun mdview-parse--list-matches-p (list data)
  "Return non-nil when LIST block can hold an item with marker DATA."
  (and (eq (mdview-parse--block-list-type list) (plist-get data :type))
       (eq (mdview-parse--block-bullet-char list) (plist-get data :bullet))
       (eq (mdview-parse--block-delimiter list) (plist-get data :delimiter))))

(defun mdview-parse--start-list-item (p container)
  "Try to start a list item in parser state P inside CONTAINER.
A list is opened first when needed.  Return 1 on success."
  (when (and (or (not (mdview-parse--state-indented p))
                 (eq (mdview-parse--block-type container) 'list))
             (mdview-parse--depth-ok-p container))
    (let ((data (mdview-parse--parse-list-marker p container)))
      (when data
        (mdview-parse--close-unmatched-blocks p)
        (let ((tip (mdview-parse--state-tip p)))
          (unless (and (eq (mdview-parse--block-type tip) 'list)
                       (mdview-parse--list-matches-p tip data))
            (let ((list (mdview-parse--add-child p 'list)))
              (setf (mdview-parse--block-list-type list) (plist-get data :type)
                    (mdview-parse--block-bullet-char list) (plist-get data :bullet)
                    (mdview-parse--block-delimiter list) (plist-get data :delimiter)
                    (mdview-parse--block-start list) (plist-get data :start)))))
        (let ((item (mdview-parse--add-child p 'item)))
          (setf (mdview-parse--block-padding item) (plist-get data :padding)
                (mdview-parse--block-marker-offset item) (plist-get data :marker-offset)))
        1))))

(defun mdview-parse--start-indented-code (p _container)
  "Try to start an indented code block in parser state P.
Return 2 on success."
  (when (and (mdview-parse--state-indented p)
             (not (eq (mdview-parse--block-type (mdview-parse--state-tip p))
                      'paragraph))
             (not (mdview-parse--state-blank p)))
    (mdview-parse--advance-offset p 4 t)
    (mdview-parse--close-unmatched-blocks p)
    (mdview-parse--add-child p 'code-block)
    2))

;;;; Phase 1: GFM tables

(defun mdview-parse--split-row (text)
  "Split table row TEXT into a list of trimmed cell strings.
Leading and trailing pipes are optional; a pipe preceded by a backslash
belongs to the cell and becomes a literal `|' (also inside code spans)."
  (let* ((s (mdview-parse--trim text))
         (len (length s))
         (i 0) (start 0) (cells nil))
    (when (and (> len 0) (eq (aref s 0) ?|))
      (setq i 1 start 1))
    (while (< i len)
      (let ((c (aref s i)))
        (cond ((and (eq c ?\\) (< (1+ i) len))
               (setq i (+ i 2)))
              ((eq c ?|)
               (push (substring s start i) cells)
               (setq i (1+ i) start i))
              (t (setq i (1+ i))))))
    (let ((last (substring s start)))
      ;; Everything after the last pipe is a cell unless it is only
      ;; whitespace, which means the row ended with a pipe.
      (unless (and cells (mdview-parse--blank-from-p last 0))
        (push last cells)))
    (mapcar (lambda (cell)
              (mdview-parse--trim (string-replace "\\|" "|" cell)))
            (nreverse cells))))

(defun mdview-parse--delimiter-row (text)
  "If TEXT is a GFM table delimiter row, return its list of alignments.
Each element is `left', `center', `right' or nil."
  (when (string-match-p "\\`[ \t|:-]+\\'" text)
    (let ((cells (mdview-parse--split-row text)) (aligns nil) (ok t))
      (dolist (cell cells)
        (if (string-match "\\`\\(:?\\)-+\\(:?\\)\\'" cell)
            (let ((left (> (match-end 1) (match-beginning 1)))
                  (right (> (match-end 2) (match-beginning 2))))
              (push (cond ((and left right) 'center)
                          (left 'left)
                          (right 'right))
                    aligns))
          (setq ok nil)))
      (and ok cells (nreverse aligns)))))

(defun mdview-parse--start-table-header (p container)
  "Try to turn the last line of paragraph CONTAINER into a table header.
The current line of parser state P must be a delimiter row with as many
cells as that line.  Return 2 on success."
  (when (and (eq (mdview-parse--block-type container) 'paragraph)
             (not (mdview-parse--state-indented p)))
    (let* ((line (mdview-parse--state-line p))
           (rest (substring line (mdview-parse--state-next-nonspace p)))
           (aligns (mdview-parse--delimiter-row rest)))
      (when aligns
        ;; The paragraph's lines are stored newest first, so its last
        ;; line is simply the head of the list; nothing is joined or
        ;; copied unless the header actually matches.
        (let* ((strings (mdview-parse--block-strings container))
               (cells (mdview-parse--split-row (car strings))))
          (when (= (length cells) (length aligns))
            (mdview-parse--close-unmatched-blocks p)
            (let ((parent (mdview-parse--block-parent container)))
              (if (cdr strings)
                  (progn
                    (setf (mdview-parse--block-strings container) (cdr strings))
                    (mdview-parse--finalize p container))
                (mdview-parse--remove-block container)
                (setf (mdview-parse--state-tip p) parent))
              (let ((table (mdview-parse--add-child p 'table)))
                (setf (mdview-parse--block-align table) aligns
                      (mdview-parse--block-rows table) (list cells)
                      (mdview-parse--block-line table)
                      (1- (mdview-parse--state-line-number p)))))
            (mdview-parse--advance-offset p (length line) nil)
            2))))))

(defun mdview-parse--start-table-row (p container)
  "Add the current line of parser state P as a row of table CONTAINER.
Return 2 on success."
  (when (and (eq (mdview-parse--block-type container) 'table)
             (not (mdview-parse--state-indented p)))
    (let ((line (mdview-parse--state-line p)))
      (push (mdview-parse--split-row
             (substring line (mdview-parse--state-next-nonspace p)))
            (mdview-parse--block-rows container))
      (mdview-parse--advance-offset p (length line) nil)
      2)))

;;;; Phase 1: dispatcher and line driver

(defconst mdview-parse--block-starts
  '(mdview-parse--start-blockquote
    mdview-parse--start-atx-heading
    mdview-parse--start-fenced-code
    mdview-parse--start-html-block
    mdview-parse--start-setext-heading
    mdview-parse--start-thematic-break
    mdview-parse--start-footnote-definition
    mdview-parse--start-list-item
    mdview-parse--start-indented-code
    mdview-parse--start-table-header
    mdview-parse--start-table-row)
  "Block start functions in the order they are tried.
Each takes the parser state and the current container and returns nil
\(no match), 1 (a container was opened; keep looking for starts on the
rest of the line) or 2 (a leaf was opened or the line was consumed).")

(defun mdview-parse--maybe-special-p (p container)
  "Return non-nil when the line of P may start a block inside CONTAINER.
A cheap filter on the first non-space character that avoids running
every block start on ordinary text lines."
  (or (eq (mdview-parse--block-type container) 'table)
      (let ((c (mdview-parse--peek (mdview-parse--state-line p)
                                   (mdview-parse--state-next-nonspace p))))
        (and c (or (memq c '(?# ?` ?~ ?* ?+ ?_ ?= ?< ?> ?- ?\[ ?| ?:))
                   (<= ?0 c ?9))))))

(defun mdview-parse--try-block-starts (p container)
  "Try every block start on the current line of P in CONTAINER.
Return 1, 2 or nil as the start functions do."
  (let ((starts mdview-parse--block-starts) (result nil))
    (while (and starts (not result))
      (setq result (funcall (car starts) p container)
            starts (cdr starts)))
    result))

(defun mdview-parse--incorporate-line (p line)
  "Add LINE to the block tree being built in parser state P."
  (let ((container (mdview-parse--state-doc p)))
    (setf (mdview-parse--state-oldtip p) (mdview-parse--state-tip p)
          (mdview-parse--state-offset p) 0
          (mdview-parse--state-column p) 0
          (mdview-parse--state-blank p) nil
          (mdview-parse--state-partial p) nil
          (mdview-parse--state-line-number p) (1+ (mdview-parse--state-line-number p))
          (mdview-parse--state-line p) line)
    (catch 'consumed
      ;; 1. Match the open containers against the line.
      (catch 'matched
        (let (child)
          (while (and (setq child (car (mdview-parse--block-children container)))
                      (mdview-parse--block-open child))
            (setq container child)
            (mdview-parse--find-next-nonspace p)
            (pcase (mdview-parse--continue p container)
              (1 (setq container (mdview-parse--block-parent container))
                 (throw 'matched nil))
              (2 (throw 'consumed nil))))))
      (setf (mdview-parse--state-all-closed p)
            (eq container (mdview-parse--state-oldtip p))
            (mdview-parse--state-last-matched p) container)
      ;; 2. Look for new block starts.
      (let ((done (and (not (eq (mdview-parse--block-type container) 'paragraph))
                       (mdview-parse--accepts-lines-p container))))
        (while (not done)
          (mdview-parse--find-next-nonspace p)
          (if (and (not (mdview-parse--state-indented p))
                   (not (mdview-parse--maybe-special-p p container)))
              (progn (mdview-parse--advance-next-nonspace p) (setq done t))
            (pcase (mdview-parse--try-block-starts p container)
              (1 (setq container (mdview-parse--state-tip p)))
              (2 (setq container (mdview-parse--state-tip p) done t))
              (_ (mdview-parse--advance-next-nonspace p) (setq done t))))))
      ;; 3. What remains is text: lazy continuation, leaf content or a
      ;; new paragraph.
      (let ((tip (mdview-parse--state-tip p))
            (blank (mdview-parse--state-blank p)))
        (if (and (not (mdview-parse--state-all-closed p))
                 (not blank)
                 (eq (mdview-parse--block-type tip) 'paragraph))
            (mdview-parse--add-line p)
          (mdview-parse--close-unmatched-blocks p)
          (let* ((type (mdview-parse--block-type container))
                 (last-child (car (mdview-parse--block-children container)))
                 (line-number (mdview-parse--state-line-number p))
                 (last-line-blank
                  (and blank
                       (not (or (eq type 'blockquote)
                                (and (eq type 'code-block)
                                     (mdview-parse--block-fenced container))
                                (and (eq type 'item)
                                     (null (mdview-parse--block-children container))
                                     (= (mdview-parse--block-line container)
                                        line-number)))))))
            (when (and blank last-child)
              (setf (mdview-parse--block-last-line-blank last-child) t))
            (let ((b container))
              (while b
                (setf (mdview-parse--block-last-line-blank b) last-line-blank)
                (setq b (mdview-parse--block-parent b))))
            (cond
             ((mdview-parse--accepts-lines-p container)
              ;; The opening fence line itself is not code.
              (unless (and (eq type 'code-block)
                           (mdview-parse--block-fenced container)
                           (= (mdview-parse--block-line container) line-number))
                (mdview-parse--add-line p))
              (when (and (eq type 'html-block)
                         (<= 1 (mdview-parse--block-html-kind container) 5)
                         (mdview-parse--html-block-ends-p
                          (mdview-parse--block-html-kind container)
                          (substring line (mdview-parse--state-offset p))))
                (mdview-parse--finalize p container)))
             ((and (not blank)
                   (< (mdview-parse--state-offset p) (length line)))
              (mdview-parse--add-child p 'paragraph)
              (mdview-parse--advance-next-nonspace p)
              (mdview-parse--add-line p)))))))))

;;;; Link reference definitions

(defconst mdview-parse--punctuation
  (append "!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~" nil)
  "The ASCII punctuation characters that a backslash may escape.")

(defsubst mdview-parse--escapable-p (char)
  "Return non-nil when CHAR is ASCII punctuation."
  (and char (memq char mdview-parse--punctuation)))

(defun mdview-parse--scan-link-label (s pos)
  "Return the position after a link label `[...]' starting at POS in S, or nil.
The label may hold at most 999 characters and no unescaped brackets."
  (when (eq (mdview-parse--peek s pos) ?\[)
    (let ((i (1+ pos)) (len (length s)) (result nil) (done nil))
      (while (and (not done) (< i len) (<= (- i pos) 1000))
        (let ((c (aref s i)))
          (cond ((eq c ?\\) (setq i (+ i 2)))
                ((eq c ?\[) (setq done t))
                ((eq c ?\]) (setq result (1+ i) done t))
                (t (setq i (1+ i))))))
      result)))

(defun mdview-parse--scan-link-destination (s pos)
  "Scan a link destination at POS in S; return (END . RAW-TEXT) or nil.
Either an angle-bracketed destination (RAW-TEXT excludes the brackets)
or a run of non-space characters with balanced parentheses."
  (let ((len (length s)))
    (if (eq (mdview-parse--peek s pos) ?<)
        (let ((i (1+ pos)) (result nil) (done nil))
          (while (and (not done) (< i len))
            (let ((c (aref s i)))
              (cond ((and (eq c ?\\) (< (1+ i) len)) (setq i (+ i 2)))
                    ((eq c ?>)
                     (setq result (cons (1+ i) (substring s (1+ pos) i)) done t))
                    ((memq c '(?\n ?<)) (setq done t))
                    (t (setq i (1+ i))))))
          result)
      (let ((i pos) (parens 0) (done nil))
        (while (and (not done) (< i len))
          (let ((c (aref s i)))
            (cond ((and (eq c ?\\) (< (1+ i) len)
                        (mdview-parse--escapable-p (aref s (1+ i))))
                   (setq i (+ i 2)))
                  ((eq c ?\()
                   ;; Like cmark, give up after 32 unclosed parens.
                   (setq parens (1+ parens))
                   (if (> parens 32) (setq done t) (setq i (1+ i))))
                  ((eq c ?\))
                   (if (< parens 1) (setq done t) (setq parens (1- parens) i (1+ i))))
                  ((or (<= c ?\s) (eq c #x7f)) (setq done t))
                  (t (setq i (1+ i))))))
        (and (> i pos) (= parens 0) (cons i (substring s pos i)))))))

(defun mdview-parse--scan-link-title (s pos)
  "Scan a link title at POS in S; return (END . RAW-TEXT) or nil.
Titles are delimited by double quotes, single quotes or parentheses."
  (let* ((open (mdview-parse--peek s pos))
         (close (pcase open (?\" ?\") (?' ?') (?\( ?\)))))
    (when close
      (let ((i (1+ pos)) (len (length s)) (result nil) (done nil))
        (while (and (not done) (< i len))
          (let ((c (aref s i)))
            (cond ((and (eq c ?\\) (< (1+ i) len)) (setq i (+ i 2)))
                  ((eq c close)
                   (setq result (cons (1+ i) (substring s (1+ pos) i)) done t))
                  ((and (eq open ?\() (eq c ?\()) (setq done t))
                  (t (setq i (1+ i))))))
        result))))

(defun mdview-parse--skip-ws-one-newline (s pos)
  "Skip spaces, tabs and at most one newline at POS in S; return the new position."
  (let ((i (mdview-parse--skip-spaces s pos)))
    (if (eq (mdview-parse--peek s i) ?\n)
        (mdview-parse--skip-spaces s (1+ i))
      i)))

(defun mdview-parse--line-end-after (s pos)
  "Return the start of the next line if only blanks follow POS on its line in S.
At the end of S return its length.  Otherwise return nil."
  (let ((i (mdview-parse--skip-spaces s pos)))
    (cond ((>= i (length s)) i)
          ((eq (aref s i) ?\n) (1+ i)))))

(defun mdview-parse--parse-reference (s pos refs)
  "Parse a link reference definition at POS in S and record it in REFS.
REFS maps normalized labels to (URL . TITLE); the first definition of a
label wins.  Return the position after the definition or nil."
  (let ((label-end (mdview-parse--scan-link-label s pos)))
    (when (and label-end (eq (mdview-parse--peek s label-end) ?:))
      (let* ((label (substring s (1+ pos) (1- label-end)))
             (dest-start (mdview-parse--skip-ws-one-newline s (1+ label-end)))
             (dest (mdview-parse--scan-link-destination s dest-start)))
        (when dest
          (let* ((after-dest (car dest))
                 (title-start (mdview-parse--skip-ws-one-newline s after-dest))
                 (title (and (> title-start after-dest)
                             (mdview-parse--scan-link-title s title-start)))
                 (end (and title (mdview-parse--line-end-after s (car title)))))
            ;; A title not followed by the line end is not part of the
            ;; definition; the definition may still end after the URL.
            (unless end
              (setq title nil
                    end (mdview-parse--line-end-after s after-dest)))
            (when end
              (let ((key (mdview-parse-normalize-label label)))
                (when (> (length key) 0)
                  (unless (gethash key refs)
                    (puthash key
                             (cons (mdview-parse--unescape (cdr dest))
                                   (and title (mdview-parse--unescape (cdr title))))
                             refs))
                  end)))))))))

(defun mdview-parse--strip-references (content refs)
  "Remove the link reference definitions at the start of CONTENT.
Each one is recorded in REFS.  Return the remaining text."
  (let ((pos 0) (len (length content)))
    (while (and (< pos len)
                (eq (aref content pos) ?\[)
                (let ((end (mdview-parse--parse-reference content pos refs)))
                  (when end (setq pos end) t))))
    (if (= pos 0) content (substring content pos))))

;;;; Phase 1: driver

(defun mdview-parse--front-matter-lines (lines)
  "Return how many of the leading LINES form a YAML front matter block, or nil."
  (when (and mdview-parse-front-matter lines
             (string-match-p "\\`---[ \t]*\\'" (car lines))
             (mdview-parse--yaml-line-p (cadr lines)))
    (let ((n 1) (rest (cdr lines)) (found nil))
      (while (and rest (not found))
        (setq n (1+ n))
        (when (string-match-p "\\`\\(?:---\\|\\.\\.\\.\\)[ \t]*\\'" (car rest))
          (setq found t))
        (setq rest (cdr rest)))
      (and found n))))

(defun mdview-parse--yaml-line-p (line)
  "Return non-nil when LINE is a plausible first line of YAML front matter.
That is a `key: value' mapping entry or a `#' comment."
  (and line
       (string-match-p "\\`[ \t]*\\(?:#\\|[A-Za-z0-9_\"'][^:]\\{0,200\\}:\\(?:[ \t]\\|\\'\\)\\)"
                       line)))

(defun mdview-parse--build-tree (string)
  "Run phase 1 over STRING and return the final parser state."
  (let* ((text (mdview-parse--normalize-newlines string))
         (lines (split-string text "\n"))
         (doc (mdview-parse--make-block :type 'document :line 1 :depth 0))
         (p (mdview-parse--make-state :doc doc :tip doc
                                      :refs (make-hash-table :test #'equal)))
         (skip (mdview-parse--front-matter-lines lines)))
    ;; A final newline produces an empty last element, not a blank line.
    (when (string-suffix-p "\n" text)
      (setq lines (nbutlast lines)))
    (when skip
      (setf (mdview-parse--state-line-number p) skip)
      (setq lines (nthcdr skip lines)))
    (dolist (line lines)
      (mdview-parse--incorporate-line p line))
    (while (mdview-parse--state-tip p)
      (mdview-parse--finalize p (mdview-parse--state-tip p)))
    p))

;;;; Phase 2: AST construction

(defun mdview-parse--inline (string refs)
  "Parse STRING into inline nodes with `mdview-inline-parse' and REFS.
The parser must never signal, so an error inside the inline parser
degrades to a single text node holding STRING."
  (condition-case nil
      (mdview-inline-parse string refs)
    (error (list string))))

(defun mdview-parse--unique-id (text ids)
  "Return a slug of heading TEXT not yet in hash table IDS, and register it.
Duplicates get the suffixes -1, -2, ... like GitHub's anchors.  IDS maps
every id handed out to t and, under the key (SLUG), the next suffix to
try for SLUG, so a document with thousands of equal headings stays
linear."
  (let* ((base (mdview-slug text)) (id base))
    (when (gethash id ids)
      (let ((n (gethash (list base) ids 1)))
        (while (gethash (setq id (format "%s-%d" base n)) ids)
          (setq n (1+ n)))
        (puthash (list base) (1+ n) ids)))
    (puthash id t ids)
    id))

(defun mdview-parse--take-task-marker (item)
  "Strip a GFM task marker from the first paragraph of ITEM.
Return `checked', `unchecked' or nil.  The marker must be followed by
whitespace, a line ending or the end of the paragraph (`- [ ]' alone,
as in issue templates, is an empty check box on GitHub too)."
  (let ((first (car (last (mdview-parse--block-children item)))))
    (when (and first (eq (mdview-parse--block-type first) 'paragraph))
      (let ((content (mdview-parse--content first)))
        (when (string-match "\\`\\[\\([ xX]\\)\\]\\(?:[ \t]+\\|\n\\|\\'\\)" content)
          (setf (mdview-parse--block-strings first)
                (list (substring content (match-end 0))))
          (if (eq (aref content 1) ?\s) 'unchecked 'checked))))))

(defun mdview-parse--pad-cells (cells count)
  "Return CELLS adjusted to exactly COUNT strings (missing ones are empty)."
  (let ((n (length cells)))
    (cond ((= n count) cells)
          ((> n count) (seq-take cells count))
          (t (append cells (make-list (- count n) ""))))))

(defun mdview-parse--table-node (block refs)
  "Build the `table' AST node for table BLOCK, parsing cells with REFS."
  (let* ((aligns (mdview-parse--block-align block))
         (count (length aligns))
         (header t)
         (rows nil))
    (dolist (cells (reverse (mdview-parse--block-rows block)))
      (push (apply #'mdview-node 'table-row (list :header header)
                   (mapcar (lambda (cell)
                             (apply #'mdview-node 'table-cell nil
                                    (mdview-parse--inline cell refs)))
                           (mdview-parse--pad-cells cells count)))
            rows)
      (setq header nil))
    (apply #'mdview-node 'table
           (list :align aligns :line (mdview-parse--block-line block))
           (nreverse rows))))

(defun mdview-parse--children-nodes (block refs ids)
  "Convert the children of BLOCK into AST nodes using REFS and IDS."
  (mapcar (lambda (child) (mdview-parse--to-node child refs ids))
          (reverse (mdview-parse--block-children block))))

(defun mdview-parse--to-node (block refs ids)
  "Convert phase-1 BLOCK into an AST node.
REFS is the reference map handed to the inline parser and IDS the hash
table of heading ids used so far."
  (let ((line (mdview-parse--block-line block)))
    (pcase (mdview-parse--block-type block)
      ('document
       (apply #'mdview-node 'document (list :refs refs :footnotes nil)
              (mdview-parse--children-nodes block refs ids)))
      ('paragraph
       (apply #'mdview-node 'paragraph (list :line line)
              (mdview-parse--inline
               (mdview-parse--trim-right (mdview-parse--content block)) refs)))
      ('heading
       (let* ((inlines (mdview-parse--inline
                        (mdview-parse--trim (mdview-parse--content block)) refs))
              (id (mdview-parse--unique-id
                   (mapconcat #'mdview-node-text inlines "") ids)))
         (apply #'mdview-node 'heading
                (list :level (mdview-parse--block-level block) :id id :line line)
                inlines)))
      ('blockquote
       (apply #'mdview-node 'blockquote (list :line line)
              (mdview-parse--children-nodes block refs ids)))
      ('list
       (let ((ordered (eq (mdview-parse--block-list-type block) 'ordered)))
         (apply #'mdview-node 'list
                (append (list :ordered ordered)
                        (and ordered (list :start (mdview-parse--block-start block)))
                        (list :tight (mdview-parse--block-tight block)
                              :marker (if ordered
                                          (mdview-parse--block-delimiter block)
                                        (mdview-parse--block-bullet-char block))
                              :line line))
                (mdview-parse--children-nodes block refs ids))))
      ('item
       (let ((task (mdview-parse--take-task-marker block)))
         (apply #'mdview-node 'item (list :task task :line line)
                (mdview-parse--children-nodes block refs ids))))
      ('code-block
       (let* ((info (mdview-parse--block-info block))
              (info (and info (not (string-empty-p info)) info))
              (lang (and info (car (split-string info "[ \t]+" t)))))
         (mdview-node 'code-block
                      (list :lang lang :info info
                            :fenced (and (mdview-parse--block-fenced block) t)
                            :line line)
                      (mdview-parse--content block))))
      ('html-block
       (mdview-node 'html-block (list :line line) (mdview-parse--content block)))
      ('thematic-break
       (mdview-node 'thematic-break (list :line line)))
      ('table (mdview-parse--table-node block refs))
      ('footnote-definition
       (apply #'mdview-node 'footnote-definition
              (list :label (mdview-parse--block-label block) :index nil :line line)
              (mdview-parse--children-nodes block refs ids))))))

;;;; Phase 2: footnotes

(defun mdview-parse--map-children (node function)
  "Return NODE with every descendant replaced by the value of FUNCTION for it.
FUNCTION is applied to each child before its own children are visited;
returning nil drops the child.  NODE itself is not passed to FUNCTION.
Unchanged subtrees are shared, changed ones are rebuilt, so nodes
received from other modules are never mutated."
  (if (stringp node)
      node
    (let* ((changed nil)
           (children
            (delq nil
                  (mapcar
                   (lambda (child)
                     (let ((replacement (funcall function child)))
                       (unless (eq replacement child) (setq changed t))
                       (when replacement
                         (let ((rebuilt (mdview-parse--map-children
                                         replacement function)))
                           (unless (eq rebuilt replacement) (setq changed t))
                           rebuilt))))
                   (mdview-node-children node)))))
      (if changed
          (cons (car node) (cons (cadr node) children))
        node))))

(defun mdview-parse--with-prop (node key value)
  "Return a copy of NODE whose property KEY is VALUE."
  (cons (car node)
        (cons (plist-put (copy-sequence (cadr node)) key value)
              (mdview-node-children node))))

(defun mdview-parse--resolve-footnotes (doc)
  "Move footnote definitions out of DOC and number the references.
Definitions are removed from the block flow and returned in the
`:footnotes' property in order of first reference, each with its
1-based `:index'; references get the same `:index'.  Unreferenced
definitions are dropped and references to undefined labels become
plain text."
  (let ((defs (make-hash-table :test #'equal))
        (indices (make-hash-table :test #'equal))
        (by-index (make-hash-table :test #'eql))
        (counter 0))
    (setq doc (mdview-parse--map-children
               doc
               (lambda (node)
                 (if (eq (mdview-node-type node) 'footnote-definition)
                     (let ((key (mdview-parse-normalize-label
                                 (or (mdview-node-prop node :label) ""))))
                       (unless (gethash key defs) (puthash key node defs))
                       nil)
                   node))))
    (progn
      (cl-labels ((resolve (node)
                    (if (not (eq (mdview-node-type node) 'footnote-reference))
                        node
                      (let* ((label (or (mdview-node-prop node :label) ""))
                             (key (mdview-parse-normalize-label label))
                             (def (gethash key defs)))
                        (if (null def)
                            (concat "[^" label "]")
                          (let ((index (gethash key indices)))
                            (unless index
                              (setq counter (1+ counter) index counter)
                              (puthash key index indices)
                              (puthash index def by-index))
                            (mdview-node 'footnote-reference
                                         (list :label label :index index))))))))
        (setq doc (mdview-parse--map-children doc #'resolve))
        (let ((k 1) (footnotes nil))
          (while (<= k counter)
            (push (mdview-parse--with-prop
                   (mdview-parse--map-children (gethash k by-index) #'resolve)
                   :index k)
                  footnotes)
            (setq k (1+ k)))
          (setq doc (mdview-parse--with-prop doc :footnotes (nreverse footnotes))))))
    doc))

;;;; Public API

(defun mdview-parse-string (string)
  "Parse Markdown STRING and return a `document' AST node.
The node has `:refs', a hash table from normalized link labels to
\(URL . TITLE), and `:footnotes', the referenced footnote definitions
in order of first reference; its children are the block nodes of
docs/DESIGN.md section 3.  Parsing never signals an error."
  ;; Nesting is capped (`mdview-parse-max-depth' for blocks,
  ;; `mdview-inline-max-depth' for inlines), so the passes below need a
  ;; few hundred frames at most; the raised limit is a safety margin.
  (let* ((max-lisp-eval-depth (max max-lisp-eval-depth 6000))
         (p (mdview-parse--build-tree string))
         (refs (mdview-parse--state-refs p))
         (ids (make-hash-table :test #'equal)))
    (mdview-parse--resolve-footnotes
     (mdview-parse--to-node (mdview-parse--state-doc p) refs ids))))

(defun mdview-parse-buffer (&optional buffer)
  "Parse the accessible portion of BUFFER (default: the current buffer).
Return a `document' node as `mdview-parse-string' does."
  (with-current-buffer (or buffer (current-buffer))
    (mdview-parse-string
     (buffer-substring-no-properties (point-min) (point-max)))))

(provide 'mdview-parse)
;;; mdview-parse.el ends here
