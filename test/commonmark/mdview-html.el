;;; mdview-html.el --- HTML serializer for the CommonMark spec tests  -*- lexical-binding: t; -*-

;; This file is part of mdview, distributed under the MIT license; see
;; LICENSE in the repository root.

;;; Commentary:

;; Serializes an mdview document AST to HTML the way the CommonMark
;; specification examples expect (docs/DESIGN.md section 4).  The
;; conventions follow cmark's HTML renderer: block tags are preceded by
;; a newline unless one is already there (cmark's `cr'), tight list
;; items render their paragraphs without <p>, fenced code with an info
;; string gets `<pre><code class="language-x">', `<hr />', `<br />' and
;; `<img />' are self-closing, text is escaped as &amp; &lt; &gt; &quot;
;; and link destinations are percent-encoded like cmark's
;; `houdini_escape_href'.  GFM constructs the specification does not
;; cover (tables, task items, strikethrough, footnotes) are emitted in
;; GitHub's style so the serializer is also useful for unit tests.  Not
;; part of the package.

;;; Code:

(require 'cl-lib)
(require 'mdview-ast)

(defun mdview-html-escape (string)
  "Return STRING with &, <, > and double quotes replaced by entities."
  (let ((s string))
    (dolist (pair '(("&" . "&amp;") ("<" . "&lt;") (">" . "&gt;") ("\"" . "&quot;")))
      (setq s (string-replace (car pair) (cdr pair) s)))
    s))

(defconst mdview-html--href-safe
  (append "-_.+!*(),%#@?=;:/,+&$~" nil)
  "Non-alphanumeric characters cmark leaves unescaped in href attributes.")

(defun mdview-html-escape-href (url)
  "Return URL percent-encoded and entity-escaped like cmark does for href."
  (mapconcat
   (lambda (byte)
     (cond ((or (<= ?a byte ?z) (<= ?A byte ?Z) (<= ?0 byte ?9)
                (memq byte mdview-html--href-safe))
            (if (eq byte ?&) "&amp;" (string byte)))
           ((eq byte ?') "&#x27;")
           (t (format "%%%02X" byte))))
   (encode-coding-string url 'utf-8)
   ""))

;;;; Inlines

(defun mdview-html--inlines (nodes)
  "Return the serialization of the list of inline NODES."
  (mapconcat #'mdview-html--inline nodes ""))

(defun mdview-html--title (title)
  "Return the title attribute text for TITLE, or an empty string."
  (if title (concat " title=\"" (mdview-html-escape title) "\"") ""))

(defun mdview-html--inline (node)
  "Return the serialization of inline NODE."
  (if (stringp node)
      (mdview-html-escape node)
    (let ((children (mdview-node-children node)))
      (pcase (mdview-node-type node)
        ('soft-break "\n")
        ('hard-break "<br />\n")
        ('emphasis (concat "<em>" (mdview-html--inlines children) "</em>"))
        ('strong (concat "<strong>" (mdview-html--inlines children) "</strong>"))
        ('strikethrough (concat "<del>" (mdview-html--inlines children) "</del>"))
        ('code (concat "<code>" (mdview-html-escape (mdview-node-text node)) "</code>"))
        ('link
         (concat "<a href=\"" (mdview-html-escape-href (or (mdview-node-prop node :url) ""))
                 "\"" (mdview-html--title (mdview-node-prop node :title)) ">"
                 (mdview-html--inlines children) "</a>"))
        ('image
         (concat "<img src=\"" (mdview-html-escape-href (or (mdview-node-prop node :url) ""))
                 "\" alt=\"" (mdview-html-escape (mdview-node-text node)) "\""
                 (mdview-html--title (mdview-node-prop node :title)) " />"))
        ('html-inline (or (car children) ""))
        ('footnote-reference
         (let ((n (or (mdview-node-prop node :index) 0)))
           (format "<sup class=\"footnote-ref\"><a href=\"#fn-%d\" id=\"fnref-%d\">%d</a></sup>"
                   n n n)))
        (_ (mdview-html--inlines children))))))

;;;; Blocks

(defun mdview-html--cr ()
  "Insert a newline unless the buffer is empty or already ends with one."
  (unless (or (bobp) (eq (char-before) ?\n))
    (insert "\n")))

(defun mdview-html--blocks (nodes tight)
  "Insert the serialization of block NODES.
TIGHT non-nil drops the <p> tags of paragraphs."
  (dolist (node nodes)
    (mdview-html--block node tight)))

(defun mdview-html--block (node tight)
  "Insert the serialization of block NODE at point.
TIGHT non-nil means NODE is a direct child of a tight list item, so a
paragraph is emitted without <p> tags."
  (let ((children (mdview-node-children node)))
    (pcase (mdview-node-type node)
      ('document (mdview-html--blocks children nil))
      ('paragraph
       (if tight
           (insert (mdview-html--inlines children))
         (mdview-html--cr)
         (insert "<p>" (mdview-html--inlines children) "</p>\n")))
      ('heading
       (let ((level (mdview-node-prop node :level)))
         (mdview-html--cr)
         (insert (format "<h%d>%s</h%d>\n" level (mdview-html--inlines children) level))))
      ('blockquote
       (mdview-html--cr)
       (insert "<blockquote>\n")
       (mdview-html--blocks children nil)
       (mdview-html--cr)
       (insert "</blockquote>\n"))
      ('list
       (let* ((ordered (mdview-node-prop node :ordered))
              (start (mdview-node-prop node :start))
              (tag (if ordered "ol" "ul")))
         (mdview-html--cr)
         (insert "<" tag
                 (if (and ordered start (/= start 1)) (format " start=\"%d\"" start) "")
                 ">\n")
         (mdview-html--blocks children (mdview-node-prop node :tight))
         (mdview-html--cr)
         (insert "</" tag ">\n")))
      ('item
       (mdview-html--cr)
       (insert "<li>")
       (pcase (mdview-node-prop node :task)
         ('checked (insert "<input checked=\"\" disabled=\"\" type=\"checkbox\"> "))
         ('unchecked (insert "<input disabled=\"\" type=\"checkbox\"> ")))
       (mdview-html--blocks children tight)
       (insert "</li>\n"))
      ('code-block
       (let ((lang (mdview-node-prop node :lang))
             (code (mdview-node-text node)))
         (mdview-html--cr)
         (insert "<pre><code"
                 (if lang (concat " class=\"language-" (mdview-html-escape lang) "\"") "")
                 ">" (mdview-html-escape code)
                 (if (string-empty-p code) "" "\n")
                 "</code></pre>\n")))
      ('html-block
       (mdview-html--cr)
       (insert (mdview-node-text node))
       (mdview-html--cr))
      ('thematic-break
       (mdview-html--cr)
       (insert "<hr />\n"))
      ('table (mdview-html--table node))
      ('footnote-definition
       (mdview-html--cr)
       (insert (format "<li id=\"fn-%d\">\n" (or (mdview-node-prop node :index) 0)))
       (mdview-html--blocks children nil)
       (mdview-html--cr)
       (insert "</li>\n")))))

(defun mdview-html--table (node)
  "Insert table NODE in GitHub's style."
  (let ((aligns (mdview-node-prop node :align))
        (rows (mdview-node-children node)))
    (cl-flet ((row (row tag)
                (insert "<tr>\n")
                (cl-loop for cell in (mdview-node-children row)
                         for align in (append aligns (make-list (length (mdview-node-children row)) nil))
                         do (insert "<" tag
                                    (if align (format " align=\"%s\"" align) "")
                                    ">" (mdview-html--inlines (mdview-node-children cell))
                                    "</" tag ">\n"))
                (insert "</tr>\n")))
      (mdview-html--cr)
      (insert "<table>\n<thead>\n")
      (row (car rows) "th")
      (insert "</thead>\n")
      (when (cdr rows)
        (insert "<tbody>\n")
        (dolist (r (cdr rows)) (row r "td"))
        (insert "</tbody>\n"))
      (insert "</table>\n"))))

(defun mdview-html-render (doc)
  "Return the HTML serialization of document AST DOC.
Referenced footnotes are appended in a <section class=\"footnotes\">."
  (with-temp-buffer
    (mdview-html--block doc nil)
    (let ((footnotes (mdview-node-prop doc :footnotes)))
      (when footnotes
        (mdview-html--cr)
        (insert "<section class=\"footnotes\">\n<ol>\n")
        (dolist (fn footnotes) (mdview-html--block fn nil))
        (insert "</ol>\n</section>\n")))
    (buffer-string)))

(provide 'mdview-html)
;;; mdview-html.el ends here
