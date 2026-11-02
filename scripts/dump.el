;;; dump.el --- Development dumps of mdview renderings  -*- lexical-binding: t; -*-

;; Not part of the package.  Loaded by the Makefile targets `render',
;; `render-faces', `render-ansi' and `golden'.  Usage from the shell:
;;
;;   emacs -Q --batch -L . -l mdview -l scripts/dump.el \
;;         --eval '(mdview-dev-dump "test/fixtures/showcase.md" 100 nil)'

;;; Code:

(require 'mdview)
(require 'color)

(defun mdview-dev-render-to-string (file width)
  "Render FILE at WIDTH columns and return the propertized buffer text."
  (let ((doc (with-temp-buffer
               (insert-file-contents file)
               (mdview-parse-buffer)))
        (default-directory (file-name-directory (expand-file-name file))))
    (with-temp-buffer
      (mdview-render-document doc :width width
                              :base-dir (file-name-directory
                                         (expand-file-name file)))
      (buffer-string))))

(defun mdview-dev--face-list (face)
  "Normalize FACE (symbol, list or plist) into a list of items."
  (cond ((null face) nil)
        ((symbolp face) (list face))
        ((keywordp (car-safe face)) (list face))
        (t (apply #'append (mapcar #'mdview-dev--face-list face)))))

(defun mdview-dev-dump (file width &optional with-faces)
  "Print FILE rendered at WIDTH to stdout.
With WITH-FACES non-nil, insert {face} markers where the face changes."
  (let ((text (mdview-dev-render-to-string file width)))
    (if (not with-faces)
        (princ (substring-no-properties text))
      (let ((pos 0) (len (length text)) (last 'none))
        (while (< pos len)
          (let* ((face (get-text-property pos 'face text))
                 (next (or (next-single-property-change pos 'face text) len)))
            (unless (equal face last)
              (princ (format "{%s}" (if face (mapconcat
                                              (lambda (f) (format "%s" f))
                                              (mdview-dev--face-list face) "+")
                                      "-")))
              (setq last face))
            (princ (substring-no-properties text pos next))
            (setq pos next)))))
    (unless (string-suffix-p "\n" text) (princ "\n"))))

(defun mdview-dev--attr (face attr)
  "Return attribute ATTR of FACE (symbol, list or plist), first match wins."
  (catch 'found
    (dolist (f (mdview-dev--face-list face))
      (let ((v (cond ((symbolp f) (face-attribute f attr nil t))
                     ((plist-member f attr) (plist-get f attr)))))
        (when (and v (not (eq v 'unspecified)))
          (throw 'found v))))
    nil))

(defun mdview-dev--rgb (color)
  "Return COLOR as (R G B) 0-255, or nil."
  (when (and (stringp color) (not (string-empty-p color)))
    (let ((rgb (or (color-name-to-rgb color)
                   (and (string-match-p "\\`#[0-9a-fA-F]\\{6\\}\\'" color)
                        (list (/ (string-to-number (substring color 1 3) 16) 255.0)
                              (/ (string-to-number (substring color 3 5) 16) 255.0)
                              (/ (string-to-number (substring color 5 7) 16) 255.0))))))
      (and rgb (mapcar (lambda (x) (round (* 255 x))) rgb)))))

(defun mdview-dev--ansi (face)
  "Return an ANSI SGR sequence for FACE, or \"\" when nothing applies."
  (let ((codes nil))
    (let ((fg (mdview-dev--rgb (mdview-dev--attr face :foreground)))
          (bg (mdview-dev--rgb (mdview-dev--attr face :background))))
      (when fg (push (format "38;2;%d;%d;%d" (nth 0 fg) (nth 1 fg) (nth 2 fg)) codes))
      (when bg (push (format "48;2;%d;%d;%d" (nth 0 bg) (nth 1 bg) (nth 2 bg)) codes)))
    (when (memq (mdview-dev--attr face :weight) '(bold semi-bold extra-bold ultra-bold))
      (push "1" codes))
    (when (memq (mdview-dev--attr face :slant) '(italic oblique))
      (push "3" codes))
    (when (mdview-dev--attr face :underline) (push "4" codes))
    (when (mdview-dev--attr face :strike-through) (push "9" codes))
    (if codes (format "\e[%sm" (mapconcat #'identity (nreverse codes) ";")) "")))

(defun mdview-dev-dump-ansi (file width)
  "Print FILE rendered at WIDTH with 24-bit ANSI colours to stdout."
  (let* ((text (mdview-dev-render-to-string file width))
         (pos 0) (len (length text)))
    (while (< pos len)
      (let* ((face (get-text-property pos 'face text))
             (next (or (next-single-property-change pos 'face text) len))
             (chunk (substring-no-properties text pos next)))
        (if face
            (princ (concat (mdview-dev--ansi face)
                           (replace-regexp-in-string "\n" "\e[0m\n" chunk t t)
                           "\e[0m"))
          (princ chunk))
        (setq pos next)))
    (unless (string-suffix-p "\n" text) (princ "\n"))))

(defun mdview-dev-update-golden ()
  "Regenerate test/golden/*.txt from test/fixtures/*.md at width 80."
  (let* ((root (file-name-directory (directory-file-name
                                     (file-name-directory
                                      (or load-file-name buffer-file-name
                                          default-directory)))))
         (fixtures (directory-files (expand-file-name "test/fixtures" root) t "\\.md\\'")))
    (dolist (f fixtures)
      (let ((out (expand-file-name
                  (concat "test/golden/" (file-name-base f) ".txt") root)))
        (with-temp-file out
          (insert (substring-no-properties (mdview-dev-render-to-string f 80))))
        (message "wrote %s" out)))))

(provide 'mdview-dev-dump)
;;; dump.el ends here
