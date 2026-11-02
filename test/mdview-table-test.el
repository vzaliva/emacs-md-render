;;; mdview-table-test.el --- Tests for mdview-table  -*- lexical-binding: t; -*-

;; This file is part of mdview, distributed under the MIT license; see
;; LICENSE in the repository root.

;;; Commentary:

;; ERT tests for the table layout in mdview-table.el (docs/DESIGN.md §6
;; "Tables", §13, §15).  Cells are rendered by a plain-text cell renderer
;; and wrapped by a simple greedy wrapper, both defined here, so the tests
;; do not depend on mdview-render.el.  All tests run headless.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'mdview-ast)
(require 'mdview-faces)
(require 'mdview-table)

;;;; Helpers

(defun mdview-table-test--render-cell (cell)
  "Render CELL to its plain text.
Strings render as themselves; `strong' children get face `mdview-strong'
so that face combination in header cells can be checked."
  (if (stringp cell)
      cell
    (mapconcat (lambda (child)
                 (let ((text (mdview-node-text child)))
                   (if (and (consp child) (eq (mdview-node-type child) 'strong))
                       (propertize text 'face 'mdview-strong)
                     text)))
               (mdview-node-children cell) "")))

(defun mdview-table-test--wrap (string width)
  "Greedily wrap STRING into lines at most WIDTH columns wide.
Words are split on spaces and newlines; a word wider than WIDTH is broken
at WIDTH (wide characters are never split in two)."
  (let ((width (max width 1)) (lines nil) (line ""))
    (dolist (word (split-string string "[ \n]+" t))
      (while (> (string-width word) width)
        (unless (string= line "") (push line lines) (setq line ""))
        (let ((piece (truncate-string-to-width word width)))
          (when (string= piece "") (setq piece (substring word 0 1)))
          (push piece lines)
          (setq word (substring word (length piece)))))
      (cond ((string= word "") nil)
            ((string= line "") (setq line word))
            ((<= (+ (string-width line) 1 (string-width word)) width)
             (setq line (concat line " " word)))
            (t (push line lines) (setq line word))))
    (nreverse (cons line lines))))

(defun mdview-table-test--row (cells &optional header)
  "Make a `table-row' node from CELLS; HEADER non-nil marks the header row.
Each element of CELLS is a string (one text child), a list of inline
children, or the keyword `:nil' for a literally nil cell."
  (apply #'mdview-node 'table-row (and header '(:header t))
         (mapcar (lambda (cell)
                   (cond ((eq cell :nil) nil)
                         ((stringp cell) (mdview-node 'table-cell nil cell))
                         (t (apply #'mdview-node 'table-cell nil cell))))
                 cells)))

(defun mdview-table-test--table (align header &rest rows)
  "Make a `table' node with ALIGN, a HEADER row and body ROWS.
HEADER and each of ROWS are lists of cells as for `mdview-table-test--row'."
  (apply #'mdview-node 'table (list :align align :line 1)
         (mdview-table-test--row header t)
         (mapcar #'mdview-table-test--row rows)))

(defun mdview-table-test--layout (table width &rest keys)
  "Lay out TABLE at inner WIDTH with the test cell renderer and wrapper.
KEYS are passed on to `mdview-table-layout'."
  (apply #'mdview-table-layout table width
         #'mdview-table-test--render-cell #'mdview-table-test--wrap keys))

(defun mdview-table-test--check-widths (lines width)
  "Assert that every line in LINES has `string-width' exactly WIDTH."
  (should lines)
  (dolist (line lines)
    (should (= (string-width line) width))))

(defun mdview-table-test--spaces (n)
  "Return a string of N spaces."
  (make-string n ?\s))

(defun mdview-table-test--line (&rest parts)
  "Concatenate PARTS; an integer part stands for that many spaces."
  (mapconcat (lambda (part) (if (integerp part) (mdview-table-test--spaces part) part))
             parts ""))

(defun mdview-table-test--faces-at (string pos)
  "Return the faces of STRING at POS as a list."
  (let ((face (get-text-property pos 'face string)))
    (if (listp face) face (list face))))

(defconst mdview-table-test-abc
  (mdview-table-test--table nil
                            '("Column A" "Column B" "Column C")
                            '("left" "center" "right")
                            '("a longer cell value" "x" "12345.67"))
  "The three-column table of the design document, without alignment.")

(defconst mdview-table-test-abc-aligned
  (mdview-table-test--table '(left center right)
                            '("Column A" "Column B" "Column C")
                            '("left" "center" "right")
                            '("a longer cell value" "x" "12345.67"))
  "The three-column table of the design document, with alignment.")

(defconst mdview-table-test-shrink
  (mdview-table-test--table nil
                            '("Name" "Description")
                            '("Emacs" "An extensible, customizable, free/libre text editor, and more."))
  "A table whose description column must shrink and wrap at inner width 30.")

(defconst mdview-table-test-long-word
  (mdview-table-test--table nil
                            '("A" "B")
                            '("Supercalifragilisticexpialidocious" "short words here and more"))
  "A table with an unbreakable 34-column word in the first column.")

(defconst mdview-table-test-cjk
  (mdview-table-test--table nil
                            '("名前" "説明")
                            '("日本語" "テキスト"))
  "A table whose cells are wide (double-column) characters.")

;;;; Arithmetic helpers

(ert-deftest mdview-table-round-half-even ()
  (should (= (mdview-table--round-half-even 5 2) 2))   ; 2.5 -> 2
  (should (= (mdview-table--round-half-even 7 2) 4))   ; 3.5 -> 4
  (should (= (mdview-table--round-half-even 3 2) 2))   ; 1.5 -> 2
  (should (= (mdview-table--round-half-even 1 2) 0))   ; 0.5 -> 0
  (should (= (mdview-table--round-half-even 11 2) 6))  ; 5.5 -> 6
  (should (= (mdview-table--round-half-even 10 3) 3))
  (should (= (mdview-table--round-half-even 20 3) 7))
  (should (= (mdview-table--round-half-even 4 2) 2))
  (should (= (mdview-table--ceil-div 0 5) 0))
  (should (= (mdview-table--ceil-div 10 5) 2))
  (should (= (mdview-table--ceil-div 11 5) 3)))

(ert-deftest mdview-table-ratio-distribute-matches-rich ()
  "Sequential-ceiling distribution exactly as Rich's `ratio_distribute'."
  (should (equal (mdview-table--ratio-distribute 23 '(19 8 8)) '(13 5 5)))
  (should (equal (mdview-table--ratio-distribute 57 '(19 8 8)) '(31 13 13)))
  (should (equal (mdview-table--ratio-distribute 59 '(19 8 8)) '(33 13 13)))
  (should (equal (mdview-table--ratio-distribute 75 '(9 9)) '(38 37)))
  (should (equal (mdview-table--ratio-distribute 0 '(1 2)) '(0 0)))
  (should (equal (mdview-table--ratio-distribute 5 '(1)) '(5))))

(ert-deftest mdview-table-ratio-distribute-sums-exactly ()
  (dolist (ratios '((7 3 11 1) (1 1 1) (50 1) (0 4 0 6) (2)))
    (dotimes (total 60)
      (let ((parts (mdview-table--ratio-distribute total ratios)))
        (should (= (length parts) (length ratios)))
        (should (= (apply #'+ parts) total))
        (should (cl-every (lambda (p) (>= p 0)) parts))))))

(ert-deftest mdview-table-ratio-distribute-zero-ratios-split-evenly ()
  (should (equal (mdview-table--ratio-distribute 5 '(0 0)) '(3 2)))
  (should (equal (mdview-table--ratio-distribute 6 '(0 0 0)) '(2 2 2)))
  (should (equal (mdview-table--ratio-distribute 4 nil) nil)))

(ert-deftest mdview-table-ratio-reduce-matches-rich ()
  (should (equal (mdview-table--ratio-reduce 11 '(1 1) '(11 11) '(25 25)) '(19 20)))
  ;; A slot with maximum 0 does not take part.
  (should (equal (mdview-table--ratio-reduce 4 '(1 1) '(0 10) '(5 5)) '(5 1)))
  ;; Caps limit what a slot gives up; the rest is left over.
  (should (equal (mdview-table--ratio-reduce 10 '(1 1) '(2 2) '(9 9)) '(7 7)))
  ;; All ratios zero: nothing changes.
  (should (equal (mdview-table--ratio-reduce 3 '(0 0) '(5 5) '(4 4)) '(4 4))))

;;;; Column widths

(ert-deftest mdview-table-collapse-reduces-widest-towards-next ()
  (should (equal (mdview-table--collapse '(50 20 10) '(3 3 3) 70) '(40 20 10)))
  (should (equal (mdview-table--collapse '(30 20 10) '(25 3 3) 40) '(25 8 7)))
  ;; Equal columns share the reduction with Python's round-half-even.
  (should (equal (mdview-table--collapse '(25 25) '(1 1) 39) '(19 20)))
  ;; Nothing to do when it already fits.
  (should (equal (mdview-table--collapse '(5 5) '(1 1) 20) '(5 5))))

(ert-deftest mdview-table-collapse-respects-minimums ()
  (should (equal (mdview-table--collapse '(34 25) '(34 5) 39) '(34 5)))
  ;; When the minimums do not fit the result stays above AVAILABLE.
  (should (equal (mdview-table--collapse '(19 19) '(19 19) 19) '(19 19)))
  (should (equal (mdview-table--collapse '(10 10) '(8 8) 10) '(8 8))))

(ert-deftest mdview-table-scale-minimums ()
  (should (equal (mdview-table--scale-minimums '(19 19) 19) '(10 9)))
  (should (equal (mdview-table--scale-minimums '(60 3) 39) '(37 2)))
  (should (equal (mdview-table--scale-minimums '(1 1 1) 3) '(1 1 1))))

(ert-deftest mdview-table-column-widths-strategies ()
  ;; Fits and expands.
  (should (equal (mdview-table--column-widths '(19 8 8) '(3 3 3) 58 t) '(32 13 13)))
  ;; Fits, no expansion.
  (should (equal (mdview-table--column-widths '(19 8 8) '(3 3 3) 58 nil) '(19 8 8)))
  ;; Does not fit: collapse (expand is irrelevant).
  (should (equal (mdview-table--column-widths '(9 90) '(4 9) 93 nil) '(9 84)))
  (should (equal (mdview-table--column-widths '(9 90) '(4 9) 93 t) '(9 84)))
  ;; Minimums do not fit: scaled.
  (should (equal (mdview-table--column-widths '(19 19) '(19 19) 19 t) '(10 9)))
  ;; Degenerate: one column each.
  (should (equal (mdview-table--column-widths '(5 5 5) '(3 3 3) 2 t) '(1 1 1))))

(ert-deftest mdview-table-measure-naturals-and-minimums ()
  (let ((measure (mdview-table--measure '(("Hello world" "ab" "x" "a b" "" "abcdefghij")
                                          ("hi" "" "yy" "" "" ""))
                                        6 6)))
    (should (equal (car measure) '(6 2 2 3 1 6)))   ; naturals, capped at 6
    (should (equal (cdr measure) '(5 2 2 3 1 6))))) ; minimums

;;;; Exact layouts

(ert-deftest mdview-table-expand-three-columns-width-60 ()
  (let ((lines (mdview-table-test--layout mdview-table-test-abc 60 :expand t)))
    (mdview-table-test--check-widths lines 60)
    (should (= (length lines) 4))
    ;; Natural widths 19 8 8, 2 separators, 23 spare -> 32 13 13.
    (should (equal (nth 0 lines)
                   (mdview-table-test--line "Column A" 24 " " "Column B" 5 " " "Column C" 5)))
    (should (equal (nth 2 lines)
                   (mdview-table-test--line "left" 28 " " "center" 7 " " "right" 8)))
    (should (equal (nth 3 lines)
                   (mdview-table-test--line "a longer cell value" 13 " " "x" 12 " "
                                            "12345.67" 5)))))

(ert-deftest mdview-table-no-expand-three-columns-width-60 ()
  (let ((lines (mdview-table-test--layout mdview-table-test-abc 60 :expand nil)))
    (mdview-table-test--check-widths lines 60)
    (should (equal (nth 0 lines)
                   (mdview-table-test--line "Column A" 11 " " "Column B" " " "Column C" 23)))
    (should (equal (nth 2 lines)
                   (mdview-table-test--line "left" 15 " " "center" 2 " " "right" 3 23)))
    (should (equal (nth 3 lines)
                   (mdview-table-test--line "a longer cell value" " " "x" 7 " "
                                            "12345.67" 23)))))

(ert-deftest mdview-table-expand-defcustom-is-the-default ()
  (let ((expanded (mdview-table-test--layout mdview-table-test-abc 60 :expand t))
        (natural (mdview-table-test--layout mdview-table-test-abc 60 :expand nil)))
    (should-not (equal expanded natural))
    (let ((mdview-table-expand nil))
      (should (equal (mdview-table-test--layout mdview-table-test-abc 60) natural))
      ;; An explicit key overrides the option.
      (should (equal (mdview-table-test--layout mdview-table-test-abc 60 :expand t)
                     expanded)))
    (let ((mdview-table-expand t))
      (should (equal (mdview-table-test--layout mdview-table-test-abc 60) expanded)))))

(ert-deftest mdview-table-matches-frogmouth-reference ()
  "The three showcase tables at Frogmouth's inner width (94 columns)."
  (let ((lines (mdview-table-test--layout mdview-table-test-abc 94)))
    (mdview-table-test--check-widths lines 94)
    (should (equal (nth 0 lines)
                   (mdview-table-test--line "Column A" 42 " " "Column B" 13 " " "Column C" 13)))
    (should (equal (nth 2 lines)
                   (mdview-table-test--line "left" 46 " " "center" 15 " " "right" 16)))
    (should (equal (nth 3 lines)
                   (mdview-table-test--line "a longer cell value" 31 " " "x" 20 " "
                                            "12345.67" 13))))
  (let ((lines (mdview-table-test--layout
                (mdview-table-test--table nil '("Feature" "Supported")
                                          '("Images" "yes") '("Tables" "yes")
                                          '("Footnotes" "partially"))
                94)))
    (mdview-table-test--check-widths lines 94)
    (should (equal (nth 0 lines)
                   (mdview-table-test--line "Feature" 40 " " "Supported" 37)))
    (should (equal (nth 2 lines) (mdview-table-test--line "Images" 41 " " "yes" 43)))
    (should (equal (nth 4 lines)
                   (mdview-table-test--line "Footnotes" 38 " " "partially" 37))))
  (let ((lines (mdview-table-test--layout
                (mdview-table-test--table
                 nil '("Name" "Description")
                 '("Frogmouth" "A Markdown browser for the terminal, built with Textual. It renders tables, code and more.")
                 '("Emacs" "An extensible, customizable, free/libre text editor, and more."))
                94)))
    (mdview-table-test--check-widths lines 94)
    (should (= (length lines) 5))
    (should (equal (nth 0 lines)
                   (mdview-table-test--line "Name" 5 " " "Description" 73)))
    (should (equal (nth 2 lines)
                   (mdview-table-test--line
                    "Frogmouth" " "
                    "A Markdown browser for the terminal, built with Textual. It renders tables, code and")))
    (should (equal (nth 3 lines) (mdview-table-test--line 9 " " "more." 79)))
    (should (equal (nth 4 lines)
                   (mdview-table-test--line
                    "Emacs" 4 " "
                    "An extensible, customizable, free/libre text editor, and more." 22)))))

;;;; Alignment

(ert-deftest mdview-table-alignment-left-center-right ()
  (let ((lines (mdview-table-test--layout mdview-table-test-abc-aligned 60)))
    (mdview-table-test--check-widths lines 60)
    ;; Widths 32 13 13: left pads right, center splits, right pads left.
    (should (equal (nth 2 lines)
                   (mdview-table-test--line "left" 28 " " 3 "center" 4 " " 8 "right")))
    (should (equal (nth 3 lines)
                   (mdview-table-test--line "a longer cell value" 13 " " 6 "x" 6 " "
                                            5 "12345.67")))))

(ert-deftest mdview-table-center-odd-space-goes-right ()
  (let ((lines (mdview-table-test--layout
                (mdview-table-test--table '(center) '("abcdefghij") '("zzz") '("yy"))
                10 :expand nil)))
    (should (equal (nth 2 lines) (mdview-table-test--line 3 "zzz" 4)))
    (should (equal (nth 3 lines) (mdview-table-test--line 4 "yy" 4)))))

(ert-deftest mdview-table-header-follows-alignment ()
  (let ((lines (mdview-table-test--layout mdview-table-test-abc-aligned 60)))
    (should (equal (nth 0 lines)
                   (mdview-table-test--line "Column A" 24 " " 2 "Column B" 3 " "
                                            5 "Column C")))))

(ert-deftest mdview-table-alignment-applies-to-wrapped-lines ()
  (let ((lines (mdview-table-test--layout
                (mdview-table-test--table '(nil right) '("K" "V")
                                          '("k" "one two three"))
                9)))
    ;; Available 8: naturals 1 13 -> capped 1 8, min 5 -> collapse to 1 7.
    (mdview-table-test--check-widths lines 9)
    (should (equal (nth 2 lines) (mdview-table-test--line "k" " " "one two")))
    (should (equal (nth 3 lines) (mdview-table-test--line " " " " 2 "three")))))

(ert-deftest mdview-table-short-or-missing-align-means-left ()
  (let ((short (mdview-table-test--layout
                (mdview-table-test--table '(right) '("A" "B") '("1" "2")) 7 :expand nil))
        (none (mdview-table-test--layout
               (mdview-table-test--table nil '("A" "B") '("1" "2")) 7 :expand nil)))
    (should (equal (nth 2 short) "1 2    "))
    (should (equal (nth 2 none) "1 2    "))))

;;;; Shrinking and wrapping

(ert-deftest mdview-table-shrinks-and-wraps-rows ()
  (let ((lines (mdview-table-test--layout mdview-table-test-shrink 30)))
    (mdview-table-test--check-widths lines 30)
    ;; Naturals 5 62 -> capped 5 29 -> collapsed to 5 24; three wrapped lines.
    (should (= (length lines) 5))
    (should (equal (nth 0 lines) (mdview-table-test--line "Name" 1 " " "Description" 13)))
    (should (equal (nth 2 lines) (mdview-table-test--line "Emacs" " " "An extensible," 10)))
    (should (equal (nth 3 lines) (mdview-table-test--line 5 " " "customizable, free/libre")))
    (should (equal (nth 4 lines) (mdview-table-test--line 5 " " "text editor, and more." 2)))))

(ert-deftest mdview-table-expand-nil-still-shrinks ()
  (should (equal (mdview-table-test--layout mdview-table-test-shrink 30 :expand nil)
                 (mdview-table-test--layout mdview-table-test-shrink 30 :expand t))))

(ert-deftest mdview-table-minimum-width-keeps-long-word-whole ()
  (let ((lines (mdview-table-test--layout mdview-table-test-long-word 40)))
    (mdview-table-test--check-widths lines 40)
    ;; Column 1 cannot go below its 34-column word; column 2 shrinks to 5.
    (should (= (length lines) 7))
    (should (equal (nth 0 lines) (mdview-table-test--line "A" 33 " " "B" 4)))
    (should (equal (nth 2 lines)
                   (mdview-table-test--line "Supercalifragilisticexpialidocious" " " "short")))
    (should (equal (nth 3 lines) (mdview-table-test--line 34 " " "words")))
    (should (equal (nth 4 lines) (mdview-table-test--line 34 " " "here" 1)))
    (should (equal (nth 5 lines) (mdview-table-test--line 34 " " "and" 2)))
    (should (equal (nth 6 lines) (mdview-table-test--line 34 " " "more" 1)))))

(ert-deftest mdview-table-scaled-minimums-break-words ()
  (let* ((word "abcdefghijklmnopqrstuvwxyz0123")
         (lines (mdview-table-test--layout
                 (mdview-table-test--table nil '("W1" "W2") (list word word))
                 20)))
    (mdview-table-test--check-widths lines 20)
    ;; Minimums 19 19 do not fit in 19: scaled to 10 9, words break.
    (should (= (length lines) 6))
    (should (equal (nth 0 lines) (mdview-table-test--line "W1" 8 " " "W2" 7)))
    (should (equal (nth 2 lines) "abcdefghij abcdefghi"))
    (should (equal (nth 3 lines) "klmnopqrst jklmnopqr"))
    (should (equal (nth 4 lines) "uvwxyz0123 stuvwxyz0"))
    (should (equal (nth 5 lines) (mdview-table-test--line 10 " " "123" 6)))))

(ert-deftest mdview-table-wrap-fn-called-only-for-overlong-cells ()
  (let ((calls nil))
    (cl-flet ((wrap (string width)
                (push (cons (substring-no-properties string) width) calls)
                (mdview-table-test--wrap string width)))
      (mdview-table-layout mdview-table-test-abc 60
                           #'mdview-table-test--render-cell #'wrap)
      (should (null calls))
      (mdview-table-layout mdview-table-test-shrink 30
                           #'mdview-table-test--render-cell #'wrap)
      (should (equal calls
                     '(("An extensible, customizable, free/libre text editor, and more."
                        . 24)))))))

(ert-deftest mdview-table-overlong-wrap-output-is-truncated ()
  "A WRAP-FN that does not break lines cannot break the rectangle."
  (let ((lines (mdview-table-layout mdview-table-test-shrink 30
                                    #'mdview-table-test--render-cell
                                    (lambda (string _width) (list string)))))
    (mdview-table-test--check-widths lines 30)
    (should (= (length lines) 3))
    (should (equal (nth 2 lines) "Emacs An extensible, customiza"))))

(ert-deftest mdview-table-hard-break-in-cell-starts-new-line ()
  (let ((lines (mdview-table-test--layout
                (mdview-table-test--table nil '("A" "B") '("a" "x\ny"))
                5 :expand nil)))
    (mdview-table-test--check-widths lines 5)
    (should (equal (nth 2 lines) "a x  "))
    (should (equal (nth 3 lines) "  y  "))))

;;;; Cells and rows

(ert-deftest mdview-table-empty-cells-and-ragged-rows ()
  (let ((lines (mdview-table-test--layout
                (mdview-table-test--table nil '("A" "B" "C")
                                          '("only")
                                          '("1" "2" "3" "4" "5")
                                          '(:nil "mid" :nil))
                20 :expand nil)))
    (mdview-table-test--check-widths lines 20)
    (should (= (length lines) 5))
    ;; Naturals 4 3 1; extra cells are dropped, missing ones are empty.
    (should (equal (nth 0 lines) (mdview-table-test--line "A" 3 " " "B" 2 " " "C" 10)))
    (should (equal (nth 2 lines) (mdview-table-test--line "only" 16)))
    (should (equal (nth 3 lines) (mdview-table-test--line "1" 3 " " "2" 2 " " "3" 10)))
    (should (equal (nth 4 lines) (mdview-table-test--line 5 "mid" 12)))))

(ert-deftest mdview-table-empty-column ()
  (let ((table (mdview-table-test--table nil '("A" "" "C") '("a" "" "c"))))
    (should (equal (mdview-table-test--layout table 11 :expand nil)
                   (list "A   C      " (nth 1 (mdview-table-test--layout table 11))
                         "a   c      ")))
    ;; Expanded: 9 columns shared as 3 3 3.
    (should (equal (nth 0 (mdview-table-test--layout table 11)) "A       C  "))
    (mdview-table-test--check-widths (mdview-table-test--layout table 11) 11)))

(ert-deftest mdview-table-nil-render-result-is-empty ()
  (let ((lines (mdview-table-layout mdview-table-test-abc 10
                                    (lambda (_cell) nil) #'mdview-table-test--wrap)))
    (mdview-table-test--check-widths lines 10)
    (should (equal (nth 0 lines) (mdview-table-test--spaces 10)))))

(ert-deftest mdview-table-zero-body-rows ()
  (let ((lines (mdview-table-test--layout
                (mdview-table-test--table nil '("Only" "Header")) 20)))
    (mdview-table-test--check-widths lines 20)
    (should (= (length lines) 2))
    (should (equal (nth 0 lines) (mdview-table-test--line "Only" 4 " " "Header" 5)))
    (should (equal (nth 1 lines) (make-string 20 ?━)))))

(ert-deftest mdview-table-no-rows-yields-nil ()
  (should (null (mdview-table-test--layout (mdview-node 'table '(:align nil)) 20)))
  ;; Children that are not rows are ignored.
  (let ((lines (mdview-table-test--layout
                (mdview-node 'table nil "stray" (mdview-table-test--row '("H") t)
                             "stray" (mdview-table-test--row '("b")))
                4)))
    (should (equal lines (list "H   " "━━━━" "b   ")))))

(ert-deftest mdview-table-one-column ()
  (let ((lines (mdview-table-test--layout
                (mdview-table-test--table '(right) '("H") '("abc")) 10)))
    (mdview-table-test--check-widths lines 10)
    (should (equal lines (list (mdview-table-test--line 9 "H") (make-string 10 ?━)
                               (mdview-table-test--line 7 "abc")))))
  ;; A single column wider than the table wraps.
  (let ((lines (mdview-table-test--layout
                (mdview-table-test--table '(right) '("H") '("hello world")) 5)))
    (should (equal lines (list "    H" "━━━━━" "hello" "world")))))

(ert-deftest mdview-table-degenerate-tiny-width ()
  (dolist (width '(3 2 1 0 -3))
    (let ((lines (mdview-table-test--layout mdview-table-test-abc width)))
      (should (= (length lines) 4))
      (dolist (line lines)
        (should (= (string-width line) (max 0 width))))))
  (should (equal (mdview-table-test--layout mdview-table-test-abc 2)
                 '("C " "━━" "l " "a ")))
  ;; Width 5 is not degenerate (3 columns fit): the columns are scaled to
  ;; one column each and the cells wrap letter by letter.
  (let ((lines (mdview-table-test--layout mdview-table-test-abc 5)))
    (mdview-table-test--check-widths lines 5)
    (should (equal (nth 0 lines) "C C C"))
    (should (equal (nth 1 lines) "o o o"))
    (should (equal (nth 7 lines) "━━━━━"))))

;;;; Faces and glyphs

(ert-deftest mdview-table-header-face-present ()
  (let* ((lines (mdview-table-test--layout mdview-table-test-abc 60))
         (header (nth 0 lines))
         (body (nth 2 lines)))
    (should (memq 'mdview-table-header (mdview-table-test--faces-at header 0)))
    (should (memq 'mdview-table-header
                  (mdview-table-test--faces-at header (cl-search "Column C" header))))
    (should-not (memq 'mdview-table-header (mdview-table-test--faces-at body 0)))))

(ert-deftest mdview-table-header-face-combines-with-inline-faces ()
  (let* ((table (mdview-table-test--table
                 nil (list (list (mdview-node 'strong nil "Bold") " plain"))
                 '("x")))
         (header (nth 0 (mdview-table-test--layout table 20))))
    (should (equal (get-text-property 0 'face header)
                   '(mdview-table-header mdview-strong)))
    (should (equal (get-text-property (cl-search "plain" header) 'face header)
                   'mdview-table-header))))

(ert-deftest mdview-table-header-face-does-not-mutate-input ()
  (let* ((shared (copy-sequence "Shared"))
         (lines (mdview-table-layout
                 (mdview-table-test--table nil '("h") '("b")) 10
                 (lambda (_cell) shared) #'mdview-table-test--wrap)))
    (should (memq 'mdview-table-header (mdview-table-test--faces-at (nth 0 lines) 0)))
    (should-not (get-text-property 0 'face shared))))

(ert-deftest mdview-table-rule-line-glyph-and-face ()
  (let* ((lines (mdview-table-test--layout mdview-table-test-abc 60))
         (rule (nth 1 lines)))
    (should (equal rule (make-string 60 ?━)))
    (dotimes (i 60)
      (should (eq (get-text-property i 'face rule) 'mdview-table-rule))))
  (let ((mdview-use-ascii-glyphs t))
    (should (equal (nth 1 (mdview-table-test--layout mdview-table-test-abc 60))
                   (make-string 60 ?-))))
  ;; A multi-character glyph is repeated and cut to the width.
  (let ((mdview-glyphs (cons '(table-rule . "=-") mdview-glyphs))
        (table (mdview-table-test--table nil '("a" "b"))))
    (should (equal (mdview-table-test--layout table 7)
                   (list "a   b  " "=-=-=-=")))))

;;;; Wide characters

(ert-deftest mdview-table-cjk-widths ()
  (let ((lines (mdview-table-test--layout mdview-table-test-cjk 20 :expand nil)))
    (mdview-table-test--check-widths lines 20)
    ;; Naturals 6 8 measured with `string-width'.
    (should (equal (nth 0 lines) (mdview-table-test--line "名前" 2 " " "説明" 4 5)))
    (should (equal (nth 2 lines) (mdview-table-test--line "日本語" " " "テキスト" 5))))
  (let ((lines (mdview-table-test--layout mdview-table-test-cjk 20)))
    (mdview-table-test--check-widths lines 20)
    ;; 5 spare columns over ratios 6 8 -> widths 9 10.
    (should (equal (nth 2 lines) (mdview-table-test--line "日本語" 3 " " "テキスト" 2)))))

(ert-deftest mdview-table-cjk-wrapping-and-truncation ()
  (let ((lines (mdview-table-test--layout mdview-table-test-cjk 9)))
    (mdview-table-test--check-widths lines 9)
    ;; Minimums 6 8 do not fit in 8 -> scaled to 4 4; cells break per glyph.
    (should (equal (nth 2 lines) "日本 テキ"))
    (should (equal (nth 3 lines) (mdview-table-test--line "語" 2 " " "スト"))))
  (dolist (width '(0 1 2 3 4 5 6 7))
    (dolist (line (mdview-table-test--layout mdview-table-test-cjk width))
      (should (= (string-width line) width)))))

;;;; Invariants

(ert-deftest mdview-table-every-line-has-exact-width ()
  (dolist (table (list mdview-table-test-abc mdview-table-test-abc-aligned
                       mdview-table-test-shrink mdview-table-test-long-word
                       mdview-table-test-cjk))
    (dolist (expand '(t nil))
      (dotimes (width 71)
        (let ((lines (mdview-table-test--layout table width :expand expand)))
          (should (>= (length lines) 2))
          (dolist (line lines)
            (should (= (string-width line) width))))))))

(ert-deftest mdview-table-row-count-and-top-alignment ()
  (let ((lines (mdview-table-test--layout
                (mdview-table-test--table nil '("A" "B" "C")
                                          '("one two" "x" "p q r")
                                          '("z" "y" "w"))
                9 :expand nil)))
    (mdview-table-test--check-widths lines 9)
    ;; Available 7: naturals 7 1 5 -> collapse to 3 1 3; row 1 is 2 lines.
    (should (= (length lines) 5))
    (should (equal (nth 2 lines) "one x p q"))
    (should (equal (nth 3 lines) "two   r  "))
    (should (equal (nth 4 lines) "z   y w  "))))

;;;; Review findings

(ert-deftest mdview-table-cell-lines-are-trimmed-after-hard-break ()
  "Text after a <br> starts at the column edge whether or not it wraps."
  (let ((table (mdview-table-test--table nil '("A" "B") '("\n in cell " " after "))))
    (let ((lines (mdview-table-test--layout table 20 :expand nil)))
      (mdview-table-test--check-widths lines 20)
      ;; Naturals 7 5 measured on the trimmed pieces.
      (should (equal (nth 0 lines) (mdview-table-test--line "A" 6 " " "B" 4 7)))
      (should (equal (nth 2 lines) (mdview-table-test--line 7 " " "after" 7)))
      (should (equal (nth 3 lines) (mdview-table-test--line "in cell" " " 5 7))))
    ;; Narrow enough to wrap (column A collapses to 6): still flush left.
    (let ((lines (mdview-table-test--layout table 12)))
      (mdview-table-test--check-widths lines 12)
      (should (equal (nth 2 lines) (mdview-table-test--line 6 " " "after")))
      (should (equal (nth 3 lines) (mdview-table-test--line "in" 4 " " 5)))
      (should (equal (nth 4 lines) (mdview-table-test--line "cell" 2 " " 5))))))

(ert-deftest mdview-table-minimums-measured-only-when-needed ()
  (let ((calls 0))
    (cl-letf* ((original (symbol-function 'mdview-table--longest-word))
               ((symbol-function 'mdview-table--longest-word)
                (lambda (string) (setq calls (1+ calls)) (funcall original string))))
      (mdview-table-test--layout mdview-table-test-abc 60)
      (should (= calls 0))
      (mdview-table-test--layout mdview-table-test-shrink 30)
      (should (> calls 0))))
  ;; A thunk is accepted in place of the list.
  (should (equal (mdview-table--column-widths '(9 90) (lambda () '(4 9)) 93 t) '(9 84)))
  (should (equal (mdview-table--column-widths '(5 5) (lambda () (error "Not needed")) 20 nil)
                 '(5 5))))

(ert-deftest mdview-table-fit-fast-paths ()
  (let ((exact "abc"))
    (should (eq (mdview-table--fit exact 3) exact)))
  (should (equal (mdview-table--fit "ab" 4) "ab  "))
  (should (equal (mdview-table--fit "abcdef" 4) "abcd"))
  (should (equal (mdview-table--fit "日本" 3) "日 "))
  (should (equal (mdview-table--fit "" 0) "")))

(ert-deftest mdview-table-width-helpers-fast-paths ()
  (should (= (mdview-table--natural-width "hello") 5))
  (should (= (mdview-table--natural-width "hi\nthere") 5))
  (should (= (mdview-table--longest-word "hello") 5))
  (should (= (mdview-table--longest-word "a bb\nccc d") 3))
  (should (= (mdview-table--longest-word "") 0)))

(provide 'mdview-table-test)
;;; mdview-table-test.el ends here
