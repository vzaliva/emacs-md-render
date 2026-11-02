;;; gui-check.el --- Report images displayed by mdview in a graphical Emacs  -*- lexical-binding: t; -*-

;; This file is part of mdview, distributed under the MIT license; see
;; LICENSE in the repository root.

;;; Commentary:

;; Not part of the package.  Renders a Markdown file with mdview in a
;; GRAPHICAL Emacs started in the background, waits for pending remote
;; images, and writes a plain-text report listing every image `display'
;; property found in the view (source file or data, image type, pixel
;; size via `image-size') followed by the first 60 lines of the
;; rendering, then kills Emacs.  It is the screenshot-free GUI image
;; check of docs/DESIGN.md section 13.
;;
;; Usage (from the repository root; this opens a frame, so do not run it
;; from an automated agent) -- start Emacs with:
;;
;;   emacs -Q -L . -l scripts/gui-check.el \
;;         --eval '(mdview-gui-check "test/fixtures/showcase.md" "/tmp/mdview-gui-report.txt")'
;;
;; The report ends with a line "mdview-gui-check: done" so a caller can
;; tell a complete run from a crash.

;;; Code:

(require 'mdview)

(defvar mdview-gui-check-timeout 10
  "Seconds to wait for pending remote images before writing the report.")

(defvar mdview-gui-check-lines 60
  "Number of rendered lines to include in the report.")

(defun mdview-gui-check--pending-p (buffer)
  "Return non-nil while a pending image placeholder remains in BUFFER."
  (with-current-buffer buffer
    (save-excursion
      (goto-char (point-min))
      (and (text-property-search-forward 'mdview-image-pending) t))))

(defun mdview-gui-check--wait (buffer)
  "Give BUFFER's remote images up to `mdview-gui-check-timeout' seconds."
  (let ((deadline (+ (float-time) mdview-gui-check-timeout)))
    (while (and (mdview-gui-check--pending-p buffer)
                (< (float-time) deadline))
      (accept-process-output nil 0.2)
      (sit-for 0.1))))

(defun mdview-gui-check--describe-image (spec)
  "Return a one-line description of the image display SPEC."
  (let* ((props (cdr spec))
         (file (plist-get props :file))
         (data (plist-get props :data))
         (type (plist-get props :type))
         (size (condition-case err
                   (image-size spec t)
                 (error (format "image-size error: %s" (error-message-string err))))))
    (format "type=%s source=%s pixels=%s max-width=%s max-height=%s"
            type
            (cond (file (abbreviate-file-name file))
                  (data (format "<data %d bytes>" (length data)))
                  (t "?"))
            (if (consp size) (format "%dx%d" (car size) (cdr size)) size)
            (plist-get props :max-width)
            (plist-get props :max-height))))

(defun mdview-gui-check--image-spec (display)
  "Return the image spec inside the DISPLAY property value, or nil."
  (cond
   ((and (consp display) (eq (car display) 'image)) display)
   ((consp display)
    (seq-some #'mdview-gui-check--image-spec display))))

(defun mdview-gui-check--images (buffer)
  "Return a list of (POSITION LINE DESCRIPTION) for every image in BUFFER."
  (with-current-buffer buffer
    (let ((pos (point-min)) (result nil))
      (while (< pos (point-max))
        (let* ((display (get-text-property pos 'display))
               (spec (and display (mdview-gui-check--image-spec display)))
               (next (or (next-single-property-change pos 'display) (point-max))))
          (when spec
            (push (list pos (line-number-at-pos pos)
                        (mdview-gui-check--describe-image spec)
                        (or (get-text-property pos 'mdview-link) ""))
                  result))
          (setq pos next)))
      (nreverse result))))

(defun mdview-gui-check--head (buffer n)
  "Return the first N lines of BUFFER as plain text."
  (with-current-buffer buffer
    (save-excursion
      (goto-char (point-min))
      (forward-line n)
      (substring-no-properties (buffer-substring (point-min) (point))))))

(defun mdview-gui-check (file report)
  "Render FILE with mdview in a frame and write a report to REPORT.
The report lists every image `display' property (source, type, pixel
size), the pending placeholders that never resolved, and the first
`mdview-gui-check-lines' lines of the rendering; then Emacs exits."
  (let ((status "done"))
    (condition-case err
        (progn
          (unless (display-graphic-p)
            (error "The GUI check needs a graphical display"))
          (let* ((file (expand-file-name file))
                 (view (progn (mdview-file file) (current-buffer))))
            (mdview-gui-check--wait view)
            (let ((images (mdview-gui-check--images view))
                  (pending (mdview-gui-check--pending-p view))
                  (width (window-body-width (get-buffer-window view))))
              (with-temp-file report
                (insert (format "mdview-gui-check report for %s\n" file))
                (insert (format "Emacs %s, frame %dx%d px, char %dx%d px, window %d columns\n"
                                emacs-version (frame-pixel-width) (frame-pixel-height)
                                (frame-char-width) (frame-char-height) width))
                (insert (format "display-images-p: %s; image types: %s\n"
                                (display-images-p)
                                (mapconcat #'symbol-name
                                           (seq-filter #'image-type-available-p
                                                       '(png jpeg gif svg webp tiff xpm))
                                           " ")))
                (insert (format "\n%d image(s) displayed%s\n" (length images)
                                (if pending "; some placeholders still pending" "")))
                (pcase-dolist (`(,pos ,line ,description ,link) images)
                  (insert (format "  line %4d pos %6d  %s  link=%s\n" line pos description link)))
                (insert (format "\nFirst %d lines of the rendering:\n\n" mdview-gui-check-lines))
                (insert (mdview-gui-check--head view mdview-gui-check-lines))))))
      (error
       (setq status (format "error: %s" (error-message-string err)))
       (with-temp-file report
         (insert (format "mdview-gui-check failed: %s\n" status)))))
    (with-temp-buffer
      (insert-file-contents report)
      (goto-char (point-max))
      (insert (format "\nmdview-gui-check: %s\n" status))
      (write-region (point-min) (point-max) report))
    (kill-emacs (if (string= status "done") 0 1))))

(provide 'mdview-gui-check)
;;; gui-check.el ends here
