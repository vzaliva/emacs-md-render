;;; mdview-test.el --- Tests for the mdview commands  -*- lexical-binding: t; -*-

;; This file is part of mdview, distributed under the MIT license; see
;; LICENSE in the repository root.

;;; Commentary:

;; ERT tests for mdview.el (docs/DESIGN.md section 10 and 13): the mode,
;; the commands, link navigation and following, history, refit, source
;; synchronisation and the integration hooks.  The tests exercise the
;; plumbing only and never depend on the exact rendering; links,
;; headings and footnote markers are inserted as text properties into
;; view buffers directly.  Everything runs headless.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'mdview)

(defconst mdview-test-dir
  (file-name-directory (or load-file-name buffer-file-name default-directory))
  "Directory of this test file.")

(defvar md-mode-map)                    ; stands in for md-mode's keymap below

(defun mdview-test--cleanup (&rest buffers)
  "Kill every mdview view and the BUFFERS, discarding modifications."
  (let ((kill-buffer-query-functions nil))
    (dolist (buffer (buffer-list))
      (when (mdview--view-p buffer)
        (kill-buffer buffer)))
    (dolist (buffer buffers)
      (when (buffer-live-p buffer)
        (with-current-buffer buffer (set-buffer-modified-p nil))
        (kill-buffer buffer)))))

(defmacro mdview-test-with-source (binding &rest body)
  "Bind the variable of BINDING to a buffer holding its text; run BODY.
BINDING is (VAR TEXT).  Views and the buffer are killed afterwards."
  (declare (indent 1))
  (let ((var (car binding)))
    `(let ((,var (generate-new-buffer "test.md")))
       (unwind-protect
           (progn
             (with-current-buffer ,var
               (insert ,(cadr binding))
               (goto-char (point-min)))
             ,@body)
         (mdview-test--cleanup ,var)))))

(defmacro mdview-test-with-fake-view (binding &rest body)
  "Bind the variable of BINDING to a view buffer holding its text; run BODY.
BINDING is (VAR TEXT); TEXT may carry text properties.  BODY runs with
the view current; the view is killed afterwards."
  (declare (indent 1))
  (let ((var (car binding)))
    `(let ((,var (generate-new-buffer "*mdview: fake*")))
       (unwind-protect
           (with-current-buffer ,var
             (mdview-mode)
             (let ((inhibit-read-only t))
               (insert ,(cadr binding)))
             (set-buffer-modified-p nil)
             (goto-char (point-min))
             ,@body)
         (mdview-test--cleanup ,var)))))

(defun mdview-test--link (text url)
  "Return TEXT propertized as a rendered link to URL."
  (propertize text 'mdview-link url 'face 'mdview-link 'mouse-face 'highlight))

(defun mdview-test--heading (text level id)
  "Return TEXT propertized as a rendered heading of LEVEL with ID."
  (propertize text 'mdview-heading-level level 'mdview-heading-id id))

(defun mdview-test--source-lines ()
  "Return the source lines recorded in the current view, in order."
  (mapcar #'car (mdview--block-starts)))

(defun mdview-test--write-file (dir name content)
  "Write CONTENT to file NAME in DIR and return its absolute name."
  (let ((file (expand-file-name name dir)))
    (with-temp-file file (insert content))
    file))

;;;; Mode

(ert-deftest mdview-test-mode-basics ()
  (with-temp-buffer
    (mdview-mode)
    (should (derived-mode-p 'special-mode))
    (should truncate-lines)
    (should buffer-read-only)
    (should (eq imenu-create-index-function #'mdview--imenu-create-index))
    (should (eq left-margin-width mdview-margin))
    (should (memq #'mdview--on-kill kill-buffer-hook))
    (should (memq #'mdview--window-size-changed window-size-change-functions))))

(ert-deftest mdview-test-mode-remaps-faces ()
  (let ((called nil))
    (cl-letf (((symbol-function 'mdview-faces-remap)
               (lambda () (setq called t) nil)))
      (with-temp-buffer (mdview-mode)))
    (should called)))

(ert-deftest mdview-test-keymap ()
  (dolist (binding '(("q" . mdview-quit) ("g" . mdview-refresh)
                     ("TAB" . mdview-next-link) ("<backtab>" . mdview-previous-link)
                     ("RET" . mdview-follow-link) ("n" . mdview-next-heading)
                     ("p" . mdview-previous-heading) ("t" . mdview-toc)
                     ("l" . mdview-history-back) ("r" . mdview-history-forward)
                     ("i" . mdview-toggle-images) ("e" . mdview-visit-source)
                     ("w" . mdview-copy-link) ("SPC" . scroll-up-command)
                     ("DEL" . scroll-down-command) ("S-SPC" . scroll-down-command)
                     ("<" . beginning-of-buffer) (">" . end-of-buffer)
                     ("C-c C-v" . mdview-toggle)))
    (should (eq (lookup-key mdview-mode-map (kbd (car binding))) (cdr binding))))
  (should (eq (lookup-key mdview-mode-map [mouse-1]) #'mdview-mouse-follow-link))
  (should (eq (lookup-key mdview-mode-map [mouse-2]) #'mdview-mouse-follow-link)))

(ert-deftest mdview-test-version ()
  (should (stringp (mdview-version)))
  (should (equal (mdview-version) mdview-version)))

;;;; The mdview command and the view buffer

(ert-deftest mdview-test-mdview-creates-view ()
  (mdview-test-with-source (source "Hello world\n\nSecond paragraph\n")
    (let ((view (with-current-buffer source (mdview))))
      (should (eq view (get-buffer "*mdview: test.md*")))
      (should (eq (window-buffer (selected-window)) view))
      (with-current-buffer view
        (should (derived-mode-p 'mdview-mode))
        (should buffer-read-only)
        (should truncate-lines)
        (should (> (buffer-size) 0))
        (should (string-match-p "Hello world" (buffer-string)))
        (should (eq mdview--source-buffer source))
        (should (null mdview--source-file))
        (should (equal default-directory
                       (buffer-local-value 'default-directory source)))
        (should (equal mdview--base-dir default-directory))
        (should (= (length mdview--history) 1))
        (should (= mdview--history-index 0))
        (should (integerp mdview--last-width))))))

(ert-deftest mdview-test-mdview-reuses-view ()
  (mdview-test-with-source (source "One\n")
    (let ((first (with-current-buffer source (mdview)))
          (second (with-current-buffer source (mdview))))
      (should (eq first second))
      (should (= (length (seq-filter #'mdview--view-p (buffer-list))) 1))
      ;; Calling `mdview' inside a view refreshes it instead of nesting.
      (should (eq (with-current-buffer first (mdview)) first)))))

(ert-deftest mdview-test-render-string ()
  (let ((rendered (mdview-render-string "Hello *world*\n\nAgain\n" 40)))
    (should (stringp rendered))
    (should (string-match-p "Hello" rendered))
    (should (string-match-p "Again" rendered))))

;;;; Source synchronisation

(ert-deftest mdview-test-toggle-round-trip ()
  (mdview-test-with-source (source "First\n\nSecond\n\nThird\n")
    (with-current-buffer source
      (goto-char (point-min))
      (forward-line 2)
      (should (= (line-number-at-pos) 3))
      (mdview-toggle))
    (let ((view (window-buffer (selected-window))))
      (should (mdview--view-p view))
      (with-current-buffer view
        (should (equal (mdview-test--source-lines) '(1 3 5)))
        (should (= (mdview--source-line-at (point)) 3))
        (mdview-toggle)))
    (should (eq (window-buffer (selected-window)) source))
    (with-current-buffer source
      (should (= (line-number-at-pos) 3)))))

(ert-deftest mdview-test-visit-source-from-file-view ()
  (let* ((dir (make-temp-file "mdview-test" t))
         (file (mdview-test--write-file dir "doc.md" "Alpha\n\nBeta\n"))
         (buffer nil))
    (unwind-protect
        (let ((view (mdview-file file)))
          (with-current-buffer view
            (should (null mdview--source-buffer))
            (mdview--goto-source-line 3)
            (mdview-toggle))
          (setq buffer (window-buffer (selected-window)))
          (should (equal (buffer-file-name buffer) file))
          (with-current-buffer buffer
            (should (= (line-number-at-pos) 3)))
          ;; The view adopted the visiting buffer as its source.
          (should (eq (buffer-local-value 'mdview--source-buffer view) buffer)))
      (mdview-test--cleanup buffer)
      (delete-directory dir t))))

(ert-deftest mdview-test-refresh-keeps-source-line ()
  (mdview-test-with-source (source "First\n\nSecond\n\nThird\n")
    (let ((view (with-current-buffer source (mdview))))
      (with-current-buffer source
        (goto-char (point-max))
        (insert "\nFourth\n"))
      (with-current-buffer view
        (mdview--goto-source-line 5)
        (should (= (mdview--source-line-at (point)) 5))
        (mdview-refresh)
        (should (string-match-p "Fourth" (buffer-string)))
        (should (equal (mdview-test--source-lines) '(1 3 5 7)))
        (should (= (mdview--source-line-at (point)) 5))
        (should-not (buffer-modified-p))))))

(ert-deftest mdview-test-refresh-without-source ()
  (mdview-test-with-source (source "Gone soon\n")
    (let ((view (with-current-buffer source (mdview))))
      (kill-buffer source)
      (with-current-buffer view
        (should (buffer-live-p view))
        (should (string-match-p "Gone soon" (buffer-string)))
        (should-error (mdview-refresh) :type 'user-error)
        (should (string-match-p "Gone soon" (buffer-string)))
        (should-error (mdview-visit-source) :type 'user-error)))))

(ert-deftest mdview-test-killed-source-falls-back-to-file ()
  (let* ((dir (make-temp-file "mdview-test" t))
         (file (mdview-test--write-file dir "doc.md" "On disk\n"))
         (source (find-file-noselect file)))
    (unwind-protect
        (let ((view (mdview source)))
          (with-current-buffer source
            (goto-char (point-max))
            (insert "Unsaved\n")
            (set-buffer-modified-p nil))
          (kill-buffer source)
          (with-current-buffer view
            (should (equal mdview--source-file file))
            (mdview-refresh)
            (should (string-match-p "On disk" (buffer-string)))
            (should-not (string-match-p "Unsaved" (buffer-string)))))
      (mdview-test--cleanup source)
      (delete-directory dir t))))

(ert-deftest mdview-test-refresh-on-save ()
  (let* ((dir (make-temp-file "mdview-test" t))
         (file (mdview-test--write-file dir "doc.md" "Alpha\n\nBeta\n"))
         (source (find-file-noselect file)))
    (unwind-protect
        (let ((view (mdview source)))
          (should (memq #'mdview--after-save
                        (buffer-local-value 'after-save-hook source)))
          (with-current-buffer source
            (goto-char (point-max))
            (insert "\nGamma\n")
            (let ((inhibit-message t))
              (save-buffer)))
          (should (string-match-p "Gamma" (with-current-buffer view (buffer-string))))
          ;; Disabled option: the hook stays but does nothing.
          (let ((mdview-refresh-on-save nil))
            (with-current-buffer source
              (goto-char (point-max))
              (insert "\nDelta\n")
              (let ((inhibit-message t))
                (save-buffer))))
          (should-not (string-match-p "Delta" (with-current-buffer view (buffer-string)))))
      (mdview-test--cleanup source)
      (delete-directory dir t))))

(ert-deftest mdview-test-kill-view-removes-save-hook ()
  (mdview-test-with-source (source "Text\n")
    (let ((view (with-current-buffer source (mdview))))
      (should (memq #'mdview--after-save
                    (buffer-local-value 'after-save-hook source)))
      (kill-buffer view)
      (should-not (memq #'mdview--after-save
                        (buffer-local-value 'after-save-hook source))))))

;;;; Quitting

(ert-deftest mdview-test-quit-returns-to-source ()
  (mdview-test-with-source (source "Text\n")
    (let ((view (with-current-buffer source (mdview))))
      (should (eq (window-buffer (selected-window)) view))
      (with-current-buffer view (mdview-quit))
      (should (eq (window-buffer (selected-window)) source))
      (should (buffer-live-p view)))))

(ert-deftest mdview-test-quit-without-origin ()
  (mdview-test-with-source (source "Text\n")
    (let ((view (with-current-buffer source (mdview))))
      (with-current-buffer view
        (setq mdview--source-window nil)
        (mdview-quit))
      (should-not (eq (window-buffer (selected-window)) view)))))

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
          (should (= (mdview--content-width) 20)))))))

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
          (should (= right-margin-width 4)))))))

(ert-deftest mdview-test-refit-only-when-width-changes ()
  (mdview-test-with-source (source "Some text\n")
    (let ((view (with-current-buffer source (mdview))))
      (should (get-buffer-window view t))
      (with-current-buffer view
        (let ((tick (buffer-chars-modified-tick))
              (width mdview--last-width))
          (should-not (mdview--refit view))
          (should (= tick (buffer-chars-modified-tick)))
          (should (= width mdview--last-width))
          (cl-letf (((symbol-function 'window-margins) (lambda (&rest _) '(nil)))
                    ((symbol-function 'window-body-width) (lambda (&rest _) 40)))
            (let ((mdview-margin 4) (mdview-max-width 100))
              (should (mdview--refit view))
              (should (= mdview--last-width 31))
              (should (/= tick (buffer-chars-modified-tick))))))))))

(ert-deftest mdview-test-window-size-change-schedules-timer ()
  (mdview-test-with-source (source "Some text\n")
    (let ((view (with-current-buffer source (mdview))))
      (with-current-buffer view
        (let ((mdview-auto-refit t))
          (mdview--window-size-changed (selected-window))
          (should (timerp mdview--refit-timer))
          (mdview--cancel-refit)
          (should (null mdview--refit-timer)))
        (let ((mdview-auto-refit nil))
          (mdview--window-size-changed (selected-window))
          (should (null mdview--refit-timer)))))))

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

(ert-deftest mdview-test-follow-local-file-links ()
  (let* ((dir (make-temp-file "mdview-test" t))
         (other (mdview-test--write-file dir "other.txt" "plain\n"))
         (linked (mdview-test--write-file dir "linked.md" "Linked document\n")))
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
          (should (string-match-p "Linked document" (buffer-string)))
          (should (equal mdview--source-file linked))
          (should (equal default-directory (file-name-as-directory dir)))
          (should (equal (buffer-name) "*mdview: linked.md*")))
      (delete-directory dir t))))

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

;;;; History

(ert-deftest mdview-test-history-back-and-forward ()
  (let* ((dir (make-temp-file "mdview-test" t))
         (linked (mdview-test--write-file dir "linked.md" "Linked document\n")))
    (unwind-protect
        (mdview-test-with-source (source "Original document\n")
          (let ((view (with-current-buffer source (mdview))))
            (with-current-buffer view
              (let ((inhibit-read-only t))
                (goto-char (point-max))
                (insert (mdview-test--link "next" linked)))
              (goto-char (1- (point-max)))
              (mdview-follow-link)
              (should (string-match-p "Linked document" (buffer-string)))
              (should (= (length mdview--history) 2))
              (should (= mdview--history-index 1))
              (should (equal (buffer-name) "*mdview: linked.md*"))
              (should-error (mdview-history-forward) :type 'user-error)
              (mdview-history-back)
              (should (string-match-p "Original document" (buffer-string)))
              (should (= mdview--history-index 0))
              (should (eq mdview--source-buffer source))
              (should (equal (buffer-name) "*mdview: test.md*"))
              (should (memq #'mdview--after-save
                            (buffer-local-value 'after-save-hook source)))
              (should-error (mdview-history-back) :type 'user-error)
              (mdview-history-forward)
              (should (string-match-p "Linked document" (buffer-string)))
              (should (= mdview--history-index 1)))))
      (delete-directory dir t))))

(ert-deftest mdview-test-history-push-drops-forward-entries ()
  (mdview-test-with-fake-view (view "text\n")
    (setq mdview--source-file "/tmp/a.md")
    (mdview--history-push)
    (setq mdview--source-file "/tmp/b.md")
    (mdview--history-push)
    (setq mdview--source-file "/tmp/c.md")
    (mdview--history-push)
    (should (equal (mapcar #'car mdview--history) '("/tmp/a.md" "/tmp/b.md" "/tmp/c.md")))
    (setq mdview--history-index 0)
    (setq mdview--source-file "/tmp/d.md")
    (mdview--history-push)
    (should (equal (mapcar #'car mdview--history) '("/tmp/a.md" "/tmp/d.md")))
    (should (= mdview--history-index 1))))

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
      (view (concat (mdview-test--heading "First" 1 "first") "\n\n"
                    (mdview-test--heading "Second" 2 "second") "\n"))
    (let ((second (cdr (assoc "Second" (mdview--imenu-create-index)))))
      ;; `imenu' selects the window of `last-nonmenu-event' (nil in batch).
      (set-window-buffer (selected-window) view)
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (&rest _) "Second")))
        (goto-char (point-min))
        (mdview-toc)
        (should (= (point) second))
        ;; When `imenu' itself fails, the completion fallback is used.
        (goto-char (point-min))
        (cl-letf (((symbol-function 'imenu)
                   (lambda (&rest _) (error "No imenu"))))
          (mdview-toc))
        (should (= (point) second))))))

(ert-deftest mdview-test-toc-without-headings ()
  (mdview-test-with-fake-view (view "nothing\n")
    (should-error (mdview-toc) :type 'user-error)))

;;;; Images

(ert-deftest mdview-test-toggle-images ()
  (mdview-test-with-source (source "Some text\n")
    (let ((view (with-current-buffer source (mdview))))
      (with-current-buffer view
        (let ((before mdview--images-enabled)
              (tick (buffer-chars-modified-tick))
              (inhibit-message t))
          (mdview-toggle-images)
          (should (eq mdview--images-enabled (not before)))
          (should (/= tick (buffer-chars-modified-tick)))
          (should (string-match-p "Some text" (buffer-string)))
          (mdview-toggle-images)
          (should (eq mdview--images-enabled before)))))))

;;;; Files

(ert-deftest mdview-test-file-renders-minimal ()
  (let ((file (expand-file-name "fixtures/minimal.md" mdview-test-dir)))
    (unwind-protect
        (let ((view (mdview-file file)))
          (should (eq view (get-buffer "*mdview: minimal.md*")))
          (should (eq (window-buffer (selected-window)) view))
          (should-not (find-buffer-visiting file))
          (with-current-buffer view
            (should (derived-mode-p 'mdview-mode))
            (should (string-match-p "Title" (buffer-string)))
            (should (equal mdview--source-file file))
            (should (equal mdview--base-dir (file-name-directory file)))
            (should (equal default-directory (file-name-directory file)))
            (should (= (length mdview--history) 1))))
      (mdview-test--cleanup))))

(ert-deftest mdview-test-file-reuses-visiting-buffer ()
  (let* ((dir (make-temp-file "mdview-test" t))
         (file (mdview-test--write-file dir "doc.md" "Content\n"))
         (source (find-file-noselect file)))
    (unwind-protect
        (let ((view (mdview-file file)))
          (should (eq (buffer-local-value 'mdview--source-buffer view) source))
          (should (equal (buffer-local-value 'mdview--source-file view) file))
          (should (eq (mdview-file file) view)))
      (mdview-test--cleanup source)
      (delete-directory dir t))))

(ert-deftest mdview-test-file-missing ()
  (should-error (mdview-file "/nonexistent/dir/missing.md") :type 'user-error))

;;;; Integration

(ert-deftest mdview-test-install-keybinding ()
  (let ((map (make-sparse-keymap)))
    (unwind-protect
        (progn
          (setq features (delq 'md-mode features))
          (setq md-mode-map map)
          (mdview-install-keybinding "C-c C-v")
          (should-not (eq (lookup-key map (kbd "C-c C-v")) #'mdview-toggle))
          (provide 'md-mode)
          (should (eq (lookup-key map (kbd "C-c C-v")) #'mdview-toggle))
          ;; Vectors work too, and a loaded feature is bound immediately.
          (mdview-install-keybinding [f9])
          (should (eq (lookup-key map [f9]) #'mdview-toggle)))
      (setq features (delq 'md-mode features))
      (makunbound 'md-mode-map))))

(provide 'mdview-test)
;;; mdview-test.el ends here
