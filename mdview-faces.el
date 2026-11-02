;;; mdview-faces.el --- Faces, palette and glyphs for mdview  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Vadim Zaliva

;; Author: Vadim Zaliva
;; Keywords: text, docs, faces
;; Package-Requires: ((emacs "29.1"))

;; This file is part of mdview, distributed under the MIT license; see
;; LICENSE in the repository root.

;;; Commentary:

;; The visual vocabulary of mdview (docs/DESIGN.md sections 6, 7, 11 and
;; 12): the `mdview' customization group, every face that is not owned by
;; a specific module, the glyph tables with their ASCII fallback, and the
;; buffer-local derivation of theme-dependent colours (block quote
;; backgrounds and the box frame colour) from the actual `default' face.
;; Everything here is safe under `emacs -Q --batch': when no colour
;; information is available the derivation is a silent no-op and the
;; static face specs apply.
;;
;; Colours are Textual's default design as resolved by Frogmouth:
;;
;;   text-muted  #A5A5A5 / #666666      panel     #24292F / #DCE3E8
;;   foreground  #EDEDED / #101010      primary   #004578
;;   primary-lighten-1 #23568B          accent    #0178D4
;;   accent-darken-2   #0053AA          success   #4EBF71
;;   code background   #263238          code text #EEFFFF
;;   inline code       #939393 / #6E6E6E
;;
;; (dark / light where they differ).

;;; Code:

(require 'color)
(require 'face-remap)
(require 'seq)

(defgroup mdview nil
  "Render Markdown in the visual style of Frogmouth."
  :group 'text
  :prefix "mdview-"
  :link '(url-link "https://github.com/vzaliva/emacs-md-render"))

;;;; Faces

(defface mdview-muted
  '((((background dark)) :foreground "#A5A5A5")
    (((background light)) :foreground "#666666"))
  "Face for de-emphasized text (Textual's text-muted)."
  :group 'mdview)

(defface mdview-h1
  '((t :weight bold :foreground "#DDE8F3" :background "#0053AA"))
  "Face for level-1 headings: bold, light text on the accent-coloured box."
  :group 'mdview)

(defface mdview-h2
  '((((background dark)) :weight bold :background "#24292F")
    (((background light)) :weight bold :background "#DCE3E8"))
  "Face for level-2 headings: bold text on the panel-coloured box."
  :group 'mdview)

(defface mdview-h3
  '((t :weight bold))
  "Face for level-3 headings (a rule in `mdview-h3-rule' follows)."
  :group 'mdview)

(defface mdview-h3-rule
  '((((background dark)) :foreground "#EDEDED")
    (((background light)) :foreground "#101010"))
  "Face for the rule drawn under a level-3 heading."
  :group 'mdview)

(defface mdview-h4
  '((t :underline t))
  "Face for level-4 headings."
  :group 'mdview)

(defface mdview-h5
  '((t :weight bold))
  "Face for level-5 headings."
  :group 'mdview)

(defface mdview-h6
  '((t :weight bold :inherit mdview-muted))
  "Face for level-6 headings: bold and muted."
  :group 'mdview)

(defface mdview-emphasis
  '((t :slant italic))
  "Face for emphasized (italic) text."
  :group 'mdview)

(defface mdview-strong
  '((t :weight bold))
  "Face for strong (bold) text."
  :group 'mdview)

(defface mdview-strikethrough
  '((t :strike-through t))
  "Face for struck-through text."
  :group 'mdview)

(defface mdview-inline-code
  '((((background dark)) :weight bold :foreground "#939393")
    (((background light)) :weight bold :foreground "#6E6E6E"))
  "Face for inline code spans (Rich's \"bold dim\")."
  :group 'mdview)

(defface mdview-link
  '((t :underline t))
  "Face for links; the foreground is inherited from the surrounding text."
  :group 'mdview)

(defface mdview-quote
  '((((background dark)) :background "#272727")
    (((background light)) :background "#EBEBEB"))
  "Face for the background of a first-level block quote.
The static colours assume Textual's app background; `mdview-faces-remap'
replaces them buffer-locally with a 4 % blend of the real `default'
background towards white (dark themes) or black (light themes)."
  :group 'mdview)

(defface mdview-quote-2
  '((((background dark)) :background "#303030")
    (((background light)) :background "#E2E2E2"))
  "Face for the background of a second-level (nested) block quote.
See `mdview-quote'; the blend is applied twice."
  :group 'mdview)

(defface mdview-quote-3
  '((((background dark)) :background "#383838")
    (((background light)) :background "#D9D9D9"))
  "Face for the background of block quotes nested three levels or deeper.
See `mdview-quote'; the blend is applied three times."
  :group 'mdview)

(defface mdview-quote-border
  '((t :foreground "#4EBF71"))
  "Face for the vertical bar at the left of a block quote."
  :group 'mdview)

(defface mdview-bullet
  '((t :weight bold :foreground "#4EBF71"))
  "Face for list bullets and ordered-list numbers."
  :group 'mdview)

(defface mdview-task-checked
  '((t :foreground "#4EBF71"))
  "Face for the check box of a completed task-list item."
  :group 'mdview)

(defface mdview-task-unchecked
  '((t :inherit mdview-muted))
  "Face for the check box of an open task-list item."
  :group 'mdview)

(defface mdview-rule
  '((t :foreground "#004578"))
  "Face for thematic breaks and the rule above the footnotes section."
  :group 'mdview)

(defface mdview-box-frame
  '((((background dark)) :foreground "#1E1E1E")
    (((background light)) :foreground "#F5F5F5"))
  "Face for the frame glyphs of heading and table boxes.
The foreground must equal the buffer background so the frame reads as a
thin inset; `mdview-faces-remap' sets it buffer-locally from the real
`default' face."
  :group 'mdview)

(defface mdview-footnote-ref
  '((t :foreground "#0178D4"))
  "Face for footnote reference markers such as [1]."
  :group 'mdview)

(defface mdview-table
  '((((background dark)) :background "#24292F")
    (((background light)) :background "#DCE3E8"))
  "Face for the background of a table box."
  :group 'mdview)

(defface mdview-table-header
  '((t :weight bold))
  "Face for table header cells (the renderer adds the box background)."
  :group 'mdview)

(defface mdview-table-rule
  '((t :foreground "#23568B"))
  "Face for the rule separating the table header from the body."
  :group 'mdview)

(defface mdview-code-block
  '((t :background "#263238" :foreground "#EEFFFF"))
  "Face for code blocks: Material background and default text, both themes."
  :group 'mdview)

(defface mdview-code-indent-guide
  '((t :inherit mdview-code-block :foreground "#4A5A63"))
  "Face for indentation guides inside code blocks."
  :group 'mdview)

(defface mdview-image-placeholder
  '((t :inherit mdview-link))
  "Face for the text shown in place of an image that is not displayed."
  :group 'mdview)

(defface mdview-image-caption
  '((t :inherit mdview-muted :slant italic))
  "Face for image captions (the alt text under a block image)."
  :group 'mdview)

;;;; Options

(defcustom mdview-box-frame-style 'wide
  "How heading and table boxes are framed.
`wide' draws Textual's wide border in the buffer background colour
\(`mdview-box-frame'); `none' uses plain blank rows instead of frame rows."
  :type '(choice (const :tag "Wide inset frame" wide)
                 (const :tag "No frame" none))
  :group 'mdview)

(defcustom mdview-use-ascii-glyphs 'auto
  "Whether to draw with `mdview-ascii-glyphs' instead of `mdview-glyphs'.
t always uses ASCII, nil always uses the Unicode glyphs, and `auto'
uses ASCII only when the display cannot show the bullet `●'.  In batch
mode `auto' selects the Unicode glyphs."
  :type '(choice (const :tag "Automatically" auto)
                 (const :tag "Always ASCII" t)
                 (const :tag "Always Unicode" nil))
  :group 'mdview)

(defcustom mdview-glyphs
  '((bullet-1 . "●") (bullet-2 . "▪") (bullet-3 . "‣") (bullet-4 . "•")
    (bullet-5 . "⭑") (quote-bar . "▌") (box-top . "▁") (box-bottom . "▔")
    (box-left . "▎") (box-right . "▊") (rule . "━") (thin-rule . "─")
    (guide . "│") (task-checked . "☑") (task-unchecked . "☐")
    (table-rule . "━") (h3-rule . "▔") (image . "🖼"))
  "Glyphs used by the renderer, keyed by role.
`bullet-1' .. `bullet-5' are the bullets for successive list depths;
`quote-bar' the block quote border; `box-top', `box-bottom', `box-left'
and `box-right' the frame of heading and table boxes; `rule' the thematic
break; `thin-rule' the footnotes separator; `guide' the code indent
guide; `task-checked' and `task-unchecked' the task-list boxes;
`table-rule' the header rule of tables; `h3-rule' the underline of level-3
headings; `image' the marker of image placeholders.  Every value should
be one column wide (see `string-width') except the task boxes and image
marker, which may be wider."
  :type '(alist :key-type symbol :value-type string)
  :group 'mdview)

(defcustom mdview-ascii-glyphs
  '((bullet-1 . "*") (bullet-2 . "-") (bullet-3 . "+") (bullet-4 . ".")
    (bullet-5 . "*") (quote-bar . "|") (box-top . "-") (box-bottom . "-")
    (box-left . "|") (box-right . "|") (rule . "-") (thin-rule . "-")
    (guide . "|") (task-checked . "[x]") (task-unchecked . "[ ]")
    (table-rule . "-") (h3-rule . "-") (image . "[img]"))
  "ASCII replacements for `mdview-glyphs', with the same keys.
Used when `mdview-use-ascii-glyphs' selects the ASCII profile."
  :type '(alist :key-type symbol :value-type string)
  :group 'mdview)

;;;; Glyphs

(defun mdview-faces-ascii-p ()
  "Return non-nil when the ASCII glyph profile should be used.
Honours `mdview-use-ascii-glyphs'; in `auto' mode the ASCII profile is
chosen only on an interactive display that cannot show `●'."
  (pcase mdview-use-ascii-glyphs
    ('auto (and (not noninteractive)
                (not (char-displayable-p ?●))))
    (value value)))

(defun mdview-glyph (key)
  "Return the glyph string for KEY from the active glyph profile.
KEY is one of the keys of `mdview-glyphs'.  Falls back to the other
profile when KEY is missing from the active one, and to the empty string
when KEY is unknown, so rendering never signals."
  (or (and (mdview-faces-ascii-p) (cdr (assq key mdview-ascii-glyphs)))
      (cdr (assq key mdview-glyphs))
      (cdr (assq key mdview-ascii-glyphs))
      ""))

;;;; Colour derivation

(defun mdview-faces-color-rgb (color)
  "Return COLOR as a list (R G B) of floats in 0..1, or nil when unknown.
Hex and rgb: specifications are parsed on any display, including batch
mode; colour names are resolved only on a colour display."
  (cond
   ((or (not (stringp color)) (string-prefix-p "unspecified" color)) nil)
   ((color-values-from-color-spec color)
    (mapcar (lambda (v) (/ v 65535.0)) (color-values-from-color-spec color)))
   ((and (not noninteractive) (display-color-p) (color-defined-p color))
    (color-name-to-rgb color))
   (t nil)))

(defun mdview-faces-rgb-to-hex (rgb)
  "Return the #RRGGBB string for RGB, a list (R G B) of floats in 0..1.
Components are clamped and rounded to the nearest of 256 levels (unlike
`color-rgb-to-hex', which truncates)."
  (apply #'format "#%02x%02x%02x"
         (mapcar (lambda (v) (round (* 255 (min 1.0 (max 0.0 v))))) rgb)))

(defun mdview-faces-dark-p (rgb)
  "Return non-nil when RGB (a list of floats in 0..1) is a dark colour."
  (< (+ (* 0.299 (nth 0 rgb)) (* 0.587 (nth 1 rgb)) (* 0.114 (nth 2 rgb)))
     0.5))

(defun mdview-faces-blend (rgb target fraction)
  "Move RGB FRACTION (0..1) of the way towards TARGET.
Both colours are lists (R G B) of floats in 0..1; return such a list."
  (seq-mapn (lambda (a b) (+ a (* fraction (- b a)))) rgb target))

(defun mdview-faces-boost (rgb level)
  "Return the block quote background for nesting LEVEL over background RGB.
Each level blends 4 % towards white on a dark background or towards black
on a light one, like Textual's $boost layered LEVEL times.  Return a
#RRGGBB string."
  (let ((target (if (mdview-faces-dark-p rgb) '(1.0 1.0 1.0) '(0.0 0.0 0.0)))
        (color rgb))
    (dotimes (_ (max level 1))
      (setq color (mdview-faces-blend color target 0.04)))
    (mdview-faces-rgb-to-hex color)))

(defun mdview-faces-default-background ()
  "Return the `default' face background as an (R G B) list, or nil.
Nil means the colour is unavailable (batch mode, monochrome terminal)."
  (ignore-errors
    (mdview-faces-color-rgb (face-background 'default nil t))))

(defvar-local mdview-faces--remap-cookies nil
  "Cookies returned by `face-remap-add-relative' in this buffer.")

(defun mdview-faces-remap ()
  "Install the theme-derived faces buffer-locally.
Computes the `mdview-quote', `mdview-quote-2' and `mdview-quote-3'
backgrounds with `mdview-faces-boost' and the `mdview-box-frame'
foreground (equal to the buffer background) from the `default' face, and
installs them with `face-remap-add-relative'.  Any earlier remapping by
this function is removed first.  When the default background cannot be
determined (as in batch mode) nothing is changed and no error is
signalled.  Return the list of remapping cookies."
  (mdview-faces-unremap)
  (let ((rgb (mdview-faces-default-background)))
    (when rgb
      (let ((level 0))
        (dolist (face '(mdview-quote mdview-quote-2 mdview-quote-3))
          (setq level (1+ level))
          (push (face-remap-add-relative
                 face :background (mdview-faces-boost rgb level))
                mdview-faces--remap-cookies)))
      (push (face-remap-add-relative
             'mdview-box-frame :foreground (mdview-faces-rgb-to-hex rgb))
            mdview-faces--remap-cookies)))
  mdview-faces--remap-cookies)

(defun mdview-faces-unremap ()
  "Remove the face remappings installed by `mdview-faces-remap'."
  (mapc #'face-remap-remove-relative mdview-faces--remap-cookies)
  (setq mdview-faces--remap-cookies nil))

(provide 'mdview-faces)
;;; mdview-faces.el ends here
