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
;; Usage: start a graphical `emacs' in the background with ABSOLUTE paths
;; (the GUI build may be launched through a wrapper that ignores the
;; shell's working directory, so relative -L/-l/file arguments would not
;; resolve), then poll for the report; it opens a frame briefly and
;; kills that Emacs when done:
;;
;;   emacs -Q -L /path/to/emacs-md-render \
;;         -l /path/to/emacs-md-render/scripts/gui-check.el \
;;         --eval '(mdview-gui-check "/path/to/emacs-md-render/test/fixtures/showcase.md" "/tmp/mdview-gui-report.txt")' &
;;
;; The check is driven by timers rather than by a blocking wait loop:
;; `mdview-gui-check' returns immediately and the rendering, the polling
;; for pending images and the report happen once the command loop runs.
;; This matters because the asynchronous image path (the fetch queue,
;; its watchdog timers and the idle-timer re-render after images arrive)
;; needs the command loop -- a loop of `accept-process-output'/`sit-for'
;; inside `--eval' never lets Emacs become idle, so the view would never
;; settle and (with the `url-queue' the image module used earlier) no
;; remote image would even have been fetched.
;;
;; The report ends with a line "mdview-gui-check: done" so a caller can
;; tell a complete run from a crash.

;;; Code:

(require 'mdview)

(defvar mdview-gui-check-timeout 10
  "Seconds to wait for pending remote images before writing the report.")

(defvar mdview-gui-check-lines 60
  "Number of rendered lines to include in the report.")

(defvar mdview-gui-check-poll-interval 0.2
  "Seconds between two checks for still pending images.")

(defvar mdview-gui-check--file nil
  "The Markdown file being checked.")

(defvar mdview-gui-check--report nil
  "The file the report is written to.")

(defvar mdview-gui-check--view nil
  "The view buffer under inspection.")

(defvar mdview-gui-check--started nil
  "`float-time' when the rendering finished and the wait began.")

(defvar mdview-gui-check--deadline nil
  "`float-time' after which pending images are given up on.")

(defun mdview-gui-check--pending-p (buffer)
  "Return non-nil while a pending image placeholder remains in BUFFER."
  (with-current-buffer buffer
    (save-excursion
      (goto-char (point-min))
      (and (text-property-search-forward 'mdview-image-pending) t))))

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
  "Return a list of (POSITION LINE DESCRIPTION LINK) for every image in BUFFER."
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

(defun mdview-gui-check--write-report ()
  "Write the report about `mdview-gui-check--view' to the report file."
  (let* ((view mdview-gui-check--view)
         (images (mdview-gui-check--images view))
         (pending (mdview-gui-check--pending-p view))
         (waited (- (float-time) mdview-gui-check--started))
         (width (window-body-width (get-buffer-window view))))
    (with-temp-file mdview-gui-check--report
      (insert (format "mdview-gui-check report for %s\n" mdview-gui-check--file))
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
                      (if pending
                          (format "; some placeholders still pending after %.1f s"
                                  waited)
                        (format "; no placeholder pending after %.1f s" waited))))
      (pcase-dolist (`(,pos ,line ,description ,link) images)
        (insert (format "  line %4d pos %6d  %s  link=%s\n" line pos description link)))
      (insert (format "\nFirst %d lines of the rendering:\n\n" mdview-gui-check-lines))
      (insert (mdview-gui-check--head view mdview-gui-check-lines)))))

(defun mdview-gui-check--finish (status)
  "Write the report (or the failure STATUS), append the status line and exit."
  (condition-case err
      (if (string= status "done")
          (mdview-gui-check--write-report)
        (with-temp-file mdview-gui-check--report
          (insert (format "mdview-gui-check failed: %s\n" status))))
    (error
     (setq status (format "error: %s" (error-message-string err)))
     (with-temp-file mdview-gui-check--report
       (insert (format "mdview-gui-check failed: %s\n" status)))))
  (with-temp-buffer
    (insert-file-contents mdview-gui-check--report)
    (goto-char (point-max))
    (insert (format "\nmdview-gui-check: %s\n" status))
    (write-region (point-min) (point-max) mdview-gui-check--report))
  (kill-emacs (if (string= status "done") 0 1)))

(defun mdview-gui-check--poll ()
  "Finish when no placeholder is pending or the deadline passed; else poll again."
  (condition-case err
      (if (and (mdview-gui-check--pending-p mdview-gui-check--view)
               (< (float-time) mdview-gui-check--deadline))
          (run-with-timer mdview-gui-check-poll-interval nil #'mdview-gui-check--poll)
        (mdview-gui-check--finish "done"))
    (error (mdview-gui-check--finish (format "error: %s" (error-message-string err))))))

(defun mdview-gui-check--render ()
  "Render the file into a view and start polling for its remote images."
  (condition-case err
      (progn
        (unless (display-graphic-p)
          (error "The GUI check needs a graphical display"))
        (setq mdview-gui-check--view (mdview-file mdview-gui-check--file)
              mdview-gui-check--started (float-time)
              mdview-gui-check--deadline (+ (float-time) mdview-gui-check-timeout))
        (redisplay t)
        (mdview-gui-check--poll))
    (error (mdview-gui-check--finish (format "error: %s" (error-message-string err))))))

(defun mdview-gui-check (file report)
  "Render FILE with mdview in a frame and write a report to REPORT, then exit.
The report lists every image `display' property (source, type, pixel
size), whether placeholders were still pending, and the first
`mdview-gui-check-lines' lines of the rendering.  Remote images get up
to `mdview-gui-check-timeout' seconds.

This returns at once and does the work from timers, so that it can be
called from `--eval' and Emacs still enters its command loop and becomes
idle (which the asynchronous image fetches and the re-render after they
arrive need)."
  (setq mdview-gui-check--file (expand-file-name file)
        mdview-gui-check--report (expand-file-name report))
  (run-with-timer 0 nil #'mdview-gui-check--render))

(provide 'mdview-gui-check)
;;; gui-check.el ends here
