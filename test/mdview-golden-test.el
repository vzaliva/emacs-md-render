;;; mdview-golden-test.el --- Golden rendering tests for mdview  -*- lexical-binding: t; -*-

;; This file is part of mdview, distributed under the MIT license; see
;; LICENSE in the repository root.

;;; Commentary:

;; Renders every Markdown fixture in test/fixtures/ at width 80 in batch
;; (images degrade to placeholders) and compares the plain text with the
;; golden rendering in test/golden/<name>.txt (docs/DESIGN.md section
;; 13).  `make golden' regenerates the golden files; review the diff
;; against test/reference/showcase.frogmouth.txt before committing it.
;; On a mismatch the test reports the first differing line and writes
;; the actual rendering to test/out/<name>.actual.txt so that it can be
;; diffed against the golden file.

;;; Code:

(require 'ert)
(require 'mdview)

(defconst mdview-golden-test-root
  (file-name-directory
   (directory-file-name
    (file-name-directory (or load-file-name buffer-file-name default-directory))))
  "The repository root (the parent of the test/ directory).")

(defconst mdview-golden-test-width 80
  "Content width at which the golden files were produced.")

(defun mdview-golden-test--path (relative)
  "Return RELATIVE expanded against the repository root."
  (expand-file-name relative mdview-golden-test-root))

(defun mdview-golden-test--fixtures ()
  "Return the sorted list of fixture base names (without .md)."
  (sort (mapcar #'file-name-base
                (directory-files (mdview-golden-test--path "test/fixtures")
                                 nil "\\.md\\'"))
        #'string<))

(defun mdview-golden-test--render (file width)
  "Render the Markdown FILE at WIDTH columns and return the plain text."
  (let* ((file (expand-file-name file))
         (base (file-name-directory file))
         (doc (with-temp-buffer
                (insert-file-contents file)
                (mdview-parse-buffer))))
    (with-temp-buffer
      (let ((default-directory base))
        (mdview-render-document doc :width width :base-dir base))
      (substring-no-properties (buffer-string)))))

(defun mdview-golden-test--read (file)
  "Return the contents of FILE as a string."
  (with-temp-buffer
    (insert-file-contents file)
    (buffer-string)))

(defun mdview-golden-test--diff-message (name expected actual)
  "Describe the first difference between EXPECTED and ACTUAL for fixture NAME."
  (let ((e (split-string expected "\n"))
        (a (split-string actual "\n"))
        (line 1))
    (while (and e a (string= (car e) (car a)))
      (pop e) (pop a) (setq line (1+ line)))
    (format (concat "Golden mismatch for %s.md at line %d:\n"
                    "  golden: %S\n"
                    "  actual: %S\n"
                    "(%d golden lines, %d actual lines; the actual rendering is in "
                    "test/out/%s.actual.txt -- diff it against test/golden/%s.txt and, "
                    "if the change is intended, run `make golden')")
            name line (or (car e) "<end of file>") (or (car a) "<end of file>")
            (length (split-string expected "\n"))
            (length (split-string actual "\n"))
            name name)))

(defun mdview-golden-test--check (name)
  "Fail unless fixture NAME renders exactly like its golden file."
  (let ((fixture (mdview-golden-test--path (format "test/fixtures/%s.md" name)))
        (golden (mdview-golden-test--path (format "test/golden/%s.txt" name))))
    (unless (file-readable-p golden)
      (ert-fail (format "No golden file for %s.md; run `make golden'" name)))
    (let ((expected (mdview-golden-test--read golden))
          (actual (mdview-golden-test--render fixture mdview-golden-test-width)))
      (unless (string= expected actual)
        (let ((out (mdview-golden-test--path (format "test/out/%s.actual.txt" name))))
          (make-directory (file-name-directory out) t)
          (with-temp-file out (insert actual))
          (ert-fail (mdview-golden-test--diff-message name expected actual)))))))

(ert-deftest mdview-golden-showcase ()
  "The showcase fixture renders like test/golden/showcase.txt."
  (mdview-golden-test--check "showcase"))

(ert-deftest mdview-golden-minimal ()
  "The minimal fixture renders like test/golden/minimal.txt."
  (mdview-golden-test--check "minimal"))

(ert-deftest mdview-golden-every-fixture ()
  "Every fixture in test/fixtures/ has a golden file and matches it."
  (let ((fixtures (mdview-golden-test--fixtures)))
    (should fixtures)
    (dolist (name fixtures)
      (mdview-golden-test--check name))))

(ert-deftest mdview-golden-lines-have-the-golden-width ()
  "Every golden line is at most the golden width wide; padded lines exactly.
Code lines longer than the width are the only ones allowed to overflow."
  (dolist (name (mdview-golden-test--fixtures))
    (let ((golden (mdview-golden-test--path (format "test/golden/%s.txt" name))))
      (when (file-readable-p golden)
        (dolist (line (split-string (mdview-golden-test--read golden) "\n" t))
          (should (or (= (string-width line) mdview-golden-test-width)
                      (> (string-width line) mdview-golden-test-width))))))))

(ert-deftest mdview-golden-rendering-is-deterministic ()
  "Rendering the same fixture twice gives identical text."
  (let ((fixture (mdview-golden-test--path "test/fixtures/minimal.md")))
    (should (string= (mdview-golden-test--render fixture 60)
                     (mdview-golden-test--render fixture 60)))))

(provide 'mdview-golden-test)
;;; mdview-golden-test.el ends here
