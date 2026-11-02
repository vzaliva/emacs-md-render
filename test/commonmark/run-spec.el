;;; run-spec.el --- CommonMark conformance runner for mdview  -*- lexical-binding: t; -*-

;; This file is part of mdview, distributed under the MIT license; see
;; LICENSE in the repository root.

;;; Commentary:

;; Runs every example of the CommonMark specification (spec.json, which
;; `make commonmark' downloads from spec.commonmark.org) through
;; `mdview-parse-string' and the HTML serializer in mdview-html.el,
;; compares the result with the expected HTML after whitespace
;; normalization, prints a per-section report and writes the failing
;; examples to test/out/commonmark-failures.txt.  The pass count must not
;; drop below the integer in test/commonmark/baseline (docs/DESIGN.md
;; section 4).  Entry points: `mdview-commonmark-run' returns the results
;; as a plist; `mdview-commonmark-report' prints them and, in batch mode,
;; exits with a non-zero status when the baseline is not met.
;;
;; Usage (from the repository root):
;;   $EMACS -Q --batch -L . -l mdview -l test/commonmark/run-spec.el \
;;          -f mdview-commonmark-report

;;; Code:

(require 'json)
(require 'mdview-parse)

(eval-and-compile
  (defconst mdview-commonmark-directory
    (file-name-directory
     (expand-file-name
      (or (let ((file (bound-and-true-p byte-compile-current-file)))
            (and (stringp file) file)) ; a buffer when compiling a buffer
          load-file-name buffer-file-name default-directory)))
    "The directory holding this file, spec.json and the baseline.")
  ;; Also at compile time, so that byte-compiling this file (as
  ;; `package-vc-install' does for every file in the checkout) finds the
  ;; serializer next to it.  The file being compiled wins over
  ;; `load-file-name': `package-vc-install' called from an init file
  ;; compiles while that init file is being loaded.
  (add-to-list 'load-path mdview-commonmark-directory))
(require 'mdview-html)

(defvar mdview-commonmark-spec-file
  (expand-file-name "spec.json" mdview-commonmark-directory)
  "The CommonMark spec.json file.")

(defvar mdview-commonmark-baseline-file
  (expand-file-name "baseline" mdview-commonmark-directory)
  "File holding the minimum number of examples that must pass.")

(defvar mdview-commonmark-failures-file
  (expand-file-name "../out/commonmark-failures.txt" mdview-commonmark-directory)
  "File receiving the failing examples of the last run.")

(defun mdview-commonmark-normalize (html)
  "Normalize HTML for comparison.
Runs of whitespace collapse to one space, lines are trimmed and empty
lines dropped."
  (string-join
   (delq nil
         (mapcar (lambda (line)
                   (let ((s (string-trim (replace-regexp-in-string "[ \t\r]+" " " line))))
                     (and (not (string-empty-p s)) s)))
                 (split-string html "\n")))
   "\n"))

(defun mdview-commonmark-load-examples (&optional file)
  "Return the examples of spec FILE (default `mdview-commonmark-spec-file').
Each example is an alist with the keys `markdown', `html', `example' and
`section'."
  (with-temp-buffer
    (insert-file-contents (or file mdview-commonmark-spec-file))
    (goto-char (point-min))
    (if (fboundp 'json-parse-buffer)
        (json-parse-buffer :object-type 'alist :array-type 'list)
      (let ((json-object-type 'alist) (json-array-type 'list))
        (json-read)))))

(defun mdview-commonmark-render (markdown)
  "Parse MARKDOWN and return its HTML, or an error description string."
  (condition-case err
      (mdview-html-render (mdview-parse-string markdown))
    (error (format "ERROR: %S" err))))

(defun mdview-commonmark-run (&optional file)
  "Run all examples of spec FILE and return the results.
The value is a plist with `:total', `:passed', `:sections' (an alist of
section name to (PASSED . TOTAL) in spec order) and `:failures' (a list
of plists with `:example', `:section', `:markdown', `:expected' and
`:got')."
  (let ((sections nil) (failures nil) (passed 0) (total 0))
    (dolist (example (mdview-commonmark-load-examples file))
      (let* ((markdown (alist-get 'markdown example))
             (expected (alist-get 'html example))
             (section (alist-get 'section example))
             (number (alist-get 'example example))
             (got (mdview-commonmark-render markdown))
             (ok (string= (mdview-commonmark-normalize got)
                          (mdview-commonmark-normalize expected)))
             (entry (or (assoc section sections)
                        (car (push (cons section (cons 0 0)) sections)))))
        (setq total (1+ total))
        (setcdr (cdr entry) (1+ (cddr entry)))
        (if ok
            (progn (setq passed (1+ passed))
                   (setcar (cdr entry) (1+ (cadr entry))))
          (push (list :example number :section section :markdown markdown
                      :expected expected :got got)
                failures))))
    (list :total total :passed passed
          :sections (nreverse sections)
          :failures (nreverse failures))))

(defun mdview-commonmark-baseline ()
  "Return the integer in `mdview-commonmark-baseline-file', or 0."
  (if (file-readable-p mdview-commonmark-baseline-file)
      (with-temp-buffer
        (insert-file-contents mdview-commonmark-baseline-file)
        (string-to-number (string-trim (buffer-string))))
    0))

(defun mdview-commonmark-write-failures (results &optional file)
  "Write the failing examples of RESULTS to FILE."
  (let ((file (or file mdview-commonmark-failures-file)))
    (make-directory (file-name-directory file) t)
    (with-temp-file file
      (dolist (f (plist-get results :failures))
        (insert (format "=== Example %d (%s)\n--- markdown\n%s--- expected\n%s--- got\n%s\n"
                        (plist-get f :example) (plist-get f :section)
                        (plist-get f :markdown) (plist-get f :expected)
                        (plist-get f :got)))))
    file))

(defun mdview-commonmark-report ()
  "Run the CommonMark examples, print a report and check the baseline.
Failing examples are written to `mdview-commonmark-failures-file'.  In
batch mode Emacs exits with status 1 when fewer examples pass than the
baseline requires; interactively a `user-error' is signalled."
  (interactive)
  (unless (file-readable-p mdview-commonmark-spec-file)
    (error "Missing %s; run `make test/commonmark/spec.json'"
           mdview-commonmark-spec-file))
  (let* ((results (mdview-commonmark-run))
         (total (plist-get results :total))
         (passed (plist-get results :passed))
         (baseline (mdview-commonmark-baseline))
         (file (mdview-commonmark-write-failures results)))
    (dolist (entry (plist-get results :sections))
      (princ (format "%-42s %3d / %3d\n" (car entry) (cadr entry) (cddr entry))))
    (princ (format "%-42s %3d / %3d  (%.1f%%)\n" "TOTAL" passed total
                   (/ (* 100.0 passed) (max total 1))))
    (princ (format "baseline %d; failures written to %s\n" baseline file))
    (when (< passed baseline)
      (if noninteractive
          (progn (princ (format "FAIL: %d < baseline %d\n" passed baseline))
                 (kill-emacs 1))
        (user-error "CommonMark conformance dropped: %d < baseline %d" passed baseline)))
    results))

(provide 'mdview-commonmark-run-spec)
;;; run-spec.el ends here
