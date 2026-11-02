;;; shot-colors.el --- Record the default colours of a capture  -*- lexical-binding: t; -*-

;; Loaded by scripts/tmux-shot.sh into the Emacs it captures.  A text
;; capture does not say which colour the page is: Emacs leaves cells in the
;; default face unpainted or paints them with the theme's colours, so the
;; renderer needs the real `default' colours to draw padding and frames
;; right (scripts/ansi-to-png.sh reads them from the .colors file).

;;; Code:

(defun mdview-shot-record-colors (file)
  "Write the `default' face colours to FILE as \"#RRGGBB #RRGGBB\".
The background comes first, then the foreground.  A colour Emacs cannot
resolve, such as the terminal's own default, is written as \"none\"."
  (let ((hex (lambda (attribute)
               (let ((color (ignore-errors
                              (color-values
                               (face-attribute 'default attribute nil t)))))
                 (if color
                     (apply #'format "#%02x%02x%02x"
                            (mapcar (lambda (v) (/ v 257)) color))
                   "none")))))
    (with-temp-file file
      (insert (funcall hex :background) " " (funcall hex :foreground)))))

(provide 'mdview-dev-shot-colors)
;;; shot-colors.el ends here
