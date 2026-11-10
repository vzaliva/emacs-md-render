;;; mdview-faces.el --- Faces, palette and glyphs for mdview  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Vadim Zaliva

;; Author: Vadim Zaliva
;; SPDX-License-Identifier: MIT
;; Keywords: text, docs, faces

;; This file is part of mdview, distributed under the MIT license; see
;; LICENSE in the repository root.

;;; Commentary:

;; The visual vocabulary of mdview (docs/DESIGN.md sections 6, 7, 11 and
;; 12): the `mdview' customization group, every face that is not owned by
;; a specific module, the glyph tables with their ASCII fallback, and the
;; buffer-local derivation of theme-dependent colours (block quote
;; backgrounds, the box frame colour and the heading and table panels)
;; from the actual `default' face.
;; Everything here is safe under `emacs -Q --batch': when no colour
;; information is available the derivation is a silent no-op and the
;; static face specs apply.
;;
;; The glyph profile (ASCII or Unicode, and whether the emoji image
;; marker must give way to a plain symbol the display draws one column
;; wide) is resolved by `mdview-faces-resolve-glyphs'; the renderer binds
;; the result to `mdview-faces--profile' for the duration of a document
;; so that `mdview-glyph' does not probe the display per glyph.  Buffers
;; whose derived faces were installed by `mdview-faces-remap' are
;; refreshed from `enable-theme-functions' and `disable-theme-functions'.
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
;; (dark / light where they differ).  They are what you get in batch mode
;; and on terminals whose colours cannot be read; on a display that can
;; report the `default' face colours the panel colour is derived from the
;; theme instead (`mdview-panel-blend').

;;; Code:

(require 'color)
(require 'face-remap)
(require 'seq)
(require 'mdview-ast)                   ; the `mdview' customization group

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

(defface mdview-summary
  '((t :weight bold))
  "Face for the summary line of an HTML <details> element."
  :group 'mdview)

;; GitHub's alert colours (light theme / dark theme).
(defface mdview-alert-note
  '((((background dark)) :foreground "#4493F8")
    (((background light)) :foreground "#0969DA"))
  "Face for the bar and title of a [!NOTE] alert."
  :group 'mdview)

(defface mdview-alert-tip
  '((((background dark)) :foreground "#3FB950")
    (((background light)) :foreground "#1A7F37"))
  "Face for the bar and title of a [!TIP] alert."
  :group 'mdview)

(defface mdview-alert-important
  '((((background dark)) :foreground "#AB7DF8")
    (((background light)) :foreground "#8250DF"))
  "Face for the bar and title of an [!IMPORTANT] alert."
  :group 'mdview)

(defface mdview-alert-warning
  '((((background dark)) :foreground "#D29922")
    (((background light)) :foreground "#9A6700"))
  "Face for the bar and title of a [!WARNING] alert."
  :group 'mdview)

(defface mdview-alert-caution
  '((((background dark)) :foreground "#F85149")
    (((background light)) :foreground "#CF222E"))
  "Face for the bar and title of a [!CAUTION] alert."
  :group 'mdview)

;;;; Options

(defcustom mdview-box-frame-style 'wide
  "How heading and table boxes are framed.
`wide' draws Textual's wide border in the buffer background colour
\(`mdview-box-frame'); `none' uses plain blank rows instead of frame rows."
  :type '(choice (const :tag "Wide inset frame" wide)
                 (const :tag "No frame" none))
  :group 'mdview)

(defcustom mdview-panel-blend 0.09
  "How strongly the heading and table panels stand out from the theme.
The background of level-2 headings and of tables is derived from your
theme's `default' face instead of using Frogmouth's fixed blue-grey: it
is the page background moved this fraction of the way towards the text
colour, so the panels take their hue from the theme.  Useful values lie
between a few percent, the quiet step of the original, and about 0.3.
The colour is then adjusted so that the panel stays visible and the text
on it readable even for themes with very little or very much contrast.
Nil keeps the fixed colours of the `mdview-h2' and `mdview-table' faces,
which you can then customize.  Takes effect when a view is next
rendered or the theme changes."
  :type '(choice (const :tag "Fixed Frogmouth colours" nil)
                 (number :tag "Fraction from background to text colour"))
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
    (table-rule . "━") (h3-rule . "▔") (image . "🖼") (summary . "▸")
    (alert-note . "◉") (alert-tip . "✦") (alert-important . "❢")
    (alert-warning . "⚠") (alert-caution . "⊘"))
  "Glyphs used by the renderer, keyed by role.
`bullet-1' .. `bullet-5' are the bullets for successive list depths;
`quote-bar' the block quote border; `box-top', `box-bottom', `box-left'
and `box-right' the frame of heading and table boxes; `rule' the thematic
break; `thin-rule' the footnotes separator; `guide' the code indent
guide; `task-checked' and `task-unchecked' the task-list boxes;
`table-rule' the header rule of tables; `h3-rule' the underline of level-3
headings; `image' the marker of image placeholders; `summary' the marker
of a <details> summary line; `alert-note' .. `alert-caution' the icons of
GitHub alerts.  Every value should be one column wide (see
`string-width') except the task boxes, the alert icons and the image
marker, which may be wider.  The `image' glyph is replaced by
`mdview-image-glyph-fallback' on displays that do not draw it one column
wide (see `mdview-faces-resolve-glyphs')."
  :type '(alist :key-type symbol :value-type string)
  :group 'mdview)

(defcustom mdview-ascii-glyphs
  '((bullet-1 . "*") (bullet-2 . "-") (bullet-3 . "+") (bullet-4 . ".")
    (bullet-5 . "*") (quote-bar . "|") (box-top . "-") (box-bottom . "-")
    (box-left . "|") (box-right . "|") (rule . "-") (thin-rule . "-")
    (guide . "|") (task-checked . "[x]") (task-unchecked . "[ ]")
    (table-rule . "-") (h3-rule . "-") (image . "[img]") (summary . ">")
    (alert-note . "(i)") (alert-tip . "(*)") (alert-important . "(!!)")
    (alert-warning . "(!)") (alert-caution . "(x)"))
  "ASCII replacements for `mdview-glyphs', with the same keys.
Used when `mdview-use-ascii-glyphs' selects the ASCII profile."
  :type '(alist :key-type symbol :value-type string)
  :group 'mdview)

(defcustom mdview-image-glyph-fallback "▣"
  "Glyph drawn instead of the `image' glyph of `mdview-glyphs' when needed.
The default image marker is an emoji that graphical Emacs draws with an
emoji font, often wider than a text column, and that many terminals draw
two cells wide although `string-width' counts one; both misalign the
right edge of boxes.  This Basic Multilingual Plane symbol is used
instead on a graphical frame whose font does not draw the configured
glyph exactly one column wide, and on text terminals whenever the
configured glyph lies outside the Basic Multilingual Plane.  In batch
mode the configured glyph is always used."
  :type 'string
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

(defun mdview-faces-glyph-fits-p (glyph)
  "Return non-nil when the display draws GLYPH `string-width' columns wide.
Everything fits in batch mode.  On a graphical frame the glyph must be
displayable and its pixel width must be its column count times
`frame-char-width'.  On a text terminal a glyph outside the Basic
Multilingual Plane is assumed not to fit, because many terminals draw
such pictographs two cells wide while Emacs counts one."
  (cond
   (noninteractive t)
   ((display-graphic-p)
    (condition-case nil
        (and (seq-every-p #'char-displayable-p glyph)
             (= (string-pixel-width glyph)
                (* (string-width glyph) (frame-char-width))))
      (error t)))
   (t (not (seq-some (lambda (char) (>= char #x10000)) glyph)))))

(defun mdview-faces--image-glyph-override ()
  "Return the glyph replacing the Unicode `image' glyph, or nil to keep it."
  (let ((glyph (cdr (assq 'image mdview-glyphs))))
    (and (stringp glyph)
         (not (string-empty-p glyph))
         (not (mdview-faces-glyph-fits-p glyph))
         mdview-image-glyph-fallback)))

(defvar mdview-faces--profile nil
  "The glyph profile resolved for the current rendering, or nil.
A cons (ASCII . IMAGE): ASCII is non-nil when the ASCII profile is in
use and IMAGE is the string overriding the `image' glyph, or nil.
`mdview-render-document' binds it to `mdview-faces-resolve-glyphs' so
that `mdview-glyph' probes the display once per document rather than
once per glyph.  When nil every call of `mdview-glyph' probes.")

(defun mdview-faces-resolve-glyphs ()
  "Probe the display and return the glyph profile for `mdview-faces--profile'."
  (let ((ascii (and (mdview-faces-ascii-p) t)))
    (cons ascii (and (not ascii) (mdview-faces--image-glyph-override)))))

(defun mdview-glyph (key)
  "Return the glyph string for KEY from the active glyph profile.
KEY is one of the keys of `mdview-glyphs'.  Falls back to the other
profile when KEY is missing from the active one, and to the empty string
when KEY is unknown, so rendering never signals.  The `image' glyph is
subject to `mdview-image-glyph-fallback'."
  (let* ((profile mdview-faces--profile)
         (ascii (if profile (car profile) (mdview-faces-ascii-p))))
    (or (and (eq key 'image) (not ascii)
             (if profile (cdr profile) (mdview-faces--image-glyph-override)))
        (and ascii (cdr (assq key mdview-ascii-glyphs)))
        (cdr (assq key mdview-glyphs))
        (cdr (assq key mdview-ascii-glyphs))
        "")))

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

;;;; Panel colour

;; The panel behind level-2 headings and tables is derived from the two
;; colours every theme defines, the `default' background and foreground,
;; so that it suits any theme, not only the ones tried.  The step from
;; the background towards the foreground is taken in CIE Lab, where equal
;; steps look equal on every hue, and is then held between a floor (the
;; panel must be visible) and a ceiling (the text must stay readable on
;; it).

(defconst mdview-faces--panel-min-distance 4.0
  "Smallest CIE76 distance between the page and a derived panel colour.
Flat colours closer than about 2.3 cannot be told apart; 4 reads as a
deliberate but quiet step on an ordinary display.")

(defconst mdview-faces--panel-contrast-limit 4.5
  "Contrast ratio of text on a panel that is always readable enough.")

(defconst mdview-faces--panel-contrast-keep 0.85
  "Fraction of the page's own text contrast that a panel must keep.
It lowers the requirement for themes whose text contrast is below
`mdview-faces--panel-contrast-limit' to begin with.")

(defun mdview-faces--luminance (rgb)
  "Return the WCAG relative luminance of RGB, a list (R G B) in 0..1."
  (let ((lin (mapcar (lambda (c)
                       (if (<= c 0.04045)
                           (/ c 12.92)
                         (expt (/ (+ c 0.055) 1.055) 2.4)))
                     rgb)))
    (+ (* 0.2126 (nth 0 lin)) (* 0.7152 (nth 1 lin)) (* 0.0722 (nth 2 lin)))))

(defun mdview-faces-contrast (a b)
  "Return the WCAG contrast ratio, from 1 to 21, of the colours A and B.
Both are lists (R G B) of floats in 0..1."
  (let ((la (mdview-faces--luminance a))
        (lb (mdview-faces--luminance b)))
    (/ (+ (max la lb) 0.05) (+ (min la lb) 0.05))))

(defun mdview-faces--lab (rgb)
  "Return RGB, a list (R G B) in 0..1, as a CIE Lab list (L A B)."
  (apply #'color-srgb-to-lab rgb))

(defun mdview-faces--from-lab (lab)
  "Return the CIE Lab list LAB as (R G B) on the 8-bit grid, clipped to sRGB."
  (mapcar (lambda (v) (/ (round (* 255 (max 0.0 (min 1.0 v)))) 255.0))
          (apply #'color-lab-to-srgb lab)))

(defun mdview-faces--lab-distance (a b)
  "Return the Euclidean (CIE76) distance between the Lab lists A and B."
  (sqrt (apply #'+ (seq-mapn (lambda (x y) (expt (- x y) 2)) a b))))

(defun mdview-faces-panel (rgb foreground fraction)
  "Return the panel colour for the page background RGB as #RRGGBB.
RGB and FOREGROUND, the text colour, are lists (R G B) of floats in
0..1.  The panel lies FRACTION of the way from RGB towards FOREGROUND in
CIE Lab, but never closer to RGB than `mdview-faces--panel-min-distance'
and never so close to FOREGROUND that text on it falls below the
contrast set by `mdview-faces--panel-contrast-limit' and
`mdview-faces--panel-contrast-keep'.  When no such colour exists, as
when the text is nearly the colour of the page, the panel is moved the
other way, away from the text.  A nil FOREGROUND stands for white on a
dark background and black on a light one."
  (let* ((dark (mdview-faces-dark-p rgb))
         (text (or foreground (if dark '(1.0 1.0 1.0) '(0.0 0.0 0.0))))
         (bg-lab (mdview-faces--lab rgb))
         (text-lab (mdview-faces--lab text))
         (gap (mdview-faces--lab-distance bg-lab text-lab))
         (need (min mdview-faces--panel-contrast-limit
                    (* mdview-faces--panel-contrast-keep
                       (mdview-faces-contrast rgb text))))
         (at (lambda (k)
               (mdview-faces--from-lab
                (seq-mapn (lambda (a b) (+ a (* k (- b a)))) bg-lab text-lab))))
         (readable (lambda (k)
                     (>= (mdview-faces-contrast (funcall at k) text) need)))
         ;; Largest fraction at which the text is still readable.
         (kmax (if (funcall readable 1.0)
                   1.0
                 (let ((lo 0.0) (hi 1.0))
                   (dotimes (_ 14)
                     (let ((mid (/ (+ lo hi) 2)))
                       (if (funcall readable mid) (setq lo mid) (setq hi mid))))
                   lo)))
         ;; Smallest fraction at which the panel is visible.
         (kmin (if (> gap 0.0) (/ mdview-faces--panel-min-distance gap) 2.0))
         (fraction (max 0.0 (min 1.0 fraction))))
    (mdview-faces-rgb-to-hex
     (if (<= kmin kmax)
         (funcall at (max kmin (min kmax fraction)))
       ;; Visible and readable cannot both hold towards the text, so move
       ;; away from it, which only improves the contrast.
       (let* ((direction (cond ((> (car text-lab) (car bg-lab)) -1.0)
                               ((< (car text-lab) (car bg-lab)) 1.0)
                               (dark 1.0)
                               (t -1.0)))
              (shift (max mdview-faces--panel-min-distance (* 50.0 fraction)))
              (shifted (lambda (sign)
                         (mdview-faces--from-lab
                          (list (+ (car bg-lab) (* sign direction shift))
                                (nth 1 bg-lab) (nth 2 bg-lab)))))
              (visible (lambda (color)
                         (>= (mdview-faces--lab-distance
                              (mdview-faces--lab color) bg-lab)
                             (* 0.75 mdview-faces--panel-min-distance)))))
         ;; Away from the text first; failing that (the page is at the edge
         ;; of the gamut that way) towards it, as the theme is then
         ;; unreadable anyway; as a last resort the readable limit.
         (cond ((funcall visible (funcall shifted 1.0)) (funcall shifted 1.0))
               ((funcall visible (funcall shifted -1.0)) (funcall shifted -1.0))
               (t (funcall at kmax))))))))

(declare-function tty-color-approximate "term/tty-colors" (rgb &optional frame))

(defconst mdview-faces--panel-max-drift 8.0
  "Largest CIE76 distance between a panel colour and what a terminal draws.
A 256-colour palette is coarse in its colour cube; beyond this the
rounding turns a quiet panel into a loud one.")

(defun mdview-faces--panel-drawable-p (page panel)
  "Return non-nil when this display draws the colour PANEL well against PAGE.
Both are #RRGGBB strings.  Graphical and true-colour displays draw any
colour as it is.  A 256-colour terminal rounds colours to its palette;
PANEL is drawable when the entry Emacs picks for it differs from the one
for PAGE and lies within `mdview-faces--panel-max-drift' of PANEL.  The
entry is what `tty-color-approximate' returns for a list of 16-bit
components: (NAME INDEX R G B), with R, G and B again in 0..65535.  A
terminal with fewer colours has no subtle steps to offer."
  (cond
   ((or noninteractive (display-graphic-p) (>= (display-color-cells) 65536)) t)
   ((>= (display-color-cells) 256)
    (let* ((sixteen-bit (lambda (hex)
                          (mapcar (lambda (v) (round (* 65535 v)))
                                  (mdview-faces-color-rgb hex))))
           (page-entry (tty-color-approximate (funcall sixteen-bit page)))
           (panel-entry (tty-color-approximate (funcall sixteen-bit panel))))
      (and (not (equal page-entry panel-entry))
           (< (mdview-faces--lab-distance
               (mdview-faces--lab
                (mapcar (lambda (v) (/ v 65535.0)) (nthcdr 2 panel-entry)))
               (mdview-faces--lab (mdview-faces-color-rgb panel)))
              mdview-faces--panel-max-drift))))
   (t nil)))

(defun mdview-faces--display-panel (rgb foreground fraction)
  "Return the panel colour for the page RGB as this display draws it, or nil.
Like `mdview-faces-panel' (RGB, FOREGROUND and FRACTION mean the same
there), but the result must be drawable (`mdview-faces--panel-drawable-p'):
when the display draws it like the page, or far from what was intended,
FRACTION is raised in steps of 0.05, up to 0.3, until it is.  Nil means
no step helps."
  (let ((page (mdview-faces-rgb-to-hex rgb))
        (found nil))
    (while (and (not found) (<= fraction 0.3))
      (let ((candidate (mdview-faces-panel rgb foreground fraction)))
        (if (mdview-faces--panel-drawable-p page candidate)
            (setq found candidate)
          (setq fraction (+ fraction 0.05)))))
    found))

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

(defun mdview-faces-default-foreground ()
  "Return the `default' face foreground as an (R G B) list, or nil.
Nil means the colour is unavailable (batch mode, monochrome terminal)."
  (ignore-errors
    (mdview-faces-color-rgb (face-foreground 'default nil t))))

(defvar-local mdview-faces--remap-cookies nil
  "Cookies returned by `face-remap-add-relative' in this buffer.")

(defvar-local mdview-faces--remapped nil
  "Non-nil in buffers where `mdview-faces-remap' has run.
Such buffers get their derived faces recomputed when a theme is enabled
or disabled (see `mdview-faces-theme-changed').")

(defun mdview-faces-theme-changed (&rest _)
  "Recompute the derived faces in every buffer that has them.
Runs from `enable-theme-functions' and `disable-theme-functions' so that
open views follow the new `default' background without a re-render."
  (dolist (buffer (buffer-list))
    (when (buffer-local-value 'mdview-faces--remapped buffer)
      (with-current-buffer buffer
        (mdview-faces-remap)))))

(defun mdview-faces-remap ()
  "Install the theme-derived faces buffer-locally.
Computes the `mdview-quote', `mdview-quote-2' and `mdview-quote-3'
backgrounds with `mdview-faces-boost', the `mdview-box-frame'
foreground (equal to the buffer background) and, unless
`mdview-panel-blend' is nil, the `mdview-h2' and `mdview-table'
backgrounds (`mdview-faces--display-panel', which uses
`mdview-faces-panel') from the `default' face, and
installs them with `face-remap-add-relative'.  A background the display
cannot draw faithfully (a 256-colour terminal rounds to its palette)
is left to the face's own static colour.  Any earlier remapping by
this function is removed first.  When the default background cannot be
determined (as in batch mode) nothing is changed and no error is
signalled.  The buffer is remembered so that `mdview-faces-theme-changed'
refreshes it after `load-theme' or `disable-theme'.  Return the list of
remapping cookies."
  (mdview-faces-unremap)
  (setq mdview-faces--remapped t)
  (add-hook 'enable-theme-functions #'mdview-faces-theme-changed)
  (add-hook 'disable-theme-functions #'mdview-faces-theme-changed)
  (let ((rgb (mdview-faces-default-background)))
    (when rgb
      (let ((level 0)
            (page (mdview-faces-rgb-to-hex rgb)))
        (dolist (face '(mdview-quote mdview-quote-2 mdview-quote-3))
          (setq level (1+ level))
          (let ((quote-color (mdview-faces-boost rgb level)))
            (when (mdview-faces--panel-drawable-p page quote-color)
              (push (face-remap-add-relative face :background quote-color)
                    mdview-faces--remap-cookies)))))
      (push (face-remap-add-relative
             'mdview-box-frame :foreground (mdview-faces-rgb-to-hex rgb))
            mdview-faces--remap-cookies)
      (when (numberp mdview-panel-blend)
        ;; Without a colour of its own on this display the panel keeps the
        ;; static Frogmouth colour.
        (let ((panel (mdview-faces--display-panel
                      rgb (mdview-faces-default-foreground) mdview-panel-blend)))
          (when panel
            (dolist (face '(mdview-h2 mdview-table))
              (push (face-remap-add-relative face :background panel)
                    mdview-faces--remap-cookies)))))))
  mdview-faces--remap-cookies)

(defun mdview-faces-unremap ()
  "Remove the face remappings installed by `mdview-faces-remap'.
The buffer no longer follows theme changes until the next remap."
  (mapc #'face-remap-remove-relative mdview-faces--remap-cookies)
  (setq mdview-faces--remap-cookies nil
        mdview-faces--remapped nil))

(provide 'mdview-faces)
;;; mdview-faces.el ends here
