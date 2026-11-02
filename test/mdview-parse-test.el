;;; mdview-parse-test.el --- Tests for mdview-parse  -*- lexical-binding: t; -*-

;; This file is part of mdview, distributed under the MIT license; see
;; LICENSE in the repository root.

;;; Commentary:

;; ERT tests for the block parser (docs/DESIGN.md sections 3, 4 and 13):
;; every block type, nesting, loose/tight lists, start numbers, lazy
;; continuation, setext/thematic-break ambiguity, fenced code edge cases,
;; tables, footnotes, task items, reference definitions, heading ids,
;; `:line' numbers, front matter, the fixtures, robustness and the
;; CommonMark conformance baseline.  The tests are written so that they
;; pass with any inline parser: text is compared through
;; `mdview-node-text' on snippets without inline markup, and the footnote
;; tests install a tiny stand-in inline parser.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'mdview-ast)
(require 'mdview-parse)

(declare-function mdview-commonmark-run "run-spec" (&optional file))
(declare-function mdview-commonmark-baseline "run-spec" ())

;;;; Helpers

(defconst mdview-parse-test--root
  (expand-file-name
   ".." (file-name-directory (or load-file-name buffer-file-name default-directory)))
  "The repository root.")

(defun mdview-parse-test--path (relative)
  "Return RELATIVE resolved against the repository root."
  (expand-file-name relative mdview-parse-test--root))

(defun mdview-parse-test--blocks (markdown)
  "Return the top-level blocks of MARKDOWN."
  (mdview-node-children (mdview-parse-string markdown)))

(defun mdview-parse-test--types (markdown)
  "Return the list of top-level block types of MARKDOWN."
  (mapcar #'mdview-node-type (mdview-parse-test--blocks markdown)))

(defun mdview-parse-test--lines (markdown)
  "Return the `:line' of every top-level block of MARKDOWN."
  (mapcar (lambda (b) (mdview-node-prop b :line)) (mdview-parse-test--blocks markdown)))

(defun mdview-parse-test--first (markdown)
  "Return the first top-level block of MARKDOWN."
  (car (mdview-parse-test--blocks markdown)))

(defun mdview-parse-test--flat (node)
  "Return the plain text of NODE with collapsed and trimmed whitespace."
  (string-trim (replace-regexp-in-string "[ \t\n]+" " " (mdview-node-text node))))

(defun mdview-parse-test--child-types (node)
  "Return the types of the children of NODE."
  (mapcar #'mdview-node-type (mdview-node-children node)))

(defun mdview-parse-test--fake-inline (string _refs)
  "Split STRING into text and `footnote-reference' nodes for [^label]."
  (let ((pos 0) (nodes nil))
    (while (string-match "\\[\\^\\([^]]+\\)\\]" string pos)
      (when (> (match-beginning 0) pos)
        (push (substring string pos (match-beginning 0)) nodes))
      (push (mdview-node 'footnote-reference (list :label (match-string 1 string))) nodes)
      (setq pos (match-end 0)))
    (when (< pos (length string))
      (push (substring string pos) nodes))
    (nreverse nodes)))

(defmacro mdview-parse-test--with-fake-inline (&rest body)
  "Run BODY with `mdview-inline-parse' replaced by the stand-in parser."
  (declare (indent 0))
  `(cl-letf (((symbol-function 'mdview-inline-parse)
              #'mdview-parse-test--fake-inline))
     ,@body))

;;;; Document and paragraphs

(ert-deftest mdview-parse-empty-document ()
  (let ((doc (mdview-parse-string "")))
    (should (eq (mdview-node-type doc) 'document))
    (should-not (mdview-node-children doc))
    (should (hash-table-p (mdview-node-prop doc :refs)))
    (should-not (mdview-node-prop doc :footnotes)))
  (should-not (mdview-parse-test--blocks "\n\n   \n\t\n")))

(ert-deftest mdview-parse-paragraphs ()
  (let ((blocks (mdview-parse-test--blocks "one\ntwo\n\n  three\n\n\n\nfour")))
    (should (equal (mapcar #'mdview-node-type blocks) '(paragraph paragraph paragraph)))
    (should (equal (mapcar #'mdview-parse-test--flat blocks) '("one two" "three" "four")))
    (should (equal (mapcar (lambda (b) (mdview-node-prop b :line)) blocks) '(1 4 8)))))

(ert-deftest mdview-parse-paragraph-strips-leading-whitespace ()
  ;; Leading whitespace of continuation lines is gone; the inline parser
  ;; turns the line endings into soft breaks, which read as spaces.
  (let ((p (mdview-parse-test--first "aaa\n             bbb\n   ccc")))
    (should (equal (mdview-node-text p) "aaa bbb ccc"))
    (should (equal (mdview-parse-test--with-fake-inline
                     (mdview-node-text
                      (mdview-parse-test--first "aaa\n             bbb\n   ccc")))
                   "aaa\nbbb\nccc"))))

(ert-deftest mdview-parse-line-endings-and-nul ()
  (should (equal (mdview-parse-test--types "a\r\n\r\nb\r\rc\n")
                 '(paragraph paragraph paragraph)))
  (should (equal (mdview-node-text (mdview-parse-test--first "a\0b"))
                 (string ?a #xFFFD ?b))))

(ert-deftest mdview-parse-buffer-respects-narrowing ()
  (with-temp-buffer
    (insert "# skip\n\nkept\n\n# tail\n")
    (narrow-to-region 9 14)
    (let ((doc (mdview-parse-buffer)))
      (should (equal (mdview-parse-test--child-types doc) '(paragraph)))
      (should (equal (mdview-node-text (car (mdview-node-children doc))) "kept"))))
  (with-temp-buffer
    (insert "x")
    (should (equal (mdview-parse-test--child-types (mdview-parse-buffer (current-buffer)))
                   '(paragraph)))))

;;;; ATX headings

(ert-deftest mdview-parse-atx-levels ()
  (let ((blocks (mdview-parse-test--blocks "# h1\n## h2\n### h3\n#### h4\n##### h5\n###### h6\n####### no")))
    (should (equal (mapcar #'mdview-node-type blocks)
                   '(heading heading heading heading heading heading paragraph)))
    (should (equal (mapcar (lambda (b) (mdview-node-prop b :level)) (butlast blocks))
                   '(1 2 3 4 5 6)))
    (should (equal (mapcar #'mdview-node-text (butlast blocks))
                   '("h1" "h2" "h3" "h4" "h5" "h6")))
    (should (equal (mapcar (lambda (b) (mdview-node-prop b :line)) blocks)
                   '(1 2 3 4 5 6 7)))))

(ert-deftest mdview-parse-atx-requires-space ()
  (should (equal (mdview-parse-test--types "#5 bolt\n\n#hashtag") '(paragraph paragraph)))
  (should (equal (mdview-parse-test--types "   # indented 3\n\n    # code")
                 '(heading code-block)))
  (should (equal (mdview-node-text (mdview-parse-test--first "#\ttab")) "tab")))

(ert-deftest mdview-parse-atx-closing-sequence ()
  (should (equal (mdview-node-text (mdview-parse-test--first "## foo ##")) "foo"))
  (should (equal (mdview-node-text (mdview-parse-test--first "# foo ##################")) "foo"))
  (should (equal (mdview-node-text (mdview-parse-test--first "### foo ###     ")) "foo"))
  (should (equal (mdview-node-text (mdview-parse-test--first "# foo#")) "foo#"))
  (should (equal (mdview-node-text (mdview-parse-test--first "### foo ### b")) "foo ### b"))
  ;; A backslash-escaped # is not a closing sequence; the text keeps it.
  (should (string-suffix-p "###" (mdview-node-text (mdview-parse-test--first "### foo \\###"))))
  (let ((empty (mdview-parse-test--blocks "## \n#\n### ###")))
    (should (equal (mapcar #'mdview-node-type empty) '(heading heading heading)))
    (should (equal (mapcar #'mdview-node-text empty) '("" "" "")))))

;;;; Setext headings and thematic breaks

(ert-deftest mdview-parse-setext-headings ()
  (let ((blocks (mdview-parse-test--blocks "Foo\n===\n\nBar\n---\n\n   Baz  \n  ----------")))
    (should (equal (mapcar #'mdview-node-type blocks) '(heading heading heading)))
    (should (equal (mapcar (lambda (b) (mdview-node-prop b :level)) blocks) '(1 2 2)))
    (should (equal (mapcar #'mdview-node-text blocks) '("Foo" "Bar" "Baz")))
    (should (equal (mapcar (lambda (b) (mdview-node-prop b :line)) blocks) '(1 4 7)))))

(ert-deftest mdview-parse-setext-multiline-content ()
  (let ((h (mdview-parse-test--first "Foo\nbar\n baz\n====")))
    (should (eq (mdview-node-type h) 'heading))
    (should (equal (mdview-parse-test--flat h) "Foo bar baz"))))

(ert-deftest mdview-parse-setext-vs-thematic-break ()
  ;; `---' after paragraph text is a heading underline, `***' a break.
  (should (equal (mdview-parse-test--types "Foo\n---") '(heading)))
  (should (equal (mdview-parse-test--types "Foo\n***") '(paragraph thematic-break)))
  (should (equal (mdview-parse-test--types "Foo\n- - -") '(paragraph thematic-break)))
  (should (equal (mdview-parse-test--types "---\nFoo") '(thematic-break paragraph)))
  (should (equal (mdview-parse-test--types "---\n---") '(thematic-break thematic-break)))
  (should (equal (mdview-parse-test--types "Foo\n    ---") '(paragraph)))
  (should (equal (mdview-parse-test--types "Foo\n= =") '(paragraph)))
  (should (equal (mdview-parse-test--types "> Foo\n---") '(blockquote thematic-break)))
  (should (equal (mdview-parse-test--types "- Foo\n---") '(list thematic-break)))
  (should (equal (mdview-parse-test--types "---\nFoo\n---\nBar\n---\nBaz")
                 '(thematic-break heading heading paragraph))))

(ert-deftest mdview-parse-thematic-breaks ()
  (should (equal (mdview-parse-test--types "***\n---\n___")
                 '(thematic-break thematic-break thematic-break)))
  (should (equal (mdview-parse-test--types " - - -\n\n _____________\n\n*\t*\t*")
                 '(thematic-break thematic-break thematic-break)))
  (should (equal (mdview-parse-test--types "+++\n\n**\n\n_ _ _ a") '(paragraph paragraph paragraph)))
  (should (equal (mdview-parse-test--types "    ***") '(code-block)))
  (should (equal (mdview-parse-test--types "- foo\n***\n- bar") '(list thematic-break list)))
  (should (equal (mdview-node-prop (mdview-parse-test--first "\n\n***") :line) 3)))

;;;; Code blocks

(ert-deftest mdview-parse-fenced-code-basic ()
  (let ((c (mdview-parse-test--first "```python extra info\nprint(1)\n\nprint(2)\n```")))
    (should (eq (mdview-node-type c) 'code-block))
    (should (mdview-node-prop c :fenced))
    (should (equal (mdview-node-prop c :lang) "python"))
    (should (equal (mdview-node-prop c :info) "python extra info"))
    (should (equal (mdview-node-text c) "print(1)\n\nprint(2)"))
    (should (= (mdview-node-prop c :line) 1)))
  (let ((c (mdview-parse-test--first "~~~\nx\n~~~")))
    (should-not (mdview-node-prop c :lang))
    (should-not (mdview-node-prop c :info))
    (should (equal (mdview-node-text c) "x"))))

(ert-deftest mdview-parse-fenced-code-edge-cases ()
  ;; Empty block, block with only a blank line.
  (should (equal (mdview-node-text (mdview-parse-test--first "```\n```")) ""))
  ;; Unclosed fence runs to the end of the document.
  (let ((blocks (mdview-parse-test--blocks "para\n\n```\nfoo\n\nbar")))
    (should (equal (mapcar #'mdview-node-type blocks) '(paragraph code-block)))
    (should (equal (mdview-node-text (cadr blocks)) "foo\n\nbar")))
  ;; The closing fence must be at least as long; shorter runs are content.
  (should (equal (mdview-node-text (mdview-parse-test--first "````\n```\naaa\n````")) "```\naaa"))
  ;; Different fence characters do not close.
  (should (equal (mdview-node-text (mdview-parse-test--first "```\n~~~\n```")) "~~~"))
  ;; Closing fence may be indented up to three spaces but not four.
  (should (equal (mdview-node-text (mdview-parse-test--first "```\nx\n   ```")) "x"))
  (should (equal (mdview-node-text (mdview-parse-test--first "```\nx\n    ```")) "x\n    ```"))
  ;; Info strings of backtick fences may not contain backticks.
  (should (equal (mdview-parse-test--types "``` a`b\nfoo") '(paragraph)))
  ;; ... and a later bare fence still opens a (then unclosed) code block.
  (should (equal (mdview-parse-test--types "``` a`b\nfoo\n```") '(paragraph code-block)))
  (should (equal (mdview-node-prop (mdview-parse-test--first "~~~ a`b\nfoo\n~~~") :info) "a`b"))
  ;; Two backticks are not a fence.
  (should (equal (mdview-parse-test--types "``\nfoo\n``") '(paragraph)))
  ;; Info strings are unescaped and entity-decoded.
  (should (equal (mdview-node-prop (mdview-parse-test--first "~~~ a\\&amp;b &copy;\nx\n~~~") :info)
                 "a&amp;b ©"))
  ;; A fence can interrupt a paragraph.
  (should (equal (mdview-parse-test--types "foo\n```\nbar\n```\nbaz")
                 '(paragraph code-block paragraph))))

(ert-deftest mdview-parse-fenced-code-indentation ()
  ;; The fence's indentation is removed from the content lines.
  (should (equal (mdview-node-text (mdview-parse-test--first "  ```\n  aaa\n    bbb\n aaa\n  ```"))
                 "aaa\n  bbb\naaa"))
  (should (equal (mdview-node-text (mdview-parse-test--first "   ```\n   aaa\n    aaa\n  aaa\n   ```"))
                 "aaa\n aaa\naaa"))
  ;; Four spaces make it indented code instead.
  (should (equal (mdview-node-text (mdview-parse-test--first "    ```\n    aaa\n    ```"))
                 "```\naaa\n```")))

(ert-deftest mdview-parse-indented-code ()
  (let ((c (mdview-parse-test--first "    a simple\n      indented code block")))
    (should (eq (mdview-node-type c) 'code-block))
    (should-not (mdview-node-prop c :fenced))
    (should (equal (mdview-node-text c) "a simple\n  indented code block")))
  ;; Blank lines inside are kept, trailing and leading ones are not.
  (should (equal (mdview-node-text (mdview-parse-test--first "\n    \n    foo\n    \n\n    bar\n\n    \n"))
                 "foo\n\n\nbar"))
  ;; Indented code cannot interrupt a paragraph, but a paragraph can follow.
  (should (equal (mdview-parse-test--types "Foo\n    bar") '(paragraph)))
  (should (equal (mdview-parse-test--types "    foo\nbar") '(code-block paragraph)))
  ;; Tabs count as four columns.
  (should (equal (mdview-node-text (mdview-parse-test--first "\tfoo\tbaz\t\tbim")) "foo\tbaz\t\tbim"))
  (should (equal (mdview-node-text (mdview-parse-test--first "  \tfoo")) "foo"))
  (should (equal (mdview-node-text (mdview-parse-test--first "    a\tb")) "a\tb")))

(ert-deftest mdview-parse-tabs-in-containers ()
  ;; `- foo' then a tab-indented paragraph continues the item.
  (let ((item (car (mdview-node-children (mdview-parse-test--first "- foo\n\n\tbar")))))
    (should (equal (mdview-parse-test--child-types item) '(paragraph paragraph)))
    (should (equal (mdview-node-text (cadr (mdview-node-children item))) "bar")))
  ;; `>\t\tfoo': one column of the tab is the quote's space, the rest is code.
  (let ((code (car (mdview-node-children (mdview-parse-test--first ">\t\tfoo")))))
    (should (eq (mdview-node-type code) 'code-block))
    (should (equal (mdview-node-text code) "  foo")))
  (let ((code (car (mdview-node-children (car (mdview-node-children (mdview-parse-test--first "-\t\tfoo")))))))
    (should (eq (mdview-node-type code) 'code-block))
    (should (equal (mdview-node-text code) "  foo"))))

;;;; HTML blocks

(ert-deftest mdview-parse-html-blocks ()
  ;; Kind 6 ends at a blank line and keeps leading indentation.
  (let ((blocks (mdview-parse-test--blocks "<div>\n  *hello*\n         <foo><a>\n\nafter")))
    (should (equal (mapcar #'mdview-node-type blocks) '(html-block paragraph)))
    (should (equal (mdview-node-text (car blocks)) "<div>\n  *hello*\n         <foo><a>")))
  (should (equal (mdview-node-text (mdview-parse-test--first " <DIV CLASS=\"x\">\n</DIV>"))
                 " <DIV CLASS=\"x\">\n</DIV>"))
  ;; Kind 1 ends at the closing tag, even past blank lines.
  (let ((blocks (mdview-parse-test--blocks "<pre>\n\n  x\n</pre>\nrest\n")))
    (should (equal (mapcar #'mdview-node-type blocks) '(html-block paragraph)))
    (should (equal (mdview-node-text (car blocks)) "<pre>\n\n  x\n</pre>")))
  ;; Kinds 2-5: comment, processing instruction, declaration, CDATA.
  (should (equal (mdview-parse-test--types "<!-- a\n\nb -->\n<?php x\n?>\n<!DOCTYPE html>\n<![CDATA[\nx\n]]>")
                 '(html-block html-block html-block html-block)))
  ;; A kind 6 start can interrupt a paragraph, kind 7 cannot.
  (should (equal (mdview-parse-test--types "Foo\n<div>\nbar") '(paragraph html-block)))
  (should (equal (mdview-parse-test--types "Foo\n<a href=\"bar\">\nbaz") '(paragraph)))
  (should (equal (mdview-parse-test--types "<a href=\"bar\">\nbaz\n\nqux") '(html-block paragraph)))
  (should (equal (mdview-parse-test--types "<Warning>\n*bar*\n</Warning>") '(html-block)))
  ;; Kind 7 needs the tag alone on its line and never pre/script/style.
  (should (equal (mdview-parse-test--types "<del>*foo*</del>") '(paragraph)))
  (should (equal (mdview-parse-test--types "<pre/>\nfoo") '(paragraph)))
  (should (equal (mdview-parse-test--types "</div>\nfoo") '(html-block)))
  (should (= (mdview-node-prop (mdview-parse-test--first "\n<hr>") :line) 2)))

;;;; Block quotes

(ert-deftest mdview-parse-blockquote-basic ()
  (let ((q (mdview-parse-test--first "> # Foo\n> bar\n> baz")))
    (should (eq (mdview-node-type q) 'blockquote))
    (should (equal (mdview-parse-test--child-types q) '(heading paragraph)))
    (should (equal (mdview-parse-test--flat (cadr (mdview-node-children q))) "bar baz"))
    (should (= (mdview-node-prop q :line) 1)))
  ;; The space after > is optional; up to three spaces of indentation allowed.
  (should (equal (mdview-parse-test--child-types (mdview-parse-test--first ">foo\n   > bar"))
                 '(paragraph)))
  (should (equal (mdview-parse-test--types "    > foo") '(code-block))))

(ert-deftest mdview-parse-blockquote-lazy-continuation ()
  (let ((q (mdview-parse-test--first "> bar\nbaz\n> foo")))
    (should (equal (mdview-parse-test--child-types q) '(paragraph)))
    (should (equal (mdview-parse-test--flat (car (mdview-node-children q))) "bar baz foo")))
  ;; Only paragraph text is lazy; a code fence is not.
  (should (equal (mdview-parse-test--types "> ```\nfoo\n```") '(blockquote paragraph code-block)))
  ;; A blank line ends the quote.
  (should (equal (mdview-parse-test--types "> foo\n\nbar") '(blockquote paragraph)))
  (should (equal (mdview-parse-test--types "> foo\n>\n> bar") '(blockquote)))
  ;; Lazy continuation through nested quotes.
  (let ((q (mdview-parse-test--first "> > > foo\nbar\n>>baz")))
    (should (equal (mdview-parse-test--flat q) "foo bar baz"))))

(ert-deftest mdview-parse-blockquote-nesting ()
  (let* ((outer (mdview-parse-test--first "> a\n>\n> > b\n> >\n> > > c\n>\n> d"))
         (children (mdview-node-children outer)))
    (should (equal (mapcar #'mdview-node-type children) '(paragraph blockquote paragraph)))
    (let ((inner (cadr children)))
      (should (equal (mdview-parse-test--child-types inner) '(paragraph blockquote)))
      (should (= (mdview-node-prop inner :line) 3))
      (should (= (mdview-node-prop (cadr (mdview-node-children inner)) :line) 5)))))

;;;; Lists

(ert-deftest mdview-parse-bullet-list-basic ()
  (let ((list (mdview-parse-test--first "- one\n- two\n- three")))
    (should (eq (mdview-node-type list) 'list))
    (should-not (mdview-node-prop list :ordered))
    (should (mdview-node-prop list :tight))
    (should (eq (mdview-node-prop list :marker) ?-))
    (should-not (plist-member (mdview-node-props list) :start))
    (should (= (length (mdview-node-children list)) 3))
    (should (equal (mapcar (lambda (i) (mdview-node-prop i :line)) (mdview-node-children list))
                   '(1 2 3)))
    (should (equal (mapcar #'mdview-parse-test--flat (mdview-node-children list))
                   '("one" "two" "three")))))

(ert-deftest mdview-parse-list-marker-change-starts-new-list ()
  (let ((blocks (mdview-parse-test--blocks "- a\n- b\n+ c\n* d")))
    (should (equal (mapcar #'mdview-node-type blocks) '(list list list)))
    (should (equal (mapcar (lambda (l) (mdview-node-prop l :marker)) blocks) '(?- ?+ ?*))))
  (let ((blocks (mdview-parse-test--blocks "1. a\n2. b\n3) c")))
    (should (equal (mapcar (lambda (l) (mdview-node-prop l :marker)) blocks) '(?. ?\))))
    (should (equal (mapcar (lambda (l) (mdview-node-prop l :start)) blocks) '(1 3)))))

(ert-deftest mdview-parse-ordered-list-start ()
  (let ((list (mdview-parse-test--first "10. ten\n11. eleven")))
    (should (mdview-node-prop list :ordered))
    (should (= (mdview-node-prop list :start) 10))
    (should (eq (mdview-node-prop list :marker) ?.)))
  (should (= (mdview-node-prop (mdview-parse-test--first "0. zero") :start) 0))
  (should (= (mdview-node-prop (mdview-parse-test--first "003. three") :start) 3))
  (should (= (mdview-node-prop (mdview-parse-test--first "123456789. ok") :start) 123456789))
  ;; Ten digits are too many; no space after the marker is not a list.
  (should (equal (mdview-parse-test--types "1234567890. no") '(paragraph)))
  (should (equal (mdview-parse-test--types "1.no\n-no") '(paragraph))))

(ert-deftest mdview-parse-list-interrupting-paragraph ()
  (should (equal (mdview-parse-test--types "Foo\n- bar\n- baz") '(paragraph list)))
  (should (equal (mdview-parse-test--types "Foo\n1. bar") '(paragraph list)))
  ;; Only a list starting with 1 may interrupt a paragraph.
  (should (equal (mdview-parse-test--types "The number is\n2. doors") '(paragraph)))
  ;; An empty item cannot interrupt a paragraph (a lone `-' would be a
  ;; setext underline, so `*' is used here).
  (should (equal (mdview-parse-test--types "foo\n*\nbar") '(paragraph)))
  (should (equal (mdview-parse-test--types "foo\n*\n\nbar") '(paragraph paragraph)))
  (should (equal (mdview-parse-test--types "foo\n-\nbar") '(heading paragraph))))

(ert-deftest mdview-parse-list-content-indentation ()
  ;; 1-4 spaces after the marker set the content column.
  (let ((item (car (mdview-node-children (mdview-parse-test--first "-    one\n\n     two")))))
    (should (equal (mdview-parse-test--child-types item) '(paragraph paragraph))))
  ;; Five spaces: the content is indented code and starts one column after the marker.
  (let ((item (car (mdview-node-children (mdview-parse-test--first "-     code\n\n  para")))))
    (should (equal (mdview-parse-test--child-types item) '(code-block paragraph)))
    (should (equal (mdview-node-text (car (mdview-node-children item))) "code")))
  ;; Not enough indentation ends the item.
  (should (equal (mdview-parse-test--types "- one\n\n two") '(list paragraph)))
  (should (equal (mdview-parse-test--types " -    one\n\n     two") '(list code-block)))
  ;; A marker indented four or more spaces is not a list item.
  (should (equal (mdview-parse-test--types "    - foo") '(code-block)))
  (let ((items (mdview-node-children (mdview-parse-test--first "- a\n - b\n  - c\n   - d\n    - e"))))
    (should (= (length items) 4))
    (should (equal (mdview-parse-test--flat (car (last items))) "d - e"))))

(ert-deftest mdview-parse-list-empty-first-line ()
  ;; A blank first line: the content starts on the next line.
  (let ((items (mdview-node-children (mdview-parse-test--first "-\n  foo\n-\n  ```\n  bar\n  ```\n-\n      baz"))))
    (should (= (length items) 3))
    (should (equal (mdview-parse-test--child-types (nth 0 items)) '(paragraph)))
    (should (equal (mdview-parse-test--child-types (nth 1 items)) '(code-block)))
    (should (equal (mdview-parse-test--child-types (nth 2 items)) '(code-block)))
    (should (equal (mdview-node-text (car (mdview-node-children (nth 2 items)))) "baz")))
  ;; An item may be empty; a blank line after an empty item ends it.
  (let ((items (mdview-node-children (mdview-parse-test--first "- foo\n-\n- bar"))))
    (should (= (length items) 3))
    (should-not (mdview-node-children (nth 1 items))))
  (should (equal (mdview-parse-test--types "-\n\n  foo") '(list paragraph))))

(ert-deftest mdview-parse-list-loose-and-tight ()
  (should (mdview-node-prop (mdview-parse-test--first "- a\n- b\n- c") :tight))
  ;; Blank line between items: loose.
  (should-not (mdview-node-prop (mdview-parse-test--first "- a\n\n- b") :tight))
  ;; Blank line between two blocks inside an item: loose.
  (should-not (mdview-node-prop (mdview-parse-test--first "- a\n\n  b\n- c") :tight))
  ;; Blank line inside a nested list or at the very end does not matter.
  (should (mdview-node-prop (mdview-parse-test--first "- a\n  - b\n\n    c\n- d") :tight))
  (should (mdview-node-prop (mdview-parse-test--first "- a\n- b\n\n") :tight))
  ;; Blank lines inside a fenced code block do not make the list loose.
  (should (mdview-node-prop (mdview-parse-test--first "- a\n- ```\n  b\n\n\n  ```\n- c") :tight))
  ;; A blank line after a nested list, before more content of the item: loose.
  (let ((outer (mdview-parse-test--first "* foo\n  * bar\n\n  baz")))
    (should-not (mdview-node-prop outer :tight))
    (should (mdview-node-prop (cadr (mdview-node-children (car (mdview-node-children outer)))) :tight)))
  ;; Items separated by a blank line are still one (loose) list.
  (let ((list (mdview-parse-test--first "1. a\n2. b\n\n10. c")))
    (should (= (length (mdview-node-children list)) 3))
    (should-not (mdview-node-prop list :tight))))

(ert-deftest mdview-parse-nested-lists ()
  (let* ((outer (mdview-parse-test--first "- foo\n  - bar\n    - baz\n      - boo"))
         (depth 0) (node outer))
    (while (and node (eq (mdview-node-type node) 'list))
      (setq depth (1+ depth))
      (setq node (cadr (mdview-node-children (car (mdview-node-children node))))))
    (should (= depth 4)))
  ;; One space less than the content column: a sibling, not a child.
  (should (= (length (mdview-node-children (mdview-parse-test--first "- foo\n - bar\n  - baz\n   - boo"))) 4))
  ;; Ordered list content column with `10)': nested only when indented enough.
  (should (equal (mdview-parse-test--child-types
                  (car (mdview-node-children (mdview-parse-test--first "10) foo\n    - bar"))))
                 '(paragraph list)))
  (should (equal (mdview-parse-test--types "10) foo\n   - bar") '(list list)))
  ;; Nested markers on one line.
  (let ((inner (car (mdview-node-children (car (mdview-node-children (mdview-parse-test--first "1. - 2. foo")))))))
    (should (eq (mdview-node-type inner) 'list))
    (should-not (mdview-node-prop inner :ordered))
    (let ((innermost (car (mdview-node-children (car (mdview-node-children inner))))))
      (should (= (mdview-node-prop innermost :start) 2)))))

(ert-deftest mdview-parse-lists-in-quotes-in-lists ()
  (let* ((md "1. item\n   > quoted\n   > - a\n   > - b\n   >   - deep\n   >\n   > after\n2. next")
         (list (mdview-parse-test--first md))
         (items (mdview-node-children list)))
    (should (= (length items) 2))
    (should (mdview-node-prop list :tight))
    (let* ((item (car items))
           (quote (cadr (mdview-node-children item))))
      (should (equal (mdview-parse-test--child-types item) '(paragraph blockquote)))
      (should (equal (mdview-parse-test--child-types quote) '(paragraph list paragraph)))
      (should (= (mdview-node-prop quote :line) 2))
      (let ((inner (cadr (mdview-node-children quote))))
        (should (= (length (mdview-node-children inner)) 2))
        (should (= (mdview-node-prop inner :line) 3))
        (should (equal (mdview-parse-test--child-types (cadr (mdview-node-children inner)))
                       '(paragraph list)))))
    (should (= (mdview-node-prop (cadr items) :line) 8))))

(ert-deftest mdview-parse-list-item-with-blocks ()
  (let ((item (car (mdview-node-children
                    (mdview-parse-test--first "1.  A paragraph\n    with two lines.\n\n        indented code\n\n    > A block quote.")))))
    (should (equal (mdview-parse-test--child-types item) '(paragraph code-block blockquote)))
    (should (equal (mdview-parse-test--flat (car (mdview-node-children item)))
                   "A paragraph with two lines."))
    (should (equal (mdview-node-text (cadr (mdview-node-children item))) "indented code")))
  ;; Lazy continuation inside a list item.
  (should (equal (mdview-parse-test--flat (mdview-parse-test--first "  1.  A paragraph\nwith two lines."))
                 "A paragraph with two lines."))
  ;; A heading and a setext heading inside items.
  (let ((items (mdview-node-children (mdview-parse-test--first "- # Foo\n- Bar\n  ---\n  baz"))))
    (should (equal (mdview-parse-test--child-types (car items)) '(heading)))
    (should (equal (mdview-parse-test--child-types (cadr items)) '(heading paragraph)))
    (should (= (mdview-node-prop (car (mdview-node-children (cadr items))) :level) 2))))

;;;; Tables

(ert-deftest mdview-parse-table-basic ()
  (let* ((table (mdview-parse-test--first "| a | b | c |\n|:--|:-:|--:|\n| 1 | 2 | 3 |\n| x | y | z |"))
         (rows (mdview-node-children table)))
    (should (eq (mdview-node-type table) 'table))
    (should (equal (mdview-node-prop table :align) '(left center right)))
    (should (= (mdview-node-prop table :line) 1))
    (should (= (length rows) 3))
    (should (mdview-node-prop (car rows) :header))
    (should-not (mdview-node-prop (cadr rows) :header))
    (should (equal (mapcar #'mdview-node-type (mdview-node-children (car rows)))
                   '(table-cell table-cell table-cell)))
    (should (equal (mapcar #'mdview-node-text (mdview-node-children (car rows))) '("a" "b" "c")))
    (should (equal (mapcar #'mdview-node-text (mdview-node-children (nth 2 rows))) '("x" "y" "z")))))

(ert-deftest mdview-parse-table-alignment-and-pipes ()
  (let ((table (mdview-parse-test--first "a | b\n--- | ---\n1 | 2")))
    (should (equal (mdview-node-prop table :align) '(nil nil)))
    (should (= (length (mdview-node-children table)) 2)))
  (should (equal (mdview-node-prop (mdview-parse-test--first "| a |\n| :-: |") :align) '(center)))
  ;; Escaped pipes stay in the cell as literal pipes, also inside code spans.
  (let* ((table (mdview-parse-test--first "| a | b |\n|---|---|\n| x \\| y | `c \\| d` |"))
         (cells (mdview-node-children (cadr (mdview-node-children table)))))
    (should (= (length cells) 2))
    (should (equal (mdview-node-text (car cells)) "x | y"))
    (should (string-search "c | d" (mdview-node-text (cadr cells))))))

(ert-deftest mdview-parse-table-ragged-rows ()
  (let* ((table (mdview-parse-test--first "| a | b |\n|---|---|\n| only |\n| 1 | 2 | extra | more |"))
         (rows (mdview-node-children table)))
    (should (= (length rows) 3))
    (should (equal (mapcar #'mdview-node-text (mdview-node-children (nth 1 rows))) '("only" "")))
    (should (equal (mapcar #'mdview-node-text (mdview-node-children (nth 2 rows))) '("1" "2")))))

(ert-deftest mdview-parse-table-requires-matching-header ()
  ;; Header and delimiter row must have the same number of cells.
  (should (equal (mdview-parse-test--types "| a | b |\n|---|\n| 1 |") '(paragraph)))
  (should (equal (mdview-parse-test--types "| a |\n|---|---|") '(paragraph)))
  ;; A delimiter row needs at least one dash per cell.
  (should (equal (mdview-parse-test--types "| a |\n| : |") '(paragraph))))

(ert-deftest mdview-parse-table-termination ()
  ;; Blank line ends the table; another block start ends it too.
  (let ((blocks (mdview-parse-test--blocks "| a |\n|---|\n| 1 |\n\n| 2 |")))
    (should (equal (mapcar #'mdview-node-type blocks) '(table paragraph)))
    (should (= (length (mdview-node-children (car blocks))) 2)))
  (should (equal (mdview-parse-test--types "| a |\n|---|\n| 1 |\n> quote") '(table blockquote)))
  (should (equal (mdview-parse-test--types "| a |\n|---|\n| 1 |\n# h") '(table heading)))
  (should (equal (mdview-parse-test--types "| a |\n|---|\n| 1 |\n- item") '(table list)))
  ;; A line without pipes is still a row.
  (let ((table (mdview-parse-test--first "| a | b |\n|---|---|\nbar\n")))
    (should (= (length (mdview-node-children table)) 2))
    (should (equal (mapcar #'mdview-node-text (mdview-node-children (cadr (mdview-node-children table))))
                   '("bar" "")))))

(ert-deftest mdview-parse-table-header-candidates-linear ()
  "Delimiter rows that never match the line above cost linear time.
Only the paragraph's last line is examined (it is the head of the stored
lines); joining the paragraph for every candidate was cubic."
  (let* ((md (apply #'concat (make-list 2000 "a\n|-|-|-\n")))
         (start (float-time))
         (types (mdview-parse-test--types md)))
    (should (< (- (float-time) start) 2))
    (should (equal types '(paragraph))))
  ;; Several candidates, then a match: the text before stays a paragraph.
  (let ((blocks (mdview-parse-test--blocks "a\n|-|-|\nb\n|-|-|\n| c | d |\n|---|---|\n| 1 | 2 |")))
    (should (equal (mapcar #'mdview-node-type blocks) '(paragraph table)))
    (should (equal (mdview-parse-test--flat (car blocks)) "a |-|-| b |-|-|"))
    (should (= (mdview-node-prop (cadr blocks) :line) 5))))

(ert-deftest mdview-parse-table-after-paragraph-and-in-containers ()
  ;; Only the last line of a paragraph becomes the header.
  (let ((blocks (mdview-parse-test--blocks "intro text\n| a | b |\n|---|---|\n| 1 | 2 |")))
    (should (equal (mapcar #'mdview-node-type blocks) '(paragraph table)))
    (should (equal (mdview-node-text (car blocks)) "intro text"))
    (should (= (mdview-node-prop (cadr blocks) :line) 2)))
  ;; Tables inside block quotes and list items.
  (let ((q (mdview-parse-test--first "> | a |\n> |---|\n> | 1 |")))
    (should (equal (mdview-parse-test--child-types q) '(table))))
  (let ((item (car (mdview-node-children (mdview-parse-test--first "- | a |\n  |---|\n  | 1 |")))))
    (should (equal (mdview-parse-test--child-types item) '(table)))))

;;;; Footnotes

(ert-deftest mdview-parse-footnotes-order-and-index ()
  (mdview-parse-test--with-fake-inline
    (let* ((doc (mdview-parse-string "See[^b] and[^a] and[^b] again.\n\n[^a]: Note A.\n[^b]: Note B.\n[^c]: Unused.\n"))
           (footnotes (mdview-node-prop doc :footnotes))
           (refs (mdview-ast-map (lambda (n) (and (eq (mdview-node-type n) 'footnote-reference) n)) doc)))
      (should (equal (mdview-parse-test--child-types doc) '(paragraph)))
      (should (= (length footnotes) 2))
      (should (equal (mapcar (lambda (f) (mdview-node-prop f :label)) footnotes) '("b" "a")))
      (should (equal (mapcar (lambda (f) (mdview-node-prop f :index)) footnotes) '(1 2)))
      (should (equal (mapcar #'mdview-node-type footnotes) '(footnote-definition footnote-definition)))
      (should (equal (mapcar #'mdview-parse-test--flat footnotes) '("Note B." "Note A.")))
      (should (equal (mapcar (lambda (f) (mdview-node-prop f :line)) footnotes) '(4 3)))
      (should (equal (mapcar (lambda (r) (mdview-node-prop r :index)) (delq nil refs)) '(1 2 1))))))

(ert-deftest mdview-parse-footnotes-undefined-becomes-text ()
  (mdview-parse-test--with-fake-inline
    (let* ((doc (mdview-parse-string "Missing[^nope] here.\n"))
           (p (car (mdview-node-children doc))))
      (should-not (mdview-node-prop doc :footnotes))
      (should (equal (mdview-node-text p) "Missing[^nope] here."))
      (should (cl-every #'stringp (mdview-node-children p))))))

(ert-deftest mdview-parse-footnotes-continuation-and-labels ()
  (mdview-parse-test--with-fake-inline
    (let* ((doc (mdview-parse-string "Ref[^Long Note].\n\n[^long note]: First paragraph\n    continues here.\n\n    Second paragraph.\n\n        code\n\nNot part of it."))
           (fn (car (mdview-node-prop doc :footnotes))))
      (should (equal (mdview-parse-test--child-types doc) '(paragraph paragraph)))
      (should (equal (mdview-parse-test--child-types fn) '(paragraph paragraph code-block)))
      (should (equal (mdview-parse-test--flat (car (mdview-node-children fn)))
                     "First paragraph continues here."))
      (should (equal (mdview-node-text (nth 2 (mdview-node-children fn))) "code")))
    ;; Consecutive definitions, and a definition inside a block quote.
    (let ((doc (mdview-parse-string "a[^1] b[^2]\n\n[^1]: one\n[^2]: two\n\n> [^3]: three\n\nc[^3]")))
      (should (equal (mapcar (lambda (f) (mdview-node-prop f :label)) (mdview-node-prop doc :footnotes))
                     '("1" "2" "3")))
      (should (equal (mdview-parse-test--child-types doc) '(paragraph blockquote paragraph))))))

(ert-deftest mdview-parse-footnotes-nested-references ()
  (mdview-parse-test--with-fake-inline
    (let* ((doc (mdview-parse-string "x[^a]\n\n[^a]: refers to[^b]\n[^b]: leaf\n"))
           (footnotes (mdview-node-prop doc :footnotes)))
      (should (equal (mapcar (lambda (f) (mdview-node-prop f :label)) footnotes) '("a" "b")))
      (let ((inner (car (delq nil (mdview-ast-map
                                   (lambda (n) (and (eq (mdview-node-type n) 'footnote-reference) n))
                                   (car footnotes))))))
        (should (= (mdview-node-prop inner :index) 2))))))

;;;; Task items

(ert-deftest mdview-parse-task-items ()
  (let ((items (mdview-node-children (mdview-parse-test--first "- [ ] todo\n- [x] done\n- [X] DONE\n- [ ]not a task\n- plain [ ] text"))))
    (should (equal (mapcar (lambda (i) (mdview-node-prop i :task)) items)
                   '(unchecked checked checked nil nil)))
    (should (equal (mapcar #'mdview-parse-test--flat items)
                   '("todo" "done" "DONE" "[ ]not a task" "plain [ ] text")))))

(ert-deftest mdview-parse-task-items-in-ordered-and-nested-lists ()
  (let* ((list (mdview-parse-test--first "1. [x] first\n   - [ ] nested\n2. [ ]\ttabbed"))
         (items (mdview-node-children list)))
    (should (eq (mdview-node-prop (car items) :task) 'checked))
    (should (eq (mdview-node-prop (cadr items) :task) 'unchecked))
    (should (equal (mdview-parse-test--flat (cadr items)) "tabbed"))
    (let ((nested (car (mdview-node-children (cadr (mdview-node-children (car items)))))))
      (should (eq (mdview-node-prop nested :task) 'unchecked))))
  ;; Only the first paragraph counts.
  (let ((item (car (mdview-node-children (mdview-parse-test--first "- text\n\n  [ ] later")))))
    (should-not (mdview-node-prop item :task))))

(ert-deftest mdview-parse-task-marker-alone ()
  "A marker with nothing after it is a task too (GitHub issue templates)."
  (let ((items (mdview-node-children
                (mdview-parse-test--first "- [x]\n- [ ]\n  - sub\n- [X]  \n- [ ]\n\n  later"))))
    (should (equal (mapcar (lambda (i) (mdview-node-prop i :task)) items)
                   '(checked unchecked checked unchecked)))
    (should (equal (mapcar #'mdview-parse-test--flat items)
                   '("" "sub" "" "later")))
    ;; The nested list of the second item is intact.
    (should (equal (mdview-parse-test--child-types (nth 1 items)) '(paragraph list))))
  ;; Without a space after `]' it is still ordinary text.
  (should-not (mdview-node-prop
               (car (mdview-node-children (mdview-parse-test--first "- [ ]x")))
               :task)))

;;;; Link reference definitions

(ert-deftest mdview-parse-reference-definitions-basic ()
  (let* ((doc (mdview-parse-string "[foo]: /url \"title\"\n\n[bar]: </my url> 'single'\n[baz]: (paren) (parens)\n\ntext"))
         (refs (mdview-node-prop doc :refs)))
    (should (equal (mdview-parse-test--child-types doc) '(paragraph)))
    (should (= (hash-table-count refs) 3))
    (should (equal (gethash (mdview-parse-normalize-label "foo") refs) '("/url" . "title")))
    (should (equal (gethash (mdview-parse-normalize-label "bar") refs) '("/my url" . "single")))
    (should (equal (gethash (mdview-parse-normalize-label "baz") refs) '("(paren)" . "parens")))))

(ert-deftest mdview-parse-reference-definitions-multiline ()
  (let* ((doc (mdview-parse-string "   [foo]: \n      /url  \n           'the title'  \n\n[bar]:\n<>\n\n[baz]: /x '\nmulti\nline\n'"))
         (refs (mdview-node-prop doc :refs)))
    (should-not (mdview-node-children doc))
    (should (equal (gethash "FOO" refs) '("/url" . "the title")))
    (should (equal (gethash "BAR" refs) '("" . nil)))
    (should (equal (gethash "BAZ" refs) '("/x" . "\nmulti\nline\n")))))

(ert-deftest mdview-parse-reference-definitions-labels ()
  (let ((refs (mdview-node-prop (mdview-parse-string "[Foo  Bar]: /a\n[foo]: first\n[FOO]: second\n[ΑΓΩ]: /g\n[ẞ]: /sharp") :refs)))
    (should (equal (car (gethash (mdview-parse-normalize-label " foo\tbar ") refs)) "/a"))
    (should (equal (car (gethash (mdview-parse-normalize-label "foo") refs)) "first"))
    (should (equal (car (gethash (mdview-parse-normalize-label "αγω") refs)) "/g"))
    (should (equal (car (gethash (mdview-parse-normalize-label "SS") refs)) "/sharp"))
    (should (= (hash-table-count refs) 4)))
  (should (equal (mdview-parse-normalize-label "  A  b\n C ") "A B C"))
  (should (equal (mdview-parse-normalize-label "   ") "")))

(ert-deftest mdview-parse-reference-definitions-not-definitions ()
  ;; Title not at the end of the line: the whole thing is a paragraph.
  (let ((doc (mdview-parse-string "[foo]: /url \"title\" ok")))
    (should (equal (mdview-parse-test--child-types doc) '(paragraph)))
    (should (= (hash-table-count (mdview-node-prop doc :refs)) 0)))
  ;; ... but a URL followed by junk after a line break keeps the definition.
  (let ((doc (mdview-parse-string "[foo]: /url\n\"title\" ok")))
    (should (equal (mdview-parse-test--child-types doc) '(paragraph)))
    (should (equal (gethash "FOO" (mdview-node-prop doc :refs)) '("/url" . nil))))
  ;; Definitions cannot interrupt a paragraph.
  (let ((doc (mdview-parse-string "Foo\n[bar]: /baz\n\n[bar]")))
    (should (equal (mdview-parse-test--child-types doc) '(paragraph paragraph)))
    (should (= (hash-table-count (mdview-node-prop doc :refs)) 0)))
  ;; Empty or whitespace labels, missing colon, destination with spaces.
  (dolist (md '("[]: /x" "[ ]: /x" "[foo] /x" "[foo]: /a b" "[foo]: <bar>(baz)"))
    (let ((doc (mdview-parse-string md)))
      (should (equal (mdview-parse-test--child-types doc) '(paragraph)))
      (should (= (hash-table-count (mdview-node-prop doc :refs)) 0))))
  ;; Indented four spaces it is code.
  (should (equal (mdview-parse-test--types "    [foo]: /url") '(code-block))))

(ert-deftest mdview-parse-reference-definitions-unescape ()
  (let ((refs (mdview-node-prop (mdview-parse-string "[foo]: /url\\bar\\*baz \"foo\\\"bar\\baz\"\n[amp]: /a&amp;b&copy; \"t&#x41;\"") :refs)))
    (should (equal (gethash "FOO" refs) '("/url\\bar*baz" . "foo\"bar\\baz")))
    (should (equal (gethash "AMP" refs) '("/a&b©" . "tA")))))

(ert-deftest mdview-parse-reference-definitions-and-headings ()
  ;; A definition before a setext underline is removed; the underline is text.
  (let ((doc (mdview-parse-string "[foo]: /url\n===\n[foo]")))
    (should (equal (mdview-parse-test--child-types doc) '(paragraph)))
    ;; The paragraph text is "=== [foo]"; the inline parser resolves
    ;; [foo] against the definition, so it reads as a link to /url.
    (let ((children (mdview-node-children (car (mdview-node-children doc)))))
      (should (equal (mdview-parse-test--flat (car (mdview-node-children doc))) "=== foo"))
      (should (eq (mdview-node-type (nth 2 children)) 'link))
      (should (equal (mdview-node-prop (nth 2 children) :url) "/url")))
    (should (= (hash-table-count (mdview-node-prop doc :refs)) 1)))
  (let ((doc (mdview-parse-string "[foo]: /url\nbar\n===")))
    (should (equal (mdview-parse-test--child-types doc) '(heading)))
    (should (equal (mdview-node-text (car (mdview-node-children doc))) "bar")))
  ;; Definitions after a heading and before a quote are removed.
  (let ((doc (mdview-parse-string "# [Foo]\n[foo]: /url\n> bar")))
    (should (equal (mdview-parse-test--child-types doc) '(heading blockquote)))
    (should (= (hash-table-count (mdview-node-prop doc :refs)) 1)))
  ;; A paragraph consisting of definitions followed by text keeps the text.
  (let* ((doc (mdview-parse-string "[a]: /a\n[b]: /b\n  \"title b\"\n[c]: /c\nvisible"))
         (p (car (mdview-node-children doc))))
    (should (equal (mdview-node-text p) "visible"))
    (should (= (mdview-node-prop p :line) 1))
    (should (= (hash-table-count (mdview-node-prop doc :refs)) 3))))

;;;; Heading ids

(ert-deftest mdview-parse-heading-ids ()
  (let ((blocks (mdview-parse-test--blocks "# Hello World!\n## Hello World!\n### hello-world\n# Hello World!\n## Ünïcode Ok")))
    (should (equal (mapcar (lambda (h) (mdview-node-prop h :id)) blocks)
                   '("hello-world" "hello-world-1" "hello-world-2" "hello-world-3" "ünïcode-ok")))))

(ert-deftest mdview-parse-heading-ids-everywhere ()
  ;; Headings inside containers take part in the numbering, in order.
  (let* ((doc (mdview-parse-string "# A\n> ## A\n- ### A\n\nB\n=\n"))
         (ids (delq nil (mdview-ast-map
                         (lambda (n) (and (eq (mdview-node-type n) 'heading) (mdview-node-prop n :id)))
                         doc))))
    (should (equal ids '("a" "a-1" "a-2" "b"))))
  (should (equal (mdview-node-prop (mdview-parse-test--first "#") :id) ""))
  (should (equal (mdview-node-prop (cadr (mdview-parse-test--blocks "#\n#")) :id) "-1")))

;;;; Line numbers and front matter

(ert-deftest mdview-parse-line-numbers ()
  (let ((md (concat "# H\n"            ; 1
                    "\n"
                    "para\n"           ; 3
                    "more\n"
                    "\n"
                    "> quote\n"        ; 6
                    "\n"
                    "- one\n"          ; 8
                    "- two\n"
                    "\n"
                    "```\n"            ; 11
                    "code\n"
                    "```\n"
                    "    indented\n"   ; 14
                    "\n"
                    "| a |\n"          ; 16
                    "|---|\n"
                    "\n"
                    "<div>\n"          ; 19
                    "\n"
                    "***\n"            ; 21
                    "end\n")))         ; 22
    (should (equal (mdview-parse-test--lines md) '(1 3 6 8 11 14 16 19 21 22)))
    (let ((list (nth 3 (mdview-parse-test--blocks md))))
      (should (equal (mapcar (lambda (i) (mdview-node-prop i :line)) (mdview-node-children list))
                     '(8 9))))))

(ert-deftest mdview-parse-line-numbers-in-containers ()
  (let* ((q (mdview-parse-test--first "\n> a\n>\n> b\n> - c\n>   d\n> - e"))
         (children (mdview-node-children q)))
    (should (= (mdview-node-prop q :line) 2))
    (should (equal (mapcar (lambda (b) (mdview-node-prop b :line)) children) '(2 4 5)))
    (should (equal (mapcar (lambda (i) (mdview-node-prop i :line))
                           (mdview-node-children (nth 2 children)))
                   '(5 7)))))

(ert-deftest mdview-parse-front-matter ()
  (let ((blocks (mdview-parse-test--blocks "---\ntitle: Hello\ntags: [a, b]\n---\n\n# Heading\n\ntext")))
    (should (equal (mapcar #'mdview-node-type blocks) '(heading paragraph)))
    ;; Line numbers still count the skipped lines.
    (should (equal (mapcar (lambda (b) (mdview-node-prop b :line)) blocks) '(6 8))))
  ;; `...' closes front matter too.
  (should (equal (mdview-parse-test--types "---\nkey: v\n...\ntext") '(paragraph)))
  ;; Without a closing line, or without YAML-looking content, it is Markdown.
  (should (equal (mdview-parse-test--types "---\ntitle: x\n\ntext")
                 '(thematic-break paragraph paragraph)))
  (should (equal (mdview-parse-test--types "---\nFoo\n---") '(thematic-break heading)))
  ;; Front matter must start on the first line.
  (should (equal (mdview-parse-test--types "\n---\ntitle: x\n---") '(thematic-break heading)))
  ;; The option turns it off.
  (let ((mdview-parse-front-matter nil))
    (should (equal (mdview-parse-test--types "---\ntitle: x\n---") '(thematic-break heading)))))

;;;; Fixtures

(ert-deftest mdview-parse-fixture-minimal ()
  (with-temp-buffer
    (insert-file-contents (mdview-parse-test--path "test/fixtures/minimal.md"))
    (let ((doc (mdview-parse-buffer)))
      (should (equal (mdview-parse-test--child-types doc) '(heading paragraph list table)))
      (should (equal (mapcar (lambda (b) (mdview-node-prop b :line)) (mdview-node-children doc))
                     '(1 3 5 8))))))

(ert-deftest mdview-parse-fixture-showcase ()
  (with-temp-buffer
    (insert-file-contents (mdview-parse-test--path "test/fixtures/showcase.md"))
    (let* ((doc (mdview-parse-buffer))
           (blocks (mdview-node-children doc))
           (types (mapcar #'mdview-node-type blocks)))
      (should (equal types
                     '(heading paragraph heading paragraph heading heading heading heading
                       heading heading thematic-break
                       heading list list list list
                       heading blockquote blockquote
                       heading paragraph code-block paragraph code-block code-block code-block
                       heading table table paragraph table
                       heading paragraph paragraph paragraph paragraph
                       heading html-block paragraph paragraph paragraph paragraph
                       thematic-break paragraph)))
      (should (= (cl-count 'heading types) 14))
      (should (= (cl-count 'table types) 3))
      (should (= (cl-count 'code-block types) 4))
      (should (= (cl-count 'list types) 4))
      ;; Five code blocks in total: one lives inside the loose list.
      (should (= (length (delq nil (mdview-ast-map
                                    (lambda (n) (eq (mdview-node-type n) 'code-block)) doc)))
                 5))
      (should (equal (mapcar (lambda (h) (mdview-node-prop h :level))
                             (cl-remove-if-not (lambda (b) (eq (mdview-node-type b) 'heading)) blocks))
                     '(1 2 3 4 5 6 1 2 2 2 2 2 2 2)))
      (should (equal (mapcar (lambda (c) (mdview-node-prop c :lang))
                             (cl-remove-if-not (lambda (b) (eq (mdview-node-type b) 'code-block)) blocks))
                     '(nil "python" "elisp" nil)))
      (should (equal (mdview-node-prop (nth 27 blocks) :align) '(nil center right)))
      (should (= (hash-table-count (mdview-node-prop doc :refs)) 2))
      (should (equal (car (gethash (mdview-parse-normalize-label "ref") (mdview-node-prop doc :refs)))
                     "https://www.gnu.org/software/emacs/"))
      ;; The task list and the loose list.
      (should (equal (mapcar (lambda (i) (mdview-node-prop i :task))
                             (mdview-node-children (nth 14 blocks)))
                     '(unchecked checked unchecked)))
      (should-not (mdview-node-prop (nth 15 blocks) :tight))
      ;; Footnote definitions never remain in the block flow.
      (should-not (memq 'footnote-definition types))
      ;; With an inline parser that produces footnote references, both
      ;; definitions are collected in order of reference.
      (when (cl-some (lambda (n) (eq (mdview-node-type n) 'footnote-reference))
                     (mdview-inline-parse "a[^1]" nil))
        (should (equal (mapcar (lambda (f) (mdview-node-prop f :label))
                               (mdview-node-prop doc :footnotes))
                       '("1" "note")))))))

;;;; Robustness and performance

(ert-deftest mdview-parse-never-signals-on-fixture-slices ()
  (let ((text (with-temp-buffer
                (insert-file-contents (mdview-parse-test--path "test/fixtures/showcase.md"))
                (buffer-string)))
        (state (cl-make-random-state t)))
    (ignore state)
    (random "mdview-parse-fuzz")
    (dotimes (_ 300)
      (let* ((a (random (length text)))
             (b (random (length text)))
             (slice (substring text (min a b) (max a b))))
        (should (eq (mdview-node-type (mdview-parse-string slice)) 'document))))))

(ert-deftest mdview-parse-reference-destination-paren-nesting-limit ()
  "A definition's destination may nest parens 32 deep but not 33 (cmark)."
  (let ((ok (concat "[a]: " (make-string 32 ?\() "b" (make-string 32 ?\)) "\n\n[a]"))
        (deep (concat "[a]: " (make-string 33 ?\() "b" (make-string 33 ?\)) "\n\n[a]")))
    (let ((para (mdview-parse-test--first ok)))
      (should (eq (mdview-node-type (car (mdview-node-children para))) 'link))
      (should (equal (mdview-node-prop (car (mdview-node-children para)) :url)
                     (concat (make-string 32 ?\() "b" (make-string 32 ?\))))))
    (should (equal (mdview-parse-test--types deep) '(paragraph paragraph)))))

(ert-deftest mdview-parse-never-signals-on-adversarial-input ()
  (dolist (md (list (make-string 5000 ?>)
                    (concat (make-string 3000 ?>) " deep")
                    (apply #'concat (make-list 3000 "- "))
                    (apply #'concat (make-list 2000 "1. "))
                    (make-string 100000 ?`)
                    (make-string 100000 ?#)
                    (concat "#" (make-string 100000 ?\s) "x")
                    (make-string 100000 ?\[)
                    (concat "[" (make-string 100000 ?a) "]: /x")
                    (apply #'concat (make-list 50000 "- "))
                    (apply #'concat (make-list 50000 "* "))
                    (concat "<a " (apply #'concat (make-list 20000 "b=\"c\" ")))
                    (concat "| " (apply #'concat (make-list 20000 "a | ")) "\n| " (apply #'concat (make-list 20000 "- | ")))
                    (apply #'concat (make-list 2000 "[^x]: y\n"))
                    (apply #'concat (make-list 2000 "    code\n\n"))
                    "---\n---\n---\n" "-\n-\n-\n" "1.\n2.\n" "> \n>\n> >" "```\n" "~~~~\n```\n~~~"
                    "\t\t\t-\t\t\tfoo" "|\n|\n|---|\n|" "[^]: x\n[^ ]: y\n[^a]:" "- [ ]\n- [x]"))
    (should (eq (mdview-node-type (mdview-parse-string md)) 'document))))

(ert-deftest mdview-parse-deep-inline-nesting-never-signals ()
  "Thousands of nested emphasis runs degrade to text in every pass.
The inline parser caps nesting, so the footnote pass and the heading id
pass, which recurse over the tree, cannot overflow the stack."
  (dolist (n '(5800 5900 5950 5990))
    (let* ((stars (concat (make-string n ?*) "a" (make-string n ?*)))
           (doc (mdview-parse-string stars))
           (para (car (mdview-node-children doc))))
      (should (eq (mdview-node-type para) 'paragraph))
      (should (equal (mdview-node-children para) (list stars)))
      (let ((heading (car (mdview-node-children
                           (mdview-parse-string (concat "# " stars))))))
        (should (eq (mdview-node-type heading) 'heading))
        (should (stringp (mdview-node-prop heading :id))))
      (should (eq (mdview-node-type
                   (with-temp-buffer (insert stars "\n\n[^f]\n\n[^f]: n " stars)
                                     (mdview-parse-buffer)))
                  'document))))
  ;; Moderate nesting is still parsed as a tree.
  (let ((para (mdview-parse-test--first
               (concat (make-string 100 ?*) "a" (make-string 100 ?*)))))
    (should (eq (mdview-node-type (car (mdview-node-children para))) 'strong))))

(ert-deftest mdview-parse-deep-nesting-is-capped ()
  ;; Deeper than the cap, markers become paragraph text and nothing signals.
  (let ((mdview-parse-max-depth 10))
    (let ((doc (mdview-parse-string (concat (make-string 50 ?>) " x"))))
      (should (eq (mdview-node-type doc) 'document))
      (let ((depth 0) (node (car (mdview-node-children doc))))
        (while (eq (mdview-node-type node) 'blockquote)
          (setq depth (1+ depth) node (car (mdview-node-children node))))
        (should (= depth 10))
        (should (eq (mdview-node-type node) 'paragraph))))))

(defun mdview-parse-test--generate-document (size)
  "Return a Markdown string of at least SIZE bytes exercising every block type."
  (let ((chunk (concat "# Heading with *emphasis* and `code`\n\n"
                       "A paragraph with a [link](http://example.com/path) and some more words to make it\n"
                       "wrap across lines, plus an entity &amp; and an escape \\*.\n\n"
                       "- item one\n- item two\n  - nested item\n    with continuation\n\n"
                       "1. first\n2. second\n\n"
                       "> quoted text\n> > nested quote\n\n"
                       "```python\ndef f(x):\n    return x * 2\n```\n\n"
                       "    indented code\n\n"
                       "| a | b | c |\n|---|:-:|--:|\n| 1 | 2 | 3 |\n| 4 | 5 | 6 |\n\n"
                       "Footnote[^n] and reference [ref].\n\n[^n]: The note.\n[ref]: /url \"title\"\n\n"
                       "<div>\nraw html\n</div>\n\n***\n\n"))
        (parts nil) (total 0))
    (while (< total size)
      (push chunk parts)
      (setq total (+ total (length chunk))))
    (apply #'concat parts)))

(defun mdview-parse-test--ensure-compiled ()
  "Load a byte-compiled copy of mdview-parse.el if the loaded one is interpreted.
The copy is compiled into a temporary directory so the repository stays
clean; the definitions replace the interpreted ones."
  (unless (byte-code-function-p (symbol-function 'mdview-parse--incorporate-line))
    (let* ((dir (make-temp-file "mdview-parse-" t))
           (copy (expand-file-name "mdview-parse.el" dir)))
      (copy-file (mdview-parse-test--path "mdview-parse.el") copy t)
      (let ((byte-compile-warnings nil))
        (byte-compile-file copy))
      (load (expand-file-name "mdview-parse.elc" dir) nil t))))

(ert-deftest mdview-parse-performance-1mb ()
  "A one megabyte document parses in well under five seconds when compiled.
The package ships byte-compiled, so the parser is compiled first when the
interpreted sources are loaded.  Set MDVIEW_SLOW_TESTS in the
environment to run this test."
  :tags '(slow)
  (skip-unless (getenv "MDVIEW_SLOW_TESTS"))
  (let* ((text (mdview-parse-test--generate-document (* 1024 1024)))
         (interpreted (unless (byte-code-function-p
                               (symbol-function 'mdview-parse--incorporate-line))
                        (car (benchmark-run 1 (mdview-parse-string text))))))
    (mdview-parse-test--ensure-compiled)
    (let ((seconds (car (benchmark-run 1 (mdview-parse-string text)))))
      (message "mdview-parse: %d bytes in %.2f s compiled%s" (length text) seconds
               (if interpreted (format " (%.2f s interpreted)" interpreted) ""))
      (should (< seconds 5.0)))))

;;;; CommonMark conformance

(ert-deftest mdview-parse-commonmark-baseline ()
  "The CommonMark pass count must not drop below test/commonmark/baseline."
  (let ((spec (mdview-parse-test--path "test/commonmark/spec.json")))
    (skip-unless (file-readable-p spec))
    (load (mdview-parse-test--path "test/commonmark/run-spec.el") nil t)
    (let* ((results (mdview-commonmark-run spec))
           (passed (plist-get results :passed))
           (baseline (mdview-commonmark-baseline)))
      (message "CommonMark: %d / %d passed (baseline %d)"
               passed (plist-get results :total) baseline)
      (should (>= passed baseline)))))

(provide 'mdview-parse-test)
;;; mdview-parse-test.el ends here
