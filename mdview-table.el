;;; mdview-table.el --- Table layout for mdview  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Vadim Zaliva

;; Author: Vadim Zaliva
;; Keywords: text, docs
;; Package-Requires: ((emacs "29.1"))

;; This file is part of mdview, distributed under the MIT license; see
;; LICENSE in the repository root.

;;; Commentary:

;; Table layout (docs/DESIGN.md section 6 "Tables" and section 15): turn a
;; `table' AST node into a list of propertized lines, each exactly as wide
;; as the inner width of the panel box the renderer draws around them.
;;
;; The column widths follow Rich's `Table(expand=True, box=SIMPLE_HEAVY,
;; padding=0, collapse_padding=True)', which is what Frogmouth draws:
;;
;; - the natural width of a column is its widest cell (header included);
;; - columns are separated by one space;
;; - when the natural widths fit, the spare columns are distributed in
;;   proportion to the natural widths (a port of Rich's `ratio_distribute');
;; - when they do not fit, the widest columns are reduced towards the next
;;   widest (a port of Rich's `_collapse_widths'), never below a column's
;;   minimum, which is its longest word (at least 3); if even the minimums
;;   do not fit they are scaled down proportionally and words break;
;; - cells wider than their column are wrapped with the wrap function the
;;   caller supplies; a row spans as many lines as its tallest cell.
;;
;; Cells are received already rendered (propertized strings come from the
;; caller's RENDER-CELL function), so this file does not depend on the
;; inline renderer.  Header cells get the face `mdview-table-header', the
;; rule below them is drawn with the `table-rule' glyph in face
;; `mdview-table-rule', and `:align' is honoured (an improvement over
;; Frogmouth).  No background is painted here: the renderer colours whole
;; lines when it builds the box.

;;; Code:

(require 'cl-lib)
(require 'mdview-ast)
(require 'mdview-faces)

;;;; Options

(defcustom mdview-table-expand t
  "Non-nil means a table grows to fill the available width.
When the natural column widths fit, the spare columns are given to the
columns in proportion to their natural widths, as Rich does for a table
with `expand=True'.  When nil the columns keep their natural widths and
the lines are padded on the right.  A table that is too wide is shrunk
either way."
  :type 'boolean
  :group 'mdview)

(defconst mdview-table-min-column-width 3
  "Narrowest width a column with text is shrunk to before words break.
A column's minimum is its longest word, but never less than this (and
never more than its natural width).  Empty columns have minimum 1.")

;;;; Measuring cells

(defun mdview-table--trim (string)
  "Return STRING without leading and trailing whitespace, offsets kept.
Like `string-trim', except that the result is cut with
`mdview-ast-substring', so the source offsets carried by the text
property `mdview-pos' stay exact when leading characters are removed
\(docs/DESIGN.md section 3)."
  (let ((start 0) (end (length string)))
    (while (and (< start end) (memq (aref string start) '(?\s ?\t ?\n ?\r)))
      (setq start (1+ start)))
    (while (and (> end start) (memq (aref string (1- end)) '(?\s ?\t ?\n ?\r)))
      (setq end (1- end)))
    (if (and (zerop start) (= end (length string)))
        string
      (mdview-ast-substring string start end))))

(defun mdview-table--split-lines (string)
  "Split STRING at newlines (hard breaks), keeping text properties.
The pieces are cut with `mdview-ast-substring', so source offsets in
`mdview-pos' stay exact."
  (if (string-search "\n" string)
      (let ((pos 0) (lines nil) (more t))
        (while more
          (let ((nl (string-search "\n" string pos)))
            (push (mdview-ast-substring string pos nl) lines)
            (if nl (setq pos (1+ nl)) (setq more nil))))
        (nreverse lines))
    (list string)))

(defun mdview-table--cell-string (cell render-cell)
  "Return the rendered string of CELL, calling RENDER-CELL on it.
A nil (missing) CELL, or a non-string result, yields the empty string.
Tabs are replaced by spaces so that `string-width' agrees with the
display width, and every line (the pieces between hard breaks) is
trimmed, so that the text after a <br> starts at the column edge
whether or not the cell has to wrap.  Source offsets in `mdview-pos'
stay exact (see `mdview-table--trim')."
  (let ((string (and cell (funcall render-cell cell))))
    (cond
     ((not (stringp string)) "")
     (t
      (when (string-search "\t" string)
        (setq string (subst-char-in-string ?\t ?\s string)))
      (if (string-search "\n" string)
          (mapconcat #'mdview-table--trim (mdview-table--split-lines string) "\n")
        (mdview-table--trim string))))))

(defun mdview-table--max-width (strings)
  "Return the largest `string-width' among STRINGS, or 0 when empty."
  (apply #'max 0 (mapcar #'string-width strings)))

(defun mdview-table--natural-width (string)
  "Return the width of the widest line of cell STRING."
  (if (string-search "\n" string)
      (mdview-table--max-width (mdview-table--split-lines string))
    (string-width string)))

(defun mdview-table--longest-word (string)
  "Return the width of the widest space-separated word of cell STRING."
  (if (string-match-p "[ \n]" string)
      (mdview-table--max-width (split-string string "[ \n]+" t))
    (string-width string)))

(defun mdview-table--naturals (rows ncols available)
  "Return the natural widths of the NCOLS columns of ROWS.
A column's natural width is its widest cell, at least 1 and at most
AVAILABLE, the width the columns may share."
  (let ((cap (max 1 available))
        (naturals nil))
    (dotimes (index ncols)
      (push (min cap (apply #'max 1 (mapcar (lambda (row)
                                               (mdview-table--natural-width
                                                (nth index row)))
                                             rows)))
            naturals))
    (nreverse naturals)))

(defun mdview-table--minimums (rows ncols naturals)
  "Return the minimum widths of the NCOLS columns of ROWS given NATURALS.
A column's minimum width is its longest word, at least
`mdview-table-min-column-width' but no more than its natural width, or 1
for a column without words."
  (let ((minimums nil))
    (dotimes (index ncols)
      (let ((word (apply #'max 0 (mapcar (lambda (row)
                                           (mdview-table--longest-word
                                            (nth index row)))
                                         rows)))
            (natural (nth index naturals)))
        (push (if (zerop word)
                  1
                (min natural (max mdview-table-min-column-width word)))
              minimums)))
    (nreverse minimums)))

(defun mdview-table--measure (rows ncols available)
  "Measure the columns of ROWS; return (NATURALS . MINIMUMS).
ROWS is a list of rows, each a list of NCOLS cell strings.  See
`mdview-table--naturals' and `mdview-table--minimums'; both are capped
at AVAILABLE, the width the columns may share."
  (let ((naturals (mdview-table--naturals rows ncols available)))
    (cons naturals (mdview-table--minimums rows ncols naturals))))

;;;; Integer arithmetic (ports of Rich's helpers)

(defun mdview-table--ceil-div (num den)
  "Return NUM divided by DEN, rounded up.
NUM must be non-negative and DEN positive."
  (/ (+ num den -1) den))

(defun mdview-table--round-half-even (num den)
  "Return NUM divided by DEN, rounded to the nearest integer, ties to even.
This is Python's `round', which Rich uses while collapsing columns.  NUM
must be non-negative and DEN positive."
  (let ((quotient (/ num den))
        (twice-remainder (* 2 (% num den))))
    (cond ((< twice-remainder den) quotient)
          ((> twice-remainder den) (1+ quotient))
          ((cl-evenp quotient) quotient)
          (t (1+ quotient)))))

(defun mdview-table--ratio-distribute (total ratios)
  "Split the non-negative integer TOTAL into parts proportional to RATIOS.
Port of Rich's `ratio_distribute': each part is the ceiling of its share
of what is still left, so the parts are non-negative integers that add up
to exactly TOTAL.  When every ratio is zero the split is even."
  (let* ((ratios (if (cl-every #'zerop ratios)
                     (make-list (length ratios) 1)
                   ratios))
         (total-ratio (apply #'+ ratios))
         (remaining (max 0 total))
         (parts nil))
    (dolist (ratio ratios)
      (let ((part (if (> total-ratio 0)
                      (mdview-table--ceil-div (* ratio remaining) total-ratio)
                    remaining)))
        (push part parts)
        (setq total-ratio (- total-ratio ratio)
              remaining (- remaining part))))
    (nreverse parts)))

(defun mdview-table--ratio-reduce (total ratios maximums values)
  "Take TOTAL away from VALUES in proportion to RATIOS, capped by MAXIMUMS.
Port of Rich's `ratio_reduce': a slot whose maximum is zero does not take
part; every other slot gives up its rounded share of what is still left,
at most its maximum.  Return the reduced values; the full TOTAL is not
reached when the maximums are too tight."
  (let* ((ratios (cl-mapcar (lambda (ratio maximum) (if (> maximum 0) ratio 0))
                            ratios maximums))
         (total-ratio (apply #'+ ratios))
         (remaining total)
         (result nil))
    (cl-mapc (lambda (ratio maximum value)
               (if (and (> ratio 0) (> total-ratio 0))
                   (let ((taken (min maximum
                                     (mdview-table--round-half-even
                                      (* ratio remaining) total-ratio))))
                     (push (- value taken) result)
                     (setq remaining (- remaining taken)
                           total-ratio (- total-ratio ratio)))
                 (push value result)))
             ratios maximums values)
    (nreverse result)))

;;;; Column widths

(defun mdview-table--collapse (widths minimums available)
  "Shrink WIDTHS so that they sum to at most AVAILABLE, honouring MINIMUMS.
Port of Rich's `Table._collapse_widths': repeatedly reduce the widest
columns towards the next widest, but never below a column's minimum.
Return the new widths; their sum stays above AVAILABLE only when the
minimums alone do not fit."
  (let ((excess (- (apply #'+ widths) available))
        (progress t))
    (while (and (> excess 0) progress)
      (let* ((shrinkable (cl-mapcar #'> widths minimums))
             (widest (apply #'max 0 (cl-mapcar (lambda (width ok) (if ok width 0))
                                               widths shrinkable)))
             (second (apply #'max 0 (cl-mapcar (lambda (width ok)
                                                 (if (and ok (/= width widest))
                                                     width
                                                   0))
                                               widths shrinkable)))
             (difference (- widest second))
             (ratios (cl-mapcar (lambda (width ok) (if (and ok (= width widest)) 1 0))
                                widths shrinkable))
             (caps (cl-mapcar (lambda (width minimum ratio)
                                (if (> ratio 0)
                                    (min excess difference (- width minimum))
                                  0))
                              widths minimums ratios))
             (reduced (mdview-table--ratio-reduce excess ratios caps widths)))
        (setq progress (not (equal reduced widths))
              widths reduced
              excess (- (apply #'+ widths) available))))
    widths))

(defun mdview-table--scale-minimums (minimums available)
  "Return widths proportional to MINIMUMS that sum to AVAILABLE.
Every width is at least 1; AVAILABLE must be at least the number of
columns.  Used when even the minimum widths do not fit."
  (mapcar #'1+ (mdview-table--ratio-distribute (- available (length minimums))
                                               minimums)))

(defun mdview-table--column-widths (naturals minimums available expand)
  "Return the column widths for NATURALS and MINIMUMS within AVAILABLE.
AVAILABLE is the width the columns share, separators excluded.  When the
natural widths fit, the spare width is distributed in proportion to them
if EXPAND is non-nil, otherwise they are kept.  When they do not fit the
widest columns are collapsed first and, if the minimums still do not fit,
the minimums are scaled down.  MINIMUMS may be a function returning the
list, called only when the natural widths do not fit.  When AVAILABLE is
smaller than the number of columns every column is one column wide and
the caller truncates."
  (let ((count (length naturals))
        (total (apply #'+ naturals)))
    (cond
     ((< available count) (make-list count 1))
     ((<= total available)
      (if expand
          (cl-mapcar #'+ naturals
                     (mdview-table--ratio-distribute (- available total) naturals))
        naturals))
     (t
      (let* ((minimums (if (functionp minimums) (funcall minimums) minimums))
             (widths (mdview-table--collapse naturals minimums available)))
        (if (<= (apply #'+ widths) available)
            widths
          (mdview-table--scale-minimums minimums available)))))))

;;;; Cells to lines

(defun mdview-table--cell-lines (string width wrap)
  "Return the lines of cell STRING fitted into WIDTH columns.
A newline in STRING always starts a new line.  A piece wider than WIDTH
is wrapped by calling WRAP with the piece and WIDTH; when WRAP is nil, or
leaves a line too wide, the line is truncated instead."
  (let ((lines nil))
    (dolist (piece (mdview-table--split-lines string))
      (dolist (line (if (and wrap (> (string-width piece) width))
                        (or (funcall wrap piece width) (list ""))
                      (list piece)))
        (push (if (> (string-width line) width)
                  (truncate-string-to-width line width)
                line)
              lines)))
    (nreverse lines)))

(defun mdview-table--align (line width align)
  "Pad LINE with spaces to WIDTH columns according to ALIGN.
ALIGN is `right' (pad on the left), `center' (split the padding, the odd
column going to the right) or anything else (pad on the right)."
  (let* ((extra (max 0 (- width (string-width line))))
         (left (pcase align
                 ('right extra)
                 ('center (/ extra 2))
                 (_ 0))))
    (concat (make-string left ?\s) line (make-string (- extra left) ?\s))))

(defun mdview-table--row-lines (strings widths aligns wrap)
  "Lay out the cell STRINGS of one row; return its lines.
WIDTHS and ALIGNS give each column's width and alignment, WRAP wraps
cells that are too wide (see `mdview-table--cell-lines').  Columns are
joined by one space.  The row spans as many lines as its tallest cell;
shorter cells are padded with blank lines at the bottom."
  (let* ((cells (cl-mapcar (lambda (string width)
                             (mdview-table--cell-lines string width wrap))
                           strings widths))
         (height (apply #'max 1 (mapcar #'length cells)))
         (lines nil))
    (dotimes (index height)
      (push (mapconcat #'identity
                       (cl-mapcar (lambda (cell width align)
                                    (mdview-table--align (or (nth index cell) "")
                                                         width align))
                                  cells widths aligns)
                       " ")
            lines))
    (nreverse lines)))

(defun mdview-table--fit (string width)
  "Return STRING padded with spaces or truncated to exactly WIDTH columns.
A string that already has the right width (the common case for a row
assembled from aligned cells) is returned as is."
  (let ((current (string-width string)))
    (cond
     ((= current width) string)
     ((< current width) (concat string (make-string (- width current) ?\s)))
     (t (truncate-string-to-width string width nil ?\s)))))

(defun mdview-table--rule (width)
  "Return the header rule: WIDTH columns of the `table-rule' glyph.
The glyph is repeated (and cut) to the exact width, in face
`mdview-table-rule'."
  (let* ((glyph (let ((g (mdview-glyph 'table-rule)))
                  (if (> (string-width g) 0) g "-")))
         (repeat (mdview-table--ceil-div width (string-width glyph))))
    (propertize (mdview-table--fit (apply #'concat (make-list repeat glyph)) width)
                'face 'mdview-table-rule)))

(defun mdview-table--add-header-face (string)
  "Return a copy of STRING with face `mdview-table-header' prepended.
The face is added with `add-face-text-property' so that it combines with
inline faces such as `mdview-inline-code' already on the text."
  (let ((copy (copy-sequence string)))
    (add-face-text-property 0 (length copy) 'mdview-table-header nil copy)
    copy))

;;;; Rows

(defun mdview-table--rows (table)
  "Return the `table-row' children of TABLE, ignoring anything else."
  (cl-remove-if-not (lambda (node) (eq (mdview-node-type node) 'table-row))
                    (mdview-node-children table)))

(defun mdview-table--row-strings (row ncols render-cell)
  "Return the NCOLS rendered cell strings of ROW, using RENDER-CELL.
Missing cells are empty; cells beyond NCOLS are ignored (as GFM does)."
  (let ((cells (mdview-node-children row)))
    (cl-loop for index below ncols
             collect (mdview-table--cell-string (nth index cells) render-cell))))

(defun mdview-table--column-count (rows align)
  "Return the number of columns given the table ROWS and ALIGN list.
The header (first) row defines the count; it is at least 1 and at least
as long as ALIGN."
  (max 1
       (length (mdview-node-children (car rows)))
       (if (listp align) (length align) 0)))

;;;; Entry point

(cl-defun mdview-table-layout (table inner-width render-cell wrap
                                     &key (expand mdview-table-expand))
  "Lay out TABLE into a list of lines, each exactly INNER-WIDTH columns.
TABLE is a `table' node whose `table-row' children hold `table-cell'
nodes; the first row is the header and the `:align' property lists each
column's alignment (`left', `center', `right' or nil).  RENDER-CELL is
called with each cell node and returns a propertized string.  WRAP is
called with a string and a width and returns the list of wrapped lines
\(see `mdview-wrap').  EXPAND defaults to `mdview-table-expand'; when
non-nil a table narrower than INNER-WIDTH grows to fill it.

The lines come in order: the header line(s), with the face
`mdview-table-header' added to the cell text; the rule line, the
`table-rule' glyph in face `mdview-table-rule'; then the body lines.
There is no frame and no blank edge rows: the caller draws the panel
box and paints the background of whole lines.

Column widths follow Rich (see `mdview-table--column-widths'): one space
separates columns, cells wider than their column are wrapped, a row
spans as many lines as its tallest cell and cells are top-aligned.  Body
rows with fewer cells than the header get empty cells; extra cells are
ignored.  When INNER-WIDTH cannot even hold one column per column plus
the separators, every column is one column wide and the lines are
truncated.  A table without rows yields nil."
  (let* ((inner-width (max 0 inner-width))
         (rows (mdview-table--rows table))
         (align (mdview-node-prop table :align)))
    (when rows
      (let* ((ncols (mdview-table--column-count rows align))
             (aligns (cl-loop for index below ncols
                              collect (and (listp align) (nth index align))))
             (header (mapcar #'mdview-table--add-header-face
                             (mdview-table--row-strings (car rows) ncols render-cell)))
             (body (mapcar (lambda (row)
                             (mdview-table--row-strings row ncols render-cell))
                           (cdr rows)))
             (available (max 0 (- inner-width (1- ncols))))
             (cells (cons header body))
             (naturals (mdview-table--naturals cells ncols available))
             ;; The minimums (longest words) are only needed when the
             ;; natural widths do not fit; measure them lazily.
             (widths (mdview-table--column-widths
                      naturals
                      (lambda () (mdview-table--minimums cells ncols naturals))
                      available expand))
             ;; In the degenerate case wrapping at width 1 would only
             ;; multiply lines that get truncated anyway.
             (wrap (and (>= available ncols) wrap)))
        (mapcar (lambda (line) (mdview-table--fit line inner-width))
                (append (mdview-table--row-lines header widths aligns wrap)
                        (list (mdview-table--rule inner-width))
                        (mapcan (lambda (row)
                                  (mdview-table--row-lines row widths aligns wrap))
                                body)))))))

(provide 'mdview-table)
;;; mdview-table.el ends here
