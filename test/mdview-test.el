;;; mdview-test.el --- Tests for the mdview commands  -*- lexical-binding: t; -*-

;; This file is part of mdview, distributed under the MIT license; see
;; LICENSE in the repository root.

;;; Commentary:

;; ERT tests for mdview.el (docs/DESIGN.md sections 10 and 13): the
;; in-place minor mode and what it must preserve of the source, saving,
;; reverting and auto-revert of a rendered buffer, the commands, link
;; navigation and following, the per-window history, refit, source
;; synchronisation and the integration hooks.  The tests exercise the
;; plumbing and never depend on the exact rendering; for the navigation
;; commands, links, headings and footnote markers are inserted as text
;; properties into a "fake" rendered buffer directly.  Everything runs
;; headless.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'autorevert)
(require 'mdview)

(defconst mdview-test-dir
  (file-name-directory (or load-file-name buffer-file-name default-directory))
  "Directory of this test file.")

(defvar md-mode-map)                    ; stands in for md-mode's keymap below

(defun mdview-test--hidden-buffers ()
  "Return the live hidden buffers mdview created for renderings."
  (seq-filter (lambda (buffer)
                (string-prefix-p " *mdview: " (buffer-name buffer)))
              (buffer-list)))

(defun mdview-test--cleanup (&rest buffers)
  "Kill the BUFFERS, discarding modifications."
  (let ((kill-buffer-query-functions nil))
    (dolist (buffer buffers)
      (when (buffer-live-p buffer)
        (with-current-buffer buffer (set-buffer-modified-p nil))
        (kill-buffer buffer)))))

(defmacro mdview-test-with-source (binding &rest body)
  "Bind the variable of BINDING to a buffer holding its text; run BODY.
BINDING is (VAR TEXT).  The buffer is shown in the selected window, with
point at its beginning, and killed afterwards."
  (declare (indent 1))
  (let ((var (car binding)))
    `(let ((,var (generate-new-buffer "test.md")))
       (unwind-protect
           (progn
             (with-current-buffer ,var
               (insert ,(cadr binding))
               (set-buffer-modified-p nil)
               (goto-char (point-min)))
             (set-window-buffer (selected-window) ,var)
             ,@body)
         (mdview-test--cleanup ,var)))))

(defmacro mdview-test-with-file (binding &rest body)
  "Visit a temporary Markdown file and run BODY.
BINDING is (BUFFER FILE CONTENT): FILE is bound to the name of a new
file holding CONTENT in a temporary directory and BUFFER to the buffer
visiting it, shown in the selected window.  Everything is removed
afterwards."
  (declare (indent 1))
  (let ((buffer (nth 0 binding))
        (file (nth 1 binding))
        (dir (make-symbol "dir")))
    `(let* ((,dir (make-temp-file "mdview-test" t))
            (,file (mdview-test--write-file ,dir "doc.md" ,(nth 2 binding)))
            (,buffer (find-file-noselect ,file)))
       (unwind-protect
           (progn
             (set-window-buffer (selected-window) ,buffer)
             ,@body)
         (mdview-test--cleanup ,buffer)
         (delete-directory ,dir t)))))

(defmacro mdview-test-with-fake-view (binding &rest body)
  "Bind the variable of BINDING to a rendered-looking buffer; run BODY.
BINDING is (VAR TEXT); TEXT may carry text properties.  The buffer is
marked as rendered without any source behind it, shown in the selected
window, and BODY runs with it current; it is killed afterwards."
  (declare (indent 1))
  (let ((var (car binding)))
    `(let ((,var (generate-new-buffer "fake.md")))
       (unwind-protect
           (with-current-buffer ,var
             (insert ,(cadr binding))
             (setq mdview--rendered t
                   mdview-mode t
                   buffer-read-only t)
             (setq-local imenu-create-index-function #'mdview--imenu-create-index)
             (set-buffer-modified-p nil)
             (goto-char (point-min))
             (set-window-buffer (selected-window) ,var)
             ,@body)
         (when (buffer-live-p ,var)
           (with-current-buffer ,var
             (setq mdview--rendered nil mdview-mode nil)))
         (mdview-test--cleanup ,var)))))

(defun mdview-test--link (text url)
  "Return TEXT propertized as a rendered link to URL."
  (propertize text 'mdview-link url 'face 'mdview-link 'mouse-face 'highlight))

(defun mdview-test--heading (text level id)
  "Return TEXT propertized as a rendered heading of LEVEL with ID."
  (propertize text 'mdview-heading-level level 'mdview-heading-id id))

(defun mdview-test--source-lines ()
  "Return the source lines recorded in the current rendering, in order."
  (mapcar #'car (mdview--block-starts)))

(defun mdview-test--write-file (dir name content)
  "Write CONTENT to file NAME in DIR and return its absolute name."
  (let ((file (expand-file-name name dir)))
    (with-temp-file file (insert content))
    file))

(defun mdview-test--source-of (buffer)
  "Return the Markdown source of BUFFER, wherever it currently lives."
  (with-current-buffer buffer
    (mdview--source-text)))

(defmacro mdview-test-quietly (&rest body)
  "Run BODY without echo-area messages."
  `(let ((inhibit-message t)) ,@body))

;;;; The minor mode: what rendering changes and what leaving restores

(ert-deftest mdview-test-mode-basics ()
  (mdview-test-with-source (source "# Title\n\nSome text\n")
    (with-current-buffer source
      (setq truncate-lines nil)
      (mdview-mode 1)
      (should mdview-mode)
      (should mdview--rendered)
      (should buffer-read-only)
      (should truncate-lines)
      (should-not word-wrap)
      (should (eq buffer-undo-list t))
      (should (null fontification-functions))
      (should (eq font-lock-fontify-region-function #'mdview--ignore-fontification))
      (should (null syntax-propertize-function))
      (should (eq imenu-create-index-function #'mdview--imenu-create-index))
      (should (eq left-margin-width mdview-margin))
      (should (equal (window-margins (selected-window))
                     (cons mdview-margin mdview-margin)))
      (should (null buffer-auto-save-file-name))
      (should (memq #'mdview--on-kill kill-buffer-hook))
      (should (memq #'mdview--before-save before-save-hook))
      (should (memq #'mdview--before-revert before-revert-hook))
      (should (memq #'mdview--window-size-changed window-size-change-functions))
      (should (memq #'mdview--text-scale-changed text-scale-mode-hook))
      (should (string-match-p "Title" (buffer-string)))
      (should-not (string-match-p "#" (buffer-string)))
      (should (buffer-live-p mdview--twin))
      (should (equal (mdview-test--source-of source) "# Title\n\nSome text\n"))
      (mdview-mode -1)
      (should-not mdview--rendered)
      (should-not buffer-read-only)
      (should-not truncate-lines)
      (should (equal (buffer-string) "# Title\n\nSome text\n"))
      (should (memq left-margin-width '(nil 0)))
      (should (equal (window-margins (selected-window)) '(nil)))
      (should-not (memq #'mdview--window-size-changed window-size-change-functions))
      (should-not (memq #'mdview--text-scale-changed text-scale-mode-hook))
      (should-not (local-variable-p 'fontification-functions))
      (should-not (local-variable-p 'syntax-propertize-function))
      ;; The rendering is kept for the next toggle.
      (should (buffer-live-p mdview--twin)))))

(ert-deftest mdview-test-mode-remaps-faces ()
  (let ((remapped 0) (unremapped 0))
    (mdview-test-with-source (source "Text\n")
      (with-current-buffer source
        (cl-letf (((symbol-function 'mdview-faces-remap)
                   (lambda () (cl-incf remapped) nil))
                  ((symbol-function 'mdview-faces-unremap)
                   (lambda () (cl-incf unremapped) nil)))
          (mdview-mode 1)
          (should (= remapped 2))       ; the render buffer and the buffer
          (setq unremapped 0)
          (mdview-mode -1)
          (should (= unremapped 1)))))))

(ert-deftest mdview-test-keymap ()
  (dolist (binding '(("g" . mdview-refresh)
                     ("TAB" . mdview-next-link) ("<backtab>" . mdview-previous-link)
                     ("RET" . mdview-follow-link) ("n" . mdview-next-heading)
                     ("p" . mdview-previous-heading) ("t" . mdview-toc)
                     ("l" . mdview-history-back) ("r" . mdview-history-forward)
                     ("i" . mdview-toggle-images)
                     ("w" . mdview-copy-link) ("SPC" . scroll-up-command)
                     ("DEL" . scroll-down-command) ("S-SPC" . scroll-down-command)
                     ("<" . beginning-of-buffer) (">" . end-of-buffer)
                     ("C-c C-v" . mdview-toggle)))
    (should (eq (lookup-key mdview-mode-map (kbd (car binding))) (cdr binding))))
  (should-not (lookup-key mdview-mode-map (kbd "q")))
  (should-not (lookup-key mdview-mode-map (kbd "e")))
  (should-not (command-remapping 'read-only-mode nil (list mdview-mode-map)))
  (should (eq (lookup-key mdview-mode-map [mouse-1]) #'mdview-mouse-follow-link))
  (should (eq (lookup-key mdview-mode-map [mouse-2]) #'mdview-mouse-follow-link)))

(ert-deftest mdview-test-version ()
  (should (stringp (mdview-version)))
  (should (equal (mdview-version) mdview-version)))

(ert-deftest mdview-test-source-preserved-exactly ()
  ;; Markers, overlays, text properties, the mark, the undo list and the
  ;; modified flag of the source survive a round trip untouched.
  (mdview-test-with-source (source "Alpha\n\nBeta gamma\n\nDelta\n")
    (with-current-buffer source
      (buffer-enable-undo)
      (goto-char (point-max))
      (insert "Epsilon\n")
      (let ((marker (copy-marker 10))
            (overlay (make-overlay 3 8))
            (text (buffer-string))
            (undo nil))
        (put-text-property 1 3 'face 'bold)
        (set-mark 5)
        (setq undo buffer-undo-list)
        (should (buffer-modified-p))
        (mdview-mode 1)
        (should (buffer-modified-p))
        (should-not (eq (marker-buffer marker) source))
        (mdview-mode -1)
        (should (equal (buffer-substring-no-properties (point-min) (point-max)) text))
        (should (eq (marker-buffer marker) source))
        (should (= marker 10))
        (should (eq (overlay-buffer overlay) source))
        (should (equal (list (overlay-start overlay) (overlay-end overlay)) '(3 8)))
        (should (eq (get-text-property 1 'face) 'bold))
        (should (= (mark t) 5))
        (should (equal buffer-undo-list undo))
        (should (buffer-modified-p))
        (set-buffer-modified-p nil)
        (mdview-mode 1)
        (should-not (buffer-modified-p))
        (mdview-mode -1)
        (should-not (buffer-modified-p))))))

(ert-deftest mdview-test-rendering-takes-no-file-lock ()
  ;; Swapping texts is not an edit: an unmodified file buffer stays
  ;; unmodified and no lock file appears.
  (mdview-test-with-file (buffer file "Text\n")
    (with-current-buffer buffer
      (mdview-mode 1)
      (should-not (buffer-modified-p))
      (should-not (file-locked-p file))
      (mdview-mode -1)
      (should-not (buffer-modified-p))
      (should-not (file-locked-p file)))))

(ert-deftest mdview-test-indirect-buffers-refused ()
  (mdview-test-with-source (source "Text\n")
    (let ((indirect (make-indirect-buffer source "test.md<indirect>")))
      (unwind-protect
          (progn
            (with-current-buffer indirect
              (should-error (mdview-mode 1) :type 'user-error)
              (should-not mdview-mode))
            (with-current-buffer source
              (should-error (mdview-mode 1) :type 'user-error)
              (should-not mdview-mode)
              (should (equal (buffer-string) "Text\n"))))
        (kill-buffer indirect)))))

(ert-deftest mdview-test-fontification-cannot-touch-rendering ()
  (mdview-test-with-source (source "Para one\n\nPara two\n")
    (with-current-buffer source
      (setq-local font-lock-defaults '((("Para" . 'error))))
      (font-lock-mode 1)
      (font-lock-ensure)
      (should (eq (get-text-property 1 'face) 'error))
      (mdview-mode 1)
      (let ((pos (save-excursion (goto-char (point-min))
                                 (search-forward "Para") (match-beginning 0))))
        (font-lock-flush)
        (font-lock-ensure)
        (font-lock-fontify-buffer)
        (should-not (eq (get-text-property pos 'face) 'error))
        (font-lock-mode -1)
        (should-not (eq (get-text-property pos 'face) 'error)))
      (mdview-mode -1)
      ;; The source comes back with its own fontification.
      (should (eq (get-text-property 1 'face) 'error)))))

(define-minor-mode mdview-test-noisy-mode
  "A buffer-local minor mode for the suspension test."
  :init-value nil)

(ert-deftest mdview-test-suspended-modes ()
  (mdview-test-with-source (source "Text\n")
    (with-current-buffer source
      (let ((mdview-suspended-modes '(mdview-test-noisy-mode not-a-loaded-mode)))
        (mdview-test-noisy-mode 1)
        (mdview-mode 1)
        (should-not mdview-test-noisy-mode)
        (mdview-mode -1)
        (should mdview-test-noisy-mode)
        ;; A mode that was off stays off.
        (mdview-test-noisy-mode -1)
        (mdview-mode 1)
        (mdview-mode -1)
        (should-not mdview-test-noisy-mode)))))

(ert-deftest mdview-test-local-window-configuration-hook-suspended ()
  (mdview-test-with-source (source "Text\n")
    (with-current-buffer source
      (add-hook 'window-configuration-change-hook #'ignore nil t)
      (mdview-mode 1)
      (should (equal window-configuration-change-hook '(t)))
      (mdview-mode -1)
      (should (memq #'ignore window-configuration-change-hook)))))

(ert-deftest mdview-test-twin-cannot-be-killed-while-holding-source ()
  ;; `kill-some-buffers', `clean-buffer-list' and friends must not destroy
  ;; the source of a rendered buffer.
  (mdview-test-with-source (source "Precious\n")
    (with-current-buffer source
      (mdview-mode 1)
      (let ((twin mdview--twin))
        (should-not (kill-buffer twin))
        (should (buffer-live-p twin))
        (mdview-mode -1)
        (should (equal (buffer-string) "Precious\n"))
        ;; Holding only the kept rendering, it may go.
        (should (kill-buffer twin))
        (mdview-mode 1)
        (should (string-match-p "Precious" (buffer-string)))))))

(ert-deftest mdview-test-save-never-writes-rendering ()
  ;; Should putting the source back fail (`basic-save-buffer' only reports
  ;; errors from `before-save-hook'), the save is refused.
  (mdview-test-with-file (buffer file "Alpha\n")
    (with-current-buffer buffer
      (goto-char (point-max))
      (insert "Beta\n")
      (mdview-mode 1)
      (cl-letf (((symbol-function 'mdview--before-save) #'ignore))
        (should-error (mdview-test-quietly (save-buffer))))
      (should (equal (with-temp-buffer (insert-file-contents file) (buffer-string))
                     "Alpha\n")))))

(ert-deftest mdview-test-settings-changed-while-rendered-are-kept ()
  (mdview-test-with-source (source "Text\n")
    (with-current-buffer source
      (setq buffer-auto-save-file-name "/tmp/old-auto-save")
      (mdview-mode 1)
      (should (null buffer-auto-save-file-name))
      (setq buffer-auto-save-file-name "/tmp/new-auto-save")
      (mdview-mode -1)
      (should (equal buffer-auto-save-file-name "/tmp/new-auto-save"))
      (setq buffer-auto-save-file-name nil))))

(ert-deftest mdview-test-other-windows-keep-their-row ()
  ;; Every window showing the buffer, selected or not, gets its point at
  ;; the block of its line and keeps the screen row of that point.
  (mdview-test-with-source
      (source (mapconcat (lambda (i) (format "Paragraph %d" i))
                         (number-sequence 1 60) "\n\n"))
    (delete-other-windows)
    (let* ((top (selected-window))
           (bottom (split-window)))
      (unwind-protect
          (with-current-buffer source
            (set-window-buffer bottom source)
            (set-window-start bottom (save-excursion (goto-char (point-min))
                                                     (forward-line 20) (point)))
            (set-window-point bottom (save-excursion (goto-char (point-min))
                                                     (forward-line 24) (point)))
            (mdview-mode 1)
            (should (= (mdview--source-line-at (window-point bottom)) 25))
            (should (= (count-screen-lines (window-start bottom)
                                           (window-point bottom) nil bottom)
                       4))
            (mdview-mode -1)
            (should (= (line-number-at-pos (window-point bottom)) 25))
            (should (eq (window-buffer top) source)))
        (delete-other-windows)))))

(ert-deftest mdview-test-clone-of-rendered-buffer ()
  ;; A clone made while rendered carries no mdview state; until it is
  ;; killed the source cannot come back, and nothing is half restored.
  (mdview-test-with-source (source "Some *text*\n")
    (with-current-buffer source
      (mdview-mode 1)
      (let ((clone (clone-indirect-buffer "test.md<clone>" nil)))
        (unwind-protect
            (progn
              (with-current-buffer clone
                (should-not mdview--rendered)
                (should-not mdview-mode)
                (should-not (memq #'mdview--on-kill kill-buffer-hook)))
              (should-error (mdview-mode -1) :type 'user-error)
              (should mdview--rendered)
              (should buffer-read-only)
              (should mdview--saved))
          (kill-buffer clone))
        (mdview-mode -1)
        (should (equal (buffer-string) "Some *text*\n"))))))

(ert-deftest mdview-test-margins-restored-after-rerender ()
  (mdview-test-with-source (source "Text\n")
    (with-current-buffer source
      (let ((mdview-center-content t))
        (mdview-mode 1)
        (let ((mdview-max-width 20))
          (mdview-refresh))
        (mdview-mode -1)
        (should (memq left-margin-width '(nil 0)))
        (should (memq right-margin-width '(nil 0)))))))

(ert-deftest mdview-test-kill-emacs-puts-source-back ()
  (mdview-test-with-source (source "Alpha\n\nBeta\n")
    (with-current-buffer source
      (mdview-mode 1)
      (should (memq #'mdview--on-kill-emacs kill-emacs-hook))
      (mdview--on-kill-emacs)
      (should-not mdview--rendered)
      (should (equal (buffer-string) "Alpha\n\nBeta\n")))))

(ert-deftest mdview-test-save-keeps-narrowing ()
  (mdview-test-with-file (buffer file "Head\n\nAlpha\n\nBeta\n\nTail\n")
    (with-current-buffer buffer
      (goto-char (point-min))
      (forward-line 2)
      (narrow-to-region (point) (save-excursion (forward-line 3) (point)))
      (goto-char (point-max))
      (insert "Gamma\n")
      (mdview-mode 1)
      (should-not (string-match-p "Head" (buffer-string)))
      (mdview-test-quietly (save-buffer))
      (should mdview--rendered)
      (should-not (string-match-p "Head" (buffer-string)))
      (mdview-mode -1)
      (should (buffer-narrowed-p))
      (should (equal (buffer-string) "Alpha\n\nBeta\nGamma\n")))))

;;;; Commands that switch

(ert-deftest mdview-test-mdview-renders-in-place ()
  (mdview-test-with-source (source "Hello world\n\nSecond paragraph\n")
    (should (eq (with-current-buffer source (mdview)) source))
    (should (eq (window-buffer (selected-window)) source))
    (with-current-buffer source
      (should mdview-mode)
      (should (string-match-p "Hello world" (buffer-string)))
      (should (equal mdview--base-dir (expand-file-name default-directory)))
      (should (integerp mdview--last-width))
      ;; Calling `mdview' again renders again instead of nesting.
      (let ((twin mdview--twin))
        (should (eq (mdview) source))
        (should mdview--rendered)
        (should (eq mdview--twin twin))
        (should (equal (mdview-test--source-of source)
                       "Hello world\n\nSecond paragraph\n"))))))

(ert-deftest mdview-test-render-string ()
  (let ((rendered (mdview-render-string "Hello *world*\n\nAgain\n" 40)))
    (should (stringp rendered))
    (should (string-match-p "Hello" rendered))
    (should (string-match-p "Again" rendered))))

(ert-deftest mdview-test-toggle-round-trip ()
  (mdview-test-with-source (source "First\n\nSecond\n\nThird\n")
    (with-current-buffer source
      (goto-char (point-min))
      (forward-line 2)
      (should (= (line-number-at-pos) 3))
      (mdview-toggle)
      (should mdview--rendered)
      (should (equal (mdview-test--source-lines) '(1 3 5)))
      (should (= (mdview--source-line-at (point)) 3))
      (should (= (window-point (selected-window)) (point)))
      ;; Move to another block in the rendering: the source follows.
      (mdview--goto-source-line 5)
      (mdview-toggle)
      (should-not mdview--rendered)
      (should (= (line-number-at-pos) 5)))))

(ert-deftest mdview-test-toggle-twice-is-exact ()
  ;; Without moving, toggling there and back restores point and window
  ;; start exactly (not just the line of the block), in both directions.
  (mdview-test-with-source
      (source (mapconcat (lambda (i) (format "Paragraph number %d here" i))
                         (number-sequence 1 60) "\n\n"))
    (let ((window (selected-window)))
      (with-current-buffer source
        (goto-char (point-min))
        (forward-line 40)
        (forward-char 7)
        (set-window-point window (point))
        (set-window-start window (save-excursion (forward-line -5) (point)))
        (let ((point (point)) (start (window-start window)))
          (mdview-toggle)
          (mdview-toggle)
          (should (= (point) point))
          (should (= (window-start window) start))
          (mdview-toggle)
          (forward-char 3)
          (set-window-point window (point))
          (let ((vpoint (point)) (vstart (window-start window)))
            (mdview-toggle)
            (mdview-toggle)
            (should (= (point) vpoint))
            (should (= (window-start window) vstart))))))))

(ert-deftest mdview-test-toggle-reuses-rendering ()
  ;; Toggling back to an unchanged source swaps the kept rendering in;
  ;; an edit, or a new width, renders again.
  (mdview-test-with-source (source "Alpha\n\nBeta\n")
    (let ((renders 0))
      (cl-letf* ((render (symbol-function 'mdview-render-document))
                 ((symbol-function 'mdview-render-document)
                  (lambda (&rest args) (cl-incf renders) (apply render args))))
        (with-current-buffer source
          (mdview-toggle)
          (should (= renders 1))
          (mdview-toggle)
          (mdview-toggle)
          (should (= renders 1))
          (mdview-toggle)
          (goto-char (point-max))
          (insert "\nGamma\n")
          (mdview-toggle)
          (should (= renders 2))
          (should (string-match-p "Gamma" (buffer-string)))
          (mdview-toggle)
          (let ((mdview-max-width 30))
            (mdview-toggle))
          (should (= renders 3))
          (should (= mdview--last-width 30))
          ;; Back and forth at the width of the kept rendering reuses it;
          ;; a new image scale renders again.
          (let ((mdview-max-width 30))
            (mdview-toggle)
            (mdview-toggle)
            (should (= renders 3))
            (mdview-toggle)
            (cl-letf (((symbol-function 'mdview--image-scale) (lambda () 2.0)))
              (mdview-toggle))
            (should (= renders 4))
            (should (equal mdview--last-scale 2.0))))))))

(ert-deftest mdview-test-view-only-commands ()
  (mdview-test-with-source (source "Text\n")
    (with-current-buffer source
      (mdview-mode 1)
      (mdview-toggle)
      (should-not mdview-mode)
      (dolist (command '(mdview-refresh mdview-toggle-images
                         mdview-history-back mdview-history-forward))
        (let ((err (should-error (funcall command) :type 'user-error)))
          (should (string-match-p "Not a rendered buffer" (cadr err)))))
      (should (equal (buffer-string) "Text\n")))))

(ert-deftest mdview-test-refresh-keeps-source-line ()
  (mdview-test-with-source (source "First\n\nSecond\n\nThird\n")
    (with-current-buffer source
      (mdview-mode 1)
      (mdview--goto-source-line 5)
      (let ((parses 0))
        (cl-letf* ((parse (symbol-function 'mdview-parse-string))
                   ((symbol-function 'mdview-parse-string)
                    (lambda (&rest args) (cl-incf parses) (apply parse args))))
          (mdview-refresh)
          ;; `g' parses again, in case parser options changed.
          (should (= parses 1))))
      (should (equal (mdview-test--source-lines) '(1 3 5)))
      (should (= (mdview--source-line-at (point)) 5))
      (should-not (buffer-modified-p)))))

;;;; Saving, reverting, auto-revert, major modes, killing

(ert-deftest mdview-test-save-while-rendered ()
  ;; The file gets the source; the save hooks see the source (here one
  ;; edits it, like a formatter); afterwards the buffer is rendered again,
  ;; with the edit, and unmodified.
  (mdview-test-with-file (buffer file "Alpha\n\nBeta\n")
    (with-current-buffer buffer
      (let ((seen nil))
        (add-hook 'before-save-hook
                  (lambda ()
                    (setq seen (buffer-string))
                    (goto-char (point-max))
                    (insert "\nFormatted\n"))
                  nil t)
        (goto-char (point-max))
        (insert "\nGamma\n")
        (mdview-mode 1)
        (should (buffer-modified-p))
        (mdview-test-quietly (save-buffer))
        (should (equal seen "Alpha\n\nBeta\n\nGamma\n"))
        (should (equal (with-temp-buffer (insert-file-contents file) (buffer-string))
                       "Alpha\n\nBeta\n\nGamma\n\nFormatted\n"))
        (should mdview--rendered)
        (should mdview-mode)
        (should-not (buffer-modified-p))
        (should (string-match-p "Formatted" (buffer-string)))))))

(ert-deftest mdview-test-save-unchanged-keeps-exact-position ()
  (mdview-test-with-file (buffer file "One\n\nTwo\n\nThree\n")
    (with-current-buffer buffer
      (goto-char (point-max))
      (insert "\nFour\n")
      (mdview-mode 1)
      (mdview--goto-source-line 3)
      (forward-char 2)
      (set-window-point (selected-window) (point))
      (let ((point (point))
            (renders 0))
        (cl-letf* ((render (symbol-function 'mdview-render-document))
                   ((symbol-function 'mdview-render-document)
                    (lambda (&rest args) (cl-incf renders) (apply render args))))
          (mdview-test-quietly (save-buffer)))
        (should (= renders 0))
        (should (= (point) point))
        (should mdview--rendered)))))

(ert-deftest mdview-test-save-in-source-does-not-render ()
  (mdview-test-with-file (buffer file "Alpha\n")
    (with-current-buffer buffer
      (mdview-mode 1)
      (mdview-mode -1)
      (goto-char (point-max))
      (insert "Beta\n")
      (mdview-test-quietly (save-buffer))
      (should-not mdview--rendered)
      (should (equal (buffer-string) "Alpha\nBeta\n")))))

(ert-deftest mdview-test-failed-save-leaves-source ()
  ;; A save that fails after the source was put back leaves the source
  ;; shown, and a later successful save does not switch to the rendering.
  (mdview-test-with-file (buffer file "Alpha\n")
    (with-current-buffer buffer
      (goto-char (point-max))
      (insert "Beta\n")
      (mdview-mode 1)
      (cl-letf (((symbol-function 'basic-save-buffer-2)
                 (lambda (&rest _) (error "Disk full"))))
        (should-error (mdview-test-quietly (save-buffer))))
      (should-not mdview--rendered)
      (should-not mdview-mode)
      (should (equal (buffer-string) "Alpha\nBeta\n"))
      (should (buffer-modified-p))
      (mdview-test-quietly (save-buffer))
      (should-not mdview--rendered)
      (should (equal (with-temp-buffer (insert-file-contents file) (buffer-string))
                     "Alpha\nBeta\n")))))

(defun mdview-test--rewrite (file content)
  "Replace FILE's CONTENT and make its modification time clearly newer."
  (with-temp-file file (insert content))
  (set-file-times file (time-add (current-time) 10)))

(ert-deftest mdview-test-revert-while-rendered ()
  (mdview-test-with-file (buffer file "Before\n")
    (with-current-buffer buffer
      (mdview-mode 1)
      (mdview-test--rewrite file "After\n\nMore\n")
      (revert-buffer t t t)
      (should mdview--rendered)
      (should (string-match-p "After" (buffer-string)))
      (should (equal (mdview-test--source-of buffer) "After\n\nMore\n"))
      (should-not (buffer-modified-p))
      ;; A revert that does not preserve the modes runs `normal-mode',
      ;; which kills local variables; the buffer still ends up rendered.
      (mdview-test--rewrite file "Third version\n")
      (revert-buffer t t nil)
      (should mdview--rendered)
      (should mdview-mode)
      (should (memq #'mdview--before-save before-save-hook))
      (should (string-match-p "Third version" (buffer-string)))
      (should (= (length (mdview-test--hidden-buffers)) 1)))))

(ert-deftest mdview-test-auto-revert-while-rendered ()
  ;; The requirement of issue #3: with auto-revert, a change on disk
  ;; reaches the rendering without any key being pressed.
  (mdview-test-with-file (buffer file "Before\n")
    (with-current-buffer buffer
      (mdview-mode 1)
      (mdview-test--rewrite file "Changed on disk\n")
      (let ((auto-revert-verbose nil))
        (auto-revert-handler))
      (should mdview--rendered)
      (should (string-match-p "Changed on disk" (buffer-string)))
      (should-not (buffer-modified-p)))))

(ert-deftest mdview-test-auto-revert-in-source-then-view ()
  (mdview-test-with-file (buffer file "Before\n")
    (with-current-buffer buffer
      (mdview-mode 1)
      (mdview-mode -1)
      (mdview-test--rewrite file "Changed on disk\n")
      (let ((auto-revert-verbose nil))
        (auto-revert-handler))
      (should (equal (buffer-string) "Changed on disk\n"))
      ;; The kept rendering is stale: toggling renders the new text.
      (mdview-mode 1)
      (should (string-match-p "Changed on disk" (buffer-string))))))

(ert-deftest mdview-test-major-mode-change-restores-source ()
  (mdview-test-with-source (source "Some *text*\n")
    (with-current-buffer source
      (mdview-mode 1)
      (text-mode)
      (should-not mdview--rendered)
      (should-not mdview-mode)
      (should-not buffer-read-only)
      (should (equal (buffer-string) "Some *text*\n"))
      (should (null mdview--twin))
      (should (null (mdview-test--hidden-buffers))))))

(ert-deftest mdview-test-kill-while-rendered ()
  ;; The twin dies with the buffer, and the other kill hooks (such as
  ;; `save-place-mode') see the source, not the rendering.
  (let ((seen nil) source)
    (mdview-test-with-source (buffer "Kill me *softly*\n")
      (setq source buffer)
      (with-current-buffer buffer
        (mdview-mode 1)
        (add-hook 'kill-buffer-hook (lambda () (setq seen (buffer-string))) nil t)
        (should (= (length (mdview-test--hidden-buffers)) 1))))
    (should-not (buffer-live-p source))
    (should (equal seen "Kill me *softly*\n"))
    (should (null (mdview-test--hidden-buffers)))))

;;;; Width, margins and refit

(ert-deftest mdview-test-content-width ()
  (cl-letf (((symbol-function 'window-margins) (lambda (&rest _) '(nil))))
    (let ((mdview-margin 4))
      (cl-letf (((symbol-function 'window-body-width) (lambda (&rest _) 120)))
        (let ((mdview-max-width 100))
          (should (= (mdview--content-width) 100)))
        (let ((mdview-max-width nil))
          (should (= (mdview--content-width) 111))))
      (cl-letf (((symbol-function 'window-body-width) (lambda (&rest _) 40)))
        (let ((mdview-max-width 100))
          (should (= (mdview--content-width) 31))))
      (cl-letf (((symbol-function 'window-body-width) (lambda (&rest _) 12)))
        (let ((mdview-max-width 100))
          (should (= (mdview--content-width) 20))))
      ;; Text enlarged by `text-scale-mode' to 1.5 frame columns per
      ;; column: 80 text columns fit in 120 frame columns.
      (cl-letf (((symbol-function 'window-body-width) (lambda (&rest _) 120))
                ((symbol-function 'mdview--column-scale) (lambda (_window) 1.5)))
        (let ((mdview-max-width 100))
          (should (= (mdview--content-width) 71)))))))

(ert-deftest mdview-test-content-width-adds-back-margins ()
  ;; `window-body-width' excludes the margins already applied to the window.
  (cl-letf (((symbol-function 'window-margins) (lambda (&rest _) '(4 . 4)))
            ((symbol-function 'window-body-width) (lambda (&rest _) 72)))
    (let ((mdview-margin 4) (mdview-max-width 100))
      (should (= (mdview--content-width) 71)))))

(ert-deftest mdview-test-apply-margins-centers ()
  (mdview-test-with-fake-view (view "text\n")
    (cl-letf (((symbol-function 'window-margins) (lambda (&rest _) '(nil)))
              ((symbol-function 'window-body-width) (lambda (&rest _) 200)))
      (let ((mdview-margin 4) (mdview-max-width 100))
        (let ((mdview-center-content nil))
          (mdview--apply-margins 100)
          (should (= left-margin-width 4))
          (should (= right-margin-width 4)))
        (let ((mdview-center-content t))
          (mdview--apply-margins 100)
          (should (= left-margin-width (+ 4 (/ 91 2))))
          (should (= right-margin-width 4)))
        ;; With the text 1.5 times as wide as a frame column the margins
        ;; of 4 text columns take 6 frame columns, and centering counts
        ;; in text columns: 133 fit, 24 are left over, 12 go to the left.
        (cl-letf (((symbol-function 'mdview--column-scale) (lambda (_window) 1.5)))
          (let ((mdview-center-content nil))
            (mdview--apply-margins 100)
            (should (= left-margin-width 6))
            (should (= right-margin-width 6)))
          (let ((mdview-center-content t))
            (mdview--apply-margins 100)
            (should (= left-margin-width 24))
            (should (= right-margin-width 6))))))))

(ert-deftest mdview-test-refit-only-when-width-changes ()
  (mdview-test-with-source (source "Some text\n")
    (with-current-buffer source
      (mdview-mode 1)
      (let ((tick (buffer-chars-modified-tick))
            (width mdview--last-width))
        (should-not (mdview--refit source))
        (should (= tick (buffer-chars-modified-tick)))
        (should (= width mdview--last-width))
        (cl-letf (((symbol-function 'window-margins) (lambda (&rest _) '(nil)))
                  ((symbol-function 'window-body-width) (lambda (&rest _) 40)))
          (let ((mdview-margin 4) (mdview-max-width 100))
            (should (mdview--refit source))
            (should (= mdview--last-width 31))
            (should (/= tick (buffer-chars-modified-tick)))
            (should-not (buffer-modified-p))
            ;; A new image scale alone renders again as well.
            (should-not (mdview--refit source))
            (cl-letf (((symbol-function 'mdview--image-scale) (lambda () 2.0)))
              (should (mdview--refit source))
              (should (equal mdview--last-scale 2.0)))))))))

(ert-deftest mdview-test-text-scale-change-schedules-refit ()
  ;; `text-scale-mode' changes the size of the text, hence the number of
  ;; columns that fit and the scale of the images: a refit follows.
  (mdview-test-with-source (source "Some text\n")
    (with-current-buffer source
      (mdview-mode 1)
      (unwind-protect
          (progn
            (let ((mdview-auto-refit t))
              (text-scale-increase 1)
              (should (timerp mdview--refit-timer))
              (mdview--cancel-refit))
            (let ((mdview-auto-refit nil))
              (text-scale-increase 1)
              (should (null mdview--refit-timer)))
            (mdview-mode -1)
            (let ((mdview-auto-refit t))
              (text-scale-increase 1)
              (should (null mdview--refit-timer))))
        (text-scale-set 0)))))

(ert-deftest mdview-test-window-size-change-schedules-timer ()
  (mdview-test-with-source (source "Some text\n")
    (with-current-buffer source
      (mdview-mode 1)
      (let ((mdview-auto-refit t))
        (mdview--window-size-changed (selected-window))
        (should (timerp mdview--refit-timer))
        (mdview--cancel-refit)
        (should (null mdview--refit-timer)))
      (let ((mdview-auto-refit nil))
        (mdview--window-size-changed (selected-window))
        (should (null mdview--refit-timer)))
      ;; Leaving the rendering cancels a pending refit.
      (let ((mdview-auto-refit t))
        (mdview--window-size-changed (selected-window))
        (mdview-mode -1)
        (should (null mdview--refit-timer))))))

;;;; Links

(ert-deftest mdview-test-next-previous-link ()
  (mdview-test-with-fake-view
      (view (concat "intro " (mdview-test--link "one" "https://one.example")
                    " middle " (mdview-test--link "two" "https://two.example")
                    " end\n"))
    (let ((one (1+ (length "intro ")))
          (two (+ 1 (length "intro one middle "))))
      (goto-char (point-min))
      (mdview-next-link)
      (should (= (point) one))
      (mdview-next-link)
      (should (= (point) two))
      (mdview-next-link)                ; wraps around
      (should (= (point) one))
      (mdview-previous-link)            ; wraps around
      (should (= (point) two))
      (mdview-previous-link)
      (should (= (point) one))
      (goto-char (1+ two))              ; inside the second link
      (mdview-previous-link)
      (should (= (point) one))
      (goto-char (1+ one))              ; inside the first link
      (mdview-next-link)
      (should (= (point) two)))))

(ert-deftest mdview-test-links-at-buffer-edges ()
  (mdview-test-with-fake-view
      (view (concat (mdview-test--link "first" "a") " text "
                    (mdview-test--link "last" "b")))
    (goto-char (1+ (length "first text ")))
    (mdview-next-link)                  ; wraps to the link at point-min
    (should (= (point) (point-min)))
    (mdview-previous-link)              ; wraps to the link ending at point-max
    (should (= (point) (1+ (length "first text "))))))

(ert-deftest mdview-test-no-links ()
  (mdview-test-with-fake-view (view "no links here\n")
    (should-error (mdview-next-link) :type 'user-error)
    (should-error (mdview-previous-link) :type 'user-error)
    (should-error (mdview-follow-link) :type 'user-error)
    (should-error (mdview-copy-link) :type 'user-error)))

(ert-deftest mdview-test-copy-link ()
  (mdview-test-with-fake-view
      (view (concat "see " (mdview-test--link "here" "https://example.com/x") "\n"))
    (mdview-next-link)
    (let ((inhibit-message t))
      (mdview-copy-link))
    (should (equal (current-kill 0) "https://example.com/x"))))

(ert-deftest mdview-test-follow-anchor ()
  (mdview-test-with-fake-view
      (view (concat (mdview-test--link "go" "#my-section") "\n"
                    (mdview-test--link "go2" "#My Section") "\n"
                    (mdview-test--link "bad" "#nowhere") "\n\n\n"
                    (mdview-test--heading "My Section" 2 "my-section") "\n"
                    "body\n"))
    (let ((heading (save-excursion
                     (goto-char (point-min))
                     (prop-match-beginning
                      (text-property-search-forward
                       'mdview-heading-id "my-section" t)))))
      (set-window-buffer (selected-window) view)
      (goto-char (point-min))
      (mdview-follow-link)
      (should (= (point) heading))
      (should (= (window-start (selected-window)) (line-beginning-position)))
      (goto-char (point-min))
      (forward-line 1)
      (mdview-follow-link)              ; slug of the raw anchor
      (should (= (point) heading))
      (goto-char (point-min))
      (forward-line 2)
      (should-error (mdview-follow-link) :type 'user-error))))

(ert-deftest mdview-test-follow-external-links ()
  (mdview-test-with-fake-view
      (view (concat (mdview-test--link "web" "https://example.com/page") "\n"
                    (mdview-test--link "mail" "mailto:someone@example.com") "\n"))
    (let ((opened nil))
      (cl-letf (((symbol-function 'browse-url)
                 (lambda (url &rest _) (push url opened))))
        (goto-char (point-min))
        (mdview-follow-link)
        (forward-line 1)
        (mdview-follow-link))
      (should (equal (nreverse opened)
                     '("https://example.com/page" "mailto:someone@example.com"))))))

(ert-deftest mdview-test-follow-footnotes ()
  (mdview-test-with-fake-view
      (view (concat "text" (propertize "[1]" 'mdview-footnote-ref 1) " more\n\n"
                    (propertize "[1]" 'mdview-footnote-def 1) " the note\n"))
    (goto-char (1+ (length "text")))
    (mdview-follow-link)
    (should (eq (get-text-property (point) 'mdview-footnote-def) 1))
    (mdview-follow-link)
    (should (eq (get-text-property (point) 'mdview-footnote-ref) 1))
    (should (= (point) (1+ (length "text"))))))

(ert-deftest mdview-test-follow-image ()
  (mdview-test-with-fake-view
      (view (concat (propertize "[pic]" 'mdview-link "images/pic.png"
                                'face '(mdview-image-placeholder mdview-quote))
                    "\n"))
    (setq mdview--base-dir "/tmp/base/")
    (let ((opened nil))
      (cl-letf (((symbol-function 'mdview-image-open)
                 (lambda (url &optional base-dir) (setq opened (cons url base-dir)))))
        (goto-char (point-min))
        (mdview-follow-link))
      (should (equal opened '("images/pic.png" . "/tmp/base/"))))))

(ert-deftest mdview-test-mouse-follow-link ()
  (mdview-test-with-fake-view
      (view (concat "plain " (mdview-test--link "web" "https://example.com") "\n"))
    (let ((opened nil)
          (pos (1+ (length "plain "))))
      (cl-letf (((symbol-function 'browse-url)
                 (lambda (url &rest _) (setq opened url)))
                ((symbol-function 'mouse-set-point)
                 (lambda (&rest _) (goto-char pos))))
        (mdview-mouse-follow-link nil))
      (should (equal opened "https://example.com")))))

(ert-deftest mdview-test-follow-local-file-links ()
  (let* ((dir (make-temp-file "mdview-test" t))
         (other (mdview-test--write-file dir "other.txt" "plain\n"))
         (linked (mdview-test--write-file dir "linked.md" "Linked document\n"))
         (buffer nil))
    (unwind-protect
        (mdview-test-with-fake-view
            (view (concat (mdview-test--link "txt" "other.txt") "\n"
                          (mdview-test--link "missing" "missing.txt") "\n"
                          (mdview-test--link "md" "linked.md") "\n"))
          (setq mdview--base-dir (file-name-as-directory dir))
          (let ((visited nil))
            (cl-letf (((symbol-function 'find-file-other-window)
                       (lambda (file &rest _) (setq visited file))))
              (goto-char (point-min))
              (mdview-follow-link)
              (should (equal visited other))
              (forward-line 1)
              (should-error (mdview-follow-link) :type 'user-error)
              (forward-line 1)
              (mdview-follow-link)))
          (setq buffer (window-buffer (selected-window)))
          (should (equal (buffer-file-name buffer) linked))
          (with-current-buffer buffer
            (should mdview--rendered)
            (should (string-match-p "Linked document" (buffer-string)))
            (should (equal mdview--base-dir (file-name-as-directory dir)))))
      (mdview-test--cleanup buffer)
      (delete-directory dir t))))

;;;; History

(ert-deftest mdview-test-history-back-and-forward ()
  (let* ((dir (make-temp-file "mdview-test" t))
         (linked (mdview-test--write-file dir "linked.md" "Linked document\n"))
         (buffer nil))
    (unwind-protect
        (mdview-test-with-fake-view
            (view (concat "Original document\n" (mdview-test--link "next" linked)))
          (goto-char (1- (point-max)))
          (let ((origin (point)))
            (mdview-follow-link)
            (setq buffer (window-buffer (selected-window)))
            (with-current-buffer buffer
              (should mdview--rendered)
              (should (string-match-p "Linked document" (buffer-string)))
              (let ((history (window-parameter nil 'mdview-history)))
                (should (= (car history) 1))
                (should (equal (mapcar #'car (cdr history)) (list view buffer))))
              (should-error (mdview-history-forward) :type 'user-error)
              (mdview-history-back))
            (should (eq (window-buffer (selected-window)) view))
            (should (= (window-point) origin))
            (set-buffer view)
            (should-error (mdview-history-back) :type 'user-error)
            (mdview-history-forward)
            (should (eq (window-buffer (selected-window)) buffer))
            ;; A killed document is visited again from its file.
            (with-current-buffer buffer (mdview-history-back))
            (mdview-test--cleanup buffer)
            (with-current-buffer view (mdview-history-forward))
            (setq buffer (window-buffer (selected-window)))
            (should (equal (buffer-file-name buffer) linked))
            (should (buffer-local-value 'mdview--rendered buffer))))
      (mdview-test--cleanup buffer)
      (delete-directory dir t))))

(ert-deftest mdview-test-history-push-drops-forward-entries ()
  (let ((a (generate-new-buffer "a.md"))
        (b (generate-new-buffer "b.md"))
        (c (generate-new-buffer "c.md")))
    (unwind-protect
        (progn
          (set-window-parameter nil 'mdview-history nil)
          (set-window-buffer nil a)
          (with-current-buffer a
            (let ((history (mdview--history)))
              (set-window-buffer nil b)
              (with-current-buffer b (mdview--history-push history))))
          (with-current-buffer b
            (let ((history (mdview--history)))
              (set-window-buffer nil c)
              (with-current-buffer c (mdview--history-push history))))
          (should (equal (mapcar #'car (cdr (window-parameter nil 'mdview-history)))
                         (list a b c)))
          ;; Back to A, then a new document: B and C are dropped.
          (set-window-parameter nil 'mdview-history
                                (cons 0 (cdr (window-parameter nil 'mdview-history))))
          (set-window-buffer nil a)
          (with-current-buffer a
            (let ((history (mdview--history)))
              (set-window-buffer nil c)
              (with-current-buffer c (mdview--history-push history))))
          (should (equal (window-parameter nil 'mdview-history)
                         (list 1 (list a nil 1) (list c nil 1))))
          ;; Showing another buffer by other means starts a new history.
          (set-window-buffer nil b)
          (with-current-buffer b
            (should (equal (mdview--history) (list 0 (list b nil 1))))))
      (set-window-parameter nil 'mdview-history nil)
      (mdview-test--cleanup a b c))))

;;;; Headings, imenu and the table of contents

(ert-deftest mdview-test-heading-navigation ()
  (mdview-test-with-fake-view
      (view (concat "intro\n"
                    (mdview-test--heading "First" 1 "first") "\n\n"
                    "   " (mdview-test--heading "Second" 2 "second") "\n\n"
                    (mdview-test--heading "Second" 2 "second-1") "\n"))
    (let ((positions (mapcar #'car (mdview--headings))))
      (should (= (length positions) 3))
      (goto-char (point-min))
      (mdview-next-heading)
      (should (= (point) (nth 0 positions)))
      (mdview-next-heading)
      (should (= (point) (nth 1 positions)))
      (mdview-next-heading)
      (should (= (point) (nth 2 positions)))
      (should-error (mdview-next-heading) :type 'user-error)
      (mdview-previous-heading)
      (should (= (point) (nth 1 positions)))
      (mdview-previous-heading)
      (should (= (point) (nth 0 positions)))
      (should-error (mdview-previous-heading) :type 'user-error))))

(ert-deftest mdview-test-imenu-index ()
  (mdview-test-with-fake-view
      (view (concat (mdview-test--heading "First" 1 "first") "\n\n"
                    (mdview-test--heading "Second" 2 "second") "\n\n"
                    (mdview-test--heading "Second" 2 "second-1") "\n"))
    (let ((index (funcall imenu-create-index-function)))
      (should (equal (mapcar #'car index) '("First" "Second" "Second <2>")))
      (should (= (cdr (nth 0 index)) 1))
      (should (eq (get-text-property (cdr (nth 1 index)) 'mdview-heading-level) 2)))))

(ert-deftest mdview-test-imenu-merges-wrapped-headings ()
  (mdview-test-with-fake-view
      (view (concat (mdview-test--heading "A very long" 1 "a-very-long-title") "   \n"
                    "  " (mdview-test--heading "title" 1 "a-very-long-title") "\n"))
    (let ((headings (mdview--headings)))
      (should (= (length headings) 1))
      (should (equal (nth 3 (car headings)) "A very long title")))))

(ert-deftest mdview-test-toc ()
  (mdview-test-with-fake-view
      (view (concat (mdview-test--heading "First one" 1 "first-one") "\n\n"
                    "body\n\n"
                    (mdview-test--heading "Second one" 2 "second-one") "\n"))
    (let ((second (cdr (assoc "Second one" (mdview--imenu-create-index))))
          (prompts nil)
          (candidates nil)
          (defaults nil))
      (set-window-buffer (selected-window) view)
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (prompt collection &rest args)
                   (push prompt prompts)
                   (push (mapcar #'car collection) candidates)
                   (push (nth 4 args) defaults)
                   "Second one")))
        (goto-char (point-min))
        (mdview-toc)
        (should (= (point) second))
        ;; Heading names are offered verbatim (no imenu dots for spaces),
        ;; the prompt says what is asked for, and the heading at point is
        ;; the default.
        (should (equal (car candidates) '("First one" "Second one")))
        (should (string-prefix-p "Heading" (car prompts)))
        (should (equal (car defaults) "First one"))
        (should (string-match-p "First one" (car prompts)))
        (mdview-toc)
        (should (equal (car defaults) "Second one"))
        ;; With the popup menu requested, `imenu' is used; when it fails,
        ;; the completion fallback is.
        (goto-char (point-min))
        (cl-letf (((symbol-function 'imenu)
                   (lambda (&rest _) (error "No imenu")))
                  ((symbol-function 'display-popup-menus-p) (lambda (&rest _) t)))
          (let ((imenu-use-popup-menu 'always))
            (mdview-toc)))
        (should (= (point) second))))))

(ert-deftest mdview-test-toc-without-headings ()
  (mdview-test-with-fake-view (view "nothing\n")
    (should-error (mdview-toc) :type 'user-error)))

;;;; Images

;;;; Images

(ert-deftest mdview-test-toggle-images ()
  (mdview-test-with-source (source "Some text\n")
    (with-current-buffer source
      (mdview-mode 1)
      (let ((before mdview--images-enabled)
            (renders 0))
        (cl-letf* ((render (symbol-function 'mdview-render-document))
                   ((symbol-function 'mdview-render-document)
                    (lambda (&rest args) (cl-incf renders) (apply render args))))
          (mdview-test-quietly (mdview-toggle-images)))
        (should (eq mdview--images-enabled (not before)))
        (should (= renders 1))
        (should (string-match-p "Some text" (buffer-string)))
        (mdview-test-quietly (mdview-toggle-images))
        (should (eq mdview--images-enabled before))))))

;;;; Files

(ert-deftest mdview-test-file-renders-minimal ()
  (let* ((file (expand-file-name "fixtures/minimal.md" mdview-test-dir))
         (existing (find-buffer-visiting file))
         (buffer nil))
    (unwind-protect
        (progn
          (setq buffer (mdview-file file))
          (should (eq buffer (find-buffer-visiting file)))
          (should (eq (window-buffer (selected-window)) buffer))
          (with-current-buffer buffer
            (should mdview-mode)
            (should (string-match-p "Title" (buffer-string)))
            (should (equal mdview--base-dir (file-name-directory file))))
          ;; Visiting again reuses the buffer and keeps it rendered.
          (should (eq (mdview-file file) buffer)))
      (unless existing
        (mdview-test--cleanup buffer)))))

(ert-deftest mdview-test-file-missing ()
  (should-error (mdview-file "/nonexistent/dir/missing.md") :type 'user-error))

(ert-deftest mdview-test-file-rejects-directory ()
  (let ((dir (make-temp-file "mdview-test" t))
        (window-buffer (window-buffer (selected-window))))
    (unwind-protect
        (progn
          (should-error (mdview-file dir) :type 'user-error)
          (should-error (mdview-file (file-name-as-directory dir)) :type 'user-error)
          (should (eq (window-buffer (selected-window)) window-buffer)))
      (delete-directory dir t))))

;;;; Integration

(ert-deftest mdview-test-install-keybinding ()
  ;; Self-contained: `features', `after-load-alist' and `md-mode-map' are
  ;; dynamically bound, so a real md-mode loaded in an interactive session
  ;; is neither unregistered nor rebound, and nothing leaks afterwards.
  (let ((map (make-sparse-keymap))
        (was-bound (boundp 'md-mode-map))
        (old-map (and (boundp 'md-mode-map) md-mode-map))
        (was-provided (featurep 'md-mode)))
    (cl-letf (((symbol-value 'features) (remq 'md-mode features))
              ((symbol-value 'after-load-alist) (copy-alist after-load-alist)))
      (let ((md-mode-map map))
        (should-not (featurep 'md-mode))
        (mdview-install-keybinding "C-c C-v")
        (should-not (eq (lookup-key map (kbd "C-c C-v")) #'mdview-toggle))
        (provide 'md-mode)
        (should (eq (lookup-key map (kbd "C-c C-v")) #'mdview-toggle))
        ;; Vectors work too, and a loaded feature is bound immediately.
        (mdview-install-keybinding [f9])
        (should (eq (lookup-key map [f9]) #'mdview-toggle))))
    (should (eq (featurep 'md-mode) was-provided))
    (should (eq (boundp 'md-mode-map) was-bound))
    (when was-bound
      (should (eq md-mode-map old-map))
      (should-not (eq (lookup-key old-map [f9]) #'mdview-toggle)))))

(define-derived-mode mdview-test-markdown-mode text-mode "MDtest"
  "A stand-in for a Markdown major mode.")

(ert-deftest mdview-test-initial-view ()
  (let* ((dir (make-temp-file "mdview-test" t))
         (file (mdview-test--write-file dir "doc.mdtest" "# Heading\n\nText\n"))
         (other (mdview-test--write-file dir "notes.txt" "# Not markdown\n"))
         (auto-mode-alist (cons '("\\.mdtest\\'" . mdview-test-markdown-mode)
                                auto-mode-alist))
         (mdview-markdown-modes '(mdview-test-markdown-mode))
         (buffers nil))
    (unwind-protect
        (progn
          (should (memq #'mdview--find-file-hook find-file-hook))
          (let ((mdview-initial-view 'edit))
            (push (find-file-noselect file) buffers)
            (with-current-buffer (car buffers)
              (should-not mdview-mode)
              (should (equal (buffer-string) "# Heading\n\nText\n")))
            (mdview-test--cleanup (pop buffers)))
          (let ((mdview-initial-view 'view))
            (push (find-file-noselect file) buffers)
            (with-current-buffer (car buffers)
              (should (eq major-mode 'mdview-test-markdown-mode))
              (should mdview-mode)
              (should (string-match-p "Heading" (buffer-string)))
              (should-not (string-match-p "#" (buffer-string)))
              ;; A revert that runs `find-file-hook' renders only once.
              (let ((renders 0))
                (cl-letf* ((render (symbol-function 'mdview-render-document))
                           ((symbol-function 'mdview-render-document)
                            (lambda (&rest args) (cl-incf renders) (apply render args))))
                  (mdview-test--rewrite file "# Heading\n\nNew text\n")
                  (revert-buffer t t nil))
                (should (= renders 1))
                (should mdview-mode)))
            ;; Files in other major modes open as usual.
            (push (find-file-noselect other) buffers)
            (with-current-buffer (car buffers)
              (should-not mdview-mode))))
      (apply #'mdview-test--cleanup buffers)
      (delete-directory dir t))))

(ert-deftest mdview-test-autoloads-install-initial-view ()
  ;; The autoloads file defines the find-file hook function and adds it,
  ;; so `mdview-initial-view' works before mdview is loaded.
  (let* ((dir (make-temp-file "mdview-test" t))
         (output (expand-file-name "mdview-autoloads.el" dir)))
    (unwind-protect
        (progn
          (copy-file (expand-file-name "../mdview.el" mdview-test-dir)
                     (expand-file-name "mdview.el" dir))
          (require 'loaddefs-gen)
          (let ((inhibit-message t))
            (loaddefs-generate dir output))
          (let ((text (with-temp-buffer (insert-file-contents output) (buffer-string))))
            (should (string-match-p "(defun mdview--find-file-hook ()" text))
            (should (string-match-p "(add-hook 'find-file-hook #'mdview--find-file-hook 90)"
                                    text))
            (should (string-match-p "(defvar mdview-initial-view 'edit" text))
            (should (string-match-p "\"mdview\" '(mdview--initial-view)\\|mdview--initial-view \"mdview\""
                                    text))))
      (delete-directory dir t))))

;;;; Robustness, performance and UX of the rendering

(ert-deftest mdview-test-undo-disabled-in-rendering ()
  ;; A read-only rendering gains nothing from undo; each render would
  ;; otherwise retain the whole previous rendering on `buffer-undo-list'.
  (mdview-test-with-source (source "One\n\nTwo\n")
    (with-current-buffer source
      (buffer-enable-undo)
      (insert "Zero\n")
      (let ((undo buffer-undo-list))
        (mdview-mode 1)
        (should (eq buffer-undo-list t))
        (mdview-refresh)
        (should (eq buffer-undo-list t))
        (mdview-mode -1)
        (should (equal buffer-undo-list undo))))))

(ert-deftest mdview-test-render-reuses-parsed-document ()
  ;; Refitting and toggling images render an unchanged source without
  ;; parsing it again; an edit invalidates the cache.
  (mdview-test-with-source (source "Alpha\n\nBeta\n")
    (let ((parses 0))
      (cl-letf* ((parse (symbol-function 'mdview-parse-string))
                 ((symbol-function 'mdview-parse-string)
                  (lambda (&rest args) (cl-incf parses) (apply parse args))))
        (with-current-buffer source
          (mdview-mode 1)
          (should (= parses 1))
          (mdview-test-quietly (mdview-toggle-images))
          (mdview--render-into source)
          (should (= parses 1))
          (mdview-mode -1)
          (mdview-test-quietly (mdview-toggle))
          (should (= parses 1))
          (mdview-mode -1)
          (goto-char (point-max))
          (insert "\nGamma\n")
          (mdview-mode 1)
          (should (= parses 2))
          (should (string-match-p "Gamma" (buffer-string))))))))

(ert-deftest mdview-test-render-raises-gc-threshold ()
  (mdview-test-with-source (source "Text\n")
    (let ((seen nil))
      (cl-letf (((symbol-function 'mdview-render-document)
                 (lambda (&rest _) (setq seen gc-cons-threshold) (insert "x\n"))))
        (with-current-buffer source (mdview-mode 1)))
      (should (>= seen mdview--render-gc-threshold))
      (should (< gc-cons-threshold mdview--render-gc-threshold)))))

(ert-deftest mdview-test-refresh-keeps-window-start ()
  ;; Re-rendering must not collapse the window start to the beginning
  ;; and let redisplay recenter around point.
  (mdview-test-with-source
      (source (mapconcat (lambda (i) (format "Paragraph %d\n" i))
                         (number-sequence 1 40) "\n"))
    (let ((window (selected-window)))
      (with-current-buffer source
        (mdview-mode 1)
        (let* ((blocks (mdview--block-starts))
               (top (cdr (nth 20 blocks)))
               (target (cdr (nth 23 blocks))))
          (set-window-start window top)
          (goto-char target)
          (set-window-point window target)
          (mdview-refresh)
          (should (= (window-start window) top))
          (should (= (point) target)))))))

(ert-deftest mdview-test-failed-render-leaves-source ()
  (mdview-test-with-source (source "Text\n")
    (with-current-buffer source
      (let ((hidden (mdview-test--hidden-buffers)))
        (cl-letf (((symbol-function 'mdview-render-document)
                   (lambda (&rest _) (error "Renderer broke"))))
          (should-error (mdview-mode 1)))
        (should-not mdview-mode)
        (should-not mdview--rendered)
        (should-not buffer-read-only)
        (should (equal (buffer-string) "Text\n"))
        (should (equal (mdview-test--hidden-buffers) hidden))
        (should (null (seq-filter (lambda (b) (equal (buffer-name b) " *mdview-render*"))
                                  (buffer-list))))
        ;; A rendered buffer survives a failed refresh.
        (mdview-mode 1)
        (let ((text (buffer-string)))
          (cl-letf (((symbol-function 'mdview-render-document)
                     (lambda (&rest _) (error "Renderer broke"))))
            (should-error (mdview-refresh)))
          (should mdview--rendered)
          (should (equal (buffer-string) text)))))))

(ert-deftest mdview-test-refit-reports-errors-once ()
  (mdview-test-with-source (source "Text\n")
    (with-current-buffer source
      (mdview-mode 1)
      (let ((messages nil))
        (cl-letf (((symbol-function 'window-margins) (lambda (&rest _) '(nil)))
                  ((symbol-function 'window-body-width) (lambda (&rest _) 40))
                  ((symbol-function 'mdview-render-document)
                   (lambda (&rest _) (error "Renderer broke")))
                  ((symbol-function 'message)
                   (lambda (format &rest args)
                     (push (apply #'format format args) messages))))
          (let ((mdview-margin 4) (mdview-max-width 100))
            ;; The idle timer's function must not signal.
            (should-not (mdview--refit source))
            (should (= (length messages) 1))
            (should (string-match-p "Renderer broke" (car messages)))
            ;; The same width is not retried on the next resize.
            (should-not (mdview--refit source))
            (should (= (length messages) 1))))
        (should mdview--rendered)))))

(ert-deftest mdview-test-refit-interrupted-reschedules ()
  (mdview-test-with-source (source "Text\n")
    (with-current-buffer source
      (mdview-mode 1)
      (let ((width mdview--last-width)
            (text (buffer-string))
            (rendered nil))
        (cl-letf (((symbol-function 'window-margins) (lambda (&rest _) '(nil)))
                  ((symbol-function 'window-body-width) (lambda (&rest _) 40))
                  ((symbol-function 'mdview-render-document)
                   (lambda (&rest _)
                     (setq rendered t)
                     ;; Simulate input arriving while rendering.
                     (throw throw-on-input t))))
          (let ((mdview-margin 4) (mdview-max-width 100))
            (should-not (mdview--refit source))
            (should rendered)
            (should (timerp mdview--refit-timer))
            (should (= width mdview--last-width))
            (should (equal (buffer-string) text))
            (should (null (seq-filter (lambda (b) (equal (buffer-name b) " *mdview-render*"))
                                      (buffer-list))))
            (mdview--cancel-refit)))))))

(ert-deftest mdview-test-images-updated-schedules-rerender ()
  ;; Remote images arriving after the rendering render the buffer again
  ;; once Emacs is idle, so that paragraphs re-flow around inline images;
  ;; several arrivals share one rendering and other buffers are ignored.
  (mdview-test-with-source (source "Text ![b](https://example.invalid/b.png)\n")
    (with-current-buffer source
      (mdview-mode 1))
    (let ((renders 0))
      (should (memq #'mdview--on-images-updated mdview-image-update-functions))
      (cl-letf (((symbol-function 'mdview--render-into)
                 (lambda (&rest _) (cl-incf renders))))
        (with-current-buffer source
          (run-hook-with-args 'mdview-image-update-functions source)
          (let ((first mdview--image-update-timer))
            (should (timerp first))
            (run-hook-with-args 'mdview-image-update-functions source)
            (should (timerp mdview--image-update-timer))
            (should-not (memq first timer-idle-list)))
          (should (= renders 0))
          (mdview--rerender-for-images source)
          (should (= renders 1))
          (should (null mdview--image-update-timer))
          ;; With images switched off there is nothing to re-flow.
          (setq mdview--images-enabled nil)
          (mdview--on-images-updated source)
          (mdview--rerender-for-images source)
          (should (= renders 1)))
        (with-temp-buffer
          (run-hook-with-args 'mdview-image-update-functions (current-buffer))
          (should (null mdview--image-update-timer)))
        (should (= renders 1))))))

(ert-deftest mdview-test-images-updated-in-kept-rendering ()
  ;; Images that arrive while the buffer shows its source land in the kept
  ;; rendering; the next toggle renders again so the text re-flows.
  (mdview-test-with-source (source "Text\n")
    (with-current-buffer source
      (mdview-mode 1)
      (mdview-mode -1)
      (should mdview--twin-key)
      (mdview--on-images-updated mdview--twin)
      (should (null mdview--twin-key)))))

(ert-deftest mdview-test-images-updated-interrupted-reschedules ()
  (mdview-test-with-source (source "Text\n")
    (with-current-buffer source
      (mdview-mode 1)
      (let ((rendered nil))
        (cl-letf (((symbol-function 'mdview--render-into)
                   (lambda (&rest _)
                     (setq rendered t)
                     (throw throw-on-input t))))
          (mdview--rerender-for-images source)
          (should rendered)
          (should (timerp mdview--image-update-timer))
          (let ((timer mdview--image-update-timer))
            (mdview-mode -1)
            (should-not (memq timer timer-idle-list))))))))

(ert-deftest mdview-test-deeply-nested-emphasis-renders ()
  ;; Thousands of nested emphasis delimiters once exhausted the Lisp
  ;; stack in the parser's post-passes; `mdview' must simply show text.
  (mdview-test-with-source (source (concat (make-string 5900 ?*) "deep"
                                           (make-string 5900 ?*) "\n"))
    (with-current-buffer source
      (mdview)
      (should (string-match-p "deep" (buffer-string))))))

(ert-deftest mdview-test-copy-link-resolves-local-files ()
  (mdview-test-with-fake-view
      (view (concat (mdview-test--link "doc" "sub/b.md#details") "\n"
                    (mdview-test--link "web" "https://example.com/x") "\n"
                    (mdview-test--link "anchor" "#top") "\n"))
    (setq mdview--base-dir "/tmp/base/")
    (let ((inhibit-message t))
      (goto-char (point-min))
      (mdview-copy-link)
      (should (equal (current-kill 0) "/tmp/base/sub/b.md#details"))
      (mdview-copy-link t)
      (should (equal (current-kill 0) "sub/b.md#details"))
      (forward-line 1)
      (mdview-copy-link)
      (should (equal (current-kill 0) "https://example.com/x"))
      (forward-line 1)
      (mdview-copy-link)
      (should (equal (current-kill 0) "#top")))))

(ert-deftest mdview-test-follow-linked-image ()
  ;; An image wrapped in a link carries the link's URL; RET must follow
  ;; the link (anchor, Markdown file, ...) rather than open "the image".
  (let* ((dir (make-temp-file "mdview-test" t))
         (linked (mdview-test--write-file dir "b.md" "Document B\n"))
         (buffer nil))
    (unwind-protect
        (mdview-test-with-fake-view
            (view (concat (propertize "[badge]" 'mdview-link "b.md"
                                      'face 'mdview-image-placeholder)
                          "\n"
                          (propertize "[badge]" 'mdview-link "#target"
                                      'face 'mdview-image-placeholder)
                          "\n"
                          (propertize "[badge]" 'mdview-link "badge.png"
                                      'face 'mdview-image-placeholder)
                          "\n"
                          (propertize "[badge]" 'mdview-link "https://example.com/"
                                      'mdview-image-url "badge.png"
                                      'face 'mdview-image-placeholder)
                          "\n\n"
                          (mdview-test--heading "Target" 2 "target") "\n"))
          (setq mdview--base-dir (file-name-as-directory dir))
          (let ((opened nil) (browsed nil)
                (heading (save-excursion
                           (goto-char (point-min))
                           (prop-match-beginning
                            (text-property-search-forward
                             'mdview-heading-id "target" t)))))
            (cl-letf (((symbol-function 'mdview-image-open)
                       (lambda (url &optional _) (push url opened)))
                      ((symbol-function 'browse-url)
                       (lambda (url &rest _) (push url browsed)))
                      ((symbol-function 'find-file-other-window)
                       (lambda (&rest _) (error "Must not visit other files"))))
              (goto-char (point-min))
              (forward-line 1)
              (mdview-follow-link)             ; anchor
              (should (= (point) heading))
              (goto-char (point-min))
              (forward-line 2)
              (mdview-follow-link)             ; plain image
              (should (equal opened '("badge.png")))
              (goto-char (point-min))
              (forward-line 3)
              (mdview-follow-link)             ; linked image, own URL recorded
              (should (equal browsed '("https://example.com/")))
              (should (equal opened '("badge.png")))
              (goto-char (point-min))
              (mdview-follow-link))            ; Markdown file: shown rendered
            (setq buffer (window-buffer (selected-window)))
            (should (equal (buffer-file-name buffer) linked))
            (should (string-match-p "Document B"
                                    (with-current-buffer buffer (buffer-string))))))
      (mdview-test--cleanup buffer)
      (delete-directory dir t))))

(ert-deftest mdview-test-image-link-p ()
  (mdview-test-with-fake-view
      (view (concat (propertize "a" 'mdview-link "pic.png")
                    (propertize "b" 'mdview-link "https://x.example/" 'mdview-image-url "pic.png")
                    (propertize "c" 'mdview-link "pic.png" 'display '(image :type png :file "/base/pic.png"))
                    (propertize "d" 'mdview-link "other.md" 'display '(image :type png :file "/base/pic.png"))
                    "\n"))
    (setq mdview--base-dir "/base/")
    (should (mdview--image-link-p 1 "pic.png"))
    (should-not (mdview--image-link-p 2 "https://x.example/"))
    (should (mdview--image-link-p 3 "pic.png"))
    (should-not (mdview--image-link-p 4 "other.md"))
    (should-not (mdview--image-link-p 1 "#anchor"))
    (should-not (mdview--image-link-p 1 "notes.md"))
    (should (mdview--image-link-p 1 "https://example.com/pic.png"))))

(provide 'mdview-test)
;;; mdview-test.el ends here
