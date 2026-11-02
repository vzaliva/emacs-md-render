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

;; mdview renders a Markdown buffer or file into a read-only view buffer
;; laid out in the visual style of Frogmouth (docs/DESIGN.md).  This file
;; is the user-facing part of the package: the commands (`mdview',
;; `mdview-file', `mdview-toggle'), the major mode `mdview-mode' with its
;; keymap, link following, the view history, automatic re-flow when the
;; window width changes, re-rendering when the source is saved, and the
;; integration with Markdown editing modes (`mdview-install-keybinding').
;;
;; A view buffer (named *mdview: NAME*) remembers its source: the buffer
;; it was rendered from and/or the file.  The renderer marks the first
;; line of every block with the text property `mdview-source-line', which
;; the view uses to keep point in sync with the source in both directions.
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
  "Maximum content width of a view in columns, or nil for no limit.
The content width is the window width minus the margins, capped at this
value (docs/DESIGN.md section 10)."
  :type '(choice (const :tag "Unlimited" nil)
                 (integer :tag "Columns"))
  :group 'mdview)

(defcustom mdview-margin 4
  "Width in columns of the left and right margins of a view."
  :type 'integer
  :group 'mdview)

(defcustom mdview-center-content nil
  "Non-nil means center the content when the window is wider than needed.
The left margin grows so that content limited by `mdview-max-width' sits
in the middle of the window."
  :type 'boolean
  :group 'mdview)

(defcustom mdview-display-action #'pop-to-buffer-same-window
  "Function called with the view buffer to display it.
The default shows the view in the selected window, replacing the source,
so that `mdview-toggle' flips between the two.  Use `pop-to-buffer' to
show the view in another window instead."
  :type '(choice (const :tag "Same window" pop-to-buffer-same-window)
                 (const :tag "Other window" pop-to-buffer)
                 (function :tag "Custom function"))
  :group 'mdview)

(defcustom mdview-auto-refit t
  "Non-nil means re-render a view when the width of its window changes.
The re-rendering happens after `mdview-refit-delay' seconds of idle time
and only when the effective content width actually changed."
  :type 'boolean
  :group 'mdview)

(defcustom mdview-refit-delay 0.2
  "Idle time in seconds before a view is re-rendered after a resize."
  :type 'number
  :group 'mdview)

(defcustom mdview-refresh-on-save t
  "Non-nil means re-render the views of a source buffer when it is saved."
  :type 'boolean
  :group 'mdview)

(defcustom mdview-markdown-extensions '("md" "markdown" "mdown" "mkd" "mkdn")
  "File name extensions (lower case, without the dot) of Markdown files.
Links to such files are rendered inside the view; links to other local
files are visited with `find-file-other-window'."
  :type '(repeat string)
  :group 'mdview)

;;;; Buffer-local state of a view

(defvar-local mdview--source-buffer nil
  "The buffer this view was rendered from, or nil.")

(defvar-local mdview--source-file nil
  "The absolute file name of this view's source, or nil.")

(defvar-local mdview--base-dir nil
  "The directory against which relative links and images resolve.")

(defvar-local mdview--last-width nil
  "The content width used by the last rendering of this view.")

(defvar-local mdview--history nil
  "The documents shown in this view: a list of (FILE-OR-BUFFER . POINT).
The oldest entry comes first; `mdview--history-index' is the current one.")

(defvar-local mdview--history-index -1
  "Index into `mdview--history' of the document currently shown.")

(defvar-local mdview--images-enabled nil
  "Non-nil means this view displays images (see `mdview-toggle-images').")

(defvar-local mdview--refit-timer nil
  "The idle timer scheduled by `mdview--window-size-changed', or nil.")

(defvar-local mdview--image-update-timer nil
  "The idle timer scheduled by `mdview--on-images-updated', or nil.")

(defvar-local mdview--source-window nil
  "The window in which this view replaced its source buffer, or nil.
`mdview-quit' switches that window back to `mdview--origin-buffer'.")

(defvar-local mdview--origin-buffer nil
  "The buffer this view replaced in `mdview--source-window', or nil.
It is the buffer the view was opened from and stays the same when links
to other documents are followed, so that `mdview-quit' returns there.")

(defvar-local mdview--document nil
  "The parsed source of this view as (KEY . DOCUMENT), or nil.
KEY identifies the source text (see `mdview--source-key'); while it still
matches, re-rendering for a new width or image setting reuses DOCUMENT
instead of parsing again.")

(defvar mdview--render-gc-threshold (* 64 1024 1024)
  "Value `gc-cons-threshold' is raised to while a view is rendered.
The renderer allocates many short-lived strings and lists; with the
default threshold a large document triggers hundreds of collections,
each re-marking the intervals of every open view, and the collections
dominate the rendering time.")

;;;; Keymap and mode

(defvar mdview-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "q") #'mdview-quit)
    (define-key map (kbd "g") #'mdview-refresh)
    (define-key map (kbd "TAB") #'mdview-next-link)
    (define-key map [backtab] #'mdview-previous-link)
    (define-key map [S-tab] #'mdview-previous-link)
    (define-key map (kbd "RET") #'mdview-follow-link)
    (define-key map [mouse-1] #'mdview-mouse-follow-link)
    (define-key map [mouse-2] #'mdview-mouse-follow-link)
    (define-key map (kbd "n") #'mdview-next-heading)
    (define-key map (kbd "p") #'mdview-previous-heading)
    (define-key map (kbd "t") #'mdview-toc)
    (define-key map (kbd "l") #'mdview-history-back)
    (define-key map (kbd "r") #'mdview-history-forward)
    (define-key map (kbd "i") #'mdview-toggle-images)
    (define-key map (kbd "e") #'mdview-visit-source)
    (define-key map (kbd "w") #'mdview-copy-link)
    (define-key map (kbd "SPC") #'scroll-up-command)
    (define-key map (kbd "DEL") #'scroll-down-command)
    (define-key map (kbd "S-SPC") #'scroll-down-command)
    (define-key map (kbd "<") #'beginning-of-buffer)
    (define-key map (kbd ">") #'end-of-buffer)
    (define-key map (kbd "C-c C-v") #'mdview-toggle)
    map)
  "Keymap of `mdview-mode'.")

;;;###autoload
(define-derived-mode mdview-mode special-mode "mdview"
  "Major mode for viewing Markdown rendered by mdview.
The buffer is read-only; lines are never wrapped (the renderer lays the
text out at render time).  Headings are indexed for `imenu'.

\\{mdview-mode-map}"
  :group 'mdview
  (setq truncate-lines t)
  (setq buffer-read-only t)
  ;; The view is rewritten wholesale on every render; undo records of
  ;; that are useless in a read-only buffer and would retain the whole
  ;; previous rendering.
  (buffer-disable-undo)
  (setq-local imenu-create-index-function #'mdview--imenu-create-index)
  (setq-local revert-buffer-function #'mdview--revert-buffer)
  (setq left-margin-width mdview-margin
        right-margin-width mdview-margin)
  (setq mdview--images-enabled mdview-display-images)
  (mdview-faces-remap)
  (add-hook 'kill-buffer-hook #'mdview--on-kill nil t)
  (add-hook 'window-size-change-functions #'mdview--window-size-changed nil t)
  ;; Refresh-on-save is a global hook filtered by source buffer, so that a
  ;; mode change in the source (`kill-all-local-variables') cannot lose it.
  (add-hook 'after-save-hook #'mdview--after-save)
  ;; Remote images that arrive after the rendering re-flow the view.
  (add-hook 'mdview-image-update-functions #'mdview--on-images-updated))

;;;; Width and margins

(defun mdview--window-columns (window)
  "Return the width of WINDOW's body plus its display margins, in columns."
  (let ((margins (window-margins window)))
    (+ (window-body-width window)
       (or (car margins) 0)
       (or (cdr margins) 0))))

(defun mdview--view-window ()
  "Return a window showing the current buffer, else the selected window."
  (or (get-buffer-window (current-buffer))
      (get-buffer-window (current-buffer) t)
      (selected-window)))

(defun mdview--content-width (&optional window)
  "Return the content width for the view in WINDOW (default: its window).
This is the window width minus the margins and one column, limited by
`mdview-max-width', and never less than 20 (docs/DESIGN.md section 10)."
  (let* ((columns (mdview--window-columns (or window (mdview--view-window))))
         (available (- columns (* 2 mdview-margin) 1)))
    (max 20 (if mdview-max-width (min available mdview-max-width) available))))

(defun mdview--apply-margins (width)
  "Set the display margins of the view for content WIDTH and update windows.
With `mdview-center-content', the left margin absorbs the space left over
by `mdview-max-width'."
  (let* ((windows (get-buffer-window-list (current-buffer) nil t))
         (columns (mdview--window-columns (or (car windows) (selected-window))))
         (extra (if mdview-center-content
                    (max 0 (- columns 1 (* 2 mdview-margin) width))
                  0)))
    (setq left-margin-width (+ mdview-margin (/ extra 2))
          right-margin-width mdview-margin)
    ;; Margins take effect when the window is (re)assigned its buffer,
    ;; which also resets the window's start; only do it when they changed.
    (dolist (window windows)
      (let ((margins (window-margins window)))
        (unless (and (eql (or (car margins) 0) left-margin-width)
                     (eql (or (cdr margins) 0) right-margin-width))
          (set-window-buffer window (current-buffer)))))))

;;;; Source access and the rendering pipeline

(defun mdview--source-text ()
  "Return the Markdown text of this view's source as a string.
The live source buffer wins; otherwise the source file is read."
  (let ((buffer mdview--source-buffer)
        (file mdview--source-file))
    (cond ((buffer-live-p buffer)
           (with-current-buffer buffer
             (buffer-substring-no-properties (point-min) (point-max))))
          ((and file (file-readable-p file))
           (with-temp-buffer
             (insert-file-contents file)
             (buffer-string)))
          (t (user-error "The source of this view no longer exists")))))

(defun mdview--source-key ()
  "Return a value identifying the current text of this view's source.
A live source buffer is identified by its `buffer-chars-modified-tick',
a file by its modification time and size.  Return nil when there is no
readable source."
  (let ((buffer mdview--source-buffer)
        (file mdview--source-file))
    (cond ((buffer-live-p buffer)
           (list buffer (buffer-chars-modified-tick buffer)))
          ((and file (file-readable-p file))
           (let ((attributes (file-attributes file)))
             (list file
                   (file-attribute-modification-time attributes)
                   (file-attribute-size attributes)))))))

(defun mdview--source-document ()
  "Return the parsed document of this view's source, parsing when needed.
The result is cached in `mdview--document' together with the key of the
source text (`mdview--source-key'), so re-rendering an unchanged source
for a new width or image setting skips the parser."
  (let ((key (mdview--source-key)))
    (if (and key mdview--document (equal key (car mdview--document)))
        (cdr mdview--document)
      (let ((document (mdview-parse-string (mdview--source-text))))
        (setq mdview--document (and key (cons key document)))
        document))))

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
  "Return the blocks of the view as a list of (SOURCE-LINE . POSITION)."
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

(defun mdview--view-point ()
  "Return point as seen in the window showing the view, else `point'."
  (let ((window (get-buffer-window (current-buffer) t)))
    (if (and window (not (eq window (selected-window))))
        (window-point window)
      (point))))

(defun mdview--window-starts (buffer)
  "Return the scroll positions of the windows showing BUFFER.
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

(defun mdview--render-into (buffer &optional line)
  "Render the source of the view BUFFER into it and restore the position.
Point ends up at the block rendered from source line LINE (an integer),
or, when LINE is nil, at the block that was at point before; the windows
showing the view keep the block that was at their top.  The parsed
document is reused when the source text did not change (see
`mdview--source-document'), and garbage collection is made less eager
for the duration (`mdview--render-gc-threshold')."
  (with-current-buffer buffer
    (let* ((gc-cons-threshold (max gc-cons-threshold mdview--render-gc-threshold))
           (gc-cons-percentage (max gc-cons-percentage 0.5))
           (document (mdview--source-document))
           (line (or line (mdview--source-line-at (mdview--view-point))))
           (starts (mdview--window-starts buffer))
           (width (mdview--content-width))
           (inhibit-read-only t)
           (buffer-undo-list t)
           (mdview-display-images mdview--images-enabled))
      (mdview--cancel-refit)
      (mdview--cancel-image-update)
      (when (fboundp 'mdview-image-cancel-pending)
        (mdview-image-cancel-pending buffer))
      (erase-buffer)
      (mdview-render-document document :width width :base-dir mdview--base-dir)
      (setq mdview--last-width width)
      (setq imenu--index-alist nil)
      (set-buffer-modified-p nil)
      (mdview--apply-margins width)
      (goto-char (point-min))
      (when line (mdview--goto-source-line line))
      (dolist (window (get-buffer-window-list buffer nil t))
        (set-window-point window (point)))
      (mdview--restore-window-starts starts))))

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

;;;; Views and their sources

(defun mdview--buffer-name (name)
  "Return the name of the view buffer for a source called NAME."
  (format "*mdview: %s*" name))

(defun mdview--view-p (buffer)
  "Return non-nil when BUFFER is a live `mdview-mode' buffer."
  (and (buffer-live-p buffer)
       (provided-mode-derived-p (buffer-local-value 'major-mode buffer)
                                'mdview-mode)))

(defun mdview--views-of (source)
  "Return the live views whose source buffer is SOURCE."
  (seq-filter (lambda (buffer)
                (and (mdview--view-p buffer)
                     (eq (buffer-local-value 'mdview--source-buffer buffer)
                         source)))
              (buffer-list)))

(defun mdview--view-shows-p (view buffer file)
  "Return non-nil when VIEW's current source is BUFFER or FILE."
  (or (and buffer
           (eq (buffer-local-value 'mdview--source-buffer view) buffer))
      (and file
           (equal (buffer-local-value 'mdview--source-file view) file))))

(defun mdview--view-showed-p (view buffer file)
  "Return non-nil when BUFFER or FILE occurs in the history of VIEW."
  (seq-some (lambda (entry)
              (let ((source (car entry)))
                (or (and buffer (eq source buffer))
                    (and file (equal source file)))))
            (buffer-local-value 'mdview--history view)))

(defun mdview--find-view (buffer file)
  "Return the live view rendered from BUFFER or from FILE, or nil.
A view currently showing that source is preferred; failing that, a view
that showed it earlier in its history (and then followed a link to
another document) is returned, so that toggling from the same source
comes back to the same view instead of creating a second one."
  (let ((views (seq-filter #'mdview--view-p (buffer-list))))
    (or (seq-find (lambda (view) (mdview--view-shows-p view buffer file)) views)
        (seq-find (lambda (view) (mdview--view-showed-p view buffer file)) views))))

(defun mdview--source-name (buffer file)
  "Return the display name of a source given its BUFFER and FILE.
The result is never empty."
  (let ((name (cond (file (file-name-nondirectory (directory-file-name file)))
                    ((buffer-live-p buffer) (buffer-name buffer)))))
    (if (and name (not (string-empty-p name))) name "?")))

(defun mdview--set-source (buffer file)
  "Make BUFFER and/or FILE (either may be nil) the source of this view.
Updates the base directory, `default-directory' and the name of the view
buffer."
  (setq mdview--source-buffer buffer
        mdview--source-file (and file (expand-file-name file))
        mdview--base-dir (cond (file (file-name-directory (expand-file-name file)))
                               ((buffer-live-p buffer)
                                (buffer-local-value 'default-directory buffer))
                               (t default-directory)))
  (setq default-directory mdview--base-dir)
  (let ((name (mdview--buffer-name (mdview--source-name buffer file))))
    (unless (equal (buffer-name) name)
      (rename-buffer name t))))

(defun mdview--make-view (buffer file)
  "Return the view for source BUFFER and/or FILE, creating it if needed.
An existing view of the same source is reused; a new one is put in
`mdview-mode' and gets its first history entry."
  (let ((view (or (mdview--find-view buffer file)
                  (generate-new-buffer
                   (mdview--buffer-name (mdview--source-name buffer file))))))
    (with-current-buffer view
      (unless (derived-mode-p 'mdview-mode)
        (mdview-mode))
      (mdview--set-source buffer file)
      (unless (and (>= mdview--history-index 0)
                   (equal (car (nth mdview--history-index mdview--history))
                          (or mdview--source-file buffer)))
        (mdview--history-push)))
    view))

(defun mdview--display (view)
  "Show VIEW and remember where it came from.
When VIEW is already visible in a window of the selected frame, that
window is selected, so toggling from a source shown next to its view
keeps both visible.  Otherwise `mdview-display-action' shows it, and
when that replaced the buffer of the selected window, the window and
the buffer are remembered for `mdview-quit'."
  (let ((window (get-buffer-window view)))
    (if window
        (select-window window)
      (let* ((origin (selected-window))
             (buffer (let ((source (buffer-local-value 'mdview--source-buffer view)))
                       (if (buffer-live-p source) source (window-buffer origin)))))
        (funcall mdview-display-action view)
        (with-current-buffer view
          (let ((replaced (eq (window-buffer origin) view)))
            (setq mdview--source-window (and replaced origin)
                  mdview--origin-buffer (and replaced buffer))))))))

(defun mdview--show (view line)
  "Display VIEW and render it with point at source LINE; return VIEW.
When the very first rendering of a new view fails, the view is killed
and the windows restored before the error is signalled again, so that
no empty view is left on display."
  (let ((fresh (null (buffer-local-value 'mdview--last-width view)))
        (configuration (current-window-configuration)))
    (mdview--display view)
    (condition-case err
        (mdview--render-into view line)
      (error
       (when fresh
         (set-window-configuration configuration)
         (kill-buffer view))
       (signal (car err) (cdr err))))
    view))

(defun mdview--ensure-source-buffer ()
  "Return the live source buffer of this view, visiting the file if needed."
  (cond ((buffer-live-p mdview--source-buffer) mdview--source-buffer)
        ((and mdview--source-file (file-exists-p mdview--source-file))
         (let ((buffer (find-file-noselect mdview--source-file)))
           (mdview--set-source buffer mdview--source-file)
           buffer))
        (t (user-error "The source of this view no longer exists"))))

;;;; Hooks: saving the source, killing the view, resizing the window

(defun mdview--after-save ()
  "Re-render the views of the buffer that was just saved, if any.
Runs from the global `after-save-hook' (installed by `mdview-mode') and
does nothing for buffers that are not the source of a view."
  (when mdview-refresh-on-save
    (dolist (view (mdview--views-of (current-buffer)))
      (condition-case err
          (mdview--render-into view)
        (error (message "mdview: %s" (error-message-string err)))))))

(defun mdview--on-kill ()
  "Clean up when a view buffer is killed."
  (mdview--cancel-refit)
  (mdview--cancel-image-update)
  (when (fboundp 'mdview-image-cancel-pending)
    (mdview-image-cancel-pending (current-buffer) t))
  (setq mdview--source-buffer nil
        mdview--document nil))

(defun mdview--cancel-refit ()
  "Cancel the pending refit timer of this view, if any."
  (when mdview--refit-timer
    (cancel-timer mdview--refit-timer)
    (setq mdview--refit-timer nil)))

(defun mdview--window-size-changed (object)
  "Schedule a refit of the view shown in OBJECT, a window or a frame.
Runs from the buffer-local `window-size-change-functions'."
  (let ((buffer (if (windowp object) (window-buffer object) (current-buffer))))
    (when (mdview--view-p buffer)
      (with-current-buffer buffer
        (when mdview-auto-refit
          (mdview--cancel-refit)
          (setq mdview--refit-timer
                (run-with-idle-timer mdview-refit-delay nil
                                     #'mdview--refit buffer)))))))

(defun mdview--refit (buffer &optional line)
  "Re-render the view BUFFER if its content width changed.
Point goes to the block of source LINE, or stays on the current block
when LINE is nil.  The rendering is abandoned as soon as the user types
and rescheduled for the next idle period (with LINE remembered), so a
resize never locks Emacs up; a failure is reported in the echo area
once rather than on every resize.  Return non-nil when a rendering
completed."
  (when (mdview--view-p buffer)
    (with-current-buffer buffer
      (setq mdview--refit-timer nil)
      (let ((window (get-buffer-window buffer t)))
        (when (and window
                   (not (eql (mdview--content-width window) mdview--last-width)))
          (let ((line (or line (mdview--source-line-at (mdview--view-point)))))
            (condition-case err
                (if (while-no-input (mdview--render-into buffer line) nil)
                    (progn
                      (setq mdview--refit-timer
                            (run-with-idle-timer mdview-refit-delay nil
                                                 #'mdview--refit buffer line))
                      nil)
                  t)
              (error
               ;; Do not retry at this width on every subsequent resize.
               (setq mdview--last-width (mdview--content-width window))
               (message "mdview: %s" (error-message-string err))
               nil))))))))

(defun mdview--cancel-image-update ()
  "Cancel the pending image re-rendering timer of this view, if any."
  (when mdview--image-update-timer
    (cancel-timer mdview--image-update-timer)
    (setq mdview--image-update-timer nil)))

(defun mdview--on-images-updated (buffer)
  "Schedule a re-rendering of the view BUFFER after remote images arrived.
Runs from `mdview-image-update-functions' (installed by `mdview-mode')
and ignores buffers that are not views.  The image module replaces a
placeholder in place, which keeps the width of its line but cannot
re-wrap a paragraph around an inline image, so the view is rendered
again from the cached document (the image bytes are cached as well)
once Emacs has been idle for `mdview-refit-delay'; images arriving close
together share one rendering."
  (when (mdview--view-p buffer)
    (with-current-buffer buffer
      (mdview--cancel-image-update)
      (setq mdview--image-update-timer
            (run-with-idle-timer mdview-refit-delay nil
                                 #'mdview--rerender-for-images buffer)))))

(defun mdview--rerender-for-images (buffer)
  "Re-render the view BUFFER so that its text re-flows around its images.
Nothing happens when images are switched off in the view.  Like a refit
the rendering is abandoned and rescheduled when the user types, and a
failure is reported once in the echo area."
  (when (mdview--view-p buffer)
    (with-current-buffer buffer
      (setq mdview--image-update-timer nil)
      (when mdview--images-enabled
        (condition-case err
            (when (while-no-input (mdview--render-into buffer) nil)
              (mdview--on-images-updated buffer))
          (error (message "mdview: %s" (error-message-string err))))))))

(defun mdview--revert-buffer (&rest _)
  "Re-render the view; the `revert-buffer-function' of `mdview-mode'."
  (mdview-refresh))

;;;; History

(defun mdview--history-save-point ()
  "Record point in the current history entry."
  (when (>= mdview--history-index 0)
    (setcdr (nth mdview--history-index mdview--history) (point))))

(defun mdview--history-push ()
  "Add the current source to the history, dropping the forward entries."
  (mdview--history-save-point)
  (setq mdview--history
        (append (seq-take mdview--history (1+ mdview--history-index))
                (list (cons (or mdview--source-file mdview--source-buffer)
                            (point)))))
  (setq mdview--history-index (1- (length mdview--history))))

(defun mdview--history-move (delta)
  "Show the history entry at distance DELTA from the current one."
  (let ((index (+ mdview--history-index delta)))
    (unless (and (>= index 0) (< index (length mdview--history)))
      (user-error (if (< delta 0)
                      "No earlier document in the history"
                    "No later document in the history")))
    (mdview--history-save-point)
    (let* ((entry (nth index mdview--history))
           (source (car entry)))
      (cond ((stringp source)
             (mdview--set-source (find-buffer-visiting source) source))
            ((buffer-live-p source)
             (mdview--set-source source (buffer-file-name source)))
            (t (user-error "The source buffer of that document was killed")))
      (setq mdview--history-index index)
      (mdview--render-into (current-buffer) 1)
      (goto-char (min (cdr entry) (point-max))))))

;;;; Headings

(defun mdview--headings ()
  "Return the headings of the view as a list of (POSITION LEVEL ID TEXT).
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
  "Return an imenu index of the headings in the view."
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
  "Scroll the window of the view to put the block at POS at the top."
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
  "Return the start of the first link in the view, or nil."
  (if (get-text-property (point-min) 'mdview-link)
      (point-min)
    (mdview--next-link-position (point-min))))

(defun mdview--last-link-position ()
  "Return the start of the last link in the view, or nil."
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
resolve against the view's base directory."
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
  "Render the Markdown FILE in this view, pushing it onto the history."
  (let ((file (expand-file-name file)))
    (mdview--set-source (find-buffer-visiting file) file)
    (mdview--history-push)
    (mdview--render-into (current-buffer) 1)))

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
  "Render BUFFER (default: the current buffer) as Markdown and show the view.
The view is a buffer named *mdview: NAME* in `mdview-mode', displayed
with `mdview-display-action'; point is placed at the block rendered from
the line at point in BUFFER.  An existing view of BUFFER is reused.
Return the view buffer."
  (interactive)
  (let ((source (get-buffer (or buffer (current-buffer)))))
    (if (mdview--view-p source)
        (with-current-buffer source (mdview-refresh) source)
      (let ((line (with-current-buffer source (line-number-at-pos)))
            (file (buffer-file-name (or (buffer-base-buffer source) source))))
        (mdview--show (mdview--make-view source file) line)))))

;;;###autoload
(defun mdview-file (file)
  "Render the Markdown FILE and show the view.
A buffer visiting FILE becomes the view's source; otherwise the file is
read directly and `mdview-visit-source' visits it on demand.  Relative
links and images resolve against the directory of FILE.  Return the
view buffer."
  (interactive "fMarkdown file: ")
  (let* ((file (expand-file-name file))
         (buffer (find-buffer-visiting file)))
    (when (file-directory-p file)
      (user-error "%s is a directory, not a Markdown file" file))
    (unless (file-readable-p file)
      (user-error "Cannot read %s" file))
    (if buffer
        (mdview buffer)
      (mdview--show (mdview--make-view nil file) 1))))

;;;###autoload
(defun mdview-toggle ()
  "Switch between a Markdown buffer and its rendered view.
In a Markdown buffer, show the view with point at the block rendered
from the current line.  In a view, go back to the source at the line of
the block at point, visiting the source file when no buffer holds it."
  (interactive)
  (if (derived-mode-p 'mdview-mode)
      (mdview-visit-source)
    (mdview)))

(defun mdview--check-view ()
  "Signal a `user-error' unless the current buffer is an mdview view."
  (unless (derived-mode-p 'mdview-mode)
    (user-error "Not in an mdview buffer (use M-x mdview to render this one)")))

(defun mdview-refresh ()
  "Re-render the view from its source, keeping the current block."
  (interactive)
  (mdview--check-view)
  (mdview--render-into (current-buffer)))

(defun mdview-quit ()
  "Quit the view.
When the view replaced another buffer in the selected window (the
Markdown buffer it was opened from, even after links to other documents
were followed), show that buffer there again; otherwise use
`quit-window'."
  (interactive)
  (let ((view (current-buffer))
        (back (if (buffer-live-p mdview--origin-buffer)
                  mdview--origin-buffer
                mdview--source-buffer)))
    (if (and (eq (selected-window) mdview--source-window)
             (buffer-live-p back))
        (progn
          (setq mdview--source-window nil
                mdview--origin-buffer nil)
          (pop-to-buffer-same-window back)
          (bury-buffer view))
      (quit-window))))

(defun mdview-visit-source ()
  "Visit the source of this view at the line of the block at point."
  (interactive)
  (mdview--check-view)
  (let* ((line (mdview--source-line-at (point)))
         (buffer (mdview--ensure-source-buffer))
         (window (get-buffer-window buffer)))
    (if window
        (select-window window)
      (pop-to-buffer-same-window buffer))
    (when line
      (goto-char (point-min))
      (forward-line (1- line)))))

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
are rendered in this view (see `mdview-history-back'); other local
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
  "Show the previous document of this view's history."
  (interactive)
  (mdview--check-view)
  (mdview--history-move -1))

(defun mdview-history-forward ()
  "Show the next document of this view's history."
  (interactive)
  (mdview--check-view)
  (mdview--history-move 1))

(defun mdview-toggle-images ()
  "Toggle the display of images in this view and re-render it."
  (interactive)
  (mdview--check-view)
  (setq mdview--images-enabled (not mdview--images-enabled))
  (mdview--render-into (current-buffer))
  (message "Images %s" (if mdview--images-enabled "shown" "hidden")))

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

(provide 'mdview)
;;; mdview.el ends here
