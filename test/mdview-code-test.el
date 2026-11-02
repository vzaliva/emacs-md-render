;;; mdview-code-test.el --- Tests for mdview-code  -*- lexical-binding: t; -*-

;; This file is part of mdview, distributed under the MIT license; see
;; LICENSE in the repository root.

;;; Commentary:

;; ERT tests for language resolution, fontification, the Material face
;; mapping and indent guides in mdview-code.el (docs/DESIGN.md §8, §13).
;; All tests run headless under `emacs -Q --batch' and do not depend on
;; installed tree-sitter grammars or third-party modes: where those could
;; matter, the environment is pinned with `mdview-code-test-plain-env'.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'mdview-code)

(defvar major-mode-remap-alist)
(defvar major-mode-remap-defaults)

;;;; Fixtures

(define-derived-mode mdview-code-test-fake-mode prog-mode "Fake"
  "A major mode defined only for the tests.")

(define-derived-mode mdview-code-test-lang-mode prog-mode "FakeLang"
  "Classic mode for the pretend language mdview-code-test-lang.")

(define-derived-mode mdview-code-test-lang-ts-mode prog-mode "FakeLangTS"
  "Pretend tree-sitter mode for the language mdview-code-test-lang.")

(define-minor-mode mdview-code-test-minor-mode
  "A minor mode defined only for the tests."
  :global nil)

(defun mdview-code-test-plain-mode ()
  "A function that is not a mode at all."
  nil)

(define-derived-mode mdview-code-test-broken-mode prog-mode "Broken"
  "A major mode whose body signals an error."
  (error "This mode is broken on purpose"))

(define-derived-mode mdview-code-test-mutating-mode prog-mode "Mutating"
  "A major mode that alters the buffer text."
  (goto-char (point-min))
  (insert "oops "))

(define-derived-mode mdview-code-test-special-mode special-mode "FakeSpecial"
  "A `special-mode' descendant, like `tar-mode', defined only for the tests.")

(define-derived-mode mdview-code-test-orphan-mode nil "Orphan"
  "A major mode with no parent, defined only for the tests.")

(define-derived-mode mdview-code-test-conf-mode conf-unix-mode "FakeConf"
  "A `conf-mode' descendant defined only for the tests.")

(defvar mdview-code-test-setup-count 0
  "How often `mdview-code-test-counting-mode' was set up.")

(define-derived-mode mdview-code-test-counting-mode prog-mode "Counting"
  "A major mode that counts its own set-ups and highlights \"counted\"."
  (setq mdview-code-test-setup-count (1+ mdview-code-test-setup-count))
  (setq-local font-lock-defaults '((("counted" . font-lock-keyword-face)))))

(defface mdview-code-test-inherit
  '((t :inherit font-lock-type-face))
  "Test face inheriting from a font-lock face."
  :group 'mdview)

(defface mdview-code-test-inherit-2
  '((t :inherit mdview-code-test-inherit :weight bold))
  "Test face inheriting from `mdview-code-test-inherit'."
  :group 'mdview)

(defface mdview-code-test-cycle-a
  '((t :inherit mdview-code-test-cycle-b))
  "Test face in an inheritance cycle."
  :group 'mdview)

(defface mdview-code-test-cycle-b
  '((t :inherit mdview-code-test-cycle-a))
  "Test face in an inheritance cycle."
  :group 'mdview)

(defconst mdview-code-test-elisp
  "(defun foo (x)\n  \"Doc.\"\n  ;; note\n  (message \"hi\" x))"
  "Emacs Lisp sample with a keyword, a function name, a doc string, a
comment and a string.")

(defconst mdview-code-test-python
  "def f(x):\n    # note\n    return \"s\""
  "Python sample with keywords, a comment and a string.")

(defconst mdview-code-test-material-faces
  '(mdview-code-keyword mdview-code-builtin mdview-code-function
    mdview-code-variable mdview-code-type mdview-code-constant
    mdview-code-string mdview-code-doc mdview-code-comment
    mdview-code-preprocessor mdview-code-number mdview-code-operator
    mdview-code-punctuation mdview-code-property mdview-code-escape
    mdview-code-error)
  "Every token face that mdview-code.el must define.")

;;;; Helpers

(defmacro mdview-code-test-plain-env (&rest body)
  "Run BODY with tree-sitter grammars unavailable and no mode remapping."
  (declare (indent 0))
  `(cl-letf (((symbol-function 'mdview-code--treesit-ready-p)
              (lambda (_language) nil)))
     (let ((major-mode-remap-alist nil)
           (major-mode-remap-defaults nil))
       ,@body)))

(defun mdview-code-test-face-at (string substring)
  "Return the `face' property at the first occurrence of SUBSTRING in STRING."
  (let ((pos (string-search substring string)))
    (should pos)
    (get-text-property pos 'face string)))

(defun mdview-code-test-faces (string)
  "Return the distinct non-nil `face' values of STRING in order of appearance."
  (let ((pos 0) (faces nil))
    (while (< pos (length string))
      (let ((face (get-text-property pos 'face string)))
        (when (and face (not (member face faces)))
          (push face faces)))
      (setq pos (or (next-single-property-change pos 'face string)
                    (length string))))
    (nreverse faces)))

(defun mdview-code-test-property-names (string)
  "Return the list of text property names used anywhere in STRING."
  (let (names)
    (dolist (interval (object-intervals string))
      (let ((plist (nth 2 interval)))
        (while plist
          (cl-pushnew (car plist) names)
          (setq plist (cddr plist)))))
    names))

(defun mdview-code-test-plain-p (result code)
  "Return non-nil when RESULT is CODE with no text properties at all."
  (and (string= result code)
       (null (object-intervals result))))

;;;; Faces and options

(ert-deftest mdview-code-faces-defined ()
  "All sixteen Material token faces exist, are documented and carry no bg."
  (dolist (face mdview-code-test-material-faces)
    (should (facep face))
    (should (stringp (face-documentation face)))
    (should (assq face (get 'mdview 'custom-group)))
    (should (eq (face-attribute face :background) 'unspecified))))

(ert-deftest mdview-code-faces-material-colours ()
  "The token faces carry the Pygments material colours and italics."
  (pcase-dolist (`(,face . ,colour)
                 '((mdview-code-keyword . "#BB80B3")
                   (mdview-code-builtin . "#82AAFF")
                   (mdview-code-function . "#82AAFF")
                   (mdview-code-variable . "#89DDFF")
                   (mdview-code-type . "#FFCB6B")
                   (mdview-code-constant . "#89DDFF")
                   (mdview-code-string . "#C3E88D")
                   (mdview-code-doc . "#546E7A")
                   (mdview-code-comment . "#546E7A")
                   (mdview-code-preprocessor . "#89DDFF")
                   (mdview-code-number . "#F78C6C")
                   (mdview-code-operator . "#89DDFF")
                   (mdview-code-punctuation . "#89DDFF")
                   (mdview-code-property . "#FFCB6B")
                   (mdview-code-escape . "#89DDFF")
                   (mdview-code-error . "#FF5370")))
    (should (equal (face-attribute face :foreground) colour)))
  (dolist (face '(mdview-code-doc mdview-code-comment mdview-code-preprocessor))
    (should (eq (face-attribute face :slant) 'italic)))
  (dolist (face '(mdview-code-keyword mdview-code-string mdview-code-operator))
    (should (eq (face-attribute face :slant) 'unspecified))))

(ert-deftest mdview-code-options-defaults ()
  "The options exist in group `mdview' with the documented defaults."
  (should (= mdview-code-highlight-max-chars 100000))
  (should (eq mdview-code-material-theme t))
  (should (eq mdview-code-indent-guides t))
  (should (= mdview-code-indent-guide-width 4))
  (should (= mdview-code-tab-width 4))
  (dolist (option '(mdview-code-lang-modes mdview-code-highlight-max-chars
                    mdview-code-material-theme mdview-code-face-alist
                    mdview-code-indent-guides mdview-code-indent-guide-width
                    mdview-code-tab-width))
    (should (custom-variable-p option))
    (should (assq option (get 'mdview 'custom-group)))))

(ert-deftest mdview-code-face-alist-well-formed ()
  "Every target of the default face table is a mdview-code face."
  (should (consp mdview-code-face-alist))
  (dolist (entry mdview-code-face-alist)
    (should (symbolp (car entry)))
    (when (cdr entry)
      (should (facep (cdr entry)))
      (should (memq (cdr entry) mdview-code-test-material-faces))))
  (dolist (face '(font-lock-keyword-face font-lock-string-face
                  font-lock-comment-face font-lock-doc-face
                  font-lock-type-face font-lock-constant-face
                  font-lock-builtin-face font-lock-function-name-face
                  font-lock-variable-name-face font-lock-preprocessor-face
                  font-lock-warning-face font-lock-number-face
                  font-lock-operator-face font-lock-escape-face
                  font-lock-regexp-face font-lock-property-name-face
                  font-lock-bracket-face font-lock-delimiter-face))
    (should (assq face mdview-code-face-alist))))

(ert-deftest mdview-code-lang-modes-well-formed ()
  "Keys are lower-case strings; values nil, a symbol or a list of symbols."
  (dolist (entry mdview-code-lang-modes)
    (should (stringp (car entry)))
    (should (equal (car entry) (downcase (car entry))))
    (let ((value (cdr entry)))
      (should (or (null value)
                  (symbolp value)
                  (and (listp value) (cl-every #'symbolp value))))))
  (dolist (name '("elisp" "emacs-lisp" "sh" "bash" "python" "py" "js" "ts"
                  "json" "yaml" "toml" "html" "xml" "css" "c" "cpp" "c++"
                  "java" "go" "rust" "haskell" "ocaml" "lean" "coq" "sql"
                  "latex" "makefile" "diff" "dockerfile" "markdown" "text"))
    (should (assoc name mdview-code-lang-modes))))

;;;; Language resolution

(ert-deftest mdview-code-resolve-builtin-languages ()
  "Common language names resolve to the built-in modes of the table."
  (mdview-code-test-plain-env
    (should (eq (mdview-code-resolve-mode "elisp") 'emacs-lisp-mode))
    (should (eq (mdview-code-resolve-mode "emacs-lisp") 'emacs-lisp-mode))
    (should (eq (mdview-code-resolve-mode "el") 'emacs-lisp-mode))
    (should (eq (mdview-code-resolve-mode "python") 'python-mode))
    (should (eq (mdview-code-resolve-mode "py") 'python-mode))
    (should (eq (mdview-code-resolve-mode "sh") 'sh-mode))
    (should (eq (mdview-code-resolve-mode "bash") 'sh-mode))
    (should (eq (mdview-code-resolve-mode "c++") 'c++-mode))
    (should (eq (mdview-code-resolve-mode "cpp") 'c++-mode))
    (should (eq (mdview-code-resolve-mode "c") 'c-mode))
    (should (eq (mdview-code-resolve-mode "diff") 'diff-mode))
    (should (eq (mdview-code-resolve-mode "json") 'js-json-mode))
    (should (eq (mdview-code-resolve-mode "yaml") 'conf-colon-mode))
    (should (eq (mdview-code-resolve-mode "makefile") 'makefile-gmake-mode))))

(ert-deftest mdview-code-resolve-normalizes-name ()
  "Resolution ignores case, surrounding whitespace, and accepts symbols."
  (mdview-code-test-plain-env
    (should (eq (mdview-code-resolve-mode "ELisp") 'emacs-lisp-mode))
    (should (eq (mdview-code-resolve-mode " Python\t") 'python-mode))
    (should (eq (mdview-code-resolve-mode 'python) 'python-mode))))

(ert-deftest mdview-code-resolve-unknown-and-empty ()
  "Unknown, blank and nil language names resolve to nil."
  (mdview-code-test-plain-env
    (should-not (mdview-code-resolve-mode "no-such-language-xyz"))
    (should-not (mdview-code-resolve-mode ""))
    (should-not (mdview-code-resolve-mode "   "))
    (should-not (mdview-code-resolve-mode nil))
    (should-not (mdview-code-resolve-mode 42))))

(ert-deftest mdview-code-resolve-plain-text ()
  "The text languages are explicitly unhighlighted."
  (mdview-code-test-plain-env
    (dolist (name '("text" "plain" "plaintext" "txt"))
      (should-not (mdview-code-resolve-mode name)))))

(ert-deftest mdview-code-resolve-generic-major-mode ()
  "An unlisted language resolves to LANG-mode when that is a major mode."
  (mdview-code-test-plain-env
    (should (eq (mdview-code-resolve-mode "mdview-code-test-fake")
                'mdview-code-test-fake-mode))
    (should (eq (mdview-code-resolve-mode "awk") 'awk-mode))
    (should (eq (mdview-code-resolve-mode "tcl") 'tcl-mode))))

(ert-deftest mdview-code-resolve-rejects-non-major-modes ()
  "Minor modes, plain functions and commands ending in -mode are not used."
  (mdview-code-test-plain-env
    (should-not (mdview-code-resolve-mode "mdview-code-test-minor"))
    (should-not (mdview-code-resolve-mode "mdview-code-test-plain"))
    (should-not (mdview-code-resolve-mode "describe"))
    (should-not (mdview-code-resolve-mode "normal"))
    (should-not (mdview-code-resolve-mode "view"))))

(ert-deftest mdview-code-resolve-rejects-special-and-orphan-modes ()
  "Guessed modes must derive from prog-mode, text-mode or conf-mode.
`tar-mode' and friends signal on arbitrary text; a table entry may still
name any mode explicitly."
  (mdview-code-test-plain-env
    (dolist (name '("tar" "tabulated-list" "help" "special"
                    "mdview-code-test-special" "mdview-code-test-orphan"))
      (should-not (mdview-code-resolve-mode name)))
    (should (eq (mdview-code-resolve-mode "mdview-code-test-conf")
                'mdview-code-test-conf-mode))
    (should (eq (mdview-code-resolve-mode "conf-unix") 'conf-unix-mode))
    (should (eq (mdview-code-resolve-mode "awk") 'awk-mode))
    (should (eq (mdview-code-resolve-mode "nroff") 'nroff-mode))
    (should (mdview-code--text-mode-p 'text-mode))
    (should (mdview-code--text-mode-p 'prog-mode))
    (should (mdview-code--text-mode-p 'conf-mode))
    (should (mdview-code--text-mode-p 'emacs-lisp-mode))
    (should-not (mdview-code--text-mode-p 'fundamental-mode))
    (should-not (mdview-code--text-mode-p 'special-mode))
    (should-not (mdview-code--text-mode-p nil))
    ;; Listed explicitly, a mode of any lineage is accepted.
    (let ((mdview-code-lang-modes '(("orphan" . mdview-code-test-orphan-mode))))
      (should (eq (mdview-code-resolve-mode "orphan")
                  'mdview-code-test-orphan-mode)))))

(ert-deftest mdview-code-fontify-tar-block-is-plain-and-silent ()
  "A fence labelled tar renders as plain text without any message."
  (let ((messages nil))
    (cl-letf (((symbol-function 'message)
               (lambda (fmt &rest args)
                 (when fmt (push (apply #'format fmt args) messages))
                 nil)))
      (mdview-code-test-plain-env
        (should (mdview-code-test-plain-p (mdview-code-fontify "some text" "tar")
                                          "some text"))
        (should (mdview-code-test-plain-p (mdview-code-fontify "x" "help") "x"))))
    (should (null messages))))

(ert-deftest mdview-code-resolve-prefers-ready-treesit-mode ()
  "LANG-ts-mode wins when its grammar is ready, else LANG-mode."
  (cl-letf (((symbol-function 'mdview-code--treesit-ready-p)
             (lambda (language) (eq language 'mdview-code-test-lang))))
    (let ((major-mode-remap-alist nil) (major-mode-remap-defaults nil))
      (should (eq (mdview-code-resolve-mode "mdview-code-test-lang")
                  'mdview-code-test-lang-ts-mode))))
  (mdview-code-test-plain-env
    (should (eq (mdview-code-resolve-mode "mdview-code-test-lang")
                'mdview-code-test-lang-mode))))

(ert-deftest mdview-code-resolve-alist-candidates ()
  "Table entries try their candidates in order and are authoritative."
  (let ((mdview-code-lang-modes
         '(("one" . emacs-lisp-mode)
           ("two" no-such-mode-xyz mdview-code-test-lang-ts-mode
            mdview-code-test-lang-mode)
           ("three")
           ("mdview-code-test-fake" no-such-mode-xyz))))
    (mdview-code-test-plain-env
      (should (eq (mdview-code-resolve-mode "one") 'emacs-lisp-mode))
      ;; The ts candidate is skipped because its grammar is not ready.
      (should (eq (mdview-code-resolve-mode "two") 'mdview-code-test-lang-mode))
      (should-not (mdview-code-resolve-mode "three"))
      ;; Listed with no available mode: the generic guess is not consulted.
      (should-not (mdview-code-resolve-mode "mdview-code-test-fake")))
    (cl-letf (((symbol-function 'mdview-code--treesit-ready-p)
               (lambda (_language) t)))
      (let ((major-mode-remap-alist nil) (major-mode-remap-defaults nil))
        (should (eq (mdview-code-resolve-mode "two")
                    'mdview-code-test-lang-ts-mode))))))

(ert-deftest mdview-code-resolve-markdown-only-if-installed ()
  "md uses markdown-mode when it exists and never falls back to md-mode."
  (mdview-code-test-plain-env
    (should (eq (mdview-code-resolve-mode "md")
                (and (fboundp 'markdown-mode) 'markdown-mode)))))

(ert-deftest mdview-code-resolve-honours-major-mode-remap ()
  "A user remapping is honoured when the preferred mode is available."
  (skip-unless (fboundp 'major-mode-remap))
  (cl-letf (((symbol-function 'mdview-code--treesit-ready-p)
             (lambda (_language) nil)))
    (let ((major-mode-remap-defaults nil)
          (major-mode-remap-alist
           '((emacs-lisp-mode . mdview-code-test-fake-mode)
             (python-mode . no-such-mode-xyz))))
      (should (eq (mdview-code-resolve-mode "elisp") 'mdview-code-test-fake-mode))
      (should (eq (mdview-code-resolve-mode "python") 'python-mode)))))

;;;; Fontification

(ert-deftest mdview-code-fontify-elisp ()
  "Emacs Lisp gets keyword, function, doc, comment and string faces."
  (mdview-code-test-plain-env
    (let ((result (mdview-code-fontify mdview-code-test-elisp "elisp")))
      (should (string= result mdview-code-test-elisp))
      (should (eq (mdview-code-test-face-at result "defun") 'mdview-code-keyword))
      (should (eq (mdview-code-test-face-at result "foo") 'mdview-code-function))
      (should (eq (mdview-code-test-face-at result "\"Doc.\"") 'mdview-code-doc))
      (should (eq (mdview-code-test-face-at result ";; note") 'mdview-code-comment))
      (should (eq (mdview-code-test-face-at result "\"hi\"") 'mdview-code-string))
      (should-not (mdview-code-test-face-at result "(x)")))))

(ert-deftest mdview-code-fontify-python ()
  "Python gets keyword, comment and string faces."
  (mdview-code-test-plain-env
    (let ((result (mdview-code-fontify mdview-code-test-python "python")))
      (should (string= result mdview-code-test-python))
      (should (eq (mdview-code-test-face-at result "def") 'mdview-code-keyword))
      (should (eq (mdview-code-test-face-at result "return") 'mdview-code-keyword))
      (should (eq (mdview-code-test-face-at result "# note") 'mdview-code-comment))
      (should (eq (mdview-code-test-face-at result "\"s\"") 'mdview-code-string)))))

(ert-deftest mdview-code-fontify-other-builtin-modes ()
  "Shell, C, JSON and diff samples pick up the expected Material faces."
  (mdview-code-test-plain-env
    (let ((sh (mdview-code-fontify "if true; then echo \"hi\"; fi # c" "sh")))
      (should (eq (mdview-code-test-face-at sh "if") 'mdview-code-keyword))
      (should (eq (mdview-code-test-face-at sh "echo") 'mdview-code-builtin))
      (should (eq (mdview-code-test-face-at sh "\"hi\"") 'mdview-code-string))
      (should (eq (mdview-code-test-face-at sh "# c") 'mdview-code-comment)))
    (let ((c (mdview-code-fontify "#include <x.h>\nint main(void);" "c")))
      (should (eq (mdview-code-test-face-at c "#include") 'mdview-code-preprocessor))
      (should (eq (mdview-code-test-face-at c "int") 'mdview-code-type))
      (should (eq (mdview-code-test-face-at c "main") 'mdview-code-function)))
    (let ((json (mdview-code-fontify "{\"a\": 1}" "json")))
      (should (eq (mdview-code-test-face-at json "\"a\"") 'mdview-code-string)))
    (let ((diff (mdview-code-fontify "@@ -1 +1 @@\n-old\n+new" "diff")))
      (should (eq (mdview-code-test-face-at diff "-old") 'mdview-code-error))
      ;; The last line has no newline in the AST; it is still fontified.
      (should (eq (mdview-code-test-face-at diff "+new") 'mdview-code-string)))))

(ert-deftest mdview-code-fontify-unknown-language-is-plain ()
  "An unknown or missing language yields the text without any property."
  (mdview-code-test-plain-env
    (let ((code "some (text) \"with\" ;; markers"))
      (should (mdview-code-test-plain-p
               (mdview-code-fontify code "no-such-language-xyz") code))
      (should (mdview-code-test-plain-p (mdview-code-fontify code nil) code))
      (should (mdview-code-test-plain-p (mdview-code-fontify code "text") code)))))

(ert-deftest mdview-code-fontify-material-theme-off-keeps-faces ()
  "With `mdview-code-material-theme' nil the mode's faces are kept."
  (mdview-code-test-plain-env
    (let* ((mdview-code-material-theme nil)
           (result (mdview-code-fontify mdview-code-test-elisp "elisp")))
      (should (eq (mdview-code-test-face-at result "defun") 'font-lock-keyword-face))
      (should (eq (mdview-code-test-face-at result "\"hi\"") 'font-lock-string-face))
      (should (equal (mdview-code-test-property-names result) '(face))))))

(ert-deftest mdview-code-fontify-oversize-is-plain ()
  "Code longer than `mdview-code-highlight-max-chars' is not highlighted."
  (mdview-code-test-plain-env
    (let ((mdview-code-highlight-max-chars 5))
      (should (mdview-code-test-plain-p
               (mdview-code-fontify mdview-code-test-elisp "elisp")
               mdview-code-test-elisp)))
    (let ((mdview-code-highlight-max-chars (length mdview-code-test-elisp)))
      (should (eq (mdview-code-test-face-at
                   (mdview-code-fontify mdview-code-test-elisp "elisp") "defun")
                  'mdview-code-keyword)))))

(ert-deftest mdview-code-fontify-preserves-text-exactly ()
  "The result has the characters of CODE: no trailing newline is added."
  (mdview-code-test-plain-env
    (dolist (code (list mdview-code-test-elisp mdview-code-test-python
                        "x = 1" "" "a\n\nb" "(a)\n"))
      (dolist (lang '("elisp" "python" nil))
        (let ((result (mdview-code-fontify code lang)))
          (should (string= result code))
          (should (= (length (split-string result "\n"))
                     (length (split-string code "\n"))))
          (should (eq (string-suffix-p "\n" result)
                      (string-suffix-p "\n" code))))))))

(ert-deftest mdview-code-fontify-only-face-property ()
  "Fontified text carries `face' and nothing else (no fontified, syntax-table)."
  (mdview-code-test-plain-env
    (dolist (spec `((,mdview-code-test-elisp . "elisp")
                    (,mdview-code-test-python . "python")
                    ("echo \"$HOME\" # c" . "sh")))
      (let ((result (mdview-code-fontify (car spec) (cdr spec))))
        (should (equal (mdview-code-test-property-names result) '(face)))
        (dolist (face (mdview-code-test-faces result))
          (should (memq face mdview-code-test-material-faces)))))))

(ert-deftest mdview-code-fontify-multibyte-positions ()
  "Face runs line up with characters, not bytes, in multibyte code."
  (mdview-code-test-plain-env
    (let* ((code "s = \"héllo\"  # ç\nt = 1")
           (result (mdview-code-fontify code "python"))
           (start (string-search "\"héllo\"" result)))
      (should (eq (get-text-property start 'face result) 'mdview-code-string))
      (should (= (next-single-property-change start 'face result)
                 (+ start (length "\"héllo\""))))
      (should (eq (mdview-code-test-face-at result "# ç") 'mdview-code-comment)))))

(ert-deftest mdview-code-fontify-broken-mode-is-plain ()
  "A mode that signals during setup yields plain text, silently by default.
With `mdview-code-debug' the failure is reported; the broken mode's
scratch buffer is discarded either way."
  (let ((mdview-code-lang-modes '(("broken" . mdview-code-test-broken-mode)))
        (code "some code")
        (messages nil))
    (mdview-code-test-plain-env
      (should (eq (mdview-code-resolve-mode "broken") 'mdview-code-test-broken-mode))
      (cl-letf (((symbol-function 'message)
                 (lambda (fmt &rest args)
                   (when fmt (push (apply #'format fmt args) messages))
                   nil)))
        (should (mdview-code-test-plain-p (mdview-code-fontify code "broken")
                                          code))
        (should (null messages))
        (let ((mdview-code-debug t))
          (should (mdview-code-test-plain-p (mdview-code-fontify code "broken")
                                            code)))
        (should (= (length messages) 1))
        (should (string-prefix-p "mdview-code: highlighting failed"
                                 (car messages))))
      (should-not (get-buffer " *mdview-code:mdview-code-test-broken-mode*")))))

(ert-deftest mdview-code-fontify-mutating-mode-is-plain ()
  "A mode that changes the buffer text is ignored and its scratch buffer dropped."
  (let ((mdview-code-lang-modes '(("mutating" . mdview-code-test-mutating-mode)))
        (code "some code"))
    (mdview-code-test-plain-env
      (should (mdview-code-test-plain-p (mdview-code-fontify code "mutating") code))
      (should-not (get-buffer " *mdview-code:mdview-code-test-mutating-mode*"))
      ;; Every call fails afresh: nothing is memoized for it.
      (should (mdview-code-test-plain-p (mdview-code-fontify code "mutating") code)))))

(ert-deftest mdview-code-fontify-reuses-scratch-buffer-per-mode ()
  "The major mode is set up once per mode; later blocks reuse its buffer."
  (let ((mdview-code-lang-modes '(("counting" . mdview-code-test-counting-mode)))
        (name " *mdview-code:mdview-code-test-counting-mode*"))
    (mdview-code-test-plain-env
      (mdview-code-clear-cache)
      (setq mdview-code-test-setup-count 0)
      (let ((first (mdview-code-fontify "counted x" "counting"))
            (second (mdview-code-fontify "y counted" "counting"))
            (third (mdview-code-fontify "" "counting")))
        (should (= mdview-code-test-setup-count 1))
        (should (eq (mdview-code-test-face-at first "counted") 'mdview-code-keyword))
        ;; The second block is fontified too (font-lock state is reset).
        (should (eq (mdview-code-test-face-at second "counted") 'mdview-code-keyword))
        (should-not (mdview-code-test-face-at second "y"))
        (should (equal third "")))
      (should (buffer-live-p (get-buffer name)))
      (should (= (length (seq-filter (lambda (b) (equal (buffer-name b) name))
                                     (buffer-list)))
                 1))
      (should (string-prefix-p " " name))
      (with-current-buffer name
        (should (eq major-mode 'mdview-code-test-counting-mode))
        (should-not font-lock-mode))
      (mdview-code-clear-cache)
      (should-not (get-buffer name)))))

(ert-deftest mdview-code-fontify-memoized ()
  "Identical blocks are fontified once; callers get fresh copies."
  (let ((calls 0)
        (orig (symbol-function 'mdview-code--fontify-with-mode)))
    (mdview-code-test-plain-env
      (mdview-code-clear-cache)
      (cl-letf (((symbol-function 'mdview-code--fontify-with-mode)
                 (lambda (code mode) (cl-incf calls) (funcall orig code mode))))
        (let ((a (mdview-code-fontify mdview-code-test-elisp "elisp"))
              (b (mdview-code-fontify mdview-code-test-elisp "elisp")))
          (should (= calls 1))
          (should (equal-including-properties a b))
          (should-not (eq a b))
          (should (eq (mdview-code-test-face-at b "defun") 'mdview-code-keyword))
          ;; "el" resolves to the same mode: the entry is shared.
          (mdview-code-fontify mdview-code-test-elisp "el")
          (should (= calls 1))
          ;; Options are part of the key.
          (let ((mdview-code-material-theme nil))
            (should (eq (mdview-code-test-face-at
                         (mdview-code-fontify mdview-code-test-elisp "elisp")
                         "defun")
                        'font-lock-keyword-face)))
          (should (= calls 2))
          (let ((mdview-code-face-alist '((font-lock-keyword-face . mdview-code-error))))
            (should (eq (mdview-code-test-face-at
                         (mdview-code-fontify mdview-code-test-elisp "elisp")
                         "defun")
                        'mdview-code-error)))
          (should (= calls 3))
          ;; Altering a returned string does not poison the memo.
          (put-text-property 0 5 'face 'bold a)
          (should (equal-including-properties
                   (mdview-code-fontify mdview-code-test-elisp "elisp") b))
          (should (= calls 3))
          ;; Other code is fontified, and the memo can be emptied.
          (mdview-code-fontify "(bar)" "elisp")
          (should (= calls 4))
          (mdview-code-clear-cache)
          (should (zerop (hash-table-count mdview-code--cache)))
          (mdview-code-fontify mdview-code-test-elisp "elisp")
          (should (= calls 5)))))))

(ert-deftest mdview-code-fontify-memo-is-bounded ()
  "The memo is emptied when the code it holds would exceed its limit."
  (mdview-code-test-plain-env
    (mdview-code-clear-cache)
    (cl-letf (((symbol-value 'mdview-code--cache-max-chars) 30))
      (mdview-code-fontify "(a)" "elisp")
      (mdview-code-fontify "(bb)" "elisp")
      (should (= (hash-table-count mdview-code--cache) 2))
      (should (= mdview-code--cache-chars 7))
      (mdview-code-fontify (make-string 25 ?x) "elisp")
      (should (= (hash-table-count mdview-code--cache) 1))
      (should (= mdview-code--cache-chars 25)))
    (mdview-code-clear-cache)))

(ert-deftest mdview-code-fontify-non-string-code ()
  "Non-string CODE is treated as empty rather than signalling."
  (should (equal (mdview-code-fontify nil "elisp") ""))
  (should (equal (mdview-code-fontify "" "elisp") "")))

;;;; Face mapping

(ert-deftest mdview-code-map-face-symbols ()
  "Font-lock faces map directly or through inheritance; others to nil."
  (should (eq (mdview-code-map-face 'font-lock-keyword-face) 'mdview-code-keyword))
  (should (eq (mdview-code-map-face 'font-lock-string-face) 'mdview-code-string))
  (should (eq (mdview-code-map-face 'font-lock-warning-face) 'mdview-code-error))
  ;; Inherits from font-lock-comment-face.
  (should (eq (mdview-code-map-face 'font-lock-comment-delimiter-face)
              'mdview-code-comment))
  ;; Inherits from font-lock-function-name-face.
  (should (eq (mdview-code-map-face 'font-lock-function-call-face)
              'mdview-code-function))
  ;; Explicit entries beat inheritance (escape inherits from bold).
  (should (eq (mdview-code-map-face 'font-lock-escape-face) 'mdview-code-escape))
  (should (eq (mdview-code-map-face 'font-lock-doc-markup-face) 'mdview-code-doc))
  (should-not (mdview-code-map-face 'bold))
  (should-not (mdview-code-map-face 'default))
  (should-not (mdview-code-map-face nil))
  (should-not (mdview-code-map-face 'no-such-face-xyz)))

(ert-deftest mdview-code-map-face-inheritance ()
  "User faces inheriting (even indirectly) from a mapped face map too."
  (should (eq (mdview-code-map-face 'mdview-code-test-inherit) 'mdview-code-type))
  (should (eq (mdview-code-map-face 'mdview-code-test-inherit-2) 'mdview-code-type))
  ;; A cycle terminates with nil instead of looping.
  (should-not (mdview-code-map-face 'mdview-code-test-cycle-a))
  ;; Material faces themselves are left alone.
  (should (eq (mdview-code-map-face 'mdview-code-keyword) 'mdview-code-keyword)))

(ert-deftest mdview-code-map-face-lists-and-plists ()
  "Lists, anonymous faces, strings and colour conses are handled."
  (should (eq (mdview-code-map-face '(bold font-lock-string-face))
              'mdview-code-string))
  ;; First mapped face in a list wins.
  (should (eq (mdview-code-map-face '(font-lock-type-face font-lock-string-face))
              'mdview-code-type))
  (should-not (mdview-code-map-face '(bold italic)))
  (should (eq (mdview-code-map-face '(:inherit font-lock-comment-face :weight bold))
              'mdview-code-comment))
  (should (eq (mdview-code-map-face '(:inherit (bold font-lock-type-face)))
              'mdview-code-type))
  (should-not (mdview-code-map-face '(:foreground "red")))
  (should-not (mdview-code-map-face '(foreground-color . "red")))
  (should-not (mdview-code-map-face '(background-color . "red")))
  (should (eq (mdview-code-map-face "font-lock-keyword-face") 'mdview-code-keyword))
  (should (eq (mdview-code-map-face '((:foreground "red") font-lock-number-face))
              'mdview-code-number)))

(ert-deftest mdview-code-map-face-custom-table ()
  "`mdview-code-face-alist' is consulted before inheritance and may drop."
  (let ((mdview-code-face-alist '((bold . mdview-code-error)
                                  (font-lock-keyword-face . nil))))
    (should (eq (mdview-code-map-face 'bold) 'mdview-code-error))
    (should-not (mdview-code-map-face 'font-lock-keyword-face))
    ;; font-lock-regexp-grouping-backslash inherits from bold.
    (should (eq (mdview-code-map-face 'font-lock-regexp-grouping-backslash)
                'mdview-code-error))))

;;;; Indent guides

(ert-deftest mdview-code-indent-guides-spaces ()
  "Guides at columns 0, 4, 8 for space indentation of 4 and 8."
  (let ((four (mdview-code-indent-guides "    x"))
        (eight (mdview-code-indent-guides "        x")))
    (should (string= four "│   x"))
    (should (eq (get-text-property 0 'face four) 'mdview-code-indent-guide))
    (should-not (get-text-property 1 'face four))
    (should-not (get-text-property 4 'face four))
    (should (string= eight "│   │   x"))
    (should (eq (get-text-property 0 'face eight) 'mdview-code-indent-guide))
    (should (eq (get-text-property 4 'face eight) 'mdview-code-indent-guide))
    (should-not (get-text-property 5 'face eight))
    (should (string= (mdview-code-indent-guides "            x") "│   │   │   x"))))

(ert-deftest mdview-code-indent-guides-partial-indent ()
  "Only complete indent units get a guide, as in Rich (and Frogmouth)."
  (should (string= (mdview-code-indent-guides "  x") "  x"))
  (should (string= (mdview-code-indent-guides "      x") "│     x"))
  (should (string= (mdview-code-indent-guides "   x") "   x"))
  (should (string= (mdview-code-indent-guides "     x") "│    x")))

(ert-deftest mdview-code-indent-guides-tabs ()
  "Tabs expand to `mdview-code-tab-width' columns before guides are drawn."
  (should (string= (mdview-code-indent-guides "\tx") "│   x"))
  (should (string= (mdview-code-indent-guides "\t\tx") "│   │   x"))
  (should (string= (mdview-code-indent-guides "  \tx") "│   x"))
  (should (string= (mdview-code-indent-guides "\t  x") "│     x"))
  (let ((result (mdview-code-indent-guides "\t\tx")))
    (should (eq (get-text-property 0 'face result) 'mdview-code-indent-guide))
    (should (eq (get-text-property 4 'face result) 'mdview-code-indent-guide)))
  (let ((mdview-code-tab-width 8))
    (should (string= (mdview-code-indent-guides "\tx") "│   │   x"))
    (should (string= (mdview-code-indent-guides "    \tx") "│   │   x"))))

(ert-deftest mdview-code-indent-guides-width ()
  "`mdview-code-indent-guide-width' sets the spacing of the guides."
  (let ((mdview-code-indent-guide-width 2))
    (should (string= (mdview-code-indent-guides "    x") "│ │ x"))
    (should (string= (mdview-code-indent-guides "  x") "│ x"))
    (should (string= (mdview-code-indent-guides "   x") "│  x")))
  (let ((mdview-code-indent-guide-width 8))
    (should (string= (mdview-code-indent-guides "    x") "    x"))
    (should (string= (mdview-code-indent-guides "        x") "│       x")))
  (let ((mdview-code-indent-guide-width 1))
    (should (string= (mdview-code-indent-guides "   x") "│││x"))))

(ert-deftest mdview-code-indent-guides-unchanged-lines ()
  "Unindented, empty and whitespace-only lines come back untouched."
  (dolist (line '("x" "" "    " "\t" " \t " "x    y"))
    (should (eq (mdview-code-indent-guides line) line))))

(ert-deftest mdview-code-indent-guides-disabled ()
  "With `mdview-code-indent-guides' nil lines are returned as they are."
  (let ((mdview-code-indent-guides nil))
    (dolist (line '("    x" "\tx" "        x"))
      (should (eq (mdview-code-indent-guides line) line)))))

(ert-deftest mdview-code-indent-guides-keep-properties ()
  "Properties of the rest of the line and of untouched whitespace survive."
  (let* ((line (concat (propertize "        " 'face 'mdview-code-string)
                       (propertize "foo" 'face 'mdview-code-keyword)))
         (result (mdview-code-indent-guides line)))
    (should (string= result "│   │   foo"))
    (should (eq (get-text-property 0 'face result) 'mdview-code-indent-guide))
    (should (eq (get-text-property 1 'face result) 'mdview-code-string))
    (should (eq (get-text-property 3 'face result) 'mdview-code-string))
    (should (eq (get-text-property 4 'face result) 'mdview-code-indent-guide))
    (should (eq (get-text-property 7 'face result) 'mdview-code-string))
    (should (eq (get-text-property 8 'face result) 'mdview-code-keyword))
    (should (eq (get-text-property 10 'face result) 'mdview-code-keyword)))
  ;; A tab's properties go to the spaces that replace it.
  (let ((result (mdview-code-indent-guides
                 (concat (propertize "\t" 'face 'mdview-code-string) "x"))))
    (should (string= result "│   x"))
    (should (eq (get-text-property 2 'face result) 'mdview-code-string))))

(ert-deftest mdview-code-indent-guides-ascii-glyph ()
  "The ASCII glyph profile is honoured for the guide character."
  (let ((mdview-use-ascii-glyphs t))
    (should (string= (mdview-code-indent-guides "        x") "|   |   x"))))

(ert-deftest mdview-code-indent-guides-lines-continue-through-blanks ()
  "The list helper carries guides into blank lines before an indented line."
  (should (equal (mdview-code-indent-guides-lines
                  '("a" "    b" "" "    c" "" "d" ""))
                 '("a" "│   b" "│   " "│   c" "" "d" "")))
  (should (equal (mdview-code-indent-guides-lines '("" "  " "        x" "   "))
                 '("│   │   " "│   │   " "│   │   x" "   ")))
  (should (equal (mdview-code-indent-guides-lines nil) nil))
  (let ((mdview-code-indent-guides nil))
    (should (equal (mdview-code-indent-guides-lines '("" "    x"))
                   '("" "    x")))))

(provide 'mdview-code-test)
;;; mdview-code-test.el ends here
