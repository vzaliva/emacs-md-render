;;; mdview-inline.el --- Inline Markdown parser for mdview  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Vadim Zaliva

;; Author: Vadim Zaliva
;; SPDX-License-Identifier: MIT
;; Keywords: text, docs

;; This file is part of mdview, distributed under the MIT license; see
;; LICENSE in the repository root.

;;; Commentary:

;; The inline parser of mdview (docs/DESIGN.md sections 3, 4 and 15):
;; `mdview-inline-parse' turns the text of a paragraph, heading or table
;; cell into the list of inline nodes of the AST contract.
;;
;; The algorithm is the one of the CommonMark reference implementations:
;; the text is scanned left to right in a hidden buffer reused across
;; calls (every regexp is anchored with `looking-at', so a failed match
;; never scans ahead; searches for code span closers and HTML
;; terminators are memoized per parse as cmark does, and the link
;; destination scanner gives up after 32 unclosed parens, so that
;; pathological input stays linear-ish);
;; code spans, autolinks, raw HTML, entities and escapes are recognised
;; directly; `*', `_' and `~' runs become delimiters on a stack and `['
;; openers go on a bracket stack; when a `]' closes a link or image the
;; nodes after the opener are moved into the new node, and the delimiter
;; stack is resolved with the CommonMark emphasis algorithm (flanking
;; rules, the multiple-of-3 rule, `_' intraword rule).  Nodes live in a
;; doubly linked list while parsing so that moving ranges is cheap; the
;; result is converted to the plain (TYPE PLIST . CHILDREN) shape at the
;; end, merging adjacent text; nesting deeper than
;; `mdview-inline-max-depth' degrades the whole text to one text node so
;; that no consumer of the tree can exhaust the Lisp stack.
;;
;; Every text piece records where it came from: the text property
;; `mdview-pos' holds the offset into the parsed string of the first
;; source character of the piece, and `code' and `html-inline' nodes
;; carry `:pos' (see `mdview-inline-parse').
;;
;; GFM extensions: strikethrough (`~' and `~~', runs of equal length
;; match), footnote references `[^label]' (the block parser numbers them
;; and turns undefined ones back into text), and extended autolinks for
;; bare `http://', `https://', `ftp://', `www.' URLs and e-mail
;; addresses, applied as a final pass over text outside links exactly as
;; cmark-gfm does, controlled by `mdview-inline-extended-autolinks'.

;;; Code:

(require 'cl-lib)
(require 'mdview-ast)

(defcustom mdview-inline-extended-autolinks t
  "Non-nil turns bare URLs and e-mail addresses into links (GFM autolinks).
Recognised are `http://', `https://' and `ftp://' URLs, `www.' domains
and e-mail addresses in running text, following the rules of the GitHub
Flavored Markdown specification.  Angle-bracket autolinks are always
recognised."
  :type 'boolean
  :group 'mdview)

(defcustom mdview-inline-max-depth 100
  "Maximum nesting depth of inline nodes.
When emphasis, links and images nest more deeply than this,
`mdview-inline-parse' returns its input as a single text node instead
of a tree.  The cap bounds the Lisp recursion of the conversion to the
AST, of the block parser's passes over the tree and of the renderer on
adversarial input such as thousands of nested `*' runs; markdown-it,
the parser behind Frogmouth, limits nesting to 100 as well."
  :type 'natnum
  :group 'mdview)

;;;; Working data structures

(cl-defstruct (mdview-inline--node (:constructor mdview-inline--make-node)
                                   (:copier nil))
  "A node of the parse tree while parsing: a doubly linked list element.
TYPE is the inline node type; PROPS its property list; TEXT the string
of text, code and raw HTML nodes.  FIRST and LAST point to the children
of a container, PARENT, PREV and NEXT link the siblings."
  type props text parent first last prev next)

(cl-defstruct (mdview-inline--delim (:constructor mdview-inline--make-delim)
                                    (:copier nil))
  "An entry of the delimiter stack.
CC is the delimiter character, COUNT the number of delimiters still
unused in the run, ORIG the original run length, NODE the text node
holding the run, CAN-OPEN and CAN-CLOSE the flanking flags."
  cc count orig node can-open can-close prev next)

(cl-defstruct (mdview-inline--bracket (:constructor mdview-inline--make-bracket)
                                      (:copier nil))
  "An entry of the bracket stack.
NODE is the text node of the opening bracket, INDEX the buffer position
just after it, IMAGE non-nil for `![', ACTIVE nil once a link closed
before this opener, AFTER non-nil when a later bracket was opened,
PREV-DELIM the delimiter stack top when the bracket was pushed."
  node prev prev-delim index image active after)

(defvar mdview-inline--delims nil
  "Top of the delimiter stack of the current parse.")

(defvar mdview-inline--brackets nil
  "Top of the bracket stack of the current parse.")

(defvar mdview-inline--refs nil
  "The link reference map of the current parse (label to (URL . TITLE)).")

(defvar mdview-inline--buffer nil
  "The hidden buffer the inline parser scans in, reused across calls.
Creating and killing a temporary buffer for every paragraph, heading
and table cell was the largest single cost of parsing big documents.")

(defvar mdview-inline--absent-terminators nil
  "Terminators known not to occur after point in the current parse.
`mdview-inline--search-terminator' records every string (\"-->\",
\"]]>\", \">\", \"?>\") a search failed to find, so a text full of
unclosed comments or declarations is not rescanned for each of them.")

(defvar mdview-inline--backtick-last nil
  "Hash table from backtick run length to the start of the last run seen.
Filled while scanning for the closer of a code span; nil until the
first backtick of the parse.  See `mdview-inline--parse-backticks'.")

(defvar mdview-inline--backticks-scanned nil
  "Non-nil once a scan for a code span closer reached the end of the text.
Together with `mdview-inline--backtick-last' this makes the search for
closers linear overall, as in cmark.")

;;;; Linked-list operations

(defun mdview-inline--append-child (parent node)
  "Append NODE as the last child of PARENT."
  (let ((last (mdview-inline--node-last parent)))
    (setf (mdview-inline--node-parent node) parent
          (mdview-inline--node-prev node) last
          (mdview-inline--node-next node) nil)
    (if last
        (setf (mdview-inline--node-next last) node)
      (setf (mdview-inline--node-first parent) node))
    (setf (mdview-inline--node-last parent) node)))

(defun mdview-inline--insert-after (ref node)
  "Insert NODE as the sibling following REF."
  (let ((parent (mdview-inline--node-parent ref))
        (next (mdview-inline--node-next ref)))
    (setf (mdview-inline--node-parent node) parent
          (mdview-inline--node-prev node) ref
          (mdview-inline--node-next node) next)
    (if next
        (setf (mdview-inline--node-prev next) node)
      (setf (mdview-inline--node-last parent) node))
    (setf (mdview-inline--node-next ref) node)))

(defun mdview-inline--unlink (node)
  "Remove NODE from its parent's list of children."
  (let ((parent (mdview-inline--node-parent node))
        (prev (mdview-inline--node-prev node))
        (next (mdview-inline--node-next node)))
    (if prev
        (setf (mdview-inline--node-next prev) next)
      (when parent (setf (mdview-inline--node-first parent) next)))
    (if next
        (setf (mdview-inline--node-prev next) prev)
      (when parent (setf (mdview-inline--node-last parent) prev)))
    (setf (mdview-inline--node-parent node) nil
          (mdview-inline--node-prev node) nil
          (mdview-inline--node-next node) nil)))

(defun mdview-inline--offset (&optional position)
  "Return the content offset of buffer POSITION (default: point).
The scratch buffer holds the parsed string from position 1 on, so the
offset into the string is one less than the buffer position."
  (1- (or position (point))))

(defun mdview-inline--text (string pos)
  "Return a copy of STRING with `mdview-pos' POS over its whole length.
POS is the content offset of the first source character STRING stands
for (see `mdview-inline-parse')."
  (propertize string 'mdview-pos pos))

(defun mdview-inline--add-text (root string pos)
  "Append a text node holding STRING to ROOT and return it.
POS is the content offset of the first source character of STRING; it
becomes the text property `mdview-pos' of the whole text."
  (let ((node (mdview-inline--make-node
               :type 'text :text (mdview-inline--text string pos))))
    (mdview-inline--append-child root node)
    node))

(defun mdview-inline--add-node (root type &optional props text)
  "Append a node of TYPE with PROPS and TEXT to ROOT and return it."
  (let ((node (mdview-inline--make-node :type type :props props :text text)))
    (mdview-inline--append-child root node)
    node))

;;;; Character classes

(defun mdview-inline--whitespace-p (c)
  "Return non-nil when C is Unicode whitespace in the CommonMark sense."
  (or (memq c '(?\s ?\t ?\n ?\r ?\f))
      (eq (get-char-code-property c 'general-category) 'Zs)))

(defun mdview-inline--punctuation-p (c)
  "Return non-nil when C is a Unicode punctuation or symbol character."
  (or (<= 33 c 47) (<= 58 c 64) (<= 91 c 96) (<= 123 c 126)
      (and (> c 127)
           (memq (get-char-code-property c 'general-category)
                 '(Pc Pd Pe Pf Pi Po Ps Sc Sk Sm So)))))

(defun mdview-inline--escapable-p (c)
  "Return non-nil when C is ASCII punctuation, which a backslash escapes."
  (or (<= 33 c 47) (<= 58 c 64) (<= 91 c 96) (<= 123 c 126)))

(defun mdview-inline--trim-right-spaces (string)
  "Return STRING without trailing space characters (linear time)."
  (let ((end (length string)))
    (while (and (> end 0) (eq (aref string (1- end)) ?\s))
      (setq end (1- end)))
    (substring string 0 end)))

;;;; Escapes, entities and labels

(defconst mdview-inline--unescape-regexp
  (concat "\\\\\\([!-/:-@[-`{-~]\\)"
          "\\|&\\(?:#[xX][[:xdigit:]]\\{1,6\\}\\|#[0-9]\\{1,7\\}"
          "\\|[A-Za-z][A-Za-z0-9]\\{1,31\\}\\);")
  "Regexp matching one backslash escape or one entity reference.")

(defun mdview-inline-unescape (string)
  "Return STRING with backslash escapes and entity references resolved.
Both are processed in a single pass, so the output of one is never
re-interpreted by the other (\"\\\\&amp;\" yields \"&amp;\")."
  (if (not (or (string-search "\\" string) (string-search "&" string)))
      string
    (replace-regexp-in-string
     mdview-inline--unescape-regexp
     (lambda (match)
       (if (match-beginning 1)
           (match-string 1 match)
         (mdview-ast-decode-entities match)))
     string t t)))

(defun mdview-inline-normalize-label (label)
  "Return link LABEL normalized for reference lookup.
Whitespace is trimmed and collapsed to single spaces and the result is
case folded with `upcase' of `downcase', the convention of the block
parser's `:refs' table."
  (upcase (downcase (string-join (split-string label "[ \t\n\r]+" t) " "))))

;;;; Scanners (point at the construct; return the end position or nil)

(defconst mdview-inline--entity-regexp
  (concat "&\\(?:#[xX][[:xdigit:]]\\{1,6\\}\\|#[0-9]\\{1,7\\}"
          "\\|[A-Za-z][A-Za-z0-9]\\{1,31\\}\\);")
  "Regexp matching one entity or numeric character reference.")

(defconst mdview-inline--email-autolink-regexp
  (concat "<\\([A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@"
          "[A-Za-z0-9]\\(?:[A-Za-z0-9-]\\{0,61\\}[A-Za-z0-9]\\)?"
          "\\(?:\\.[A-Za-z0-9]\\(?:[A-Za-z0-9-]\\{0,61\\}[A-Za-z0-9]\\)?\\)*\\)>")
  "Regexp matching an e-mail autolink; group 1 is the address.")

(defconst mdview-inline--uri-autolink-regexp
  "<\\([A-Za-z][A-Za-z0-9.+-]\\{1,31\\}:[^<>[:space:][:cntrl:]]*\\)>"
  "Regexp matching a URI autolink; group 1 is the URI.")

(defun mdview-inline--scan-html-open-tag ()
  "Scan an HTML open tag at point; return its end position or nil."
  (save-excursion
    (when (looking-at "<[A-Za-z][A-Za-z0-9-]*")
      (goto-char (match-end 0))
      (catch 'done
        (while t
          (let ((before (point)))
            (skip-chars-forward " \t\n")
            (cond
             ((looking-at "/?>") (throw 'done (match-end 0)))
             ((= before (point)) (throw 'done nil))
             ((looking-at "[A-Za-z_:][A-Za-z0-9_.:-]*")
              (goto-char (match-end 0))
              (let ((after-name (point)))
                (skip-chars-forward " \t\n")
                (if (not (eq (following-char) ?=))
                    (goto-char after-name)
                  (forward-char)
                  (skip-chars-forward " \t\n")
                  (if (looking-at "[^ \t\n\"'=<>`]+\\|'[^']*'\\|\"[^\"]*\"")
                      (goto-char (match-end 0))
                    (throw 'done nil)))))
             (t (throw 'done nil)))))))))

(defun mdview-inline--search-terminator (terminator)
  "Search forward for TERMINATOR; return the position after it, or nil.
A failed search is remembered in `mdview-inline--absent-terminators'
for the rest of the parse: every later candidate lies further on, so
the terminator cannot follow it either and it is answered without
scanning the text again."
  (unless (member terminator mdview-inline--absent-terminators)
    (or (and (search-forward terminator nil t) (point))
        (progn (push terminator mdview-inline--absent-terminators) nil))))

(defun mdview-inline--scan-html ()
  "Scan a raw HTML construct at point (a `<'); return its end or nil."
  (let ((c (char-after (1+ (point)))))
    (cond
     ((null c) nil)
     ((eq c ?!)
      (cond
       ((looking-at "<!-->\\|<!--->") (match-end 0))
       ((looking-at "<!--")
        (save-excursion (goto-char (match-end 0))
                        (mdview-inline--search-terminator "-->")))
       ((looking-at "<!\\[CDATA\\[")
        (save-excursion (goto-char (match-end 0))
                        (mdview-inline--search-terminator "]]>")))
       ((looking-at "<![A-Za-z]")
        (save-excursion (goto-char (match-end 0))
                        (mdview-inline--search-terminator ">")))))
     ((eq c ??)
      (save-excursion (forward-char 2)
                      (mdview-inline--search-terminator "?>")))
     ((eq c ?/)
      (and (looking-at "</[A-Za-z][A-Za-z0-9-]*[ \t\n]*>") (match-end 0)))
     ((or (<= ?a c ?z) (<= ?A c ?Z))
      (mdview-inline--scan-html-open-tag)))))

(defun mdview-inline--scan-link-label ()
  "Scan a link label `[...]' at point.
Return the length of the label including the brackets and leave point
after it, or return 0 and leave point unchanged.  A label holds at most
999 characters and no unescaped brackets."
  (let ((start (point)) (count 0) (ok nil))
    (when (eq (following-char) ?\[)
      (save-excursion
        (forward-char)
        (while (and (not ok) (not (eobp)) (<= count 999))
          (let ((c (following-char)))
            (cond
             ((eq c ?\\)
              (forward-char (if (< (1+ (point)) (point-max)) 2 1))
              (setq count (+ count 2)))
             ((eq c ?\[) (goto-char (point-max)))
             ((eq c ?\]) (setq ok t))
             (t (forward-char) (setq count (1+ count))))))
        (when (and ok (<= count 999))
          (setq count (- (1+ (point)) start)))))
    (if (and ok (<= count 1001))
        (progn (goto-char (+ start count)) count)
      0)))

(defun mdview-inline--skip-spnl ()
  "Skip spaces and tabs and at most one line ending at point."
  (skip-chars-forward " \t")
  (when (eq (following-char) ?\n)
    (forward-char)
    (skip-chars-forward " \t")))

(defun mdview-inline--scan-link-destination ()
  "Scan a link destination at point and return it unescaped, or nil.
Point moves past the destination on success."
  (cond
   ((looking-at "<\\(\\(?:[^<>\n\\]\\|\\\\[^z-a]\\)*\\)>")
    (goto-char (match-end 0))
    (mdview-inline-unescape (match-string-no-properties 1)))
   ((eq (following-char) ?<) nil)
   (t
    (let ((start (point)) (parens 0) (done nil))
      (while (and (not done) (not (eobp)))
        (let ((c (following-char)))
          (cond
           ((and (eq c ?\\) (< (1+ (point)) (point-max))
                 (mdview-inline--escapable-p (char-after (1+ (point)))))
            (forward-char 2))
           ((eq c ?\()
            ;; Like cmark, give up after 32 unclosed parens so that a
            ;; failing scan never walks to the end of a long line.
            (setq parens (1+ parens))
            (if (> parens 32) (setq done t) (forward-char)))
           ((eq c ?\))
            (if (< parens 1) (setq done t)
              (setq parens (1- parens)) (forward-char)))
           ((or (<= c 32) (eq c 127)) (setq done t))
           (t (forward-char)))))
      (cond
       ((and (= (point) start) (not (eq (following-char) ?\)))) nil)
       ((/= parens 0) (goto-char start) nil)
       (t (mdview-inline-unescape
           (buffer-substring-no-properties start (point)))))))))

(defconst mdview-inline--link-title-regexp
  (concat "\"\\(\\(?:[^\"\\]\\|\\\\[^z-a]\\)*\\)\""
          "\\|'\\(\\(?:[^'\\]\\|\\\\[^z-a]\\)*\\)'"
          "\\|(\\(\\(?:[^()\\]\\|\\\\[^z-a]\\)*\\))")
  "Regexp matching a link title in double quotes, single quotes or parens.")

(defun mdview-inline--scan-link-title ()
  "Scan a link title at point; return it unescaped and move point, or nil."
  (when (looking-at mdview-inline--link-title-regexp)
    (goto-char (match-end 0))
    (mdview-inline-unescape
     (or (match-string-no-properties 1) (match-string-no-properties 2)
         (match-string-no-properties 3)))))

;;;; Simple constructs

(defun mdview-inline--parse-newline (root)
  "Parse the line ending at point into a soft or hard break under ROOT."
  (forward-char)
  (let ((last (mdview-inline--node-last root)))
    (if (and last (eq (mdview-inline--node-type last) 'text)
             (string-suffix-p " " (mdview-inline--node-text last)))
        (let ((hard (string-suffix-p "  " (mdview-inline--node-text last))))
          (setf (mdview-inline--node-text last)
                (mdview-inline--trim-right-spaces (mdview-inline--node-text last)))
          (mdview-inline--add-node root (if hard 'hard-break 'soft-break)))
      (mdview-inline--add-node root 'soft-break)))
  (skip-chars-forward " \t"))

(defun mdview-inline--parse-backslash (root)
  "Parse the backslash at point under ROOT: an escape, a hard break or text."
  (forward-char)
  (let ((c (following-char)))
    (cond
     ((eq c ?\n)
      (forward-char)
      (mdview-inline--add-node root 'hard-break)
      (skip-chars-forward " \t"))
     ((and (not (eobp)) (mdview-inline--escapable-p c))
      ;; The escaped character stands for itself: point at it, not at
      ;; the backslash.
      (mdview-inline--add-text root (string c) (mdview-inline--offset))
      (forward-char))
     (t (mdview-inline--add-text root "\\" (mdview-inline--offset (1- (point))))))))

(defun mdview-inline--parse-backticks (root)
  "Parse the backtick run at point under ROOT: a code span or literal text.
The search for the closing run is memoized as in cmark: every run met
while scanning is recorded in `mdview-inline--backtick-last', and once
a scan has reached the end of the text an opener with no later run of
its length is rejected without scanning again."
  (let ((start (point)))
    (skip-chars-forward "`")
    (let* ((after-open (point))
           (len (- after-open start))
           (found nil))
      (unless mdview-inline--backtick-last
        (setq mdview-inline--backtick-last (make-hash-table :test #'eql)))
      (unless (and mdview-inline--backticks-scanned
                   (<= (gethash len mdview-inline--backtick-last 0) start))
        (while (and (not found) (re-search-forward "`+" nil t))
          (let ((n (- (match-end 0) (match-beginning 0))))
            (puthash n (match-beginning 0) mdview-inline--backtick-last)
            (when (= n len)
              (setq found (match-beginning 0)))))
        (unless found
          (setq mdview-inline--backticks-scanned t)))
      (if (not found)
          (progn (goto-char after-open)
                 (mdview-inline--add-text
                  root (buffer-substring-no-properties start after-open)
                  (mdview-inline--offset start)))
        (let ((content (subst-char-in-string
                        ?\n ?\s (buffer-substring-no-properties after-open found)))
              (pos (mdview-inline--offset after-open)))
          (when (and (> (length content) 1)
                     (eq (aref content 0) ?\s)
                     (eq (aref content (1- (length content))) ?\s)
                     (string-match-p "[^ ]" content))
            (setq content (substring content 1 -1)
                  pos (1+ pos)))
          (mdview-inline--add-node root 'code (list :pos pos) content))))))

(defun mdview-inline--parse-entity (root)
  "Parse the entity reference at point under ROOT, or a literal ampersand."
  (if (looking-at mdview-inline--entity-regexp)
      (progn
        (mdview-inline--add-text
         root (mdview-ast-decode-entities (match-string-no-properties 0))
         (mdview-inline--offset))
        (goto-char (match-end 0)))
    (mdview-inline--add-text root "&" (mdview-inline--offset))
    (forward-char)))

(defun mdview-inline--parse-autolink (root)
  "Parse an angle-bracket autolink at point under ROOT; return non-nil if so."
  (cond
   ((looking-at mdview-inline--email-autolink-regexp)
    (let ((address (match-string-no-properties 1))
          (pos (mdview-inline--offset (match-beginning 1))))
      (goto-char (match-end 0))
      (mdview-inline--append-child
       (mdview-inline--add-node root 'link
                                (list :url (concat "mailto:" address)
                                      :title nil :autolink t))
       (mdview-inline--make-node :type 'text
                                 :text (mdview-inline--text address pos)))
      t))
   ((looking-at mdview-inline--uri-autolink-regexp)
    (let ((uri (match-string-no-properties 1))
          (pos (mdview-inline--offset (match-beginning 1))))
      (goto-char (match-end 0))
      (mdview-inline--append-child
       (mdview-inline--add-node root 'link (list :url uri :title nil :autolink t))
       (mdview-inline--make-node :type 'text :text (mdview-inline--text uri pos)))
      t))))

(defun mdview-inline--parse-html (root)
  "Parse raw inline HTML at point under ROOT; return non-nil if recognised."
  (let ((end (mdview-inline--scan-html)))
    (when end
      (mdview-inline--add-node root 'html-inline
                               (list :pos (mdview-inline--offset))
                               (buffer-substring-no-properties (point) end))
      (goto-char end)
      t)))

(defconst mdview-inline--text-run-regexp "[^]\n`[\\!<&*_~]+"
  "Regexp matching a run of characters with no inline significance.")

(defun mdview-inline--parse-text (root)
  "Parse a run of ordinary text at point under ROOT."
  (if (looking-at mdview-inline--text-run-regexp)
      (progn
        (mdview-inline--add-text
         root (buffer-substring-no-properties (point) (match-end 0))
         (mdview-inline--offset))
        (goto-char (match-end 0)))
    (mdview-inline--add-text root (string (following-char)) (mdview-inline--offset))
    (forward-char)))

;;;; Delimiters

(defun mdview-inline--parse-delim (root c)
  "Parse the run of delimiter character C at point under ROOT.
The run becomes a text node and, when it can open or close emphasis,
an entry of the delimiter stack."
  (let* ((start (point))
         (before (if (bobp) ?\n (char-before)))
         (count (progn (skip-chars-forward (string c)) (- (point) start)))
         (after (if (eobp) ?\n (following-char)))
         (node (mdview-inline--add-text
                root (buffer-substring-no-properties start (point))
                (mdview-inline--offset start))))
    (unless (and (eq c ?~) (> count 2))
      (let* ((after-ws (mdview-inline--whitespace-p after))
             (after-p (mdview-inline--punctuation-p after))
             (before-ws (mdview-inline--whitespace-p before))
             (before-p (mdview-inline--punctuation-p before))
             (left (and (not after-ws) (or (not after-p) before-ws before-p)))
             (right (and (not before-ws) (or (not before-p) after-ws after-p)))
             (can-open (if (eq c ?_) (and left (or (not right) before-p)) left))
             (can-close (if (eq c ?_) (and right (or (not left) after-p)) right)))
        (when (or can-open can-close)
          (let ((delim (mdview-inline--make-delim
                        :cc c :count count :orig count :node node
                        :can-open can-open :can-close can-close
                        :prev mdview-inline--delims)))
            (when mdview-inline--delims
              (setf (mdview-inline--delim-next mdview-inline--delims) delim))
            (setq mdview-inline--delims delim)))))))

(defun mdview-inline--remove-delim (delim)
  "Remove DELIM from the delimiter stack."
  (let ((prev (mdview-inline--delim-prev delim))
        (next (mdview-inline--delim-next delim)))
    (when prev (setf (mdview-inline--delim-next prev) next))
    (if next
        (setf (mdview-inline--delim-prev next) prev)
      (setq mdview-inline--delims prev))))

(defun mdview-inline--bottom-index (closer)
  "Return the `openers-bottom' slot of CLOSER (see `process-emphasis')."
  (let ((cc (mdview-inline--delim-cc closer)))
    (cond
     ((eq cc ?*) (+ 0 (if (mdview-inline--delim-can-open closer) 3 0)
                    (% (mdview-inline--delim-orig closer) 3)))
     ((eq cc ?_) (+ 6 (if (mdview-inline--delim-can-open closer) 3 0)
                    (% (mdview-inline--delim-orig closer) 3)))
     (t (+ 12 (if (mdview-inline--delim-can-open closer) 2 0)
           (1- (min 2 (mdview-inline--delim-orig closer))))))))

(defun mdview-inline--opener-matches-p (opener closer)
  "Return non-nil when delimiter OPENER can close with CLOSER."
  (let ((cc (mdview-inline--delim-cc closer)))
    (and (eq (mdview-inline--delim-cc opener) cc)
         (mdview-inline--delim-can-open opener)
         (if (eq cc ?~)
             (= (mdview-inline--delim-count opener)
                (mdview-inline--delim-count closer))
           (not (and (or (mdview-inline--delim-can-open closer)
                         (mdview-inline--delim-can-close opener))
                     (/= (% (mdview-inline--delim-orig closer) 3) 0)
                     (= (% (+ (mdview-inline--delim-orig opener)
                              (mdview-inline--delim-orig closer))
                           3)
                        0)))))))

(defun mdview-inline--close-emphasis (opener closer)
  "Wrap the nodes between OPENER and CLOSER into an emphasis node.
Return the delimiter to continue with."
  (let* ((cc (mdview-inline--delim-cc closer))
         (use (cond ((eq cc ?~) (mdview-inline--delim-count closer))
                    ((and (>= (mdview-inline--delim-count closer) 2)
                          (>= (mdview-inline--delim-count opener) 2))
                     2)
                    (t 1)))
         (opener-node (mdview-inline--delim-node opener))
         (closer-node (mdview-inline--delim-node closer))
         (emph (mdview-inline--make-node
                :type (cond ((eq cc ?~) 'strikethrough)
                            ((= use 2) 'strong)
                            (t 'emphasis)))))
    (cl-decf (mdview-inline--delim-count opener) use)
    (cl-decf (mdview-inline--delim-count closer) use)
    ;; The delimiters used are the inner ones: the opener loses its
    ;; last USE characters, so its `mdview-pos' stays; the closer loses
    ;; its first USE, so `mdview-ast-substring' moves its `mdview-pos'
    ;; on by USE (invariant R1 of docs/DESIGN.md section 3).
    (setf (mdview-inline--node-text opener-node)
          (substring (mdview-inline--node-text opener-node) 0 (- use)))
    (setf (mdview-inline--node-text closer-node)
          (mdview-ast-substring (mdview-inline--node-text closer-node) use))
    (let ((tmp (mdview-inline--node-next opener-node)))
      (while (and tmp (not (eq tmp closer-node)))
        (let ((next (mdview-inline--node-next tmp)))
          (mdview-inline--unlink tmp)
          (mdview-inline--append-child emph tmp)
          (setq tmp next))))
    (mdview-inline--insert-after opener-node emph)
    ;; Drop the delimiters between opener and closer.
    (setf (mdview-inline--delim-next opener) closer
          (mdview-inline--delim-prev closer) opener)
    (when (= (mdview-inline--delim-count opener) 0)
      (mdview-inline--unlink opener-node)
      (mdview-inline--remove-delim opener))
    (if (= (mdview-inline--delim-count closer) 0)
        (let ((next (mdview-inline--delim-next closer)))
          (mdview-inline--unlink closer-node)
          (mdview-inline--remove-delim closer)
          next)
      closer)))

(defun mdview-inline--process-emphasis (bottom)
  "Resolve the delimiter stack above BOTTOM into emphasis nodes.
This is the CommonMark `process emphasis' procedure, with the
`openers_bottom' optimisation keyed by delimiter character, the
closer's ability to open and its run length modulo 3."
  (let ((openers-bottom (make-vector 16 bottom))
        (closer mdview-inline--delims))
    (while (and closer (not (eq (mdview-inline--delim-prev closer) bottom)))
      (setq closer (mdview-inline--delim-prev closer)))
    (while closer
      (if (not (mdview-inline--delim-can-close closer))
          (setq closer (mdview-inline--delim-next closer))
        (let* ((index (mdview-inline--bottom-index closer))
               (limit (aref openers-bottom index))
               (opener (mdview-inline--delim-prev closer))
               (found nil))
          (while (and opener (not (eq opener bottom)) (not (eq opener limit))
                      (not found))
            (if (mdview-inline--opener-matches-p opener closer)
                (setq found t)
              (setq opener (mdview-inline--delim-prev opener))))
          (if found
              (setq closer (mdview-inline--close-emphasis opener closer))
            (aset openers-bottom index (mdview-inline--delim-prev closer))
            (let ((next (mdview-inline--delim-next closer)))
              (unless (mdview-inline--delim-can-open closer)
                (mdview-inline--remove-delim closer))
              (setq closer next))))))
    (while (and mdview-inline--delims (not (eq mdview-inline--delims bottom)))
      (mdview-inline--remove-delim mdview-inline--delims))))

;;;; Brackets, links and images

(defun mdview-inline--add-bracket (node index image)
  "Push a bracket opened by text NODE at buffer INDEX.
IMAGE non-nil means the bracket belongs to an image (`![')."
  (when mdview-inline--brackets
    (setf (mdview-inline--bracket-after mdview-inline--brackets) t))
  (setq mdview-inline--brackets
        (mdview-inline--make-bracket :node node :index index :image image
                                     :active t :prev mdview-inline--brackets
                                     :prev-delim mdview-inline--delims)))

(defun mdview-inline--remove-bracket ()
  "Pop the bracket stack."
  (setq mdview-inline--brackets
        (mdview-inline--bracket-prev mdview-inline--brackets)))

(defun mdview-inline--parse-open-bracket (root)
  "Parse the `[' at point under ROOT: a footnote reference or an opener."
  (if (looking-at "\\[\\^\\([^][ \t\n][^][\t\n]*\\)\\]")
      (progn
        (mdview-inline--add-node root 'footnote-reference
                                 (list :label (match-string-no-properties 1)))
        (goto-char (match-end 0)))
    (let ((node (mdview-inline--add-text root "[" (mdview-inline--offset))))
      (forward-char)
      (mdview-inline--add-bracket node (point) nil))))

(defun mdview-inline--parse-bang (root)
  "Parse the `!' at point under ROOT: an image opener when `[' follows."
  (let ((pos (mdview-inline--offset)))
    (forward-char)
    (if (eq (following-char) ?\[)
        (progn
          (forward-char)
          (mdview-inline--add-bracket (mdview-inline--add-text root "![" pos)
                                      (point) t))
      (mdview-inline--add-text root "!" pos))))

(defun mdview-inline--scan-inline-link ()
  "Scan `(destination \"title\")' at point (just after a `]').
Return (URL . TITLE) and move point past the closing paren, or return
nil and leave point unchanged."
  (let ((save (point)) dest title)
    (if (and (eq (following-char) ?\()
             (progn (forward-char) (mdview-inline--skip-spnl) t)
             (setq dest (mdview-inline--scan-link-destination))
             (let ((before (point)))
               (mdview-inline--skip-spnl)
               (when (> (point) before)
                 (setq title (mdview-inline--scan-link-title))
                 (mdview-inline--skip-spnl))
               t)
             (eq (following-char) ?\)))
        (progn (forward-char) (cons dest title))
      (goto-char save)
      nil)))

(defun mdview-inline--lookup-reference (opener close-pos)
  "Resolve the reference label for bracket OPENER closed at CLOSE-POS.
Point is just after the `]'.  Try a full label `[label]', then the
collapsed `[]' and shortcut forms using the bracketed text.  Return
\(URL . TITLE) with point after the label on success, or nil."
  (let* ((save (point))
         (before (point))
         (n (mdview-inline--scan-link-label))
         (label (cond
                 ((> n 2)
                  (buffer-substring-no-properties (1+ before) (+ before n -1)))
                 ((and (not (mdview-inline--bracket-after opener))
                       ;; Like a scanned label, the bracketed text is a
                       ;; label only when it holds at most 999 characters.
                       (<= (- close-pos (mdview-inline--bracket-index opener))
                           999))
                  (buffer-substring-no-properties
                   (mdview-inline--bracket-index opener) close-pos)))))
    (when (= n 0) (goto-char save))
    (let ((ref (and label mdview-inline--refs
                    (let ((key (mdview-inline-normalize-label label)))
                      (and (not (string-empty-p key))
                           (gethash key mdview-inline--refs))))))
      (if ref
          (cons (car ref) (cdr ref))
        (goto-char save)
        nil))))

(defun mdview-inline--close-link (root opener target)
  "Turn the bracket OPENER into a link or image node under ROOT.
TARGET is (URL . TITLE).  The nodes after the opener become children;
emphasis inside is resolved; for links, earlier openers are deactivated
so that links never nest."
  (let* ((image (mdview-inline--bracket-image opener))
         (opener-node (mdview-inline--bracket-node opener))
         (node (mdview-inline--make-node
                :type (if image 'image 'link)
                :props (list :url (car target) :title (cdr target))))
         (tmp (mdview-inline--node-next opener-node)))
    (while tmp
      (let ((next (mdview-inline--node-next tmp)))
        (mdview-inline--unlink tmp)
        (mdview-inline--append-child node tmp)
        (setq tmp next)))
    (mdview-inline--append-child root node)
    (mdview-inline--process-emphasis (mdview-inline--bracket-prev-delim opener))
    (mdview-inline--remove-bracket)
    (mdview-inline--unlink opener-node)
    (unless image
      ;; Deactivation is monotone: when a link opener was deactivated,
      ;; every older one was too, so the walk stops at the first
      ;; inactive opener instead of visiting the whole stack each time.
      (let ((b mdview-inline--brackets))
        (while (and b (or (mdview-inline--bracket-image b)
                          (mdview-inline--bracket-active b)))
          (unless (mdview-inline--bracket-image b)
            (setf (mdview-inline--bracket-active b) nil))
          (setq b (mdview-inline--bracket-prev b)))))))

(defun mdview-inline--parse-close-bracket (root)
  "Parse the `]' at point under ROOT, closing a link or image if possible."
  (let ((close-pos (point))
        (opener mdview-inline--brackets))
    (forward-char)
    (cond
     ((null opener)
      (mdview-inline--add-text root "]" (mdview-inline--offset close-pos)))
     ((not (mdview-inline--bracket-active opener))
      (mdview-inline--remove-bracket)
      (mdview-inline--add-text root "]" (mdview-inline--offset close-pos)))
     (t
      (let ((target (or (mdview-inline--scan-inline-link)
                        (mdview-inline--lookup-reference opener close-pos))))
        (if target
            (mdview-inline--close-link root opener target)
          (mdview-inline--remove-bracket)
          (goto-char (1+ close-pos))
          (mdview-inline--add-text root "]" (mdview-inline--offset close-pos))))))))

;;;; GFM extended autolinks (post-pass over text)

(defun mdview-inline--autolink-boundary-p (string index)
  "Return non-nil when a URL may start at INDEX of STRING (GFM rule)."
  (or (= index 0)
      (memq (aref string (1- index)) '(?\s ?\t ?\n ?* ?_ ?~ ?\())))

(defun mdview-inline--domain-char-p (c)
  "Return non-nil when C may appear in the domain part of a bare URL."
  (or (and (>= c ?a) (<= c ?z)) (and (>= c ?A) (<= c ?Z))
      (and (>= c ?0) (<= c ?9)) (memq c '(?_ ?- ?.))
      (and (> c 127) (memq (get-char-code-property c 'general-category)
                           '(Lu Ll Lt Lm Lo Nd Nl No)))))

(defun mdview-inline--valid-domain-p (domain need-period)
  "Return non-nil when DOMAIN is a valid GFM autolink domain.
No underscore may appear in the last two segments; NEED-PERIOD
requires at least one period (the `www.' form)."
  (let ((segments (split-string domain "\\." nil)))
    (and (not (string-empty-p domain))
         (not (seq-some #'string-empty-p segments))
         (or (not need-period) (> (length segments) 1))
         (not (seq-some (lambda (s) (string-search "_" s))
                        (last segments 2))))))

(defun mdview-inline--trim-autolink-end (string start end)
  "Return the end of the autolink in STRING from START, trimming after END.
Trailing punctuation, an unbalanced closing paren and a trailing entity
reference are excluded per the GFM rules.  The parentheses are counted
once and the count is kept up to date while trimming, so a URL followed
by thousands of `)' is handled in linear time."
  (let ((opens 0) (closes 0) (i start) (changed t))
    (while (< i end)
      (cond ((eq (aref string i) ?\() (setq opens (1+ opens)))
            ((eq (aref string i) ?\)) (setq closes (1+ closes))))
      (setq i (1+ i)))
    (while (and changed (> end start))
      (setq changed nil)
      (let ((c (aref string (1- end))))
        (cond
         ((memq c '(?? ?! ?. ?, ?: ?* ?_ ?~ ?' ?\"))
          (setq end (1- end) changed t))
         ((eq c ?\))
          (when (> closes opens)
            (setq closes (1- closes) end (1- end) changed t)))
         ((eq c ?\;)
          (let ((i (1- end)))
            (while (and (> i start)
                        (let ((d (aref string (1- i))))
                          (or (and (>= d ?a) (<= d ?z)) (and (>= d ?A) (<= d ?Z))
                              (and (>= d ?0) (<= d ?9)))))
              (setq i (1- i)))
            (when (and (> i start) (< i (1- end)) (eq (aref string (1- i)) ?&))
              (setq end (1- i) changed t)))))))
    end))

(defun mdview-inline--prefix-at-p (prefix string start)
  "Return non-nil when PREFIX occurs in STRING at index START.
Unlike an unanchored `string-match' this never scans past the prefix."
  (eq t (compare-strings prefix nil nil string start (+ start (length prefix)))))

(defun mdview-inline--match-url-autolink (string start)
  "Match a bare URL at START of STRING; return (END . URL) or nil."
  (let* ((len (length string))
         (www (mdview-inline--prefix-at-p "www." string start))
         (scheme-end (cond (www start)
                           ((mdview-inline--prefix-at-p "https://" string start)
                            (+ start 8))
                           ((mdview-inline--prefix-at-p "http://" string start)
                            (+ start 7))
                           ((mdview-inline--prefix-at-p "ftp://" string start)
                            (+ start 6)))))
    (when scheme-end
      (let ((i scheme-end)
            (domain-start (if www (+ start 4) scheme-end)))
        (while (and (< i len) (mdview-inline--domain-char-p (aref string i)))
          (setq i (1+ i)))
        ;; A period right after the domain ends the sentence rather than
        ;; a segment ("see www.example.org."): leave it to the trailing
        ;; punctuation rule, as cmark-gfm does.
        (let ((domain-end i))
          (while (and (> domain-end domain-start)
                      (eq (aref string (1- domain-end)) ?.))
            (setq domain-end (1- domain-end)))
          (when (mdview-inline--valid-domain-p
                 (substring string domain-start domain-end) www)
            (while (and (< i len)
                        (not (memq (aref string i) '(?\s ?\t ?\n ?<))))
              (setq i (1+ i)))
            (let ((end (mdview-inline--trim-autolink-end string start i)))
              (when (> end scheme-end)
                (cons end (if www
                              (concat "http://"
                                      (substring-no-properties string start end))
                            (substring-no-properties string start end)))))))))))

(defun mdview-inline--local-part-char-p (c)
  "Return non-nil when C may appear before the `@' of an e-mail address."
  (or (and (>= c ?a) (<= c ?z)) (and (>= c ?A) (<= c ?Z))
      (and (>= c ?0) (<= c ?9)) (memq c '(?. ?_ ?+ ?-))))

(defun mdview-inline--match-email-autolink (string start)
  "Match an e-mail address at START of STRING; return (END . URL) or nil."
  (let ((len (length string)) (i start))
    (while (and (< i len) (mdview-inline--local-part-char-p (aref string i)))
      (setq i (1+ i)))
    (when (and (> i start) (< i len) (eq (aref string i) ?@))
      (let ((domain-start (1+ i)))
        (setq i domain-start)
        (while (and (< i len)
                    (let ((c (aref string i)))
                      (and (mdview-inline--local-part-char-p c) (not (eq c ?+)))))
          (setq i (1+ i)))
        (when (and (> i domain-start) (eq (aref string (1- i)) ?.))
          (setq i (1- i)))
        (let ((domain (substring string domain-start i)))
          (when (and (> i domain-start)
                     (string-search "." domain)
                     (not (memq (aref string (1- i)) '(?- ?_))))
            (cons i (concat "mailto:"
                            (substring-no-properties string start i)))))))))

(defun mdview-inline--next-url-candidate (string from)
  "Return the first index at or after FROM of STRING where a URL may start."
  (let ((i (string-match "www\\.\\|https?://\\|ftp://" string from)))
    (while (and i (not (mdview-inline--autolink-boundary-p string i)))
      (setq i (string-match "www\\.\\|https?://\\|ftp://" string (1+ i))))
    i))

(defun mdview-inline--next-email-candidate (string from at-from)
  "Return the first index at or after FROM of STRING where an address may start.
The `@' is looked for from AT-FROM on; the local part before it is
followed back no further than FROM."
  (let ((at (string-search "@" string (max from at-from))) (result nil))
    (while (and at (not result))
      (let ((b at))
        (while (and (> b from) (mdview-inline--local-part-char-p (aref string (1- b))))
          (setq b (1- b)))
        (if (< b at)
            (setq result b)
          (setq at (string-search "@" string (1+ at))))))
    result))

(defun mdview-inline--autolink-split (string)
  "Split STRING into text and link nodes at bare URLs and addresses."
  (let ((len (length string)) (pos 0) (text-start 0) (out nil)
        (url-cand -1) (email-cand -1) (at-from 0))
    (while (< pos len)
      (when (and url-cand (< url-cand pos))
        (setq url-cand (mdview-inline--next-url-candidate string pos)))
      (when (and email-cand (< email-cand pos))
        (setq email-cand (mdview-inline--next-email-candidate string pos at-from)))
      (let ((cand (cond ((and url-cand email-cand) (min url-cand email-cand))
                        (t (or url-cand email-cand)))))
        (if (null cand)
            (setq pos len)
          (let* ((email (not (and url-cand (= cand url-cand))))
                 (hit (if email
                          (mdview-inline--match-email-autolink string cand)
                        (mdview-inline--match-url-autolink string cand))))
            (if hit
                (progn
                  (when (> cand text-start)
                    (push (mdview-ast-substring string text-start cand) out))
                  (push (mdview-node 'link (list :url (cdr hit) :title nil
                                                 :autolink t)
                                     (mdview-ast-substring string cand (car hit)))
                        out)
                  (setq pos (car hit) text-start pos))
              (when email
                ;; The address failed on its domain, which is the same for
                ;; every start inside this local part: look for the next
                ;; `@' beyond the one just tried instead of retrying from
                ;; each character of the local part.
                (setq at-from (1+ (string-search "@" string cand))))
              (setq pos (1+ cand)))))))
    (when (< text-start len)
      (push (mdview-ast-substring string text-start) out))
    (nreverse out)))

;;;; Conversion to the AST

(defun mdview-inline--convert (node in-link depth)
  "Return the AST node for the finished parse NODE.
IN-LINK non-nil means inside a link or image, where bare URLs stay text.
DEPTH is the nesting depth of NODE (1 for a child of the root)."
  (let ((type (mdview-inline--node-type node))
        (props (mdview-inline--node-props node)))
    (pcase type
      ((or 'code 'html-inline)
       (mdview-node type props (mdview-inline--node-text node)))
      ((or 'hard-break 'soft-break 'footnote-reference) (mdview-node type props))
      ('image
       (let ((children (mdview-inline--children node t depth)))
         (apply #'mdview-node 'image
                (append props (list :alt (mapconcat #'mdview-node-text children "")))
                children)))
      ('link (apply #'mdview-node 'link props (mdview-inline--children node t depth)))
      (_ (apply #'mdview-node type props
                (mdview-inline--children node in-link depth))))))

(defun mdview-inline--children (node in-link depth)
  "Return the AST children of container NODE, merging adjacent text.
IN-LINK is passed on to `mdview-inline--convert'.  DEPTH is the nesting
depth of NODE; beyond `mdview-inline-max-depth' the conversion is
abandoned by throwing to `mdview-inline--too-deep'."
  (when (> depth mdview-inline-max-depth)
    (throw 'mdview-inline--too-deep t))
  (let ((child (mdview-inline--node-first node))
        (pending nil)
        (out nil))
    (cl-flet ((flush ()
                (when pending
                  (let ((text (apply #'concat (nreverse pending))))
                    (setq pending nil)
                    (unless (string-empty-p text)
                      (if (and mdview-inline-extended-autolinks (not in-link))
                          (dolist (piece (mdview-inline--autolink-split text))
                            (push piece out))
                        (push text out)))))))
      (while child
        (if (eq (mdview-inline--node-type child) 'text)
            (push (mdview-inline--node-text child) pending)
          (flush)
          (push (mdview-inline--convert child in-link (1+ depth)) out))
        (setq child (mdview-inline--node-next child)))
      (flush))
    (nreverse out)))

;;;; Main loop and public API

(defun mdview-inline--parse-one (root)
  "Parse one inline construct at point under ROOT."
  (let ((c (following-char)))
    (cond
     ((eq c ?\n) (mdview-inline--parse-newline root))
     ((eq c ?\\) (mdview-inline--parse-backslash root))
     ((eq c ?`) (mdview-inline--parse-backticks root))
     ((memq c '(?* ?_ ?~)) (mdview-inline--parse-delim root c))
     ((eq c ?\[) (mdview-inline--parse-open-bracket root))
     ((eq c ?!) (mdview-inline--parse-bang root))
     ((eq c ?\]) (mdview-inline--parse-close-bracket root))
     ((eq c ?<)
      (or (mdview-inline--parse-autolink root)
          (mdview-inline--parse-html root)
          (progn (mdview-inline--add-text root "<" (mdview-inline--offset))
                 (forward-char))))
     ((eq c ?&) (mdview-inline--parse-entity root))
     (t (mdview-inline--parse-text root)))))

(defun mdview-inline--scratch-buffer ()
  "Return the hidden buffer the parser scans in, creating it when needed."
  (unless (buffer-live-p mdview-inline--buffer)
    (setq mdview-inline--buffer (generate-new-buffer " *mdview-inline*" t))
    (with-current-buffer mdview-inline--buffer
      (setq-local case-fold-search nil)))
  mdview-inline--buffer)

(defun mdview-inline-parse (string refs)
  "Parse the Markdown inline content STRING into a list of inline nodes.
REFS is the document's link reference map, a hash table from normalized
label (see `mdview-inline-normalize-label') to (URL . TITLE), or nil.
The result follows the inline node contract of docs/DESIGN.md section
3: plain strings are text (entities decoded, escapes resolved), and
`emphasis', `strong', `strikethrough', `code', `link', `image',
`hard-break', `soft-break', `html-inline' and `footnote-reference'
nodes carry the properties listed there.

Source positions are content offsets, 0-based indices into STRING.
Every character of a text string carries the text property
`mdview-pos', valued at the offset of the first source character of
its run (invariant R1 of docs/DESIGN.md section 3, so the offset of
any character is that value plus its distance from the start of the
stretch of equal values; see `mdview-ast-pos-at').  A backslash escape
points at the escaped character, a decoded entity at its `&'.  `code'
nodes have `:pos', the offset of the first character of their content
\(after the opening backticks and the space stripped with the closing
one, if any), and `html-inline' nodes have `:pos', the offset of their
`<'.  The block parser translates these offsets to source offsets.

Nesting deeper than `mdview-inline-max-depth' degrades the result to
STRING as one text node with `mdview-pos' 0.  The parser is not
reentrant: it scans in a single hidden buffer that every call reuses."
  (let ((mdview-inline--refs refs)
        (mdview-inline--delims nil)
        (mdview-inline--brackets nil)
        (mdview-inline--absent-terminators nil)
        (mdview-inline--backtick-last nil)
        (mdview-inline--backticks-scanned nil)
        (case-fold-search nil)
        (root (mdview-inline--make-node :type 'root))
        (result nil))
    (with-current-buffer (mdview-inline--scratch-buffer)
      (erase-buffer)
      (insert string)
      (goto-char (point-min))
      (while (not (eobp))
        (mdview-inline--parse-one root))
      (mdview-inline--process-emphasis nil))
    (if (catch 'mdview-inline--too-deep
          (setq result (mdview-inline--children root nil 0))
          nil)
        (list (propertize string 'mdview-pos 0))
      result)))

(provide 'mdview-inline)
;;; mdview-inline.el ends here
