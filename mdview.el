;;; mdview.el --- Render Markdown in the style of Frogmouth  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Vadim Zaliva
;; Author: Vadim Zaliva
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: text, docs, markdown
;; URL: https://github.com/vzaliva/emacs-md-render
;; This file is part of mdview, distributed under the MIT license; see
;; LICENSE in the repository root.

;;; Commentary:

;; mdview renders a Markdown buffer in place, read-only, laid out in the
;; visual style of Frogmouth (docs/DESIGN.md).  This file is the
;; user-facing part of the package: the minor mode `mdview-mode', which
;; switches a buffer between its Markdown source and the rendering, the
;; commands (`mdview', `mdview-file', `mdview-toggle'), the keymap, link
;; following, the per-window history, automatic re-flow when the window
;; width changes, the hooks that keep a rendered buffer correct across
;; saving, reverting and major-mode changes, and the integration with
;; Markdown editing modes (`mdview-install-keybinding',
;; `mdview-initial-view').
;;
;; The rendering never edits the source text.  It is built in a hidden
;; buffer and exchanged with the source text by `buffer-swap-text'; the
;; source text waits in a hidden twin buffer, with its markers, overlays,
;; text properties, undo list and modified state, until it is swapped
;; back (docs/DESIGN.md section 10).  The renderer marks the first line
;; of every block with the text property `mdview-source-line', which keeps
;; point on the same block in both directions.
;;
;; Everything degrades gracefully without a display, so the package works
;; in `emacs -nw' and its tests run under `emacs --batch'.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'imenu)
(require 'browse-url)
(require 'text-property-search)
(require 'face-remap)                   ; text-scale-mode-hook
(require 'url-parse)
(require 'url-util)
(require 'mdview-ast)
(require 'mdview-faces)
(require 'mdview-inline)
(require 'mdview-parse)
(require 'mdview-code)
(require 'mdview-image)
(require 'mdview-table)
(require 'mdview-render)

(defconst mdview-version "0.1.0"
  "Version of the mdview package.")

;;;; Options

(defcustom mdview-max-width 100
  "Maximum content width of a rendering in columns, or nil for no limit.
The content width is the window width minus the margins, capped at this
value (docs/DESIGN.md section 10)."
  :type '(choice (const :tag "Unlimited" nil)
                 (integer :tag "Columns"))
  :group 'mdview)

(defcustom mdview-width-step 4
  "Columns by which one width adjustment changes the text of a rendering.
See `mdview-increase-width' and `mdview-decrease-width'."
  :type 'natnum
  :group 'mdview)

(defcustom mdview-edit-on-typing t
  "Non-nil means typing into a rendering edits the Markdown source.
A self-inserting key pressed while a buffer is rendered switches the
buffer to its source at the word at point and inserts the character
there (see `mdview-self-insert').  When nil, such a key only reports
that the rendering is read-only."
  :type 'boolean
  :group 'mdview)

(defcustom mdview-margin 4
  "Width in columns of the left and right margins of a rendering."
  :type 'integer
  :group 'mdview)

(defcustom mdview-center-content nil
  "Non-nil means center the content when the window is wider than needed.
The left margin grows so that content limited by `mdview-max-width' sits
in the middle of the window."
  :type 'boolean
  :group 'mdview)

(defcustom mdview-auto-refit t
  "Non-nil means re-render when the width of the buffer's window changes.
The re-rendering happens after `mdview-refit-delay' seconds of idle time
and only when the effective content width actually changed."
  :type 'boolean
  :group 'mdview)

(defcustom mdview-refit-delay 0.2
  "Idle time in seconds before a rendering is redone after a resize."
  :type 'number
  :group 'mdview)

(defcustom mdview-markdown-extensions '("md" "markdown" "mdown" "mkd" "mkdn")
  "File name extensions (lower case, without the dot) of Markdown files.
Links to such files are visited and shown rendered; links to other local
files are visited with `find-file-other-window'."
  :type '(repeat string)
  :group 'mdview)

;;;###autoload
(defcustom mdview-initial-view 'edit
  "How a Markdown file is shown when it is visited.
`edit' shows the Markdown source, as Emacs always does; `view' turns on
`mdview-mode' so that the file opens rendered (\\[mdview-toggle] switches
to the source).  A file counts as Markdown when its major mode
derives from one of `mdview-markdown-modes'."
  :type '(choice (const :tag "Markdown source (edit)" edit)
                 (const :tag "Rendered (view)" view))
  :group 'mdview)

(defcustom mdview-markdown-modes '(markdown-mode gfm-mode md-mode markdown-ts-mode)
  "Major modes whose files `mdview-initial-view' applies to.
Modes derived from these count as well."
  :type '(repeat symbol)
  :group 'mdview)

(defcustom mdview-suspended-modes
  '(flyspell-mode visual-line-mode whitespace-mode display-line-numbers-mode
    display-fill-column-indicator-mode visual-fill-column-mode olivetti-mode)
  "Buffer-local minor modes that are switched off while a buffer is rendered.
These modes act on the text of the buffer or on its windows in ways
that make no sense for the rendering (spell-checking it, numbering its
lines, wrapping lines the renderer already laid out, setting margins of
their own).  A mode
in this list that is on when `mdview-mode' renders the buffer is turned
off, and turned on again when the buffer returns to its source.  Modes
that are not loaded are ignored.  Do not list global minor modes."
  :type '(repeat symbol)
  :group 'mdview)

;;;; Buffer-local state

(defvar-local mdview--rendered nil
  "Non-nil when the text of this buffer is currently its rendering.
`mdview-mode' follows this flag; the internal functions test this one,
which is only ever set together with an actual swap of the text.")

(defvar-local mdview--twin nil
  "The hidden buffer holding this buffer's other text, or nil.
While the buffer is rendered the twin holds the Markdown source; while
it shows the source the twin may hold the last rendering, which is
reused when nothing changed (see `mdview--twin-key').")

(defvar-local mdview--owner nil
  "In a hidden twin or render buffer: the buffer it works for.")

(defvar-local mdview--source-key nil
  "A value identifying the source text as it was after the last swap.
See `mdview--current-source-key'.  The parsed document and a rendering
held by the twin are valid while the key of the source still matches.")

(defvar-local mdview--twin-key nil
  "The (WIDTH IMAGES) of the rendering held by the twin, or nil.
Only meaningful while the buffer shows its source; nil when the twin
holds no usable rendering.")

(defvar-local mdview--document nil
  "The parsed source of this buffer, or nil.
It is valid while `mdview--source-key' matches the source text (always,
while the buffer is rendered: nothing can change the source then).")

(defvar-local mdview--base-dir nil
  "The directory against which relative links and images resolve.")

(defvar-local mdview--last-width nil
  "The content width used by the current rendering.")

(defvar-local mdview--last-scale nil
  "The image scale factor of the current rendering (`mdview--image-scale').")

(defvar-local mdview--images-enabled 'unset
  "Non-nil means this buffer's rendering displays images.
The value `unset' means `mdview-display-images' has not been consulted
yet.  See `mdview-toggle-images'.")
(put 'mdview--images-enabled 'permanent-local t)

(defvar-local mdview--width-override nil
  "The text width chosen with `mdview-set-width' for this buffer, or nil.
Non-nil replaces `mdview-max-width' as the limit of the content width.")
(put 'mdview--width-override 'permanent-local t)

(defvar-local mdview--saved nil
  "Settings replaced while the buffer is rendered: (VAR LOCAL-P VALUE)...")

(defvar-local mdview--suspended nil
  "The minor modes of `mdview-suspended-modes' that rendering switched off.")

(defvar-local mdview--memory nil
  "Where the last swap put point and the windows, and where they were.
A list of (WINDOW SET-POINT OLD-POINT OLD-START); WINDOW nil stands for
the buffer's own point.  When the next swap brings back the text that
the last one put away and a window's point is still SET-POINT, that
window gets OLD-POINT and OLD-START back exactly.")

(defvar-local mdview--refit-timer nil
  "The idle timer scheduled by `mdview--window-size-changed', or nil.")

(defvar-local mdview--image-update-timer nil
  "The idle timer scheduled by `mdview--on-images-updated', or nil.")

(defvar-local mdview--resume-after-save nil
  "Non-nil while a save of the rendered buffer has put its source back.")

(defvar-local mdview--narrowing nil
  "The source's restriction as (START . END) markers during a save, or nil.")

(defvar-local mdview--resume-after-revert nil
  "Non-nil while a revert of the rendered buffer has put its source back.
Permanent, because a revert may change the major mode in between.")
(put 'mdview--resume-after-revert 'permanent-local t)

(defvar mdview--render-gc-threshold (* 64 1024 1024)
  "Value `gc-cons-threshold' is raised to while a document is rendered.
The renderer allocates many short-lived strings and lists; with the
default threshold a large document triggers hundreds of collections,
each re-marking the intervals of every open rendering, and the
collections dominate the rendering time.")

(defconst mdview--overridden-settings
  '(buffer-read-only truncate-lines word-wrap
    left-margin-width right-margin-width
    fontification-functions jit-lock-mode jit-lock-functions
    jit-lock-context-unfontify-pos
    font-lock-fontify-region-function font-lock-unfontify-region-function
    syntax-propertize-function
    imenu-create-index-function imenu--index-alist
    buffer-auto-save-file-name mark-ring
    window-configuration-change-hook)
  "Buffer settings that a rendering replaces and leaving it restores.
See `mdview--apply-view-settings' for the values used while rendered.")

;;;; Keymap and mode

(defvar mdview-mode-map
  (let ((map (make-sparse-keymap)))
    ;; Typing edits the source; every other key is a `C-c' chord that
    ;; outline-mode, org-mode or markdown-mode use for the same thing,
    ;; or a key of buttons and `view-mode' (docs/DESIGN.md section 10.3).
    (define-key map [remap self-insert-command] #'mdview-self-insert)
    (define-key map (kbd "C-c C-v") #'mdview-toggle)
    (define-key map (kbd "C-c C-n") #'mdview-next-heading)
    (define-key map (kbd "C-c C-p") #'mdview-previous-heading)
    (define-key map (kbd "C-c C-f") #'mdview-forward-heading-same-level)
    (define-key map (kbd "C-c C-b") #'mdview-backward-heading-same-level)
    (define-key map (kbd "C-c C-u") #'mdview-up-heading)
    (define-key map (kbd "C-c C-j") #'mdview-toc)
    (define-key map (kbd "TAB") #'mdview-next-link)
    (define-key map [backtab] #'mdview-previous-link)
    (define-key map [S-tab] #'mdview-previous-link)
    (define-key map (kbd "C-c C-x C-n") #'mdview-next-link)
    (define-key map (kbd "C-c C-x C-p") #'mdview-previous-link)
    (define-key map (kbd "RET") #'mdview-follow-link)
    (define-key map (kbd "C-c C-o") #'mdview-follow-link)
    (define-key map [mouse-1] #'mdview-mouse-follow-link)
    (define-key map [mouse-2] #'mdview-mouse-follow-link)
    (define-key map (kbd "C-c C-l") #'mdview-copy-link)
    (define-key map (kbd "C-c &") #'mdview-history-back)
    (define-key map (kbd "C-c <left>") #'mdview-history-back)
    (define-key map (kbd "C-c <right>") #'mdview-history-forward)
    (define-key map (kbd "C-c C-x C-v") #'mdview-toggle-images)
    (define-key map (kbd "C-c C-x C-i") #'mdview-toggle-images)
    (define-key map (kbd "C-c C-r") #'mdview-refresh)
    (define-key map (kbd "SPC") #'scroll-up-command)
    (define-key map (kbd "DEL") #'scroll-down-command)
    (define-key map (kbd "S-SPC") #'scroll-down-command)
    (define-key map (kbd "C->") #'mdview-increase-width)
    (define-key map (kbd "C-<") #'mdview-decrease-width)
    (define-key map (kbd "C-0") #'mdview-reset-width)
    map)
  "Keymap of `mdview-mode', active while a buffer is rendered.")

;;;###autoload
(define-minor-mode mdview-mode
  "Show the Markdown in the current buffer rendered, in place.
When enabled, the text of the buffer is replaced by its rendering in
the style of Frogmouth, read-only; when disabled, the Markdown source
comes back exactly as it was (point, mark, markers, overlays, undo
history and fontification included) at the line of the block that
point was on.  The buffer keeps its major mode, file and name, so
saving, reverting and auto-revert keep working: a save writes the
source, and a revert renders the reloaded text.

The source is never edited by the rendering: it is kept in a hidden
buffer while the buffer is rendered (see docs/DESIGN.md section 10).
Typing a character while rendered switches to the source at the word
at point and inserts it there (`mdview-edit-on-typing').  Indirect
buffers, and buffers that have indirect buffers, cannot be rendered in
place.

\\{mdview-mode-map}"
  :lighter " mdview"
  :keymap mdview-mode-map
  :group 'mdview
  (if mdview-mode
      (unless mdview--rendered
        (condition-case err
            (mdview--enter)
          (error
           (setq mdview-mode nil)
           (signal (car err) (cdr err)))))
    (when mdview--rendered
      (mdview--leave))))

;;;; Width and margins

(defun mdview--column-scale (window)
  "Return the width of a column of text in WINDOW relative to a frame column.
The text is that of the current buffer, which WINDOW normally shows:
the ratio is 1.0 unless `text-scale-mode' (or another remapping of the
`default' face) changes the size of its text, and always 1.0 without a
graphical display."
  (let ((frame (window-frame window)))
    (if (display-graphic-p frame)
        (let ((frame-width (frame-char-width frame))
              (text-width (mdview-image-char-width window)))
          (if (and text-width (> frame-width 0))
              (/ (float text-width) frame-width)
            1.0))
      1.0)))

(defun mdview--window-columns (window)
  "Return the width of WINDOW's body plus its display margins, in text columns.
Text columns are those of the current buffer's `default' face: when
`text-scale-mode' enlarges it, fewer of them fit in WINDOW than the
frame's columns (see `mdview--column-scale')."
  (let ((margins (window-margins window)))
    (floor (+ (window-body-width window)
              (or (car margins) 0)
              (or (cdr margins) 0))
           (mdview--column-scale window))))

(defun mdview--image-scale ()
  "Return the factor applied to images in a rendering of the current buffer.
See `mdview-image-scale-factor'; the text is measured in a window
showing the buffer when there is one."
  (mdview-image-scale-factor (mdview--view-window)))

(defun mdview--view-window ()
  "Return a window showing the current buffer, else the selected window."
  (or (get-buffer-window (current-buffer))
      (get-buffer-window (current-buffer) t)
      (selected-window)))

(defun mdview--available-width (&optional window)
  "Return the content width available for a rendering in WINDOW.
WINDOW defaults to a window showing the current buffer.  This is the
window width in text columns minus the margins and one column; it may
be smaller than the 20 columns a rendering always gets."
  (- (mdview--window-columns (or window (mdview--view-window)))
     (* 2 mdview-margin) 1))

(defun mdview--content-width (&optional window)
  "Return the content width for a rendering in WINDOW.
WINDOW defaults to a window showing the current buffer.  This is the
width WINDOW leaves (`mdview--available-width'), limited by the width
chosen with `mdview-set-width' or else by `mdview-max-width', and never
less than 20 (docs/DESIGN.md section 10)."
  (let ((available (mdview--available-width window))
        (limit (or mdview--width-override mdview-max-width)))
    (max 20 (if limit (min available limit) available))))

(defun mdview--set-window-margins ()
  "Give every window showing the current buffer the buffer's margins.
`set-window-margins' is used rather than `set-window-buffer', which
would also reset the window's start and point."
  (dolist (window (get-buffer-window-list (current-buffer) nil t))
    (set-window-margins window left-margin-width right-margin-width)))

(defun mdview--apply-margins (width)
  "Set the display margins of the rendering for content WIDTH.
With `mdview-center-content', the left margin absorbs the space left over
by `mdview-max-width'.  The margins are `mdview-margin' columns of the
buffer's text, converted to the frame columns that display margins are
measured in (`mdview--column-scale').  The windows showing the buffer
are updated."
  (let* ((windows (get-buffer-window-list (current-buffer) nil t))
         (window (or (car windows) (selected-window)))
         (columns (mdview--window-columns window))
         (scale (mdview--column-scale window))
         (extra (if mdview-center-content
                    (max 0 (- columns 1 (* 2 mdview-margin) width))
                  0)))
    (setq left-margin-width (floor (* (+ mdview-margin (/ extra 2)) scale))
          right-margin-width (floor (* mdview-margin scale)))
    (mdview--set-window-margins)))

;;;; The source text and the rendering pipeline

(defun mdview--source-holder ()
  "Return the buffer whose text is the Markdown source of this buffer."
  (if mdview--rendered mdview--twin (current-buffer)))

(defun mdview--current-source-key ()
  "Return a value identifying the source text as it is now.
It combines `buffer-chars-modified-tick' with the accessible portion of
the buffer holding the source.  Each swap of the text changes the tick,
so the key is recorded right after every swap."
  (with-current-buffer (mdview--source-holder)
    (list (buffer-chars-modified-tick) (point-min) (point-max))))

(defun mdview--source-unchanged-p ()
  "Return non-nil when the source text is as it was after the last swap."
  (or mdview--rendered
      (equal (mdview--current-source-key) mdview--source-key)))

(defun mdview--source-text ()
  "Return the accessible portion of the Markdown source as a string."
  (with-current-buffer (mdview--source-holder)
    (buffer-substring-no-properties (point-min) (point-max))))

(defun mdview--source-document (&optional force)
  "Return the parsed document of the source, parsing when needed.
The document is cached in `mdview--document' and reused while the source
text is unchanged, so re-rendering for a new width or image setting
skips the parser.  FORCE non-nil parses again regardless."
  (if (and (not force) mdview--document (mdview--source-unchanged-p))
      mdview--document
    (setq mdview--document (mdview-parse-string (mdview--source-text)))))

(defun mdview--compute-base-dir ()
  "Return the directory relative links and images of this buffer resolve in."
  (let ((file (buffer-file-name (or (buffer-base-buffer) (current-buffer)))))
    (if file
        (file-name-directory (expand-file-name file))
      (expand-file-name default-directory))))

(defun mdview--kill-hidden (buffer &optional kill-fetches)
  "Kill the hidden BUFFER, forgetting the remote images it waits for.
KILL-FETCHES non-nil also aborts retrievals nobody else waits for."
  (when (buffer-live-p buffer)
    (mdview-image-cancel-pending buffer kill-fetches)
    (kill-buffer buffer)))

(defun mdview--render-to-buffer (document width images base-dir &optional scale)
  "Render DOCUMENT into a new hidden buffer and return the buffer.
WIDTH is the content width, IMAGES non-nil displays images, BASE-DIR
resolves relative image paths and SCALE is the factor applied to images
\(see `mdview--image-scale').  The width of a text column is measured in
the window showing the current buffer, like SCALE is, because the
hidden buffer has neither the window nor the text scaling of the buffer
that will show the rendering.  The new buffer belongs to the current
buffer (`mdview--owner'), has undo disabled and its text is marked as
fontified, so that jit-lock never touches it.  Garbage collection is
made less eager meanwhile (`mdview--render-gc-threshold').  On any
non-local exit, including `while-no-input' giving up, the buffer is
killed and nothing else has changed."
  (let ((owner (current-buffer))
        (char-width (mdview-image-char-width (mdview--view-window)))
        (buffer (generate-new-buffer " *mdview-render*"))
        (done nil))
    (unwind-protect
        (with-current-buffer buffer
          (buffer-disable-undo)
          (setq mdview--owner owner
                default-directory base-dir)
          (add-hook 'kill-buffer-query-functions #'mdview--twin-kill-query nil t)
          (let ((gc-cons-threshold (max gc-cons-threshold mdview--render-gc-threshold))
                (gc-cons-percentage (max gc-cons-percentage 0.5))
                (mdview-display-images images))
            (mdview-render-document document :width width :base-dir base-dir
                                    :char-width char-width
                                    :image-scale scale))
          ;; The renderer remaps the derived faces in the buffer it
          ;; renders into; the buffer that displays the text does that.
          (mdview-faces-unremap)
          (put-text-property (point-min) (point-max) 'fontified t)
          (goto-char (point-min))
          (set-buffer-modified-p nil)
          (setq done t)
          buffer)
      (unless done
        (let ((inhibit-quit t)
              (throw-on-input nil))
          (mdview--kill-hidden buffer))))))

(defun mdview-render-string (string &optional width base-dir)
  "Render the Markdown STRING and return the result as a propertized string.
WIDTH is the content width in columns (default: `mdview-max-width' or
80); BASE-DIR resolves relative image paths (default: `default-directory')."
  (let ((base-dir (or base-dir default-directory)))
    (with-temp-buffer
      (setq default-directory base-dir)
      (mdview-render-document (mdview-parse-string string)
                              :width (or width mdview-max-width 80)
                              :base-dir base-dir)
      (buffer-string))))

;;;; Mapping positions between the source and the rendering

(defun mdview--block-at (&optional pos)
  "Return (LINE . START) for the block at or before POS (default: point).
LINE is the value of the nearest preceding `mdview-source-line' text
property and START the position where that run of the property begins;
nil when there is no block before POS."
  (let ((pos (or pos (point)))
        (line nil))
    (while (and pos (not (setq line (get-text-property pos 'mdview-source-line))))
      (setq pos (previous-single-property-change pos 'mdview-source-line)))
    (and line (cons line pos))))

(defun mdview--source-line-at (&optional pos)
  "Return the source line of the block at or before POS (default: point).
This is the value of the nearest preceding `mdview-source-line' text
property, or nil when there is none."
  (car (mdview--block-at pos)))

(defun mdview--block-starts ()
  "Return the blocks of the rendering as a list of (SOURCE-LINE . POSITION)."
  (let ((pos (point-min))
        (result nil))
    (while pos
      (let ((line (get-text-property pos 'mdview-source-line)))
        (when line (push (cons line pos) result)))
      (setq pos (next-single-property-change pos 'mdview-source-line)))
    (nreverse result)))

(defun mdview--source-line-position (line)
  "Return the start of the first block rendered from source LINE or later.
When every block starts before LINE, return the start of the last block;
without any block, `point-min'."
  (let ((last nil))
    (or (catch 'found
          (dolist (entry (mdview--block-starts))
            (setq last (cdr entry))
            (when (>= (car entry) line)
              (throw 'found (cdr entry)))))
        last
        (point-min))))

(defun mdview--goto-source-line (line)
  "Move point to the first block rendered from source LINE or a later one.
When every block starts before LINE, move to the last block."
  (goto-char (mdview--source-line-position line)))

(defun mdview--line-of (pos)
  "Return the source line that POS in the current text stands for.
In the source that is the line of POS (counted in the accessible
portion); in the rendering, the line of the block at or before POS."
  (if mdview--rendered
      (or (mdview--source-line-at pos) 1)
    (line-number-at-pos pos)))

(defun mdview--line-start (line)
  "Return the position of the beginning of LINE of the current text.
Lines count from 1 in the accessible portion; past the last line the
result is `point-max'."
  (save-excursion
    (goto-char (point-min))
    (forward-line (1- line))
    (point)))

(defun mdview--position-of (line)
  "Return the position in the current text that stands for source LINE."
  (if mdview--rendered
      (mdview--source-line-position line)
    (mdview--line-start line)))

(defun mdview--anchor (pos from)
  "Describe the word at POS by its place among the words from FROM on.
A word is a run of letters and digits, the one thing the source and the
rendering share verbatim.  Return (WORD INDEX OFFSET): WORD is the word
at POS, or the last one before it; INDEX counts the occurrences of WORD
from FROM up to and including it; OFFSET is the distance of POS from
its start, at most its length.  Return nil when no word lies between
FROM and POS."
  (when (<= from pos)
    (save-excursion
      (goto-char (min (1+ pos) (point-max)))
      (when (re-search-backward "[[:alnum:]]" from t)
        (skip-chars-backward "[:alnum:]" from)
        (let* ((start (point))
               (end (progn (skip-chars-forward "[:alnum:]") (point)))
               (word (buffer-substring-no-properties start end))
               (case-fold-search nil)
               (index 1))
          (goto-char from)
          (while (re-search-forward "[[:alnum:]]+" start t)
            (when (equal (match-string-no-properties 0) word)
              (setq index (1+ index))))
          (list word index (min (- pos start) (- end start))))))))

(defun mdview--anchor-position (anchor from to)
  "Return the position ANCHOR names among the words between FROM and TO.
ANCHOR comes from `mdview--anchor'; the result is nil when the
occurrence of its word that it names is not there."
  (pcase-let ((`(,word ,index ,offset) anchor))
    (let ((case-fold-search nil))
      (when (<= from to)
        (save-excursion
          (goto-char from)
          (catch 'found
            (while (re-search-forward "[[:alnum:]]+" to t)
              (when (and (equal (match-string-no-properties 0) word)
                         (zerop (setq index (1- index))))
                (throw 'found (+ (match-beginning 0) offset))))
            nil))))))

(defun mdview--block-range (pos)
  "Return the block of the rendering at or before POS, with its extent.
The value is (LINE START END NEXT-LINE): LINE and START as in
`mdview--block-at', END the start of the following block (or
`point-max') and NEXT-LINE that block's source line (or nil).  Nil
before the first block."
  (let ((block (mdview--block-at pos)))
    (when block
      (let ((next (text-property-not-all (1+ (cdr block)) (point-max)
                                         'mdview-source-line nil)))
        (list (car block) (cdr block) (or next (point-max))
              (and next (get-text-property next 'mdview-source-line)))))))

(defun mdview--block-span (line)
  "Return the extent in the rendering of the block containing source LINE.
That is the block with the greatest source line not after LINE, together
with the blocks nested in it that start on the same line: (BLOCK-LINE
START END), or nil when every block starts after LINE."
  (let ((best nil) (first nil) (last nil))
    (dolist (entry (mdview--block-starts))
      (let ((entry-line (car entry)))
        (when (and (<= entry-line line) (or (null best) (>= entry-line best)))
          (when (or (null best) (> entry-line best))
            (setq first (cdr entry)))
          (setq best entry-line
                last (cdr entry)))))
    (and first (list best first (nth 2 (mdview--block-range last))))))

(defun mdview--matching-position (line point)
  "Return where the word at POINT of the text swapped out is in this text.
POINT belongs to the text now in the twin, where it stood for source
LINE; the word at it (`mdview--anchor') is looked for in the block of
LINE here.  Nil when there is no such word, when the block does not
contain it, or when the twin is gone."
  (let ((twin mdview--twin))
    (when (buffer-live-p twin)
      (if mdview--rendered
          (let ((span (mdview--block-span line)))
            (when span
              (let ((anchor (with-current-buffer twin
                              (mdview--anchor point (mdview--line-start
                                                     (nth 0 span))))))
                (and anchor
                     (mdview--anchor-position anchor (nth 1 span) (nth 2 span))))))
        (pcase-let ((`(,block ,anchor)
                     (with-current-buffer twin
                       (let ((block (mdview--block-range point)))
                         (list block
                               (and block (mdview--anchor point (nth 1 block))))))))
          (when anchor
            (let ((next (nth 3 block)))
              (mdview--anchor-position anchor (mdview--line-start (nth 0 block))
                                       (if (and next (> next (nth 0 block)))
                                           (mdview--line-start next)
                                         (point-max))))))))))

(defun mdview--window-row (window)
  "Return the screen row of WINDOW's point, counted from its start."
  (let ((start (window-start window))
        (point (window-point window)))
    (if (< point start)
        0
      (min (max 0 (1- (window-body-height window)))
           (save-excursion
             (goto-char point)
             (count-screen-lines start (line-beginning-position) nil window))))))

(defun mdview--capture ()
  "Record point and the windows showing the buffer before a swap.
Return a list of (WINDOW POINT START ROW LINE): POINT, START and ROW are
the window's point, start and the screen row of point, LINE the source
line point stands for.  The first element has WINDOW nil and describes
the buffer's own point."
  (cons (list nil (point) nil 0 (mdview--line-of (point)))
        (mapcar (lambda (window)
                  (let ((point (window-point window)))
                    (list window point (window-start window)
                          (mdview--window-row window)
                          (mdview--line-of point))))
                (get-buffer-window-list (current-buffer) nil t))))

(defun mdview--start-for (pos row window)
  "Return the window start that puts POS on screen ROW of WINDOW."
  (save-excursion
    (goto-char pos)
    ;; Not `with-selected-window': selecting a window loads and stores
    ;; window points, which would undo the `set-window-point' just done.
    (vertical-motion (- row) window)
    (point)))

(defun mdview--apply-capture (capture memory)
  "Put point and the windows on the text swapped in, after CAPTURE.
CAPTURE comes from `mdview--capture' before the swap.  MEMORY is the
`mdview--memory' of the previous swap when the text now current is the
text that swap put away, else nil: a window whose point did not move
since then gets its old point and start back exactly.  Other windows get
the position of the word their point was on (`mdview--matching-position'),
or failing that the block of the same source line, at the same screen
row.  Return the new memory."
  (let ((new nil))
    (pcase-dolist (`(,window ,point ,start ,row ,line) capture)
      (let* ((remembered (assq window memory))
             (exact (and remembered (eql (nth 1 remembered) point)))
             (target (min (point-max)
                          (cond (exact (nth 2 remembered))
                                ((mdview--matching-position line point))
                                (t (mdview--position-of line))))))
        (push (list window target point start) new)
        (cond ((null window) (goto-char target))
              ((and (window-live-p window) (eq (window-buffer window) (current-buffer)))
               (set-window-point window target)
               (set-window-start window
                                 (if (and exact (nth 3 remembered))
                                     (min (point-max) (nth 3 remembered))
                                   (mdview--start-for target row window))
                                 t)))))
    (nreverse new)))

(defun mdview--view-point ()
  "Return point as seen in the window showing the buffer, else `point'."
  (let ((window (get-buffer-window (current-buffer) t)))
    (if (and window (not (eq window (selected-window))))
        (window-point window)
      (point))))

(defun mdview--window-starts (buffer)
  "Return the scroll positions of the windows showing the rendered BUFFER.
Each element is (WINDOW LINE OFFSET): the source line of the block at
the top of WINDOW and the number of lines between that block's first
line and the window start.  Windows above the first block are omitted."
  (with-current-buffer buffer
    (delq nil
          (mapcar (lambda (window)
                    (let* ((start (window-start window))
                           (block (mdview--block-at start)))
                      (and block
                           (list window (car block)
                                 (count-lines (cdr block) start)))))
                  (get-buffer-window-list buffer nil t)))))

(defun mdview--restore-window-starts (positions)
  "Scroll the windows listed in POSITIONS back to where they were.
POSITIONS comes from `mdview--window-starts'.  Each window is started
at the block that was at its top before the re-rendering, the recorded
number of lines further down, so the text does not jump; redisplay may
still scroll to keep point visible."
  (pcase-dolist (`(,window ,line ,offset) positions)
    (when (and (window-live-p window)
               (eq (window-buffer window) (current-buffer)))
      (save-excursion
        (goto-char (mdview--source-line-position line))
        (forward-line offset)
        (set-window-start window (point) t)))))

;;;; Entering and leaving the rendering

(defun mdview--ignore-fontification (&rest _)
  "Do nothing; the font-lock functions of a rendered buffer."
  nil)

(defun mdview--check-swappable ()
  "Signal a `user-error' unless the current buffer can be rendered in place."
  (when mdview--owner
    (user-error "This is an internal mdview buffer"))
  (when (or (buffer-base-buffer)
            (seq-some (lambda (buffer) (eq (buffer-base-buffer buffer) (current-buffer)))
                      (buffer-list)))
    (user-error "Cannot render an indirect buffer, or one with indirect buffers, in place")))

(defun mdview--suspend-modes ()
  "Switch off the modes of `mdview-suspended-modes' that are on."
  (setq mdview--suspended nil)
  (dolist (mode mdview-suspended-modes)
    (when (and (boundp mode) (symbol-value mode) (fboundp mode))
      (condition-case err
          (progn (funcall mode -1)
                 (push mode mdview--suspended))
        (error (message "mdview: cannot switch off %s: %s"
                        mode (error-message-string err)))))))

(defun mdview--resume-modes ()
  "Switch the modes suspended by `mdview--suspend-modes' on again."
  (dolist (mode mdview--suspended)
    (condition-case err
        (funcall mode 1)
      (error (message "mdview: cannot switch %s back on: %s"
                      mode (error-message-string err)))))
  (setq mdview--suspended nil))

(defun mdview--save-settings ()
  "Remember the settings in `mdview--overridden-settings'.
Each entry of `mdview--saved' is (VAR LOCAL-P VALUE); the value set for
the rendering is appended by `mdview--note-view-settings'."
  (setq mdview--saved
        (mapcar (lambda (var)
                  (list var (local-variable-p var)
                        (and (boundp var) (symbol-value var))))
                mdview--overridden-settings)))

(defun mdview--note-view-settings (&optional vars)
  "Record in `mdview--saved' the values the rendering set.
With VARS, record only those (after a re-rendering changed them)."
  (setq mdview--saved
        (mapcar (lambda (entry)
                  (let ((var (car entry)))
                    (if (or (null vars) (memq var vars))
                        (append (seq-take entry 3)
                                (list (and (boundp var) (symbol-value var))))
                      entry)))
                mdview--saved)))

(defun mdview--restore-settings ()
  "Restore the settings remembered by `mdview--save-settings'.
A setting that something else changed while the buffer was rendered
keeps its new value: `write-file', for instance, computes a new
`buffer-auto-save-file-name', which must not be replaced by the old one."
  (pcase-dolist (`(,var ,local ,value ,set) mdview--saved)
    (when (equal (and (boundp var) (symbol-value var)) set)
      (if local
          (set (make-local-variable var) value)
        (kill-local-variable var))))
  (setq mdview--saved nil)
  (mdview--set-window-margins))

(defun mdview--install-hooks ()
  "Install the buffer-local hooks that look after a rendered buffer.
They stay when the buffer goes back to its source (they do nothing
then), and are removed with the other local variables when the major
mode changes.  The global `mdview-image-update-functions' entry
ignores buffers that are not rendered."
  (add-hook 'before-save-hook #'mdview--before-save -100 t)
  (add-hook 'write-contents-functions #'mdview--refuse-to-write-rendering nil t)
  (add-hook 'after-save-hook #'mdview--after-save 100 t)
  (add-hook 'before-revert-hook #'mdview--before-revert -100 t)
  (add-hook 'after-revert-hook #'mdview--after-revert 100 t)
  (add-hook 'change-major-mode-hook #'mdview--on-change-major-mode nil t)
  (add-hook 'kill-buffer-hook #'mdview--on-kill -100 t)
  ;; Remote images that arrive after the rendering re-flow it.
  (add-hook 'mdview-image-update-functions #'mdview--on-images-updated)
  (add-hook 'kill-emacs-hook #'mdview--on-kill-emacs -100)
  (add-hook 'clone-indirect-buffer-hook #'mdview--on-clone))

(defun mdview--apply-view-settings (width)
  "Set up the rendered buffer for content WIDTH; see `mdview--enter'."
  (setq buffer-read-only t
        truncate-lines t
        word-wrap nil
        buffer-auto-save-file-name nil)
  ;; The source keeps its fontification in the twin; nothing may
  ;; fontify, or strip the faces of, the rendering.
  (setq-local fontification-functions nil)
  (setq-local jit-lock-mode nil)
  (setq-local jit-lock-functions nil)
  (setq-local jit-lock-context-unfontify-pos nil)
  (setq-local font-lock-fontify-region-function #'mdview--ignore-fontification)
  (setq-local font-lock-unfontify-region-function #'mdview--ignore-fontification)
  (setq-local syntax-propertize-function nil)
  (setq-local imenu-create-index-function #'mdview--imenu-create-index)
  (setq-local imenu--index-alist nil)
  (setq-local mark-ring nil)
  (setq-local window-configuration-change-hook '(t))
  (mdview--apply-margins width)
  (mdview-faces-remap)
  (add-hook 'window-size-change-functions #'mdview--window-size-changed nil t)
  (add-hook 'window-buffer-change-functions #'mdview--window-size-changed nil t)
  (add-hook 'text-scale-mode-hook #'mdview--text-scale-changed nil t))

(defun mdview--swap (other)
  "Exchange the text of the current buffer with that of OTHER.
The modified flag belongs to the text, and `buffer-swap-text' also
counts the exchange as a modification, so the current buffer is given
back the modified state it reported before; the mode line, `kill-buffer',
`save-some-buffers' and the staleness check of auto-revert therefore
keep seeing the state of the source.  The variable `buffer-file-name' is unbound
meanwhile so that setting the flag takes no file lock and asks no
question.  OTHER is left unmodified."
  (unless (buffer-live-p other)
    (error "The source text of this buffer was lost (its hidden buffer was killed)"))
  (let ((modified (buffer-modified-p)))
    (buffer-swap-text other)
    (let ((buffer-file-name nil)
          (buffer-file-truename nil))
      (restore-buffer-modified-p modified))
    (with-current-buffer other
      (restore-buffer-modified-p nil))))

(defun mdview--enter ()
  "Replace the text of the current buffer by its rendering.
The rendering is built in a new hidden buffer first, so an error leaves
the buffer as it was.  When the twin still holds a rendering of the
unchanged source at the current width it is swapped in without
rendering.  Afterwards the source text lives in the twin, the buffer is
read-only, fontification, syntax propertization and auto-saving are
off, the modes of `mdview-suspended-modes' are suspended, and every
window shows the block of the source line it showed before, at the same
screen row (see `mdview--apply-capture')."
  (mdview--check-swappable)
  (let* ((source (current-buffer))
         (width (mdview--content-width))
         (scale (mdview--image-scale))
         (images (if (eq mdview--images-enabled 'unset)
                     mdview-display-images
                   mdview--images-enabled))
         (base-dir (mdview--compute-base-dir))
         (reuse (and (buffer-live-p mdview--twin)
                     mdview--twin-key
                     (equal mdview--twin-key (list width images scale))
                     (mdview--source-unchanged-p)))
         (capture (mdview--capture))
         (fresh (unless reuse
                  (mdview--render-to-buffer (mdview--source-document)
                                            width images base-dir scale)))
         ;; From here on nothing may interrupt: the texts get exchanged.
         (throw-on-input nil)
         (inhibit-quit t))
    (setq mdview--images-enabled images
          mdview--base-dir base-dir)
    (mdview--suspend-modes)
    (mdview--save-settings)
    (let ((old mdview--twin))
      (mdview--swap (or fresh old))
      (when fresh
        (setq mdview--twin fresh)
        (with-current-buffer fresh
          (setq mdview--owner source)
          (rename-buffer (format " *mdview: %s*" (buffer-name source)) t))
        (unless (eq old fresh)
          (mdview--kill-hidden old))))
    (setq mdview--rendered t
          mdview--source-key (mdview--current-source-key)
          mdview--twin-key nil
          mdview--last-width width
          mdview--last-scale scale)
    (setq mdview-mode t)
    (condition-case err
        (progn
          (syntax-ppss-flush-cache (point-min))
          (mdview--install-hooks)
          (mdview--apply-view-settings width)
          (mdview--note-view-settings)
          (setq mdview--memory
                (mdview--apply-capture capture (and reuse mdview--memory))))
      (error
       ;; Never leave the rendering in place half set up: put the source
       ;; back before reporting the error.
       (ignore-errors
         ;; Whatever was set so far counts as the rendering's value, so
         ;; that leaving restores all of it.
         (mdview--note-view-settings)
         (mdview--leave))
       (signal (car err) (cdr err))))))

(defun mdview--leave (&optional dying)
  "Put the source text of the current buffer back in place of the rendering.
Everything `mdview--enter' changed is restored, and every window shows
the line of the block it showed, at the same screen row; a window that
did not move since the rendering was shown gets its exact old point and
start back.  The rendering stays in the twin for reuse.  With DYING
non-nil (the buffer is being killed or changes major mode) the
suspended modes are not switched back on."
  (mdview--check-leavable)
  (let ((capture (mdview--capture))
        (throw-on-input nil)
        (inhibit-quit t))
    (mdview--cancel-refit)
    (mdview--cancel-image-update)
    (remove-hook 'window-size-change-functions #'mdview--window-size-changed t)
    (remove-hook 'window-buffer-change-functions #'mdview--window-size-changed t)
    (remove-hook 'text-scale-mode-hook #'mdview--text-scale-changed t)
    (mdview-faces-unremap)
    (mdview--restore-settings)
    (mdview--swap mdview--twin)
    (setq mdview--rendered nil
          mdview--source-key (mdview--current-source-key)
          mdview--twin-key (list mdview--last-width mdview--images-enabled
                                 mdview--last-scale))
    (setq mdview-mode nil)
    (syntax-ppss-flush-cache (point-min))
    (setq mdview--memory (mdview--apply-capture capture mdview--memory))
    (if dying
        (setq mdview--suspended nil)
      (mdview--resume-modes))))

(defun mdview--check-leavable ()
  "Signal an error unless the source can be swapped back now.
Checked before anything is restored, so that a failure leaves the
rendering fully in place rather than half undone."
  (unless (buffer-live-p mdview--twin)
    (error "The source text of this buffer was lost (its hidden buffer was killed)"))
  (when (seq-some (lambda (buffer) (eq (buffer-base-buffer buffer) (current-buffer)))
                  (buffer-list))
    (user-error "Kill the indirect buffers of %s before showing its source"
                (buffer-name))))

(defun mdview--enter-or-report ()
  "Render the current buffer from a hook; report an error instead of signalling."
  (condition-case err
      (mdview-mode 1)
    (error (message "mdview: %s" (error-message-string err)))))

;;;; Hooks: saving, reverting, changing the major mode, killing

(defun mdview--before-save ()
  "Put the source back before the buffer is saved, if it is rendered.
Runs first in the buffer-local `before-save-hook', so that the other
save hooks (formatters, whitespace cleanup) and the file see the
source.  The request to render again is reset on every save, so that a
save that failed cannot make a later one switch to the rendering."
  (setq mdview--resume-after-save mdview--rendered
        mdview--narrowing nil)
  (when mdview--rendered
    (mdview-mode -1)
    ;; `basic-save-buffer' runs this hook inside `save-restriction' of the
    ;; (unnarrowed) rendering, which widens the source on exit; remember
    ;; the source's restriction so that `mdview--after-save' can redo it.
    (when (buffer-narrowed-p)
      (setq mdview--narrowing (cons (copy-marker (point-min))
                                    (copy-marker (point-max) t))))))

(defun mdview--refuse-to-write-rendering ()
  "Stop a save that would write the rendering instead of the source.
Runs from `write-contents-functions', after `before-save-hook'.
`basic-save-buffer' demotes errors in `before-save-hook' to messages, so
if `mdview--before-save' failed to put the source back, the save would
otherwise go ahead with the rendering."
  (when mdview--rendered
    (error "Refusing to save the mdview rendering; switch to the source first"))
  nil)

(defun mdview--after-save ()
  "Render the buffer again after a save that `mdview--before-save' began."
  (when mdview--resume-after-save
    (setq mdview--resume-after-save nil)
    (when mdview--narrowing
      (narrow-to-region (car mdview--narrowing) (cdr mdview--narrowing))
      (set-marker (car mdview--narrowing) nil)
      (set-marker (cdr mdview--narrowing) nil)
      (setq mdview--narrowing nil))
    (mdview--enter-or-report)))

(defun mdview--before-revert ()
  "Put the source back before the buffer is reverted, if it is rendered."
  (setq mdview--resume-after-revert mdview--rendered)
  (when mdview--rendered
    (mdview-mode -1)))

(defun mdview--after-revert ()
  "Render the reverted text when `mdview--before-revert' asked for it.
This is how a rendered buffer follows its file under `auto-revert-mode'
and `global-auto-revert-mode'.  Auto-revert binds `buffer-read-only'
around the revert and so restores the rendering's t afterwards; when
rendering fails, the source is made writable again once that is over."
  (when mdview--resume-after-revert
    (setq mdview--resume-after-revert nil)
    (mdview--enter-or-report)
    (unless mdview--rendered
      (let ((buffer (current-buffer)))
        (run-at-time 0 nil #'mdview--fix-read-only buffer)))))

(defun mdview--fix-read-only (buffer)
  "Make BUFFER writable when it is back to its source and its file is writable."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (and (not mdview--rendered) buffer-read-only buffer-file-name
                 (file-writable-p buffer-file-name))
        (setq buffer-read-only nil)))))

(defun mdview--twin-kill-query ()
  "Refuse to kill a hidden buffer with the source of a rendered buffer in it.
The buffer-local `kill-buffer-query-functions' of twins and render
buffers.  Commands such as `kill-some-buffers' or `clean-buffer-list'
would otherwise destroy the Markdown source, unsaved edits included.
A twin holding only a rendering may go."
  (let ((owner mdview--owner))
    (not (and (buffer-live-p owner)
              (eq (buffer-local-value 'mdview--twin owner) (current-buffer))
              (buffer-local-value 'mdview--rendered owner)))))

(defun mdview--on-kill-emacs ()
  "Put the source back in every rendered buffer before Emacs exits.
Runs early in `kill-emacs-hook', so that `save-place-mode', desktop and
the like record positions in the source, not in the rendering."
  (dolist (buffer (buffer-list))
    (when (mdview--view-p buffer)
      (with-current-buffer buffer
        (ignore-errors (mdview--leave t))))))

(defun mdview--on-clone ()
  "Drop the mdview state that `clone-indirect-buffer' copied into a clone.
The clone shares the text of its base buffer, which may be a rendering;
it is not rendered by mdview itself (it has no twin of its own), and
while it lives the base buffer cannot swap its source back (see
`mdview--check-leavable')."
  (when (or mdview--rendered mdview--twin)
    (dolist (var '(mdview--rendered mdview--twin mdview--saved mdview--suspended
                   mdview--memory mdview--refit-timer mdview--image-update-timer))
      (kill-local-variable var))
    (setq mdview-mode nil)
    (dolist (entry '((before-save-hook . mdview--before-save)
                     (after-save-hook . mdview--after-save)
                     (write-contents-functions . mdview--refuse-to-write-rendering)
                     (before-revert-hook . mdview--before-revert)
                     (after-revert-hook . mdview--after-revert)
                     (change-major-mode-hook . mdview--on-change-major-mode)
                     (kill-buffer-hook . mdview--on-kill)
                     (window-size-change-functions . mdview--window-size-changed)
                     (window-buffer-change-functions . mdview--window-size-changed)
                     (text-scale-mode-hook . mdview--text-scale-changed)))
      (remove-hook (car entry) (cdr entry) t))))

(defun mdview--kill-twin ()
  "Kill the twin of the current buffer, if any."
  (mdview--kill-hidden mdview--twin)
  (setq mdview--twin nil
        mdview--twin-key nil))

(defun mdview--on-change-major-mode ()
  "Put the source back before a change of major mode, and drop the twin."
  (when mdview--rendered
    (condition-case err
        (mdview--leave t)
      (error (message "mdview: %s" (error-message-string err)))))
  (mdview--kill-twin))

(defun mdview--on-kill ()
  "Clean up when a buffer that was rendered is killed.
The source is put back first, so that the other functions of
`kill-buffer-hook' (such as `save-place-mode') see it.  A failure to
do so is reported but never prevents the kill."
  (when mdview--rendered
    (condition-case err
        (mdview--leave t)
      (error (message "mdview: %s" (error-message-string err)))))
  (mdview--cancel-refit)
  (mdview--cancel-image-update)
  (mdview-image-cancel-pending (current-buffer) t)
  (mdview--kill-twin)
  (setq mdview--document nil))

;;;; Re-rendering: refresh, refit, images

(defun mdview--view-p (buffer)
  "Return non-nil when BUFFER is live and currently rendered."
  (and (buffer-live-p buffer)
       (buffer-local-value 'mdview--rendered buffer)))

(defun mdview--render-into (buffer &optional line force-parse)
  "Render the rendered BUFFER again, keeping the position.
Point ends up at the block rendered from source line LINE (an integer),
or, when LINE is nil, on the word it was on before (at least on the
same block); the windows showing BUFFER keep the block that was at
their top.  The parsed document is reused unless FORCE-PARSE is
non-nil.  The new rendering is built in a hidden buffer and swapped in,
so an error, or `while-no-input' giving up, leaves the old rendering in
place."
  (with-current-buffer buffer
    (let* ((document (mdview--source-document force-parse))
           (pos (mdview--view-point))
           (anchor (unless line
                     (let ((block (mdview--block-range pos)))
                       (and block (mdview--anchor pos (nth 1 block))))))
           (line (or line (mdview--source-line-at pos)))
           (starts (mdview--window-starts buffer))
           (width (mdview--content-width))
           (scale (mdview--image-scale))
           (fresh (mdview--render-to-buffer document width mdview--images-enabled
                                            mdview--base-dir scale))
           ;; The rendering is done; exchanging it must not be interrupted.
           (throw-on-input nil)
           (inhibit-quit t))
      (mdview--cancel-refit)
      (mdview--cancel-image-update)
      (mdview--swap fresh)
      ;; FRESH now holds the old rendering; forget its pending images.
      (mdview--kill-hidden fresh)
      (setq mdview--last-width width
            mdview--last-scale scale
            imenu--index-alist nil
            mdview--memory nil)
      (mdview--apply-margins width)
      (mdview--note-view-settings '(left-margin-width right-margin-width))
      (goto-char (point-min))
      (when line
        (mdview--goto-source-line line)
        (let* ((span (and anchor (mdview--block-span line)))
               (target (and span (mdview--anchor-position
                                  anchor (nth 1 span) (nth 2 span)))))
          (when target (goto-char target))))
      (dolist (window (get-buffer-window-list buffer nil t))
        (set-window-point window (point)))
      (mdview--restore-window-starts starts))))

(defun mdview--cancel-refit ()
  "Cancel the pending refit timer of this buffer, if any."
  (when mdview--refit-timer
    (cancel-timer mdview--refit-timer)
    (setq mdview--refit-timer nil)))

(defun mdview--schedule-refit (buffer)
  "Schedule a refit of the rendering in BUFFER once Emacs has been idle.
Nothing happens when `mdview-auto-refit' is off or BUFFER is not rendered."
  (when (mdview--view-p buffer)
    (with-current-buffer buffer
      (when mdview-auto-refit
        (mdview--cancel-refit)
        (setq mdview--refit-timer
              (run-with-idle-timer mdview-refit-delay nil
                                   #'mdview--refit buffer))))))

(defun mdview--window-size-changed (object)
  "Schedule a refit of the rendering shown in OBJECT, a window or a frame.
Runs from the buffer-local `window-size-change-functions' and
`window-buffer-change-functions' of a rendered buffer.  A change of the
frame's font (`set-frame-font', `global-text-scale-adjust', zoom-frm)
arrives here as well, since it changes the size of the windows in
columns."
  (mdview--schedule-refit
   (if (windowp object) (window-buffer object) (current-buffer))))

(defun mdview--text-scale-changed ()
  "Schedule a refit after `text-scale-mode' changed the size of the text.
Runs from the buffer-local `text-scale-mode-hook' of a rendered buffer:
the number of columns of the scaled text that fit the window and the
scale of the images both follow the text."
  (mdview--schedule-refit (current-buffer)))

(defun mdview--refit (buffer &optional line)
  "Render BUFFER again if its content width or the scale of its images changed.
Point goes to the block of source LINE, or stays on the word it is on
when LINE is nil (see `mdview--render-into').  The rendering is
abandoned as soon as the user types and rescheduled for the next idle
period, so a resize never locks Emacs up; a failure is reported in the
echo area once rather than on every resize.  Return non-nil when a
rendering completed."
  (when (mdview--view-p buffer)
    (with-current-buffer buffer
      (setq mdview--refit-timer nil)
      (let ((window (get-buffer-window buffer t)))
        (when (and window
                   (not (and (eql (mdview--content-width window)
                                  mdview--last-width)
                             (eql (mdview--image-scale) mdview--last-scale))))
          (condition-case err
              (if (while-no-input (mdview--render-into buffer line) nil)
                  (progn
                    (setq mdview--refit-timer
                          (run-with-idle-timer mdview-refit-delay nil
                                               #'mdview--refit buffer line))
                    nil)
                t)
            (error
             ;; Do not retry at this size on every subsequent resize.
             (setq mdview--last-width (mdview--content-width window)
                   mdview--last-scale (mdview--image-scale))
             (message "mdview: %s" (error-message-string err))
             nil)))))))

(defun mdview--cancel-image-update ()
  "Cancel the pending image re-rendering timer of this buffer, if any."
  (when mdview--image-update-timer
    (cancel-timer mdview--image-update-timer)
    (setq mdview--image-update-timer nil)))

(defun mdview--on-images-updated (buffer)
  "Schedule a new rendering of BUFFER after remote images arrived.
Runs from `mdview-image-update-functions'.  The image module replaces a
placeholder in place, which keeps the width of its line but cannot
re-wrap a paragraph around an inline image, so a rendered buffer is
rendered again from the cached document (the image bytes are cached as
well) once Emacs has been idle for `mdview-refit-delay'; images
arriving close together share one rendering.  When BUFFER is the twin
holding the rendering of a buffer that shows its source, the rendering
is marked stale instead, so that the next \\[mdview-toggle] renders
again."
  (cond ((mdview--view-p buffer)
         (with-current-buffer buffer
           (mdview--cancel-image-update)
           (setq mdview--image-update-timer
                 (run-with-idle-timer mdview-refit-delay nil
                                      #'mdview--rerender-for-images buffer))))
        ((buffer-live-p buffer)
         (let ((owner (buffer-local-value 'mdview--owner buffer)))
           (when (and (buffer-live-p owner)
                      (eq (buffer-local-value 'mdview--twin owner) buffer))
             (with-current-buffer owner
               (unless mdview--rendered
                 (setq mdview--twin-key nil))))))))

(defun mdview--rerender-for-images (buffer)
  "Render BUFFER again so that its text re-flows around its images.
Nothing happens when images are switched off in the buffer.  Like a
refit the rendering is abandoned and rescheduled when the user types,
and a failure is reported once in the echo area."
  (when (mdview--view-p buffer)
    (with-current-buffer buffer
      (setq mdview--image-update-timer nil)
      (when mdview--images-enabled
        (condition-case err
            (when (while-no-input (mdview--render-into buffer) nil)
              (mdview--on-images-updated buffer))
          (error (message "mdview: %s" (error-message-string err))))))))

;;;; History

;; The history belongs to the window: following a link to another
;; Markdown file shows that file's buffer, rendered, in the same window,
;; and `l'/`r' go back and forth between the documents shown there.
;; The window parameter `mdview-history' holds (INDEX . ENTRIES); each
;; entry is a list (BUFFER FILE POINT).

(defun mdview--history-entry ()
  "Return a history entry for the current buffer at point."
  (list (current-buffer)
        (buffer-file-name (or (buffer-base-buffer) (current-buffer)))
        (point)))

(defun mdview--history-current-p (entry)
  "Return non-nil when the history ENTRY is the current buffer."
  (or (eq (car entry) (current-buffer))
      (and (nth 1 entry)
           (equal (nth 1 entry) (buffer-file-name)))))

(defun mdview--history (&optional window)
  "Return the history of WINDOW (default: selected) as (INDEX . ENTRIES).
A history whose current entry is not the buffer shown in WINDOW (the
user switched buffers by other means) is not continued: a fresh one
starting at the current buffer is returned instead."
  (let* ((window (or window (selected-window)))
         (history (window-parameter window 'mdview-history)))
    (if (and history
             (mdview--history-current-p (nth (car history) (cdr history))))
        history
      (cons 0 (list (mdview--history-entry))))))

(defun mdview--history-save-point (history)
  "Record point in the current entry of HISTORY."
  (setf (nth 2 (nth (car history) (cdr history))) (point)))

(defun mdview--history-push (history)
  "Make the current buffer the newest entry of HISTORY, dropping forward ones.
HISTORY is the window's history before the move; the result is stored
in the selected window."
  (let ((entries (append (seq-take (cdr history) (1+ (car history)))
                         (list (mdview--history-entry)))))
    (set-window-parameter nil 'mdview-history
                          (cons (1- (length entries)) entries))))

(defun mdview--show-rendered (buffer &optional pos)
  "Show BUFFER rendered in the selected window, at POS or its beginning."
  (pop-to-buffer-same-window buffer)
  (unless mdview--rendered
    (mdview-mode 1))
  (goto-char (min (or pos (point-min)) (point-max)))
  (set-window-point nil (point))
  (set-window-start nil (line-beginning-position) t))

(defun mdview--history-move (delta)
  "Show the history entry at distance DELTA from the current one."
  (let* ((history (mdview--history))
         (index (+ (car history) delta))
         (entries (cdr history)))
    (unless (and (>= index 0) (< index (length entries)))
      (user-error (if (< delta 0)
                      "No earlier document in the history"
                    "No later document in the history")))
    (mdview--history-save-point history)
    (let* ((entry (nth index entries))
           (buffer (car entry))
           (file (nth 1 entry)))
      (unless (buffer-live-p buffer)
        (unless (and file (file-exists-p file))
          (user-error "That document is gone"))
        (setq buffer (find-file-noselect file))
        (setcar entry buffer))
      (mdview--show-rendered buffer (nth 2 entry))
      (set-window-parameter nil 'mdview-history (cons index entries)))))

;;;; Headings

(defun mdview--headings ()
  "Return the headings of the rendering as a list of (POSITION LEVEL ID TEXT).
Consecutive runs of heading text with the same id (a wrapped heading)
are merged into one entry."
  (let ((pos (point-min))
        (result nil))
    (while pos
      (let ((level (get-text-property pos 'mdview-heading-level)))
        (when level
          (let* ((end (or (next-single-property-change pos 'mdview-heading-level)
                          (point-max)))
                 (id (get-text-property pos 'mdview-heading-id))
                 (text (string-trim (buffer-substring-no-properties pos end)))
                 (prev (car result)))
            (if (and prev id (equal (nth 2 prev) id))
                (setcar result (list (nth 0 prev) (nth 1 prev) id
                                     (string-trim (concat (nth 3 prev) " " text))))
              (push (list pos level id text) result))))
        (setq pos (next-single-property-change pos 'mdview-heading-level))))
    (nreverse result)))

(defun mdview--imenu-create-index ()
  "Return an imenu index of the headings in the rendering."
  (let ((seen (make-hash-table :test #'equal))
        (index nil))
    (dolist (heading (mdview--headings))
      (let* ((text (if (string-empty-p (nth 3 heading))
                       (format "Heading %d" (nth 1 heading))
                     (nth 3 heading)))
             (count (puthash text (1+ (gethash text seen 0)) seen))
             (label (if (> count 1) (format "%s <%d>" text count) text)))
        (push (cons label (nth 0 heading)) index)))
    (nreverse index)))

(defun mdview--find-heading (id)
  "Return the position of the heading whose id is ID, or nil."
  (and id
       (seq-some (lambda (heading)
                   (and (equal (nth 2 heading) id) (nth 0 heading)))
                 (mdview--headings))))

(defun mdview--block-start-near (pos)
  "Return the start of the block containing POS, when it is close above.
Falls back to the beginning of the line of POS."
  (save-excursion
    (goto-char pos)
    (let ((start (let ((p pos) (found nil))
                   (while (and p (not found))
                     (if (get-text-property p 'mdview-source-line)
                         (setq found p)
                       (setq p (previous-single-property-change
                                p 'mdview-source-line))))
                   found)))
      (if (and start (<= (count-lines start pos) 4))
          start
        (line-beginning-position)))))

(defun mdview--scroll-to-top (pos)
  "Scroll the window of the rendering to put the block at POS at the top."
  (let ((window (get-buffer-window (current-buffer))))
    (when window
      (set-window-start window (mdview--block-start-near pos)))))

(defun mdview--goto-anchor (anchor)
  "Move to the heading that the link fragment ANCHOR refers to."
  (let* ((raw (url-unhex-string anchor))
         (pos (or (mdview--find-heading anchor)
                  (mdview--find-heading raw)
                  (mdview--find-heading (mdview-slug raw))
                  (mdview--find-heading (downcase raw)))))
    (unless pos
      (user-error "No heading matches the anchor #%s" anchor))
    (push-mark nil t)
    (goto-char pos)
    (mdview--scroll-to-top pos)))

;;;; Links

(defun mdview--next-link-position (pos)
  "Return the start of the first link after POS, or nil."
  (let ((p pos)
        (found nil))
    (while (and (not found) p)
      (setq p (next-single-property-change p 'mdview-link))
      (when (and p (get-text-property p 'mdview-link))
        (setq found p)))
    found))

(defun mdview--link-start (pos)
  "Return the start of the link containing POS, or POS outside links."
  (let ((url (get-text-property pos 'mdview-link)))
    (if (and url
             (> pos (point-min))
             (equal (get-text-property (1- pos) 'mdview-link) url))
        (or (previous-single-property-change pos 'mdview-link) (point-min))
      pos)))

(defun mdview--previous-link-position (pos)
  "Return the start of the last link that ends at or before POS, or nil.
When POS is inside a link, that link does not count."
  (let ((p (mdview--link-start pos))
        (found nil))
    (while (and (not found) (> p (point-min)))
      (if (get-text-property (1- p) 'mdview-link)
          (setq found (or (previous-single-property-change p 'mdview-link)
                          (point-min)))
        (setq p (or (previous-single-property-change p 'mdview-link)
                    (point-min)))))
    found))

(defun mdview--first-link-position ()
  "Return the start of the first link in the rendering, or nil."
  (if (get-text-property (point-min) 'mdview-link)
      (point-min)
    (mdview--next-link-position (point-min))))

(defun mdview--last-link-position ()
  "Return the start of the last link in the rendering, or nil."
  (mdview--previous-link-position (point-max)))

(defun mdview--markdown-file-p (file)
  "Return non-nil when FILE has one of `mdview-markdown-extensions'."
  (let ((extension (file-name-extension file)))
    (and extension
         (member (downcase extension) mdview-markdown-extensions)
         t)))

(defun mdview--external-url-p (url)
  "Return non-nil when URL has a scheme handled by `browse-url'.
Links without a scheme, file: URLs and Windows drive letters are local."
  (let ((scheme (url-type (url-generic-parse-url url))))
    (and scheme
         (> (length scheme) 1)
         (not (string-equal-ignore-case scheme "file")))))

(defun mdview--split-fragment (url)
  "Split URL into (PATH . ANCHOR); ANCHOR is nil without a fragment."
  (let ((hash (string-search "#" url)))
    (if hash
        (cons (substring url 0 hash)
              (let ((anchor (substring url (1+ hash))))
                (and (not (string-empty-p anchor)) anchor)))
      (cons url nil))))

(defun mdview--local-file (path)
  "Return the absolute file name of the local link PATH.
PATH may be a file: URL; percent-escapes are decoded and relative names
resolve against the buffer's base directory."
  (let* ((parsed (url-generic-parse-url path))
         (raw (if (and (url-type parsed)
                       (string-equal-ignore-case (url-type parsed) "file"))
                  (url-filename parsed)
                path))
         (decoded (if (string-match-p "%[[:xdigit:]]\\{2\\}" raw)
                      (decode-coding-string (url-unhex-string raw) 'utf-8)
                    raw)))
    (expand-file-name decoded (or mdview--base-dir default-directory))))

(defun mdview--visit-in-view (file)
  "Show the Markdown FILE rendered in the selected window.
The file is visited (an existing buffer is reused), rendered unless it
already is, shown from its beginning, and pushed onto the window's
history after the current document."
  (let* ((history (mdview--history))
         (buffer (find-file-noselect (expand-file-name file))))
    (mdview--history-save-point history)
    (mdview--show-rendered buffer)
    (mdview--history-push history)))

(defun mdview--open-local (url)
  "Open the local link URL: Markdown files here, other files in Emacs."
  (pcase-let* ((`(,path . ,anchor) (mdview--split-fragment url))
               (file (and (not (string-empty-p path)) (mdview--local-file path))))
    (cond ((null file) (user-error "Cannot follow the link %s" url))
          ((not (file-exists-p file)) (user-error "File not found: %s" file))
          ((and (mdview--markdown-file-p file) (not (file-directory-p file)))
           (mdview--visit-in-view file)
           (when anchor (mdview--goto-anchor anchor)))
          (t (find-file-other-window file)))))

(defun mdview--open-url (url)
  "Follow the link URL: an anchor, an external URL or a local file."
  (cond ((string-prefix-p "#" url)
         (if (= (length url) 1)
             (goto-char (point-min))
           (mdview--goto-anchor (substring url 1))))
        ((mdview--external-url-p url) (browse-url url))
        (t (mdview--open-local url))))

(defun mdview--display-image-p (display)
  "Return non-nil when the `display' property DISPLAY is an image."
  (or (eq (car-safe display) 'image)
      (and (consp display)
           (seq-some (lambda (item) (eq (car-safe item) 'image)) display))))

(defun mdview--image-at-p (pos)
  "Return non-nil when the text at POS is an image or an image placeholder."
  (or (get-text-property pos 'mdview-image)
      (get-text-property pos 'mdview-image-pending)
      (mdview--display-image-p (get-text-property pos 'display))
      (mdview--face-member-p (get-text-property pos 'face)
                             'mdview-image-placeholder)))

(defun mdview--face-member-p (face target)
  "Return non-nil when the face symbol TARGET occurs in the face spec FACE."
  (cond ((eq face target) t)
        ((consp face) (or (mdview--face-member-p (car face) target)
                          (mdview--face-member-p (cdr face) target)))
        (t nil)))

(defun mdview--image-url-at (pos)
  "Return the URL of the image shown at POS when it is known, else nil.
The image module records it as the text property `mdview-image-url' or,
on pending placeholders, on their overlay; for a displayed local image
the file of its `display' spec is returned (an absolute name)."
  (or (get-text-property pos 'mdview-image-url)
      (seq-some (lambda (overlay) (overlay-get overlay 'mdview-image-url))
                (overlays-at pos))
      (let* ((display (get-text-property pos 'display))
             (spec (cond ((eq (car-safe display) 'image) display)
                         ((consp display)
                          (seq-find (lambda (item) (eq (car-safe item) 'image))
                                    display))))
             (file (and spec (plist-get (cdr spec) :file))))
        (and file (expand-file-name file)))))

(defun mdview--image-link-p (pos url)
  "Return non-nil when URL, the link at POS, is the image shown there.
An image wrapped in a link carries the link's URL instead of its own,
and following it must behave like following a text link.  When the
image's own URL is not recorded, anchors and Markdown files are taken
to be link targets, since they cannot be images."
  (let ((image (mdview--image-url-at pos))
        (path (car (mdview--split-fragment url))))
    (cond (image (or (equal url image)
                     (and (file-name-absolute-p image)
                          (not (mdview--external-url-p url))
                          (not (string-empty-p path))
                          (equal (mdview--local-file path) image))))
          ((string-prefix-p "#" url) nil)
          ((and (not (mdview--external-url-p url))
                (mdview--markdown-file-p path))
           nil)
          (t t))))

(defun mdview--goto-footnote (property index what)
  "Move to the first text whose PROPERTY equals INDEX; WHAT names it."
  (let ((target (save-excursion
                  (goto-char (point-min))
                  (let ((match (text-property-search-forward property index t)))
                    (and match (prop-match-beginning match))))))
    (unless target
      (user-error "Footnote %s %s not found" what index))
    (push-mark nil t)
    (goto-char target)))

;;;; Commands

;;;###autoload
(defun mdview (&optional buffer)
  "Render BUFFER (default: the current buffer) in place and return it.
This turns on `mdview-mode'; in a buffer that is already rendered it
renders again (`mdview-refresh')."
  (interactive)
  (with-current-buffer (get-buffer (or buffer (current-buffer)))
    (if mdview--rendered
        (mdview-refresh)
      (mdview-mode 1))
    (current-buffer)))

;;;###autoload
(defun mdview-file (file)
  "Visit the Markdown FILE in the selected window and show it rendered.
An existing buffer visiting FILE is reused.  Return the buffer."
  (interactive "fMarkdown file: ")
  (let ((file (expand-file-name file)))
    (when (file-directory-p file)
      (user-error "%s is a directory, not a Markdown file" file))
    (unless (file-readable-p file)
      (user-error "Cannot read %s" file))
    (let ((buffer (find-file-noselect file)))
      (pop-to-buffer-same-window buffer)
      (unless mdview--rendered
        (mdview-mode 1))
      buffer)))

;;;###autoload
(defun mdview-toggle ()
  "Switch the current buffer between its Markdown source and its rendering.
Point stays on the same block in both directions, at the same screen
row; toggling twice without moving returns to the exact old position."
  (interactive)
  (mdview-mode (if mdview--rendered -1 1)))

(defun mdview--check-view ()
  "Signal a `user-error' unless the current buffer is rendered."
  (unless mdview--rendered
    (user-error "Not a rendered buffer (use M-x mdview to render this one)")))

(defun mdview-self-insert ()
  "Switch to the Markdown source and type the key there.
Every self-inserting key runs this while a buffer is rendered (the
keymap remaps `self-insert-command'): the buffer goes back to its
source at the word at point, as `mdview-toggle' does, and the key is
then handled as the source handles it, normally `self-insert-command'
inserting it (repeatedly with a numeric prefix argument).  Typing into
the rendering thus edits the document without an explicit switch.  When
`mdview-edit-on-typing' is nil the key reports that the buffer is
read-only instead."
  (interactive)
  (mdview--check-view)
  (unless mdview-edit-on-typing
    (barf-if-buffer-read-only))
  (mdview-mode -1)
  (let ((command (key-binding (vector last-command-event) t)))
    (unless (and (commandp command) (not (eq command 'mdview-self-insert)))
      (setq command #'self-insert-command))
    (setq this-command command)
    (message "Editing the source (%s shows the rendering again)"
             (substitute-command-keys "\\[mdview-toggle]"))
    (call-interactively command)))

(defun mdview-refresh ()
  "Render the buffer again from its source, keeping the current block."
  (interactive)
  (mdview--check-view)
  (mdview--render-into (current-buffer) nil t))

(defun mdview-next-link ()
  "Move point to the next link, wrapping around to the first one."
  (interactive)
  (let ((next (mdview--next-link-position (point))))
    (if next
        (goto-char next)
      (let ((first (mdview--first-link-position)))
        (unless first (user-error "No links in this document"))
        (goto-char first)
        (message "Wrapped to the first link")))))

(defun mdview-previous-link ()
  "Move point to the previous link, wrapping around to the last one."
  (interactive)
  (let ((previous (mdview--previous-link-position (point))))
    (if previous
        (goto-char previous)
      (let ((last (mdview--last-link-position)))
        (unless last (user-error "No links in this document"))
        (goto-char last)
        (message "Wrapped to the last link")))))

(defun mdview-follow-link (&optional pos)
  "Follow the link, image or footnote marker at POS (default: point).
Anchors move to the heading and scroll it to the top; Markdown files
are shown rendered in this window (see `mdview-history-back'); other local
files are visited with `find-file-other-window'; external URLs go to
`browse-url'; images open with `mdview-image-open', except that an
image wrapped in a link follows the link like text would; footnote
references and definitions jump to each other."
  (interactive)
  (let* ((pos (or pos (point)))
         (ref (get-text-property pos 'mdview-footnote-ref))
         (def (get-text-property pos 'mdview-footnote-def))
         (url (get-text-property pos 'mdview-link)))
    (cond (ref (mdview--goto-footnote 'mdview-footnote-def ref "definition"))
          (def (mdview--goto-footnote 'mdview-footnote-ref def "reference"))
          ((and url (mdview--image-at-p pos) (mdview--image-link-p pos url))
           (mdview-image-open url mdview--base-dir))
          (url (mdview--open-url url))
          (t (user-error "No link at point")))))

(defun mdview-mouse-follow-link (event)
  "Move point to the mouse EVENT and follow the link there, if any."
  (interactive "e")
  (mouse-set-point event)
  (when (or (get-text-property (point) 'mdview-link)
            (get-text-property (point) 'mdview-footnote-ref)
            (get-text-property (point) 'mdview-footnote-def))
    (mdview-follow-link)))

(defun mdview-next-heading ()
  "Move point to the next heading."
  (interactive)
  (let ((next (seq-find (lambda (heading) (> (nth 0 heading) (point)))
                        (mdview--headings))))
    (unless next (user-error "No next heading"))
    (goto-char (nth 0 next))))

(defun mdview-previous-heading ()
  "Move point to the previous heading."
  (interactive)
  (let ((previous (seq-find (lambda (heading) (< (nth 0 heading) (point)))
                            (reverse (mdview--headings)))))
    (unless previous (user-error "No previous heading"))
    (goto-char (nth 0 previous))))

(defun mdview--heading-index ()
  "Return (INDEX . HEADINGS): the headings and the index of the one at point.
The heading at point is the last one starting at or before point, the
heading of the section point is in, as `outline-back-to-heading' finds
it; before the first heading signal a `user-error'."
  (let ((headings (mdview--headings))
        (index nil)
        (i 0))
    (dolist (heading headings)
      (when (<= (nth 0 heading) (point))
        (setq index i))
      (setq i (1+ i)))
    (unless index (user-error "Before first heading"))
    (cons index headings)))

(defun mdview-forward-heading-same-level ()
  "Move to the next heading of the same level as the heading at point.
As with `outline-forward-same-level', the search starts from the heading
of the section point is in and stops at a heading of a higher rank (a
smaller level number)."
  (interactive)
  (pcase-let* ((`(,index . ,headings) (mdview--heading-index))
               (level (nth 1 (nth index headings)))
               (target (seq-find (lambda (heading) (<= (nth 1 heading) level))
                                 (nthcdr (1+ index) headings))))
    (unless (and target (= (nth 1 target) level))
      (user-error "No following same-level heading"))
    (goto-char (nth 0 target))))

(defun mdview-backward-heading-same-level ()
  "Move to the previous heading of the same level as the heading at point.
As with `outline-backward-same-level', the search starts from the
heading of the section point is in and stops at a heading of a higher
rank (a smaller level number)."
  (interactive)
  (pcase-let* ((`(,index . ,headings) (mdview--heading-index))
               (level (nth 1 (nth index headings)))
               (target (seq-find (lambda (heading) (<= (nth 1 heading) level))
                                 (reverse (seq-take headings index)))))
    (unless (and target (= (nth 1 target) level))
      (user-error "No previous same-level heading"))
    (goto-char (nth 0 target))))

(defun mdview-up-heading ()
  "Move to the heading the heading at point is a subheading of.
As with `outline-up-heading', that is the nearest previous heading of a
higher rank (a smaller level number) than the heading of the section
point is in."
  (interactive)
  (pcase-let* ((`(,index . ,headings) (mdview--heading-index))
               (level (nth 1 (nth index headings)))
               (target (seq-find (lambda (heading) (< (nth 1 heading) level))
                                 (reverse (seq-take headings index)))))
    (unless target (user-error "Already at top level of the outline"))
    (goto-char (nth 0 target))))

(defun mdview--toc-default (index)
  "Return the label in the imenu INDEX of the heading at or before point."
  (let ((best nil))
    (dolist (entry index)
      (when (and (<= (cdr entry) (point))
                 (or (null best) (> (cdr entry) (cdr best))))
        (setq best entry)))
    (car best)))

(defun mdview--toc-completing-read (index)
  "Prompt for a heading from the imenu INDEX and move point to it.
The heading at or before point is offered as the default."
  (let* ((default (mdview--toc-default index))
         (choice (completing-read (format-prompt "Heading" default)
                                  index nil t nil nil default))
         (target (assoc choice index)))
    (unless target (user-error "No such heading: %s" choice))
    (goto-char (cdr target))))

(defun mdview-toc ()
  "Jump to a heading chosen from the table of contents.
The headings are offered with completion under their own names, the
one at point being the default.  When `imenu-use-popup-menu' is
`always' and the display has menus, the `imenu' menu is used instead
\(falling back to completion should it fail)."
  (interactive)
  (let ((index (mdview--imenu-create-index)))
    (unless index (user-error "No headings in this document"))
    (setq imenu--index-alist nil)
    (if (and (eq imenu-use-popup-menu 'always) (display-popup-menus-p))
        (condition-case nil
            (let ((imenu-auto-rescan t))
              (call-interactively #'imenu))
          (error (mdview--toc-completing-read index)))
      (mdview--toc-completing-read index))))

(defun mdview-history-back ()
  "Show the previous document of this window's history."
  (interactive)
  (mdview--check-view)
  (mdview--history-move -1))

(defun mdview-history-forward ()
  "Show the next document of this window's history."
  (interactive)
  (mdview--check-view)
  (mdview--history-move 1))

(defun mdview-toggle-images ()
  "Toggle the display of images in this buffer and render it again."
  (interactive)
  (mdview--check-view)
  (setq mdview--images-enabled (not mdview--images-enabled))
  (mdview--render-into (current-buffer))
  (message "Images %s" (if mdview--images-enabled "shown" "hidden")))

;;;; The width of the text

(defvar mdview-width-transient-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd ">") #'mdview-increase-width)
    (define-key map (kbd "<") #'mdview-decrease-width)
    (define-key map (kbd "C->") #'mdview-increase-width)
    (define-key map (kbd "C-<") #'mdview-decrease-width)
    (define-key map (kbd "0") #'mdview-reset-width)
    (define-key map (kbd "C-0") #'mdview-reset-width)
    map)
  "Keys that keep adjusting the text width after one adjustment.
Active right after `mdview-increase-width' or `mdview-decrease-width'
until a key outside the map is typed, like the keys that follow
`text-scale-adjust'.")

(defun mdview--report-width ()
  "Say in the echo area how wide the text of the rendering is."
  (let ((limit (or mdview--width-override mdview-max-width)))
    (message "Text width %d columns%s" mdview--last-width
             (cond ((and limit (> limit mdview--last-width))
                    " (all the window allows)")
                   (mdview--width-override "")
                   (t " (the default)")))))

(defun mdview-set-width (width)
  "Render the buffer again with its text at most WIDTH columns wide.
WIDTH replaces `mdview-max-width' for this buffer; the text is still
limited by the window and never narrower than 20 columns.  nil
\(interactively, 0) goes back to `mdview-max-width'.  The choice is
kept while the buffer shows its source and applies when it is rendered
again."
  (interactive "nText width in columns (0 for the default): ")
  (mdview--check-view)
  (setq mdview--width-override
        (and (numberp width) (> width 0) (max 20 width)))
  (mdview--render-into (current-buffer))
  (mdview--report-width))

(defun mdview-reset-width ()
  "Render the buffer again at the default text width, `mdview-max-width'.
Bound to \\<mdview-mode-map>\\[mdview-reset-width] while rendered, which
therefore does not start a numeric argument there; \\[universal-argument] 0
and \\<global-map>\\[digit-argument] still do."
  (interactive)
  (mdview-set-width nil))

(defun mdview--width-delta (arg)
  "Return the number of columns to change the width by for prefix ARG.
A numeric ARG is that many columns; nil means `mdview-width-step'."
  (if arg (prefix-numeric-value arg) (max 1 mdview-width-step)))

(defun mdview--adjust-width (delta)
  "Make the text of the rendering DELTA columns wider, or narrower if negative.
The window's width and the floor of 20 columns bound the result; when
they leave nothing to change, say so instead of rendering again.  The
keys of `mdview-width-transient-map' stay active afterwards."
  (mdview--check-view)
  (let* ((available (mdview--available-width))
         (current (mdview--content-width))
         (target (max 20 (min available (+ current delta)))))
    (if (= target current)
        (message (if (> delta 0)
                     "The window allows no more than %d columns"
                   "The text is already as narrow as it gets, %d columns")
                 current)
      (setq mdview--width-override target)
      (mdview--render-into (current-buffer))
      (mdview--report-width))
    (set-transient-map mdview-width-transient-map t)))

(defun mdview-increase-width (&optional columns)
  "Make the text of the rendering `mdview-width-step' columns wider.
With a numeric prefix argument COLUMNS, that many columns wider.  The
window limits the width.  Afterwards `>', `<' and `0' keep adjusting
the width or reset it (`mdview-width-transient-map'); `C-0' resets it
at any time."
  (interactive "P")
  (mdview--adjust-width (mdview--width-delta columns)))

(defun mdview-decrease-width (&optional columns)
  "Make the text of the rendering `mdview-width-step' columns narrower.
With a numeric prefix argument COLUMNS, that many columns narrower; the
text never gets narrower than 20 columns.  Afterwards `>', `<' and `0'
keep adjusting the width or reset it (`mdview-width-transient-map');
`C-0' resets it at any time."
  (interactive "P")
  (mdview--adjust-width (- (mdview--width-delta columns))))

(defun mdview--resolved-link (url)
  "Return URL with the path of a local link made absolute.
Anchors, external URLs and empty paths are returned unchanged; the
#anchor part of a local link is kept."
  (if (or (string-prefix-p "#" url) (mdview--external-url-p url))
      url
    (pcase-let ((`(,path . ,anchor) (mdview--split-fragment url)))
      (if (string-empty-p path)
          url
        (concat (mdview--local-file path)
                (and anchor (concat "#" anchor)))))))

(defun mdview-copy-link (&optional raw)
  "Copy the URL of the link at point to the kill ring.
A link to a local file is copied as the absolute file name it resolves
to (with any #anchor kept), because the relative form written in the
document is only meaningful next to it.  With a prefix argument RAW the
URL is copied exactly as written; anchors and external URLs always are."
  (interactive "P")
  (let ((url (get-text-property (point) 'mdview-link)))
    (unless url (user-error "No link at point"))
    (let ((text (if raw url (mdview--resolved-link url))))
      (kill-new text)
      (message "Copied %s" text))))

;;;###autoload
(defun mdview-version (&optional show)
  "Return the version of mdview; with SHOW (interactively), display it too."
  (interactive (list t))
  (when show
    (message "mdview %s" mdview-version))
  mdview-version)

;;;; Integration with Markdown editing modes

;;;###autoload
(defun mdview-install-keybinding (key)
  "Bind KEY to `mdview-toggle' in the keymaps of the Markdown editing modes.
KEY is a string in the format of `kbd' or a key vector.  The binding is
installed in `markdown-mode-map', `gfm-mode-map' and `md-mode-map' as
soon as the corresponding library is loaded, so this can be called from
the init file before those modes are available."
  (let ((key (if (stringp key) (kbd key) key)))
    (pcase-dolist (`(,feature . ,map) '((markdown-mode . markdown-mode-map)
                                         (markdown-mode . gfm-mode-map)
                                         (md-mode . md-mode-map)))
      (with-eval-after-load feature
        (when (boundp map)
          (define-key (symbol-value map) key #'mdview-toggle))))))


;;;###autoload
(defun mdview--initial-view ()
  "Render the newly visited current buffer when it is a Markdown file.
Called from `find-file-hook' (via `mdview--find-file-hook') when
`mdview-initial-view' is `view'.  Buffers whose major mode does not
derive from one of `mdview-markdown-modes', indirect buffers and
buffers being reverted (a revert renders again by itself) are left
alone; a failure is reported and leaves the source shown."
  (when (and (not revert-buffer-in-progress-p)
             (not mdview--rendered)
             (not mdview--owner)
             (not (buffer-base-buffer))
             (seq-some (lambda (mode) (provided-mode-derived-p major-mode mode))
                       mdview-markdown-modes))
    (mdview--enter-or-report)))

;; The two forms below are also copied into the autoloads file, so that
;; files open rendered without mdview being loaded beforehand, while a
;; visit costs nothing as long as the option is `edit'.
;;;###autoload (defun mdview--find-file-hook () "Apply `mdview-initial-view' to the visited file." (when (eq mdview-initial-view 'view) (mdview--initial-view)))
;;;###autoload (add-hook 'find-file-hook #'mdview--find-file-hook 90)

(defun mdview--find-file-hook ()
  "Apply `mdview-initial-view' to the visited file."
  (when (eq mdview-initial-view 'view)
    (mdview--initial-view)))

(add-hook 'find-file-hook #'mdview--find-file-hook 90)

(provide 'mdview)
;;; mdview.el ends here
