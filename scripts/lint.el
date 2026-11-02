;;; lint.el --- Run checkdoc over files and fail on findings  -*- lexical-binding: t; -*-

;; This file is part of mdview, distributed under the MIT license; see
;; LICENSE in the repository root.

;;; Commentary:

;; Not part of the package.  Backs `make lint': runs `checkdoc-file' on
;; every file named on the command line and exits with status 1 when
;; checkdoc reported anything, so that the target can gate CI.  Checkdoc
;; itself only prints its findings (through `warn') and exits 0.
;;
;;   `emacs -Q --batch -l scripts/lint.el -f mdview-dev-lint mdview*.el'

;;; Code:

(require 'checkdoc)

(defvar mdview-dev-lint-findings 0
  "Number of findings checkdoc reported so far.")

(defun mdview-dev-lint--count (&rest _)
  "Count a checkdoc finding (advice on `checkdoc-error')."
  (setq mdview-dev-lint-findings (1+ mdview-dev-lint-findings)))

(defun mdview-dev-lint ()
  "Run checkdoc on the files in `command-line-args-left'; exit 1 on findings."
  (setq checkdoc-arguments-in-order-flag nil)
  (advice-add 'checkdoc-error :before #'mdview-dev-lint--count)
  (let ((files command-line-args-left))
    (setq command-line-args-left nil)
    (dolist (file files)
      (checkdoc-file (expand-file-name file))))
  (if (zerop mdview-dev-lint-findings)
      (message "checkdoc: no findings")
    (message "checkdoc: %d finding(s)" mdview-dev-lint-findings)
    (kill-emacs 1)))

(provide 'mdview-dev-lint)
;;; lint.el ends here
