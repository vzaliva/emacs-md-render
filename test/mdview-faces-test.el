;;; mdview-faces-test.el --- Tests for mdview-faces  -*- lexical-binding: t; -*-

;; This file is part of mdview, distributed under the MIT license; see
;; LICENSE in the repository root.

;;; Commentary:

;; ERT tests for the faces, options, glyph tables and the colour derivation
;; in mdview-faces.el (docs/DESIGN.md §6, §7, §11, §12).  All tests run
;; headless.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'subr-x)                       ; `string-pixel-width' must not autoload under `cl-letf'
(require 'mdview-faces)

(defconst mdview-faces-test-faces
  '(mdview-h1 mdview-h2 mdview-h3 mdview-h4 mdview-h5 mdview-h6 mdview-h3-rule
    mdview-emphasis mdview-strong mdview-strikethrough mdview-inline-code
    mdview-link mdview-quote mdview-quote-2 mdview-quote-3 mdview-quote-border
    mdview-bullet mdview-task-checked mdview-task-unchecked mdview-rule
    mdview-box-frame mdview-muted mdview-footnote-ref mdview-table
    mdview-table-header mdview-table-rule mdview-code-block
    mdview-code-indent-guide mdview-image-placeholder mdview-image-caption
    mdview-summary mdview-alert-note mdview-alert-tip mdview-alert-important
    mdview-alert-warning mdview-alert-caution)
  "Every face that mdview-faces.el must define.")

(defconst mdview-faces-test-glyph-keys
  '(bullet-1 bullet-2 bullet-3 bullet-4 bullet-5 quote-bar box-top box-bottom
    box-left box-right rule thin-rule guide task-checked task-unchecked
    table-rule h3-rule image summary alert-note alert-tip alert-important
    alert-warning alert-caution)
  "Every key the glyph tables must contain.")

;;;; Faces and options

(ert-deftest mdview-faces-all-defined ()
  (dolist (face mdview-faces-test-faces)
    (should (facep face))
    (should (stringp (face-documentation face)))
    (should (assq face (get 'mdview 'custom-group)))))

(ert-deftest mdview-faces-attributes ()
  "Spot-check attributes that the spec fixes for both themes."
  (should (eq (face-attribute 'mdview-h1 :weight) 'bold))
  (should (equal (face-attribute 'mdview-h1 :background) "#0053AA"))
  (should (equal (face-attribute 'mdview-h1 :foreground) "#DDE8F3"))
  (should (eq (face-attribute 'mdview-h4 :underline) t))
  (should (eq (face-attribute 'mdview-emphasis :slant) 'italic))
  (should (eq (face-attribute 'mdview-strong :weight) 'bold))
  (should (eq (face-attribute 'mdview-strikethrough :strike-through) t))
  (should (eq (face-attribute 'mdview-link :underline) t))
  (should (equal (face-attribute 'mdview-code-block :background) "#263238"))
  (should (equal (face-attribute 'mdview-code-block :foreground) "#EEFFFF"))
  (should (equal (face-attribute 'mdview-code-indent-guide :foreground) "#4A5A63"))
  (should (equal (face-attribute 'mdview-rule :foreground) "#004578"))
  (should (equal (face-attribute 'mdview-table-rule :foreground) "#23568B"))
  (should (equal (face-attribute 'mdview-footnote-ref :foreground) "#0178D4"))
  (should (equal (face-attribute 'mdview-bullet :foreground) "#4EBF71"))
  (should (equal (face-attribute 'mdview-quote-border :foreground) "#4EBF71"))
  (should (eq (face-attribute 'mdview-table-header :weight) 'bold))
  (should (eq (face-attribute 'mdview-image-placeholder :inherit) 'mdview-link)))

(ert-deftest mdview-faces-theme-dependent-faces-have-colours ()
  "Faces whose colour depends on the theme still resolve to a colour."
  (dolist (face '(mdview-h2 mdview-h3-rule mdview-inline-code mdview-quote
                  mdview-quote-2 mdview-quote-3 mdview-box-frame mdview-muted
                  mdview-table))
    (let ((displays (mapcar #'car (face-default-spec face))))
      (should (member '((background dark)) displays))
      (should (member '((background light)) displays))
      (should (= (length displays) 2)))))

(ert-deftest mdview-faces-options ()
  (should (custom-variable-p 'mdview-glyphs))
  (should (custom-variable-p 'mdview-ascii-glyphs))
  (should (custom-variable-p 'mdview-use-ascii-glyphs))
  (should (custom-variable-p 'mdview-box-frame-style))
  (should (eq (default-value 'mdview-use-ascii-glyphs) 'auto))
  (should (eq (default-value 'mdview-box-frame-style) 'wide))
  (dolist (var '(mdview-glyphs mdview-ascii-glyphs mdview-use-ascii-glyphs
                 mdview-box-frame-style))
    (should (assq var (get 'mdview 'custom-group)))))

;;;; Glyphs

(ert-deftest mdview-glyph-tables-complete ()
  (dolist (key mdview-faces-test-glyph-keys)
    (should (stringp (cdr (assq key mdview-glyphs))))
    (should (stringp (cdr (assq key mdview-ascii-glyphs)))))
  (should (= (length mdview-glyphs) (length mdview-faces-test-glyph-keys)))
  (should (= (length mdview-ascii-glyphs) (length mdview-faces-test-glyph-keys))))

(ert-deftest mdview-glyph-unicode-defaults ()
  "In batch mode `auto' selects the Unicode profile."
  (skip-unless noninteractive)
  (should (equal (mdview-glyph 'bullet-1) "●"))
  (should (equal (mdview-glyph 'bullet-2) "▪"))
  (should (equal (mdview-glyph 'bullet-3) "‣"))
  (should (equal (mdview-glyph 'bullet-4) "•"))
  (should (equal (mdview-glyph 'bullet-5) "⭑"))
  (should (equal (mdview-glyph 'quote-bar) "▌"))
  (should (equal (mdview-glyph 'box-top) "▁"))
  (should (equal (mdview-glyph 'box-bottom) "▔"))
  (should (equal (mdview-glyph 'box-left) "▎"))
  (should (equal (mdview-glyph 'box-right) "▊"))
  (should (equal (mdview-glyph 'rule) "━"))
  (should (equal (mdview-glyph 'thin-rule) "─"))
  (should (equal (mdview-glyph 'guide) "│"))
  (should (equal (mdview-glyph 'task-checked) "☑"))
  (should (equal (mdview-glyph 'task-unchecked) "☐"))
  (should (equal (mdview-glyph 'table-rule) "━"))
  (should (equal (mdview-glyph 'h3-rule) "▔"))
  (should (equal (mdview-glyph 'image) "🖼"))
  (should (equal (mdview-glyph 'summary) "▸"))
  (should (equal (mdview-glyph 'alert-warning) "⚠")))

(ert-deftest mdview-glyph-ascii-profile ()
  (let ((mdview-use-ascii-glyphs t))
    (should (mdview-faces-ascii-p))
    (should (equal (mdview-glyph 'bullet-1) "*"))
    (should (equal (mdview-glyph 'bullet-2) "-"))
    (should (equal (mdview-glyph 'bullet-3) "+"))
    (should (equal (mdview-glyph 'quote-bar) "|"))
    (should (equal (mdview-glyph 'box-top) "-"))
    (should (equal (mdview-glyph 'task-checked) "[x]"))
    (should (equal (mdview-glyph 'task-unchecked) "[ ]"))
    (should (equal (mdview-glyph 'image) "[img]"))
    (dolist (key mdview-faces-test-glyph-keys)
      (should (string-match-p "\\`[[:ascii:]]+\\'" (mdview-glyph key)))))
  (let ((mdview-use-ascii-glyphs nil))
    (should-not (mdview-faces-ascii-p))
    (should (equal (mdview-glyph 'bullet-1) "●"))))

(ert-deftest mdview-glyph-unknown-and-fallback ()
  (should (equal (mdview-glyph 'no-such-glyph) ""))
  (let ((mdview-use-ascii-glyphs t)
        (mdview-ascii-glyphs '((bullet-1 . "*"))))
    ;; Missing from the ASCII profile: fall back to the Unicode glyph.
    (should (equal (mdview-glyph 'quote-bar) "▌"))))

(ert-deftest mdview-glyph-single-column ()
  "Frame, rule, bullet, bar, summary and alert glyphs are one column wide."
  (dolist (key (cl-set-difference mdview-faces-test-glyph-keys
                                  '(task-checked task-unchecked image)))
    (should (= (string-width (mdview-glyph key)) 1)))
  ;; The image fallback must be a single-column BMP symbol.
  (should (= (string-width mdview-image-glyph-fallback) 1))
  (should (< (aref mdview-image-glyph-fallback 0) #x10000)))

(ert-deftest mdview-glyph-fits-p-batch ()
  "In batch mode every glyph is assumed to fit, so the emoji stays."
  (skip-unless noninteractive)
  (should (mdview-faces-glyph-fits-p "🖼"))
  (should (mdview-faces-glyph-fits-p "▣"))
  (should-not (mdview-faces--image-glyph-override))
  (should (equal (mdview-faces-resolve-glyphs) '(nil . nil))))

(ert-deftest mdview-glyph-image-fallback-on-text-terminal ()
  "On a text terminal a non-BMP image glyph is replaced by the fallback."
  (cl-letf (((symbol-value 'noninteractive) nil)
            ((symbol-function 'display-graphic-p) (lambda (&rest _) nil))
            ((symbol-function 'char-displayable-p) (lambda (&rest _) t)))
    (should-not (mdview-faces-glyph-fits-p "🖼"))
    (should (mdview-faces-glyph-fits-p "▣"))
    (should (mdview-faces-glyph-fits-p "[img]"))
    (should (equal (mdview-faces--image-glyph-override) mdview-image-glyph-fallback))
    (should (equal (mdview-glyph 'image) mdview-image-glyph-fallback))
    (should (equal (mdview-faces-resolve-glyphs)
                   (cons nil mdview-image-glyph-fallback)))
    ;; A user-chosen BMP glyph is kept.
    (let ((mdview-glyphs (cons '(image . "◫") mdview-glyphs)))
      (should (equal (mdview-glyph 'image) "◫")))
    ;; The ASCII profile has its own marker and needs no fallback.
    (let ((mdview-use-ascii-glyphs t))
      (should (equal (mdview-glyph 'image) "[img]"))
      (should (equal (mdview-faces-resolve-glyphs) '(t . nil))))))

(ert-deftest mdview-glyph-image-fallback-on-graphic-display ()
  "On a graphical frame the glyph must be drawn exactly one column wide."
  (let ((pixels 10))
    (cl-letf (((symbol-value 'noninteractive) nil)
              ((symbol-function 'display-graphic-p) (lambda (&rest _) t))
              ((symbol-function 'char-displayable-p) (lambda (&rest _) t))
              ((symbol-function 'frame-char-width) (lambda (&rest _) 7))
              ((symbol-function 'string-pixel-width) (lambda (&rest _) pixels)))
      (should-not (mdview-faces-glyph-fits-p "🖼"))
      (should (equal (mdview-glyph 'image) mdview-image-glyph-fallback))
      (setq pixels 7)
      (should (mdview-faces-glyph-fits-p "🖼"))
      (should (equal (mdview-glyph 'image) "🖼")))))

(ert-deftest mdview-glyph-uses-bound-profile ()
  "A resolved profile in `mdview-faces--profile' is used without probing."
  (let ((probes 0))
    (cl-letf (((symbol-function 'mdview-faces-ascii-p)
               (lambda () (setq probes (1+ probes)) nil)))
      (let ((mdview-faces--profile '(t . nil)))
        (should (equal (mdview-glyph 'bullet-1) "*"))
        (should (equal (mdview-glyph 'image) "[img]")))
      (let ((mdview-faces--profile '(nil . "▣")))
        (should (equal (mdview-glyph 'bullet-1) "●"))
        (should (equal (mdview-glyph 'image) "▣")))
      (let ((mdview-faces--profile '(nil . nil)))
        (should (equal (mdview-glyph 'image) "🖼")))
      (should (= probes 0))
      (let ((mdview-faces--profile nil))
        (mdview-glyph 'bullet-1)
        (should (= probes 1))))))

;;;; Colour derivation

(ert-deftest mdview-faces-color-rgb-parsing ()
  (should (equal (mdview-faces-color-rgb "#000000") '(0.0 0.0 0.0)))
  (should (equal (mdview-faces-color-rgb "#ffffff") '(1.0 1.0 1.0)))
  (should (equal (mdview-faces-color-rgb "#FFF") '(1.0 1.0 1.0)))
  (let ((rgb (mdview-faces-color-rgb "#1E1E1E")))
    (should (= (length rgb) 3))
    (should (< (abs (- (car rgb) (/ 30 255.0))) 1e-6)))
  (should (equal (mdview-faces-color-rgb "rgb:ff/00/00") '(1.0 0.0 0.0)))
  (should-not (mdview-faces-color-rgb "unspecified-bg"))
  (should-not (mdview-faces-color-rgb "unspecified"))
  (should-not (mdview-faces-color-rgb nil))
  (should-not (mdview-faces-color-rgb "not a colour at all"))
  (when noninteractive
    ;; Colour names need a display; in batch they are unknown, not black.
    (should-not (mdview-faces-color-rgb "white"))))

(ert-deftest mdview-faces-rgb-to-hex ()
  (should (equal (mdview-faces-rgb-to-hex '(0.0 0.0 0.0)) "#000000"))
  (should (equal (mdview-faces-rgb-to-hex '(1.0 1.0 1.0)) "#ffffff"))
  (should (equal (mdview-faces-rgb-to-hex (mdview-faces-color-rgb "#1E1E1E"))
                 "#1e1e1e"))
  ;; Rounds and clamps.
  (should (equal (mdview-faces-rgb-to-hex '(0.1529 0.5 1.2)) "#2780ff")))

(ert-deftest mdview-faces-dark-p ()
  (should (mdview-faces-dark-p (mdview-faces-color-rgb "#1E1E1E")))
  (should (mdview-faces-dark-p '(0.0 0.0 0.0)))
  (should-not (mdview-faces-dark-p (mdview-faces-color-rgb "#F5F5F5")))
  (should-not (mdview-faces-dark-p '(1.0 1.0 1.0))))

(ert-deftest mdview-faces-blend ()
  (should (equal (mdview-faces-blend '(0.0 0.0 0.0) '(1.0 1.0 1.0) 0.5)
                 '(0.5 0.5 0.5)))
  (should (equal (mdview-faces-blend '(0.2 0.4 0.6) '(0.2 0.4 0.6) 0.3)
                 '(0.2 0.4 0.6)))
  (should (equal (mdview-faces-blend '(1.0 0.0 0.0) '(0.0 0.0 0.0) 0.0)
                 '(1.0 0.0 0.0))))

(ert-deftest mdview-faces-boost-matches-static-specs ()
  "Boosting Textual's app background reproduces the static face colours."
  (let ((dark (mdview-faces-color-rgb "#1E1E1E"))
        (light (mdview-faces-color-rgb "#F5F5F5")))
    (should (equal (mdview-faces-boost dark 1) "#272727"))
    (should (equal (mdview-faces-boost dark 2) "#303030"))
    (should (equal (mdview-faces-boost dark 3) "#383838"))
    (should (equal (mdview-faces-boost light 1) "#ebebeb"))
    (should (equal (mdview-faces-boost light 2) "#e2e2e2"))
    (should (equal (mdview-faces-boost light 3) "#d9d9d9"))
    ;; Level 0 behaves like level 1 rather than returning the input.
    (should (equal (mdview-faces-boost dark 0) "#272727"))))

(ert-deftest mdview-faces-remap-batch-noop ()
  "Without a known default background nothing is remapped and nothing errs."
  (skip-unless noninteractive)
  (should-not (mdview-faces-default-background))
  (with-temp-buffer
    (should-not (mdview-faces-remap))
    (should-not face-remapping-alist)
    (should-not mdview-faces--remap-cookies)
    (mdview-faces-unremap)
    (should-not face-remapping-alist)
    ;; Unremap twice is harmless.
    (mdview-faces-unremap)
    (should-not mdview-faces--remap-cookies)))

(ert-deftest mdview-faces-remap-with-known-background ()
  "With a resolvable default background the derived faces are installed."
  (with-temp-buffer
    (cl-letf (((symbol-function 'face-background)
               (lambda (&rest _) "#1E1E1E")))
      (should (= (length (mdview-faces-remap)) 4))
      (should (= (length mdview-faces--remap-cookies) 4))
      (should (local-variable-p 'face-remapping-alist))
      (should (member '(:background "#272727")
                      (cdr (assq 'mdview-quote face-remapping-alist))))
      (should (member '(:background "#303030")
                      (cdr (assq 'mdview-quote-2 face-remapping-alist))))
      (should (member '(:background "#383838")
                      (cdr (assq 'mdview-quote-3 face-remapping-alist))))
      (should (member '(:foreground "#1e1e1e")
                      (cdr (assq 'mdview-box-frame face-remapping-alist))))
      ;; Remapping again replaces rather than accumulates.
      (mdview-faces-remap)
      (should (= (length mdview-faces--remap-cookies) 4))
      (mdview-faces-unremap)
      (should-not mdview-faces--remap-cookies)
      (should-not (assq 'mdview-quote face-remapping-alist)))
    ;; A light background blends towards black.
    (cl-letf (((symbol-function 'face-background)
               (lambda (&rest _) "#F5F5F5")))
      (mdview-faces-remap)
      (should (member '(:background "#ebebeb")
                      (cdr (assq 'mdview-quote face-remapping-alist))))
      (mdview-faces-unremap))))

(ert-deftest mdview-faces-remap-follows-theme-changes ()
  "Enabling or disabling a theme recomputes the derived faces of every view."
  (let ((background "#1E1E1E"))
    (cl-letf (((symbol-function 'face-background)
               (lambda (&rest _) background)))
      (with-temp-buffer
        (let ((view (current-buffer)))
          (mdview-faces-remap)
          (should mdview-faces--remapped)
          (should (memq #'mdview-faces-theme-changed enable-theme-functions))
          (should (memq #'mdview-faces-theme-changed disable-theme-functions))
          (should (member '(:background "#272727")
                          (cdr (assq 'mdview-quote face-remapping-alist))))
          ;; The theme changes the default background: the hook refreshes.
          (setq background "#F5F5F5")
          (with-temp-buffer
            (mdview-faces-theme-changed 'some-theme))
          (should (member '(:background "#ebebeb")
                          (cdr (assq 'mdview-quote
                                     (buffer-local-value 'face-remapping-alist view)))))
          (should (member '(:foreground "#f5f5f5")
                          (cdr (assq 'mdview-box-frame
                                     (buffer-local-value 'face-remapping-alist view)))))
          (should (= (length mdview-faces--remap-cookies) 4))
          ;; After unremapping the buffer is left alone.
          (mdview-faces-unremap)
          (should-not mdview-faces--remapped)
          (setq background "#1E1E1E")
          (mdview-faces-theme-changed 'some-theme)
          (should-not face-remapping-alist))))))

(ert-deftest mdview-faces-remap-is-buffer-local ()
  (with-temp-buffer
    (cl-letf (((symbol-function 'face-background)
               (lambda (&rest _) "#1E1E1E")))
      (mdview-faces-remap)
      (let ((cookies mdview-faces--remap-cookies))
        (with-temp-buffer
          (should-not mdview-faces--remap-cookies)
          (should-not face-remapping-alist))
        (should (eq cookies mdview-faces--remap-cookies)))
      (mdview-faces-unremap))))

(provide 'mdview-faces-test)
;;; mdview-faces-test.el ends here
