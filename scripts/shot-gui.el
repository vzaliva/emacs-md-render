;;; shot-gui.el --- Prepare a graphical Emacs for a screenshot  -*- lexical-binding: t; -*-

;; Loaded by scripts/gui-shot.sh into the graphical Emacs it captures, which
;; runs on a private X virtual framebuffer.  `mdview-gui-shot' renders a
;; Markdown file, waits until no image is pending, scrolls to a section and
;; writes a "ready" file holding the id of the frame's X window; the shell
;; script then captures that window and kills Emacs.
;;
;; Everything happens from timers, not from a blocking loop: the view only
;; settles (and remote images only arrive) while the command loop runs, see
;; scripts/gui-check.el.

;;; Code:

(require 'mdview)
(require 'text-property-search)

(defvar mdview-gui-shot--ready-file nil
  "The file written when the frame is ready to be captured.")

(defvar mdview-gui-shot--section nil
  "Title of the section to scroll to, or nil for the top of the view.")

(defvar mdview-gui-shot--deadline nil
  "`float-time' after which pending images are given up on.")

(defvar mdview-gui-shot--file nil
  "The Markdown file to render.")

(defun mdview-gui-shot--pending-p ()
  "Return non-nil while the current buffer holds a pending image."
  (save-excursion
    (goto-char (point-min))
    (and (text-property-search-forward 'mdview-image-pending) t)))

(defun mdview-gui-shot--scroll ()
  "Scroll the view so that the section titled `mdview-gui-shot--section' leads.
The title of a level-1 or level-2 heading is centred alone on its row,
inside a box whose frame takes two rows above it; show those rows too.
The title is flanked by the box's frame glyphs, so any one character may
precede and follow the padding."
  (goto-char (point-min))
  (when (and mdview-gui-shot--section
             (re-search-forward
              (format "^.? +%s +.?$" (regexp-quote mdview-gui-shot--section))
              nil t))
    (beginning-of-line)
    (recenter 2)))

(defun mdview-gui-shot--render ()
  "Render the file and start waiting for pending images.
This runs from a timer, after the command loop has redisplayed the frame
at its new size: mdview lays the text out for the width of the window, so
rendering straight after `set-frame-size' would use the old width."
  (mdview-file mdview-gui-shot--file)
  (run-with-timer 0.5 nil #'mdview-gui-shot--poll))

(defun mdview-gui-shot--finish ()
  "Write the ready file: the id of the outer X window of the selected frame."
  (message nil)
  (redisplay t)
  (with-temp-file mdview-gui-shot--ready-file
    (insert (frame-parameter nil 'outer-window-id) "\n")))

(defun mdview-gui-shot--poll ()
  "Wait for pending images, then lay out the view and schedule the capture.
Timers run in whatever buffer is current, so first make the view current."
  (set-buffer (window-buffer (selected-window)))
  (if (and (mdview-gui-shot--pending-p)
           (< (float-time) mdview-gui-shot--deadline))
      (run-with-timer 0.2 nil #'mdview-gui-shot--poll)
    (mdview-gui-shot--scroll)
    (setq cursor-type nil)
    (redisplay t)
    ;; Give the X server a moment to paint before the shell captures.
    (run-with-timer 1 nil #'mdview-gui-shot--finish)))

(defun mdview-gui-shot (file ready-file columns rows theme family height
                             &optional section)
  "Render FILE in a COLUMNS x ROWS frame and write READY-FILE when ready.
THEME is loaded first.  FAMILY and HEIGHT (in 1/10 pt) set the default
face.  SECTION is the title of the heading to scroll to, or nil."
  (setq mdview-gui-shot--ready-file ready-file
        mdview-gui-shot--file file
        mdview-gui-shot--section section
        mdview-gui-shot--deadline (+ (float-time) 15)
        inhibit-startup-screen t)
  (menu-bar-mode -1)
  (tool-bar-mode -1)
  (scroll-bar-mode -1)
  (set-face-attribute 'default nil :family family :height height)
  (set-frame-size nil columns rows)
  (load-theme theme t)
  (setq mdview-auto-refit nil)
  (run-with-timer 1 nil #'mdview-gui-shot--render))

(provide 'mdview-dev-shot-gui)
;;; shot-gui.el ends here
