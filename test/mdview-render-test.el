;;; mdview-render-test.el --- Tests for mdview-render  -*- lexical-binding: t; -*-

;; This file is part of mdview, distributed under the MIT license; see
;; LICENSE in the repository root.

;;; Commentary:

;; ERT tests for the layout engine and renderer (docs/DESIGN.md sections
;; 5, 6 and 7).  Every document is built by hand with `mdview-node' so the
;; tests do not depend on the parser; the code, image and table modules
;; are stubbed with `cl-letf' where their behaviour is irrelevant.  All
;; tests run headless.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'mdview-ast)
(require 'mdview-faces)
(require 'mdview-render)

;;;; Helpers

(defun mdview-render-test--doc (&rest blocks)
  "Return a document node holding BLOCKS."
  (apply #'mdview-node 'document (list :refs nil :footnotes nil) blocks))

(defun mdview-render-test--para (&rest inlines)
  "Return a paragraph node holding INLINES."
  (apply #'mdview-node 'paragraph nil inlines))

(defun mdview-render-test--heading (level text)
  "Return a heading node of LEVEL with TEXT."
  (mdview-node 'heading (list :level level :id (mdview-slug text)) text))

(defun mdview-render-test--list (tight &rest items)
  "Return a tight (when TIGHT) bullet list whose ITEMS are strings or nodes."
  (apply #'mdview-node 'list (list :ordered nil :tight tight :marker ?-)
         (mapcar (lambda (item)
                   (if (stringp item)
                       (mdview-node 'item nil (mdview-render-test--para item))
                     item))
                 items)))

(defun mdview-render-test--render (doc &optional width)
  "Render DOC at WIDTH (default 40) and return the propertized text."
  (with-temp-buffer
    (mdview-render-document doc :width (or width 40))
    (buffer-string)))

(defun mdview-render-test--lines (doc &optional width)
  "Render DOC at WIDTH and return its plain lines (without the final newline)."
  (let ((text (substring-no-properties (mdview-render-test--render doc width))))
    (should (string-suffix-p "\n" text))
    (butlast (split-string text "\n"))))

(defun mdview-render-test--faces (text pos)
  "Return the list of faces at POS in TEXT."
  (let ((face (get-text-property pos 'face text)))
    (cond ((null face) nil)
          ((symbolp face) (list face))
          (t (flatten-tree face)))))

(defun mdview-render-test--line-pos (text n)
  "Return the index in TEXT of the first character of line N (0-based)."
  (let ((pos 0))
    (dotimes (_ n)
      (setq pos (1+ (string-search "\n" text pos))))
    pos))

(defun mdview-render-test--ctx (&rest args)
  "Return a context built from the keyword ARGS."
  (apply #'mdview-render--ctx-make args))

(defmacro mdview-render-test--emitted (&rest body)
  "Run BODY in a temporary buffer and return the buffer text."
  `(with-temp-buffer ,@body (buffer-string)))

(defun mdview-render-test--all-widths (lines width)
  "Return non-nil when every line of LINES is exactly WIDTH columns wide."
  (seq-every-p (lambda (line) (= (string-width line) width)) lines))

(defun mdview-render-test--glyph-row (key width)
  "Return WIDTH repetitions of the glyph KEY."
  (mdview-render--repeat-glyph (mdview-glyph key) width))

;;;; Line emission

(ert-deftest mdview-render-emit-line-pads-to-width ()
  (let ((text (mdview-render-test--emitted
               (mdview-render--emit-line "abc" (mdview-render-test--ctx :width 10)))))
    (should (equal text "abc       \n"))))

(ert-deftest mdview-render-emit-line-first-prefix-used-once ()
  (let* ((ctx (mdview-render-test--ctx :width 5 :prefix "  " :first-prefix "* "))
         (text (mdview-render-test--emitted
                (mdview-render--emit-line "a" ctx)
                (mdview-render--emit-line "b" ctx)
                (mdview-render--emit-line "" ctx))))
    (should (equal text "* a    \n  b    \n       \n"))
    (should (null (mdview-render-ctx-first-prefix ctx)))))

(ert-deftest mdview-render-emit-line-first-prefix-clears-ancestors ()
  (let* ((parent (mdview-render-test--ctx :width 10 :prefix "  " :first-prefix "* "))
         (child (mdview-render--ctx-child parent :addition "> ")))
    (should (equal (mdview-render-ctx-first-prefix child) "* > "))
    (mdview-render-test--emitted (mdview-render--emit-line "x" child))
    (should (null (mdview-render-ctx-first-prefix child)))
    (should (null (mdview-render-ctx-first-prefix parent)))))

(ert-deftest mdview-render-emit-line-padding-has-bg ()
  (let* ((ctx (mdview-render-test--ctx :width 6 :prefix "| " :bg 'mdview-quote))
         (text (mdview-render-test--emitted
                (mdview-render--emit-line (propertize "ab" 'face 'bold) ctx))))
    (should (equal (substring-no-properties text) "| ab    \n"))
    ;; text and padding carry the background under the text's own face;
    ;; the prefix is left alone (it carries its own)
    (should (null (get-text-property 0 'face text)))
    (should (equal (mdview-render-test--faces text 2) '(bold mdview-quote)))
    (should (equal (mdview-render-test--faces text 5) '(mdview-quote)))
    ;; the newline does not
    (should (null (get-text-property 8 'face text)))))

(ert-deftest mdview-render-emit-line-suffix-and-overlong ()
  (let ((ctx (mdview-render-test--ctx :width 4 :prefix "> " :suffix "|")))
    (should (equal (mdview-render-test--emitted (mdview-render--emit-line "ab" ctx))
                   "> ab  |\n"))
    (should (equal (mdview-render-test--emitted
                    (mdview-render--emit-line "abcdefgh" ctx))
                   "> abcdefgh|\n"))))

;;;; Wrapping

(ert-deftest mdview-render-wrap-simple ()
  (should (equal (mdview-wrap "the quick brown fox jumps" 10)
                 '("the quick" "brown fox" "jumps")))
  (should (equal (mdview-wrap "fits" 10) '("fits")))
  (should (equal (mdview-wrap "" 10) '(""))))

(ert-deftest mdview-render-wrap-long-token ()
  (should (equal (mdview-wrap "abcdefghij" 4) '("abcd" "efgh" "ij")))
  (should (equal (mdview-wrap "aa abcdefgh b" 5) '("aa" "abcde" "fgh b"))))

(ert-deftest mdview-render-wrap-forced-newline ()
  (should (equal (mdview-wrap "a b\nc d" 20) '("a b" "c d")))
  (should (equal (mdview-wrap "a\n\nb" 20) '("a" "" "b")))
  (should (equal (mdview-wrap "trailing \nspace" 20) '("trailing" "space"))))

(ert-deftest mdview-render-wrap-trims-edges-keeps-inner-spaces ()
  (should (equal (mdview-wrap "  a   b  " 10) '("a   b")))
  (should (equal (mdview-wrap "aaa    bbb" 5) '("aaa" "bbb"))))

(ert-deftest mdview-render-wrap-width-one ()
  (should (equal (mdview-wrap "ab c" 1) '("a" "b" "c")))
  (should (equal (mdview-wrap "x" 0) '("x"))))

(ert-deftest mdview-render-wrap-wide-characters ()
  (should (equal (mdview-wrap "日本語 テスト" 6) '("日本語" "テスト")))
  (should (equal (mdview-wrap "日本語" 4) '("日本" "語"))))

(ert-deftest mdview-render-wrap-preserves-properties ()
  (let* ((string (concat (propertize "foo bar" 'face 'bold 'mdview-link "u") " baz"))
         (lines (mdview-wrap string 7)))
    (should (equal (mapcar #'substring-no-properties lines) '("foo bar" "baz")))
    (should (eq (get-text-property 0 'face (car lines)) 'bold))
    (should (eq (get-text-property 3 'face (car lines)) 'bold))
    (should (equal (get-text-property 6 'mdview-link (car lines)) "u"))
    (should (null (get-text-property 0 'face (cadr lines))))))

(ert-deftest mdview-render-wrap-image-token-counts-columns ()
  (let* ((image (propertize "[i]" 'mdview-columns 8))
         (lines (mdview-wrap (concat "aaaa " image " b") 10)))
    (should (equal (mapcar #'substring-no-properties lines) '("aaaa" "[i] b")))
    (should (= (mdview-render--string-width (concat "x" image)) 9))))

;;;; Margins

(ert-deftest mdview-render-margins-paragraph-paragraph ()
  (should (equal (mdview-render-test--lines
                  (mdview-render-test--doc (mdview-render-test--para "one")
                                           (mdview-render-test--para "two"))
                  5)
                 '("one  " "     " "two  "))))

(ert-deftest mdview-render-margins-paragraph-h2-paragraph ()
  (let ((lines (mdview-render-test--lines
                (mdview-render-test--doc (mdview-render-test--para "p")
                                         (mdview-render-test--heading 2 "H")
                                         (mdview-render-test--para "q"))
                10)))
    (should (= (length lines) 8))
    (should (string-blank-p (nth 1 lines)))
    (should (equal (nth 2 lines) (mdview-render-test--glyph-row 'box-top 10)))
    (should (equal (nth 6 lines) (mdview-render-test--glyph-row 'box-bottom 10)))
    (should (equal (nth 7 lines) "q         "))))

(ert-deftest mdview-render-margins-h1-paragraph ()
  (let ((lines (mdview-render-test--lines
                (mdview-render-test--doc (mdview-render-test--heading 1 "T")
                                         (mdview-render-test--para "p"))
                10)))
    (should (= (length lines) 6))
    (should (equal (nth 5 lines) "p         "))))

(ert-deftest mdview-render-margins-h3-to-h6-sequence ()
  (should (equal (mdview-render-test--lines
                  (mdview-render-test--doc (mdview-render-test--heading 3 "ccc")
                                           (mdview-render-test--heading 4 "d")
                                           (mdview-render-test--heading 5 "e")
                                           (mdview-render-test--heading 6 "f"))
                  5)
                 (list "ccc  " (concat (mdview-render-test--glyph-row 'h3-rule 3) "  ")
                       "     " "d    " "     " "e    " "     " "f    "))))

(ert-deftest mdview-render-margins-thematic-break ()
  (should (equal (mdview-render-test--lines
                  (mdview-render-test--doc (mdview-render-test--para "p")
                                           (mdview-node 'thematic-break nil)
                                           (mdview-render-test--para "q"))
                  4)
                 (list "p   " "    " "    " (mdview-render-test--glyph-row 'rule 4)
                       "    " "q   "))))

(ert-deftest mdview-render-margins-list-paragraph ()
  (should (equal (mdview-render-test--lines
                  (mdview-render-test--doc (mdview-render-test--list t "a" "b")
                                           (mdview-render-test--para "p"))
                  6)
                 (list (concat (mdview-glyph 'bullet-1) " a   ")
                       (concat (mdview-glyph 'bullet-1) " b   ")
                       "      " "p     "))))

(ert-deftest mdview-render-margins-blockquote ()
  (let ((lines (mdview-render-test--lines
                (mdview-render-test--doc
                 (mdview-render-test--para "p")
                 (mdview-node 'blockquote nil (mdview-render-test--para "q"))
                 (mdview-render-test--para "r"))
                8)))
    (should (equal lines (list "p       " "        "
                               (concat (mdview-glyph 'quote-bar) " q     ")
                               "        " "r       ")))))

(ert-deftest mdview-render-margins-nested-quote ()
  (let* ((bar (mdview-glyph 'quote-bar))
         (lines (mdview-render-test--lines
                 (mdview-render-test--doc
                  (mdview-node 'blockquote nil
                               (mdview-render-test--para "outer")
                               (mdview-node 'blockquote nil
                                            (mdview-render-test--para "inner text"))))
                 20)))
    ;; bar + space, inner width 17, one column of right padding
    (should (equal lines (list (concat bar " outer             ")
                               (concat bar "                   ")
                               (concat bar "   " bar " inner text    "))))))

(ert-deftest mdview-render-margins-loose-vs-tight ()
  (let ((bullet (mdview-glyph 'bullet-1)))
    (should (equal (mdview-render-test--lines
                    (mdview-render-test--doc (mdview-render-test--list t "a" "b")) 4)
                   (list (concat bullet " a ") (concat bullet " b "))))
    (should (equal (mdview-render-test--lines
                    (mdview-render-test--doc (mdview-render-test--list nil "a" "b")) 4)
                   (list (concat bullet " a ") "    " (concat bullet " b "))))))

(ert-deftest mdview-render-margins-tight-item-keeps-code-margin ()
  (let ((lines (cl-letf (((symbol-function 'mdview-code-fontify)
                          (lambda (code _lang) code)))
                 (mdview-render-test--lines
                  (mdview-render-test--doc
                   (mdview-render-test--list
                    t (mdview-node 'item nil (mdview-render-test--para "a")
                                   (mdview-node 'code-block nil "c"))))
                  8))))
    ;; item text, 1 blank (code top margin), blank code row, code, blank code row
    (should (= (length lines) 5))
    (should (equal (nth 1 lines) "        "))
    (should (equal (nth 3 lines) "    c   "))))

(ert-deftest mdview-render-document-start-and-end ()
  (let ((text (mdview-render-test--render
               (mdview-render-test--doc (mdview-render-test--para "a")) 3)))
    (should (equal text "a  \n")))
  (should (equal (mdview-render-test--render (mdview-render-test--doc) 3) "")))

;;;; Headings

(ert-deftest mdview-render-h1-box-centered ()
  (let* ((text (mdview-render-test--render
                (mdview-render-test--doc (mdview-render-test--heading 1 "Title")) 20))
         (lines (butlast (split-string (substring-no-properties text) "\n"))))
    (should (= (length lines) 5))
    (should (equal (nth 0 lines) (mdview-render-test--glyph-row 'box-top 20)))
    (should (equal (nth 1 lines) (concat (mdview-glyph 'box-left) "                  "
                                         (mdview-glyph 'box-right))))
    ;; inner width 16, "Title" is 5 wide: 5 columns of centering on the left
    (should (equal (nth 2 lines) (concat (mdview-glyph 'box-left) "      Title       "
                                         (mdview-glyph 'box-right))))
    (should (equal (nth 4 lines) (mdview-render-test--glyph-row 'box-bottom 20)))
    ;; faces: frame glyphs carry mdview-box-frame over mdview-h1, text mdview-h1
    (should (equal (mdview-render-test--faces text 0) '(mdview-box-frame mdview-h1)))
    (let ((row (mdview-render-test--line-pos text 2)))
      (should (equal (mdview-render-test--faces text row) '(mdview-box-frame mdview-h1)))
      (should (equal (mdview-render-test--faces text (+ row 1)) '(mdview-h1)))
      (should (equal (mdview-render-test--faces text (+ row 7)) '(mdview-h1)))
      ;; the right glyph is reversed so that its thin edge is on the right
      (should (equal (mdview-render-test--faces text (+ row 19))
                     '(:inverse-video t mdview-box-frame mdview-h1))))))

(ert-deftest mdview-render-box-right-glyph-reversal ()
  ;; Only the Unicode `▊', which fills the left three quarters of its cell,
  ;; is reversed; the ASCII profile's `|' is drawn like the left glyph.
  (let ((text (mdview-render-test--render
               (mdview-render-test--doc (mdview-render-test--heading 1 "Title")) 20))
        (right (+ (mdview-render-test--line-pos
                   (mdview-render-test--render
                    (mdview-render-test--doc (mdview-render-test--heading 1 "Title")) 20)
                   2)
                  19)))
    (should (equal (mdview-render-test--faces text right)
                   '(:inverse-video t mdview-box-frame mdview-h1)))
    (let* ((mdview-use-ascii-glyphs t)
           (ascii (mdview-render-test--render
                   (mdview-render-test--doc (mdview-render-test--heading 1 "Title")) 20))
           (pos (+ (mdview-render-test--line-pos ascii 2) 19)))
      (should (equal (substring-no-properties ascii pos (1+ pos)) "|"))
      (should (equal (mdview-render-test--faces ascii pos)
                     '(mdview-box-frame mdview-h1))))))

(ert-deftest mdview-render-h2-box-centered ()
  ;; Like H1, the H2 box centres its text (the Frogmouth reference grid).
  (let* ((text (mdview-render-test--render
                (mdview-render-test--doc (mdview-render-test--heading 2 "Mid")) 20))
         (lines (butlast (split-string (substring-no-properties text) "\n"))))
    (should (= (length lines) 5))
    (should (equal (nth 2 lines) (concat (mdview-glyph 'box-left) "       Mid        "
                                         (mdview-glyph 'box-right))))
    (should (equal (mdview-render-test--faces text (+ (mdview-render-test--line-pos text 2) 8))
                   '(mdview-h2)))))

(ert-deftest mdview-render-h3-rule-matches-text-width ()
  (let* ((text (mdview-render-test--render
                (mdview-render-test--doc (mdview-render-test--heading 3 "Third")) 20))
         (lines (butlast (split-string (substring-no-properties text) "\n"))))
    (should (equal lines (list "Third               "
                               (concat (mdview-render-test--glyph-row 'h3-rule 5)
                                       "               "))))
    (should (equal (mdview-render-test--faces text 0) '(mdview-h3)))
    (should (equal (mdview-render-test--faces text (mdview-render-test--line-pos text 1))
                   '(mdview-h3-rule)))))

(ert-deftest mdview-render-h4-h5-h6-faces ()
  (dolist (pair '((4 . mdview-h4) (5 . mdview-h5) (6 . mdview-h6)))
    (let ((text (mdview-render-test--render
                 (mdview-render-test--doc (mdview-render-test--heading (car pair) "x")) 5)))
      (should (equal text "x    \n"))
      (should (equal (mdview-render-test--faces text 0) (list (cdr pair)))))))

(ert-deftest mdview-render-heading-properties ()
  (let* ((text (mdview-render-test--render
                (mdview-render-test--doc
                 (mdview-node 'heading '(:level 2 :id "my-id" :line 7) "My " (mdview-node 'emphasis nil "Id")))
                20))
         ;; "My Id" is centred in the 16-column interior: it starts at column 7.
         (pos (+ (mdview-render-test--line-pos text 2) 7)))
    (should (eq (get-text-property pos 'mdview-heading-level text) 2))
    (should (equal (get-text-property pos 'mdview-heading-id text) "my-id"))
    (should (equal (get-text-property (+ pos 4) 'mdview-heading-id text) "my-id"))
    (should (equal (mdview-render-test--faces text (+ pos 3)) '(mdview-emphasis mdview-h2)))
    (should (null (get-text-property (+ pos 6) 'mdview-heading-id text)))
    (should (eq (get-text-property 0 'mdview-source-line text) 7))))

(ert-deftest mdview-render-frame-style-none ()
  (let* ((mdview-box-frame-style 'none)
         (text (mdview-render-test--render
                (mdview-render-test--doc (mdview-render-test--heading 1 "Hi")) 10))
         (lines (butlast (split-string (substring-no-properties text) "\n"))))
    (should (equal lines '("          " "          " "    Hi    " "          " "          ")))
    (should (equal (mdview-render-test--faces text 0) '(mdview-h1)))
    (should (equal (mdview-render-test--faces text (mdview-render-test--line-pos text 2))
                   '(mdview-h1)))))

;;;; Lists

(ert-deftest mdview-render-bullets-by-depth-cycle ()
  (let ((inner nil))
    (dotimes (i 6)
      (let ((level (- 6 i)))
        (setq inner (mdview-node 'list '(:ordered nil :tight t :marker ?-)
                                 (apply #'mdview-node 'item nil
                                        (mdview-render-test--para (format "L%d" level))
                                        (when inner (list inner)))))))
    ;; Width 24 leaves the sixth level 12 columns, above the nesting floor.
    (should (equal (mdview-render-test--lines (mdview-render-test--doc inner) 24)
                   (list (concat (mdview-glyph 'bullet-1) " L1                    ")
                         (concat "  " (mdview-glyph 'bullet-2) " L2                  ")
                         (concat "    " (mdview-glyph 'bullet-3) " L3                ")
                         (concat "      " (mdview-glyph 'bullet-4) " L4              ")
                         (concat "        " (mdview-glyph 'bullet-5) " L5            ")
                         (concat "          " (mdview-glyph 'bullet-1) " L6          "))))))

(ert-deftest mdview-render-bullet-face-and-wrap-indent ()
  (let* ((text (mdview-render-test--render
                (mdview-render-test--doc (mdview-render-test--list t "one two three")) 9))
         (lines (butlast (split-string (substring-no-properties text) "\n"))))
    (should (equal lines (list (concat (mdview-glyph 'bullet-1) " one two")
                               "  three  ")))
    (should (equal (mdview-render-test--faces text 0) '(mdview-bullet)))
    (should (null (get-text-property 1 'face text)))))

(ert-deftest mdview-render-ordered-start-ten-right-aligned ()
  (let ((list (mdview-node 'list '(:ordered t :start 9 :tight t :marker ?.)
                           (mdview-node 'item nil (mdview-render-test--para "nine"))
                           (mdview-node 'item nil (mdview-render-test--para "ten and more words")))))
    ;; Numbers are right-aligned to the widest one, with one leading column.
    (should (equal (mdview-render-test--lines (mdview-render-test--doc list) 14)
                   '("  9. nine     " " 10. ten and  " "     more     " "     words    ")))))

(ert-deftest mdview-render-ordered-paren-delimiter-and-face ()
  (let* ((list (mdview-node 'list '(:ordered t :start 1 :tight t :marker ?\))
                            (mdview-node 'item nil (mdview-render-test--para "a"))))
         (text (mdview-render-test--render (mdview-render-test--doc list) 6)))
    (should (equal text " 1) a \n"))
    (should (equal (mdview-render-test--faces text 1) '(mdview-bullet)))
    (should (equal (mdview-render-test--faces text 2) '(mdview-bullet)))))

(ert-deftest mdview-render-task-glyphs-and-faces ()
  (let* ((list (mdview-node 'list '(:ordered nil :tight t :marker ?-)
                            (mdview-node 'item '(:task unchecked) (mdview-render-test--para "open"))
                            (mdview-node 'item '(:task checked) (mdview-render-test--para "done"))))
         (text (mdview-render-test--render (mdview-render-test--doc list) 10))
         (lines (butlast (split-string (substring-no-properties text) "\n"))))
    (should (equal lines (list (concat (mdview-glyph 'task-unchecked) " open    ")
                               (concat (mdview-glyph 'task-checked) " done    "))))
    (should (equal (mdview-render-test--faces text 0) '(mdview-task-unchecked)))
    (should (equal (mdview-render-test--faces text (mdview-render-test--line-pos text 1))
                   '(mdview-task-checked)))))

(ert-deftest mdview-render-empty-item-shows-bullet ()
  (should (equal (mdview-render-test--lines
                  (mdview-render-test--doc
                   (mdview-node 'list '(:ordered nil :tight t :marker ?-)
                                (mdview-node 'item nil)))
                  4)
                 (list (concat (mdview-glyph 'bullet-1) "   ")))))

;;;; Block quotes

(ert-deftest mdview-render-quote-bar-on-blank-lines-and-inner-width ()
  (let* ((bar (mdview-glyph 'quote-bar))
         (text (mdview-render-test--render
                (mdview-render-test--doc
                 (mdview-node 'blockquote nil
                              (mdview-render-test--para "aaaa bbbb cccc")
                              (mdview-render-test--para "d")))
                12))
         (lines (butlast (split-string (substring-no-properties text) "\n"))))
    ;; inner width 9: "aaaa bbbb" fits, "cccc" wraps
    (should (equal lines (list (concat bar " aaaa bbbb ")
                               (concat bar " cccc      ")
                               (concat bar "           ")
                               (concat bar " d         "))))
    ;; background on bar, text, padding and the right pad; border face on the bar
    (should (equal (mdview-render-test--faces text 0) '(mdview-quote-border mdview-quote)))
    (should (equal (mdview-render-test--faces text 2) '(mdview-quote)))
    (should (equal (mdview-render-test--faces text 11) '(mdview-quote)))
    (let ((blank (mdview-render-test--line-pos text 2)))
      (should (equal (mdview-render-test--faces text (+ blank 5)) '(mdview-quote))))))

(ert-deftest mdview-render-quote-levels-reuse-third-face ()
  (let* ((text (mdview-render-test--render
                (mdview-render-test--doc
                 (mdview-node 'blockquote nil
                              (mdview-node 'blockquote nil
                                           (mdview-node 'blockquote nil
                                                        (mdview-node 'blockquote nil
                                                                     (mdview-render-test--para "deep"))))))
                40))
         (line (substring-no-properties text 0 (string-search "\n" text)))
         (deep (string-search "deep" text)))
    (should (= (string-width line) 40))
    (should (equal (mdview-render-test--faces text deep) '(mdview-quote-3)))
    ;; the outer bars keep their own level's background
    (should (equal (mdview-render-test--faces text 0) '(mdview-quote-border mdview-quote)))
    (should (equal (mdview-render-test--faces text 4) '(mdview-quote-border mdview-quote-2)))
    (should (equal (mdview-render-test--faces text 5) '(mdview-quote-2)))
    (should (equal (mdview-render-test--faces text 2) '(mdview-quote)))))

;;;; Code blocks

(ert-deftest mdview-render-code-block-rows ()
  (let* ((text (cl-letf (((symbol-function 'mdview-code-fontify)
                          (lambda (code _lang) code)))
                 (mdview-render-test--render
                  (mdview-render-test--doc (mdview-node 'code-block '(:lang "sh") "a\n  b"))
                  8)))
         (lines (butlast (split-string (substring-no-properties text) "\n"))))
    (should (equal lines '("        " "  a     " "    b   " "        ")))
    (dolist (n '(0 1 2 3))
      (let ((pos (mdview-render-test--line-pos text n)))
        (should (equal (mdview-render-test--faces text pos) '(mdview-code-block)))
        (should (equal (mdview-render-test--faces text (+ pos 7)) '(mdview-code-block)))))))

(ert-deftest mdview-render-code-block-background-under-token-face ()
  (let* ((text (cl-letf (((symbol-function 'mdview-code-fontify)
                          (lambda (code _lang)
                            (propertize code 'face 'font-lock-keyword-face))))
                 (mdview-render-test--render
                  (mdview-render-test--doc (mdview-node 'code-block '(:lang "x") "kw"))
                  8)))
         (pos (+ (mdview-render-test--line-pos text 1) 2)))
    (should (equal (mdview-render-test--faces text pos)
                   '(font-lock-keyword-face mdview-code-block)))
    (should (equal (mdview-render-test--faces text (- pos 1)) '(mdview-code-block)))))

(ert-deftest mdview-render-code-block-overlong-line-not-truncated ()
  (let ((lines (cl-letf (((symbol-function 'mdview-code-fontify)
                          (lambda (code _lang) code)))
                 (mdview-render-test--lines
                  (mdview-render-test--doc (mdview-node 'code-block nil "0123456789abcdef"))
                  8))))
    (should (equal (nth 1 lines) "  0123456789abcdef"))
    (should (equal (nth 0 lines) "        "))))

(ert-deftest mdview-render-code-block-indent-guides-invoked ()
  (let ((seen nil))
    (cl-letf (((symbol-function 'mdview-code-fontify) (lambda (code _lang) code))
              ((symbol-function 'mdview-code-indent-guides)
               (lambda (line) (push line seen) (concat "G" line))))
      (should (equal (mdview-render-test--lines
                      (mdview-render-test--doc (mdview-node 'code-block nil "a\n\tb"))
                      10)
                     '("          " "  Ga      " "  G    b  " "          ")))
      (should (equal (nreverse seen) '("a" "    b"))))))

(ert-deftest mdview-render-code-block-fontify-error-falls-back ()
  (cl-letf (((symbol-function 'mdview-code-fontify)
             (lambda (_code _lang) (error "Boom"))))
    (should (equal (mdview-render-test--lines
                    (mdview-render-test--doc (mdview-node 'code-block '(:lang "zz") "ok"))
                    6)
                   '("      " "  ok  " "      ")))))

;;;; Tables

(ert-deftest mdview-render-table-box-with-stubbed-layout ()
  (let ((table (mdview-node 'table '(:align (nil nil))
                            (mdview-node 'table-row '(:header t)
                                         (mdview-node 'table-cell nil "A")
                                         (mdview-node 'table-cell nil (mdview-node 'strong nil "B")))
                            (mdview-node 'table-row nil
                                         (mdview-node 'table-cell nil "1")
                                         (mdview-node 'table-cell nil "2"))))
        (args nil))
    (cl-letf (((symbol-function 'mdview-table-layout)
               (lambda (node inner render-cell wrap &rest _)
                 (setq args (list node inner wrap))
                 (list (truncate-string-to-width
                        (mapconcat render-cell
                                   (mdview-node-children (car (mdview-node-children node)))
                                   " ")
                        inner nil ?\s)
                       (make-string inner ?-)))))
      (let* ((text (mdview-render-test--render (mdview-render-test--doc table) 12))
             (lines (butlast (split-string (substring-no-properties text) "\n"))))
        (should (eq (nth 0 args) table))
        (should (= (nth 1 args) 8))
        (should (eq (nth 2 args) #'mdview-wrap))
        (should (equal lines (list (mdview-render-test--glyph-row 'box-top 12)
                                   (concat (mdview-glyph 'box-left) "          " (mdview-glyph 'box-right))
                                   (concat (mdview-glyph 'box-left) " A B      " (mdview-glyph 'box-right))
                                   (concat (mdview-glyph 'box-left) " -------- " (mdview-glyph 'box-right))
                                   (concat (mdview-glyph 'box-left) "          " (mdview-glyph 'box-right))
                                   (mdview-render-test--glyph-row 'box-bottom 12))))
        (let ((row (mdview-render-test--line-pos text 2)))
          (should (equal (mdview-render-test--faces text row) '(mdview-box-frame mdview-table)))
          (should (equal (mdview-render-test--faces text (+ row 2)) '(mdview-table)))
          (should (equal (mdview-render-test--faces text (+ row 4)) '(mdview-strong mdview-table))))))))

(ert-deftest mdview-render-table-cells-never-insert-images ()
  (let ((calls 0)
        (table (mdview-node 'table '(:align (nil))
                            (mdview-node 'table-row '(:header t)
                                         (mdview-node 'table-cell nil
                                                      (mdview-node 'image '(:url "a.png" :alt "pic")))))))
    (cl-letf (((symbol-function 'mdview-image-insert)
               (lambda (&rest _) (setq calls (1+ calls)) (cons 1 'image)))
              ((symbol-function 'mdview-table-layout)
               (lambda (node inner render-cell _wrap &rest _)
                 (list (truncate-string-to-width
                        (funcall render-cell (car (mdview-node-children
                                                   (car (mdview-node-children node)))))
                        inner nil ?\s)))))
      (let ((lines (mdview-render-test--lines (mdview-render-test--doc table) 20)))
        (should (= calls 0))
        (should (string-search "pic" (nth 2 lines)))))))

;;;; Images

(defmacro mdview-render-test--with-image-stub (seen &rest body)
  "Run BODY with `mdview-image-insert' stubbed, pushing its arguments onto SEEN."
  (declare (indent 1))
  `(cl-letf (((symbol-function 'mdview-image-insert)
              (cl-function
               (lambda (url alt &key base-dir max-width-px max-height-px inline
                            &allow-other-keys)
                 (ignore base-dir max-height-px)
                 (push (list url alt inline max-width-px) ,seen)
                 (insert (propertize (concat "[" alt "]") 'display '(image :type xpm)))
                 (cons 12 'image)))))
     ,@body))

(ert-deftest mdview-render-images-get-text-measures ()
  "The column width and image scale of the caller reach every image."
  (let (seen)
    (cl-letf (((symbol-function 'mdview-image-insert)
               (cl-function
                (lambda (url _alt &key max-width-px scale char-width
                             &allow-other-keys)
                  (push (list url max-width-px scale char-width) seen)
                  (insert "[i]")
                  (cons 3 'image)))))
      (let ((doc (mdview-render-test--doc
                  (mdview-node 'paragraph '(:line 1)
                               (mdview-node 'image '(:url "block.png" :alt "b")))
                  (mdview-render-test--para
                   "see " (mdview-node 'image '(:url "inline.png" :alt "i"))))))
        (with-temp-buffer
          (mdview-render-document doc :width 40 :char-width 7 :image-scale 1.5))
        (should (equal (sort (copy-sequence seen)
                             (lambda (a b) (string< (car a) (car b))))
                       '(("block.png" 280 1.5 7) ("inline.png" 280 1.5 7))))
        ;; The defaults are the current buffer's measures: in batch no
        ;; column width, and text at its base size.
        (setq seen nil)
        (with-temp-buffer
          (mdview-render-document doc :width 40))
        (should (equal (mapcar #'cdr seen) '((nil 1.0 nil) (nil 1.0 nil))))))))

(ert-deftest mdview-render-block-image-detection ()
  (let ((calls nil))
    (mdview-render-test--with-image-stub calls
      (let* ((text (mdview-render-test--render
                    (mdview-render-test--doc
                     (mdview-node 'paragraph '(:line 3)
                                  (mdview-node 'image '(:url "a.png" :alt "pic"))))
                    30)))
        ;; one call with :inline nil; the line is padded using the returned 12 columns
        (should (equal calls '(("a.png" "pic" nil nil))))
        (should (equal text (concat "[pic]" (make-string 18 ?\s) "\n")))
        (should (eq (get-text-property 0 'mdview-source-line text) 3))))))

(ert-deftest mdview-render-block-image-in-link-gets-link-properties ()
  (let ((calls nil))
    (mdview-render-test--with-image-stub calls
      (let ((text (mdview-render-test--render
                   (mdview-render-test--doc
                    (mdview-render-test--para
                     (mdview-node 'link '(:url "https://x.org" :title "X")
                                  (mdview-node 'image '(:url "a.png" :alt "pic")))))
                   30)))
        (should (equal (mapcar #'caddr calls) '(nil)))
        (should (equal (get-text-property 0 'mdview-link text) "https://x.org"))
        (should (equal (get-text-property 4 'mdview-link-title text) "X"))))))

(ert-deftest mdview-render-inline-image-spliced-as-token ()
  (let ((calls nil))
    (mdview-render-test--with-image-stub calls
      (let* ((text (mdview-render-test--render
                    (mdview-render-test--doc
                     (mdview-render-test--para
                      "see " (mdview-node 'image '(:url "b.svg" :alt "tiny")) " here"))
                    30))
             (pos (string-search "[tiny]" text)))
        (should (equal calls '(("b.svg" "tiny" t nil))))
        ;; 4 + 12 + 5 = 21 columns of content, 9 of padding
        (should (equal (substring-no-properties text)
                       (concat "see [tiny] here" (make-string 9 ?\s) "\n")))
        (should (eq (get-text-property pos 'mdview-columns text) 12))
        (should (equal (get-text-property pos 'display text) '(image :type xpm)))))))

(ert-deftest mdview-render-image-caption ()
  (let ((calls nil) (mdview-image-captions t))
    (mdview-render-test--with-image-stub calls
      (let* ((text (mdview-render-test--render
                    (mdview-render-test--doc
                     (mdview-render-test--para
                      (mdview-node 'image '(:url "a.png" :alt "A caption"))))
                    20))
             (lines (butlast (split-string (substring-no-properties text) "\n"))))
        (should (equal (nth 1 lines) "A caption           "))
        (should (equal (mdview-render-test--faces text (mdview-render-test--line-pos text 1))
                       '(mdview-image-caption)))))))

;;;; HTML

(ert-deftest mdview-render-html-block-strips-tags ()
  (should (equal (mdview-render-test--lines
                  (mdview-render-test--doc
                   (mdview-node 'html-block nil
                                "<div>\n  <b>Raw</b> &amp; <i>html</i>\n</div>\n<!-- gone --><script>x()</script><style>p{}</style>"))
                  12)
                 '("Raw & html  ")))
  ;; align="center" centers the text too (one spare column goes right).
  (should (equal (mdview-render-test--lines
                  (mdview-render-test--doc
                   (mdview-node 'html-block nil
                                "<div align=\"center\">\n  <b>Raw</b> &amp; <i>html</i>\n</div>"))
                  13)
                 '(" Raw & html  "))))

(ert-deftest mdview-render-html-block-img-br-hr ()
  (let ((calls nil))
    (mdview-render-test--with-image-stub calls
      (let ((lines (mdview-render-test--lines
                    (mdview-render-test--doc
                     (mdview-node 'html-block '(:line 9)
                                  "<p>one<br>two</p><hr><p align=\"center\"><img src=\"i.png\" alt=\"Pic\"></p>"))
                    20)))
        (should (equal lines (list "one                 " "two                 "
                                   "                    " "                    "
                                   (mdview-render-test--glyph-row 'rule 20)
                                   "                    "
                                   ;; 4 + 12 image columns + 4
                                   "    [Pic]    ")))
        (should (equal calls '(("i.png" "Pic" nil nil))))))))

(ert-deftest mdview-render-inline-html-stripped ()
  (let ((calls nil))
    (mdview-render-test--with-image-stub calls
      (should (equal (mdview-render-test--lines
                      (mdview-render-test--doc
                       (mdview-render-test--para
                        "Press " (mdview-node 'html-inline nil "<kbd>") "C"
                        (mdview-node 'html-inline nil "</kbd>") " then"
                        (mdview-node 'html-inline nil "<br/>") "go "
                        (mdview-node 'html-inline nil "<img src=\"z.png\" alt=\"z\">")
                        (mdview-node 'html-inline nil "<!-- c -->")))
                      20)
                     ;; the image token counts as 12 columns
                     '("Press C then        " "go [z]     ")))
      (should (equal calls '(("z.png" "z" t nil)))))))

(ert-deftest mdview-render-html-block-shr ()
  (skip-unless (fboundp 'libxml-parse-html-region))
  (let* ((mdview-html-renderer 'shr)
         (lines (mdview-render-test--lines
                 (mdview-render-test--doc
                  (mdview-node 'html-block nil "<p>Hello <b>world</b></p>")
                  (mdview-render-test--para "after"))
                 20)))
    (should (string-prefix-p "Hello world" (car lines)))
    (should (mdview-render-test--all-widths lines 20))
    (should (equal (car (last lines)) "after               "))))

;;;; Footnotes

(ert-deftest mdview-render-footnotes-section ()
  (let* ((doc (mdview-node 'document
                           (list :refs nil
                                 :footnotes
                                 (list (mdview-node 'footnote-definition '(:label "a" :index 1 :line 5)
                                                    (mdview-render-test--para "first note text"))
                                       (mdview-node 'footnote-definition '(:label "b" :index 2)
                                                    (mdview-render-test--para "second"))))
                           (mdview-render-test--para "body")))
         (text (mdview-render-test--render doc 14))
         (lines (butlast (split-string (substring-no-properties text) "\n"))))
    (should (equal lines (list "body          " "              "
                               (mdview-render-test--glyph-row 'thin-rule 14)
                               "[1] first note" "    text      " "[2] second    ")))
    (let ((rule (mdview-render-test--line-pos text 2))
          (def (mdview-render-test--line-pos text 3)))
      (should (equal (mdview-render-test--faces text rule) '(mdview-rule)))
      (should (eq (get-text-property def 'mdview-footnote-def text) 1))
      (should (equal (mdview-render-test--faces text def) '(mdview-footnote-ref)))
      (should (eq (get-text-property def 'mdview-source-line text) 5)))))

(ert-deftest mdview-render-footnote-reference ()
  (let ((text (mdview-render-inlines
               (list "x" (mdview-node 'footnote-reference '(:label "n" :index 3))))))
    (should (equal (substring-no-properties text) "x[3]"))
    (should (eq (get-text-property 1 'mdview-footnote-ref text) 3))
    (should (equal (mdview-render-test--faces text 2) '(mdview-footnote-ref)))
    (should (eq (not (display-graphic-p)) (null (get-text-property 1 'display text))))))

;;;; Inline rendering

(ert-deftest mdview-render-link-properties ()
  (let ((text (mdview-render-inlines
               (list (mdview-node 'link '(:url "https://e.com" :title "T") "go " (mdview-node 'strong nil "now"))))))
    (should (equal (substring-no-properties text) "go now"))
    (should (equal (mdview-render-test--faces text 0) '(mdview-link)))
    (should (equal (mdview-render-test--faces text 4) '(mdview-strong mdview-link)))
    (should (equal (get-text-property 2 'mdview-link text) "https://e.com"))
    (should (equal (get-text-property 2 'mdview-link-title text) "T"))
    (should (equal (get-text-property 2 'help-echo text) "https://e.com"))
    (should (eq (get-text-property 2 'mouse-face text) 'highlight))
    (should (eq (get-text-property 2 'follow-link text) t))))

(ert-deftest mdview-render-autolink-and-empty-link-text ()
  (let ((text (mdview-render-inlines
               (list (mdview-node 'link '(:url "https://a.b" :autolink t) "https://a.b")
                     " " (mdview-node 'link '(:url "https://c.d"))))))
    (should (equal (substring-no-properties text) "https://a.b https://c.d"))
    (should (equal (get-text-property 0 'mdview-link text) "https://a.b"))
    (should (equal (get-text-property 12 'mdview-link text) "https://c.d"))
    (should (null (get-text-property 11 'mdview-link text)))))

(ert-deftest mdview-render-emphasis-nesting-combines-faces ()
  (let ((text (mdview-render-inlines
               (list (mdview-node 'strong nil "b" (mdview-node 'emphasis nil "bi") "b")
                     (mdview-node 'strikethrough nil "s")
                     (mdview-node 'code nil "c")))))
    (should (equal (substring-no-properties text) "bbibsc"))
    (should (equal (mdview-render-test--faces text 0) '(mdview-strong)))
    (should (equal (mdview-render-test--faces text 1) '(mdview-emphasis mdview-strong)))
    (should (equal (mdview-render-test--faces text 4) '(mdview-strikethrough)))
    (should (equal (mdview-render-test--faces text 5) '(mdview-inline-code)))))

(ert-deftest mdview-render-breaks-and-nil-context ()
  (should (equal (mdview-render-inlines (list "a" (mdview-node 'soft-break nil) "b"
                                              (mdview-node 'hard-break nil) "c"))
                 "a b\nc"))
  (should (equal (mdview-render-inlines nil) "")))

;;;; Whole-document properties

(ert-deftest mdview-render-source-line-properties ()
  (let* ((text (mdview-render-test--render
                (mdview-render-test--doc
                 (mdview-node 'paragraph '(:line 1) "p")
                 (mdview-node 'list '(:ordered nil :tight t :marker ?- :line 3)
                              (mdview-node 'item '(:line 3) (mdview-node 'paragraph '(:line 3) "a"))
                              (mdview-node 'item '(:line 4) (mdview-node 'paragraph '(:line 4) "b")))
                 (mdview-node 'blockquote '(:line 6) (mdview-node 'paragraph '(:line 6) "q"))
                 (mdview-node 'code-block '(:line 8) "c"))
                10))
         (found nil)
         (pos 0))
    (while (< pos (length text))
      (let ((line (get-text-property pos 'mdview-source-line text)))
        (when line (push (cons pos line) found)))
      (setq pos (1+ pos)))
    (setq found (nreverse found))
    ;; one marker per block, each at the start of a line
    (should (equal (mapcar #'cdr found) '(1 3 4 6 8)))
    (dolist (entry found)
      (should (or (zerop (car entry)) (eq (aref text (1- (car entry))) ?\n))))))

(ert-deftest mdview-render-twice-is-identical ()
  (let* ((doc (mdview-render-test--doc
               (mdview-render-test--heading 1 "Title")
               (mdview-render-test--para "text " (mdview-node 'strong nil "bold")
                                         (mdview-node 'link '(:url "u") "l"))
               (mdview-render-test--list nil "a" "b")
               (mdview-node 'blockquote nil (mdview-render-test--para "q"))
               (mdview-node 'code-block nil "c")))
         (first (cl-letf (((symbol-function 'mdview-code-fontify) (lambda (c _) c)))
                  (mdview-render-test--render doc 30)))
         (second (cl-letf (((symbol-function 'mdview-code-fontify) (lambda (c _) c)))
                   (mdview-render-test--render doc 30))))
    (should (equal-including-properties first second))
    ;; the AST strings were not mutated by rendering
    (should (null (text-properties-at 0 (nth 2 (nth 1 (mdview-node-children doc))))))))

(ert-deftest mdview-render-column-discipline ()
  (let* ((width 37)
         (doc (mdview-render-test--doc
               (mdview-render-test--heading 1 "A long centered title that wraps around")
               (mdview-render-test--heading 2 "H2")
               (mdview-render-test--heading 3 "H3")
               (mdview-render-test--para "日本語のテキスト and latin words mixed together for wrapping")
               (mdview-node 'blockquote nil
                            (mdview-render-test--list t "quoted item with enough words to wrap")
                            (mdview-node 'blockquote nil (mdview-render-test--para "inner")))
               (mdview-node 'list '(:ordered t :start 98 :tight nil :marker ?.)
                            (mdview-node 'item nil (mdview-render-test--para "x")
                                         (mdview-node 'code-block nil "code"))
                            (mdview-node 'item '(:task checked) (mdview-render-test--para "y")))
               (mdview-node 'thematic-break nil)
               (mdview-node 'html-block nil "<p>html</p>")))
         (lines (cl-letf (((symbol-function 'mdview-code-fontify) (lambda (c _) c)))
                  (mdview-render-test--lines doc width))))
    (should (> (length lines) 20))
    (should (mdview-render-test--all-widths lines width))))

;;;; Robustness and width discipline (review findings)

(ert-deftest mdview-render-deep-inline-nesting-does-not-exhaust-stack ()
  "Thousands of nested emphasis nodes render without `excessive-lisp-nesting'."
  (let ((node "a"))
    (dotimes (i 3000)
      (setq node (mdview-node (if (cl-evenp i) 'strong 'emphasis) nil node)))
    (let* ((max-lisp-eval-depth 1600)
           (text (mdview-render-test--render
                  (mdview-render-test--doc (mdview-render-test--para node)
                                           (mdview-node 'heading '(:level 1 :id "deep") node))
                  20)))
      (should (string-prefix-p "a" text))
      (should (memq 'mdview-strong (mdview-render-test--faces text 0)))
      (should (string-search "a" (substring text 20)))
      ;; The rendering must not leave the global limit changed.
      (should (= max-lisp-eval-depth 1600)))))

(ert-deftest mdview-render-tabs-are-spaces ()
  "Tabs in prose count as one column, so padding and centering stay exact."
  (should (equal (mdview-wrap "a\tb c" 10) '("a b c")))
  (let* ((bar (mdview-glyph 'quote-bar))
         (text (mdview-render-test--render
                (mdview-render-test--doc
                 (mdview-node 'blockquote nil (mdview-render-test--para "ab\tc"))
                 (mdview-render-test--heading 1 "a\tb")
                 (mdview-render-test--list t "a\tb"))
                20))
         (lines (butlast (split-string (substring-no-properties text) "\n"))))
    (should-not (string-search "\t" text))
    (should (equal (nth 0 lines) (concat bar " ab c              ")))
    (dolist (line lines)
      (should (= (string-width line) 20))
      (should (= (with-temp-buffer (insert line) (current-column)) 20)))))

(ert-deftest mdview-render-block-image-placeholder-wraps ()
  "A placeholder wider than the width wraps like a paragraph, link kept."
  (let* ((glyph (mdview-glyph 'image))
         (lines (mdview-render-test--lines
                 (mdview-render-test--doc
                  (mdview-render-test--para
                   (mdview-node 'image '(:url "x.png" :alt "a very long alternative text wider than twenty"))))
                 20)))
    (should (equal lines (list (concat glyph " a very long       ")
                               "alternative text    "
                               "wider than twenty   "))))
  ;; Inside a link and a quote: link properties and prefix on every line.
  (let* ((bar (mdview-glyph 'quote-bar))
         (text (mdview-render-test--render
                (mdview-render-test--doc
                 (mdview-node 'blockquote nil
                              (mdview-render-test--para
                               (mdview-node 'link '(:url "https://l")
                                            (mdview-node 'image '(:url "x.png" :alt "alternative text that is much longer than the quote"))))))
                20))
         (lines (butlast (split-string (substring-no-properties text) "\n"))))
    (should (> (length lines) 1))
    (dolist (line lines)
      (should (= (string-width line) 20))
      (should (string-prefix-p (concat bar " ") line)))
    (dotimes (n (length lines))
      (let ((pos (+ (mdview-render-test--line-pos text n) 2)))
        (should (equal (get-text-property pos 'mdview-link text) "https://l"))
        (should (memq 'mdview-quote (mdview-render-test--faces text pos)))))))

(ert-deftest mdview-render-block-image-placeholder-centered-wraps ()
  (let* ((glyph (mdview-glyph 'image))
         (lines (mdview-render-test--lines
                 (mdview-render-test--doc
                  (mdview-node 'paragraph '(:center t)
                               (mdview-node 'image '(:url "x.png" :alt "one two three four five six"))))
                 14)))
    ;; Every line is centered within 14 columns.
    (should (equal lines (list (concat "  " glyph " one two   ")
                               "  three four  "
                               "   five six   ")))))

(ert-deftest mdview-render-block-image-pending-is-truncated ()
  "A placeholder awaiting a remote image stays on one line, cut with an ellipsis."
  (cl-letf (((symbol-function 'mdview-image-insert)
             (cl-function
              (lambda (_url alt &key inline &allow-other-keys)
                (ignore inline)
                (insert (propertize (concat "[" alt "]") 'mdview-image-pending 7))
                (cons (+ 2 (length alt)) 'pending)))))
    (let* ((text (mdview-render-test--render
                  (mdview-render-test--doc
                   (mdview-render-test--para
                    (mdview-node 'image '(:url "https://r/i.png" :alt "a very long remote alt text"))))
                  12))
           (lines (butlast (split-string (substring-no-properties text) "\n"))))
      (should (= (length lines) 1))
      (should (= (string-width (car lines)) 12))
      (should (string-suffix-p "…" (car lines)))
      (should (eq (get-text-property 0 'mdview-image-pending text) 7))
      (should (eq (get-text-property 10 'mdview-image-pending text) 7)))))

(ert-deftest mdview-render-nesting-floor-keeps-width ()
  "Containers nested too deep for `mdview-min-content-width' render flat."
  (let ((bar (mdview-glyph 'quote-bar)))
    (cl-flet ((quotes (n) (let ((node (mdview-render-test--para "deep")))
                            (dotimes (_ n)
                              (setq node (mdview-node 'blockquote nil node)))
                            node))
              (bullets (n) (let ((node (mdview-render-test--para "deep")))
                             (dotimes (_ n)
                               (setq node (mdview-node 'list '(:ordered nil :tight t :marker ?-)
                                                       (mdview-node 'item nil node))))
                             node)))
      (dolist (width '(80 20))
        (dolist (doc (list (mdview-render-test--doc (quotes 17))
                           (mdview-render-test--doc (quotes 200))
                           (mdview-render-test--doc (bullets 40))))
          (let ((lines (mdview-render-test--lines doc width)))
            (should (= (length lines) 1))
            (should (= (string-width (car lines)) width))
            (should (string-search "deep" (car lines))))))
      ;; At width 20 the third quote level would leave 7 columns: it is flat
      ;; inside the second level, which keeps its bar and background.
      (let ((line (car (mdview-render-test--lines (mdview-render-test--doc (quotes 5)) 20))))
        (should (equal line (concat bar "   " bar " deep          ")))
        (should (= (cl-count (aref bar 0) line) 2)))
      ;; Lowering the floor restores deeper nesting.
      (let ((mdview-min-content-width 1))
        (should (= (cl-count (aref bar 0)
                             (car (mdview-render-test--lines (mdview-render-test--doc (quotes 3)) 20)))
                   3)))
      ;; A top-level container always nests, even at a tiny width.
      (should (equal (mdview-render-test--lines (mdview-render-test--doc (quotes 1)) 6)
                     (list (concat bar " dee ") (concat bar " p   ")))))))

(ert-deftest mdview-render-github-alerts ()
  (let* ((bar (mdview-glyph 'quote-bar))
         (text (mdview-render-test--render
                (mdview-render-test--doc
                 (mdview-node 'blockquote '(:line 1)
                              (mdview-node 'paragraph nil "[!TIP]" (mdview-node 'soft-break nil)
                                           "Textual is async."))
                 (mdview-node 'blockquote nil
                              (mdview-node 'paragraph nil "[!note]  " (mdview-node 'hard-break nil)
                                           "hard"))
                 (mdview-node 'blockquote nil (mdview-node 'paragraph nil "[!WARNING]"))
                 (mdview-node 'blockquote nil
                              (mdview-node 'paragraph nil "[!IMPORTANT]\nsame string"))
                 (mdview-node 'blockquote nil
                              (mdview-node 'paragraph nil "[!CAUTION] same line"))
                 (mdview-node 'blockquote nil (mdview-node 'paragraph nil "[!BOGUS]")))
                24))
         (lines (butlast (split-string (substring-no-properties text) "\n")))
         (blank (make-string 24 ?\s)))
    (cl-flet ((q (content)            ; a quote line at width 24: bar, text, pad, suffix
                (concat bar " " content (make-string (- 21 (string-width content)) ?\s) " ")))
      (should (equal lines
                     (list (q (concat (mdview-glyph 'alert-tip) " Tip"))
                           (q "Textual is async.") blank
                           (q (concat (mdview-glyph 'alert-note) " Note"))
                           (q "hard") blank
                           (q (concat (mdview-glyph 'alert-warning) " Warning")) blank
                           (q (concat (mdview-glyph 'alert-important) " Important"))
                           (q "same string") blank
                           (q "[!CAUTION] same line") blank
                           (q "[!BOGUS]")))))
    ;; Bar, icon and title carry the alert face; the body does not.
    (should (equal (mdview-render-test--faces text 0) '(mdview-alert-tip mdview-quote)))
    (should (equal (mdview-render-test--faces text 2) '(mdview-alert-tip mdview-quote)))
    (should (equal (mdview-render-test--faces text 4)
                   '(mdview-strong mdview-alert-tip mdview-quote)))
    (let ((body (+ (mdview-render-test--line-pos text 1) 2)))
      (should (equal (mdview-render-test--faces text body) '(mdview-quote))))
    (should (eq (get-text-property 0 'mdview-source-line text) 1))
    ;; An ordinary quote keeps the border face.
    (should (equal (mdview-render-test--faces text (mdview-render-test--line-pos text 11))
                   '(mdview-quote-border mdview-quote)))))

(ert-deftest mdview-render-html-block-level-tags-separate-paragraphs ()
  (should (equal (mdview-render-test--lines
                  (mdview-render-test--doc
                   (mdview-node 'html-block nil "<p>First.</p>\n<p>Second.</p>\n<div><b>Third</b></div><li>a</li><li>b</li>"))
                  10)
                 '("First.    " "          " "Second.   " "          " "Third     "
                   "          " "a         " "          " "b         ")))
  ;; Table cells only separate words.
  (should (equal (mdview-render-test--lines
                  (mdview-render-test--doc
                   (mdview-node 'html-block nil "<table><tr><td>a</td><td>b</td></tr></table>"))
                  5)
                 '("a b  "))))

(ert-deftest mdview-render-html-headings-become-headings ()
  (let* ((text (mdview-render-test--render
                (mdview-render-test--doc
                 (mdview-node 'html-block '(:line 4) "<h2 align=\"center\">Project Title</h2>\n<h4>Sub heading</h4>"))
                20))
         (lines (butlast (split-string (substring-no-properties text) "\n"))))
    (should (= (length lines) 7))
    (should (equal (nth 0 lines) (mdview-render-test--glyph-row 'box-top 20)))
    (should (equal (nth 2 lines) (concat (mdview-glyph 'box-left) "  Project Title   "
                                         (mdview-glyph 'box-right))))
    (should (equal (nth 6 lines) "Sub heading         "))
    (let ((pos (+ (mdview-render-test--line-pos text 2) 4)))
      (should (eq (get-text-property pos 'mdview-heading-level text) 2))
      (should (equal (get-text-property pos 'mdview-heading-id text) "project-title")))
    (should (equal (mdview-render-test--faces text (mdview-render-test--line-pos text 6))
                   '(mdview-h4)))
    (should (eq (get-text-property 0 'mdview-source-line text) 4))))

(ert-deftest mdview-render-trailing-hard-break-adds-nothing ()
  (should (equal (mdview-render-test--lines
                  (mdview-render-test--doc
                   (mdview-render-test--para "Trailing" (mdview-node 'html-inline nil "<br>"))
                   (mdview-render-test--para "Next" (mdview-node 'hard-break nil)
                                             (mdview-node 'hard-break nil))
                   (mdview-node 'html-block nil "<br>")
                   (mdview-node 'html-block nil "Mid<br><br>double."))
                  10)
                 (list "Trailing  " "          " "Next      " "          "
                       "Mid       " "          " "double.   ")))
  ;; A heading ending in a real break has no empty row.
  (should (equal (mdview-render-test--lines
                  (mdview-render-test--doc
                   (mdview-node 'heading '(:level 4) "H4" (mdview-node 'hard-break nil)))
                  6)
                 '("H4    "))))

(ert-deftest mdview-render-ascii-task-markers-share-content-column ()
  (let ((mdview-use-ascii-glyphs t))
    (should (equal (mdview-render-test--lines
                    (mdview-render-test--doc
                     (mdview-node 'list '(:ordered nil :tight t :marker ?-)
                                  (mdview-node 'item '(:task unchecked) (mdview-render-test--para "task"))
                                  (mdview-node 'item '(:task checked) (mdview-render-test--para "done"))
                                  (mdview-node 'item nil (mdview-render-test--para "plain")
                                               (mdview-node 'list '(:ordered nil :tight t :marker ?-)
                                                            (mdview-node 'item nil (mdview-render-test--para "nested"))))))
                    20)
                   '("[ ] task            " "[x] done            " "*   plain           "
                     "    - nested        ")))
    ;; Ordered lists pad the plain numbers to the task-item marker.
    (should (equal (mdview-render-test--lines
                    (mdview-render-test--doc
                     (mdview-node 'list '(:ordered t :start 1 :tight t :marker ?.)
                                  (mdview-node 'item nil (mdview-render-test--para "one"))
                                  (mdview-node 'item '(:task checked) (mdview-render-test--para "two"))))
                    12)
                   '(" 1.     one " " 2. [x] two "))))
  ;; The Unicode profile is unchanged: all markers are two columns.
  (should (equal (mdview-render-test--lines
                  (mdview-render-test--doc
                   (mdview-node 'list '(:ordered nil :tight t :marker ?-)
                                (mdview-node 'item '(:task unchecked) (mdview-render-test--para "task"))
                                (mdview-node 'item nil (mdview-render-test--para "plain"))))
                  8)
                 (list (concat (mdview-glyph 'task-unchecked) " task  ")
                       (concat (mdview-glyph 'bullet-1) " plain ")))))

(ert-deftest mdview-render-html-align-center-centers-text ()
  (let ((glyph (mdview-glyph 'image)))
    (should (equal (mdview-render-test--lines
                    (mdview-render-test--doc
                     (mdview-node 'html-block nil
                                  (concat "<p align=\"center\"><i>Installing deps.</i></p>\n"
                                          "<div align=\"center\"><img src=\"c.png\" alt=\"Awesome\"><br></div>\n"
                                          "<p align=\"center\"><a href=\"x\"><img src=\"a.png\" alt=\"A\"></a> "
                                          "<a href=\"y\"><img src=\"b.png\" alt=\"B\"></a></p>\n"
                                          "<p>left</p>")))
                    20)
                   (list "  Installing deps.  "
                         "                    "
                         (concat "     " glyph " Awesome      ")
                         "                    "
                         (concat "      " glyph " A " glyph " B       ")
                         "                    "
                         "left                ")))))

(ert-deftest mdview-render-empty-paragraph-is-skipped ()
  "A paragraph that strips to nothing adds neither a line nor margins."
  (should (equal (mdview-render-test--lines
                  (mdview-render-test--doc
                   (mdview-render-test--para "A")
                   (mdview-render-test--para (mdview-node 'html-inline nil "<a name=\"x\">")
                                             (mdview-node 'html-inline nil "</a>"))
                   (mdview-render-test--para "   ")
                   (mdview-render-test--para "After"))
                  7)
                 '("A      " "       " "After  ")))
  ;; A container holding nothing visible still shows its marker line.
  (should (equal (mdview-render-test--lines
                  (mdview-render-test--doc
                   (mdview-render-test--list
                    t (mdview-node 'item nil
                                   (mdview-render-test--para (mdview-node 'html-inline nil "<a name=\"x\">")))))
                  5)
                 (list (concat (mdview-glyph 'bullet-1) "    ")))))

(ert-deftest mdview-render-details-summary-and-kbd ()
  (let* ((text (mdview-render-test--render
                (mdview-render-test--doc
                 (mdview-node 'html-block nil "<details>\n<summary> Demo </summary>\ntext\n</details>")
                 (mdview-render-test--para "Press " (mdview-node 'html-inline nil "<kbd>") "C-c"
                                           (mdview-node 'html-inline nil "</kbd>") " now")
                 (mdview-node 'html-block nil "<p>Press <kbd>M-x</kbd> then</p>"))
                20))
         (lines (butlast (split-string (substring-no-properties text) "\n"))))
    (should (equal lines (list (concat (mdview-glyph 'summary) " Demo              ")
                               "                    " "text                "
                               "                    " "Press C-c now       "
                               "                    " "Press M-x then      ")))
    (should (equal (mdview-render-test--faces text 0) '(mdview-summary)))
    (should (equal (mdview-render-test--faces text 3) '(mdview-summary)))
    (should (null (get-text-property (mdview-render-test--line-pos text 2) 'face text)))
    (let ((kbd (+ (mdview-render-test--line-pos text 4) 6)))
      (should (null (get-text-property (1- kbd) 'face text)))
      (should (equal (mdview-render-test--faces text kbd) '(mdview-inline-code)))
      (should (equal (mdview-render-test--faces text (+ kbd 2)) '(mdview-inline-code)))
      (should (null (get-text-property (+ kbd 3) 'face text))))
    (let ((kbd (+ (mdview-render-test--line-pos text 6) 6)))
      (should (equal (mdview-render-test--faces text kbd) '(mdview-inline-code)))
      (should (null (get-text-property (+ kbd 3) 'face text))))))

(ert-deftest mdview-render-spacer-images-vanish ()
  (should (equal (mdview-render-test--render
                  (mdview-render-test--doc
                   (mdview-node 'html-block nil "<img src=\"https://img.spacergif.org/spacer.gif\" width=\"1\" height=\"64\"/>"))
                  10)
                 ""))
  (should (equal (mdview-render-test--lines
                  (mdview-render-test--doc
                   (mdview-render-test--para
                    "a" (mdview-node 'html-inline nil "<img src=\"x/spacer.gif\">")
                    "b" (mdview-node 'html-inline nil "<img src=\"y.png\" height=\"2px\" alt=\"tiny\">")
                    "c " (mdview-node 'html-inline nil "<img src=\"z.png\" width=\"100\" alt=\"real\">")))
                  14)
                 (list (concat "abc " (mdview-glyph 'image) " real    ")))))

(ert-deftest mdview-render-nested-list-in-loose-item-separated-from-next-block ()
  (let ((bullet (mdview-glyph 'bullet-1)) (sub (mdview-glyph 'bullet-2)))
    (should (equal (mdview-render-test--lines
                    (mdview-render-test--doc
                     (mdview-node 'list '(:ordered nil :tight nil :marker ?-)
                                  (mdview-node 'item nil
                                               (mdview-render-test--para "one")
                                               (mdview-render-test--list t "a" "b")
                                               (mdview-render-test--para "after"))
                                  (mdview-node 'item nil (mdview-render-test--para "two"))))
                    20)
                   (list (concat bullet " one               ") (make-string 20 ?\s)
                         (concat "  " sub " a               ") (concat "  " sub " b               ")
                         (make-string 20 ?\s) "  after             " (make-string 20 ?\s)
                         (concat bullet " two               "))))
    ;; Tight items keep nested lists glued to their neighbours.
    (should (equal (mdview-render-test--lines
                    (mdview-render-test--doc
                     (mdview-node 'list '(:ordered nil :tight t :marker ?-)
                                  (mdview-node 'item nil
                                               (mdview-render-test--para "one")
                                               (mdview-render-test--list t "a")
                                               (mdview-render-test--para "after"))))
                    20)
                   (list (concat bullet " one               ") (concat "  " sub " a               ")
                         "  after             ")))))

(ert-deftest mdview-render-placeholder-is-not-split-across-lines ()
  (let* ((glyph (mdview-glyph 'image))
         (badge (lambda (alt) (mdview-node 'image (list :url "b.png" :alt alt)))))
    ;; The placeholder moves to the next line as a whole ...
    (should (equal (mdview-wrap (mdview-render-inlines
                                 (list "word " (funcall badge "Guide to Markdown")))
                                16)
                   (list "word" (concat glyph " Guide to") "Markdown")))
    (should (equal (mdview-wrap (mdview-render-inlines
                                 (list (funcall badge "A badge") " " (funcall badge "B badge")))
                                15)
                   (list (concat glyph " A badge") (concat glyph " B badge"))))
    ;; ... and stays whole when it fits.
    (should (equal (mdview-wrap (mdview-render-inlines
                                 (list "word " (funcall badge "Guide to Markdown")))
                                30)
                   (list (concat "word " glyph " Guide to Markdown"))))
    (should (eq (get-text-property 0 'mdview-nobreak
                                   (mdview-render-inlines (list (funcall badge "x"))))
                t))))

(ert-deftest mdview-render-resolves-glyph-profile-once ()
  (let ((probes 0))
    (cl-letf (((symbol-function 'mdview-faces-ascii-p)
               (lambda () (setq probes (1+ probes)) nil)))
      (mdview-render-test--render
       (mdview-render-test--doc (mdview-render-test--list t "a" "b" "c")
                                (mdview-node 'blockquote nil (mdview-render-test--para "q"))
                                (mdview-node 'thematic-break nil))
       20)
      (should (= probes 1)))))

(provide 'mdview-render-test)
;;; mdview-render-test.el ends here
