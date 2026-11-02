;;; mdview-code.el --- Code block fontification for mdview  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Vadim Zaliva

;; Author: Vadim Zaliva
;; Keywords: text, docs, faces
;; Package-Requires: ((emacs "29.1"))

;; This file is part of mdview, distributed under the MIT license; see
;; LICENSE in the repository root.

;;; Commentary:

;; Syntax highlighting of fenced and indented code blocks (docs/DESIGN.md
;; section 8).  `mdview-code-fontify' resolves the language name of a
;; block to a major mode (`mdview-code-lang-modes' first, then
;; `LANG-ts-mode' when its grammar is installed, then `LANG-mode'),
;; fontifies the code with that mode in a temporary buffer with every
;; hook suppressed, and maps the resulting font-lock faces to the
;; `mdview-code-*' faces, which carry the colours of the Pygments
;; "material" theme that Frogmouth uses.  An unknown language, a block
;; larger than `mdview-code-highlight-max-chars' or any failure yields the
;; plain text, which the renderer paints with `mdview-code-block'.
;; `mdview-code-indent-guides' draws Rich-style indentation guides in the
;; leading whitespace of a line.
;;
;; Nothing here prompts, downloads a grammar or starts a process on its
;; own: tree-sitter modes are used only when `treesit-ready-p' already
;; succeeds, and a mode guessed from the language name must be a major
;; mode defined with `define-derived-mode'.  Everything works under
;; `emacs -Q --batch', where `font-lock-ensure' fontifies even though
;; `font-lock-mode' itself stays off.

;;; Code:

(require 'seq)
(require 'subr-x)
(require 'mdview-faces)

(declare-function treesit-available-p "treesit.c" ())
(declare-function treesit-ready-p "treesit" (language &optional quiet))
(declare-function major-mode-remap "files" (mode))

;;;; Faces (Pygments "material" colours, drawn on the #263238 block)

(defface mdview-code-keyword
  '((t :foreground "#BB80B3"))
  "Face for keywords in code blocks."
  :group 'mdview)

(defface mdview-code-builtin
  '((t :foreground "#82AAFF"))
  "Face for built-in names in code blocks."
  :group 'mdview)

(defface mdview-code-function
  '((t :foreground "#82AAFF"))
  "Face for function names and calls in code blocks."
  :group 'mdview)

(defface mdview-code-variable
  '((t :foreground "#89DDFF"))
  "Face for variable names and uses in code blocks."
  :group 'mdview)

(defface mdview-code-type
  '((t :foreground "#FFCB6B"))
  "Face for type names in code blocks."
  :group 'mdview)

(defface mdview-code-constant
  '((t :foreground "#89DDFF"))
  "Face for constants in code blocks."
  :group 'mdview)

(defface mdview-code-string
  '((t :foreground "#C3E88D"))
  "Face for strings in code blocks."
  :group 'mdview)

(defface mdview-code-doc
  '((t :foreground "#546E7A" :slant italic))
  "Face for documentation strings in code blocks."
  :group 'mdview)

(defface mdview-code-comment
  '((t :foreground "#546E7A" :slant italic))
  "Face for comments in code blocks."
  :group 'mdview)

(defface mdview-code-preprocessor
  '((t :foreground "#89DDFF" :slant italic))
  "Face for preprocessor directives in code blocks."
  :group 'mdview)

(defface mdview-code-number
  '((t :foreground "#F78C6C"))
  "Face for numbers in code blocks."
  :group 'mdview)

(defface mdview-code-operator
  '((t :foreground "#89DDFF"))
  "Face for operators in code blocks."
  :group 'mdview)

(defface mdview-code-punctuation
  '((t :foreground "#89DDFF"))
  "Face for brackets, delimiters and other punctuation in code blocks."
  :group 'mdview)

(defface mdview-code-property
  '((t :foreground "#FFCB6B"))
  "Face for property and field names in code blocks."
  :group 'mdview)

(defface mdview-code-escape
  '((t :foreground "#89DDFF"))
  "Face for escape sequences and regexp constructs in code blocks."
  :group 'mdview)

(defface mdview-code-error
  '((t :foreground "#FF5370"))
  "Face for warnings and errors in code blocks."
  :group 'mdview)

(defconst mdview-code-faces
  '(mdview-code-keyword mdview-code-builtin mdview-code-function
    mdview-code-variable mdview-code-type mdview-code-constant
    mdview-code-string mdview-code-doc mdview-code-comment
    mdview-code-preprocessor mdview-code-number mdview-code-operator
    mdview-code-punctuation mdview-code-property mdview-code-escape
    mdview-code-error)
  "The token faces of code blocks, the targets of `mdview-code-face-alist'.")

;;;; Options

(defcustom mdview-code-lang-modes
  '(;; Lisps
    ("elisp" . emacs-lisp-mode) ("emacs-lisp" . emacs-lisp-mode)
    ("el" . emacs-lisp-mode)
    ("lisp" . lisp-mode) ("common-lisp" . lisp-mode) ("cl" . lisp-mode)
    ("scheme" . scheme-mode) ("racket" racket-mode scheme-mode)
    ("clojure" clojure-ts-mode clojure-mode lisp-mode)
    ("clj" clojure-ts-mode clojure-mode lisp-mode)
    ("cljs" clojure-ts-mode clojure-mode lisp-mode)
    ("edn" clojure-ts-mode clojure-mode lisp-mode)
    ;; Shells
    ("sh" . sh-mode) ("bash" . sh-mode) ("zsh" . sh-mode) ("shell" . sh-mode)
    ("console" . sh-mode) ("shell-session" . sh-mode) ("fish" fish-mode)
    ("powershell" powershell-mode) ("ps1" powershell-mode)
    ;; Scripting languages
    ("python" . python-mode) ("py" . python-mode) ("python3" . python-mode)
    ("ruby" . ruby-mode) ("rb" . ruby-mode)
    ("perl" . perl-mode) ("pl" . perl-mode)
    ("lua" lua-ts-mode lua-mode)
    ("r" ess-r-mode R-mode r-mode)
    ("julia" julia-ts-mode julia-mode) ("jl" julia-ts-mode julia-mode)
    ("tcl" . tcl-mode) ("awk" . awk-mode) ("php" php-ts-mode php-mode)
    ;; Web
    ("js" . js-mode) ("javascript" . js-mode) ("mjs" . js-mode)
    ("cjs" . js-mode) ("jsx" . js-jsx-mode)
    ("ts" typescript-ts-mode typescript-mode)
    ("typescript" typescript-ts-mode typescript-mode)
    ("tsx" tsx-ts-mode typescript-mode)
    ("json" json-ts-mode js-json-mode json-mode)
    ("jsonc" json-ts-mode js-json-mode json-mode)
    ("json5" json-ts-mode js-json-mode json-mode)
    ("html" . html-mode) ("htm" . html-mode) ("xhtml" . html-mode)
    ("xml" . sgml-mode) ("svg" . sgml-mode)
    ("css" . css-mode) ("scss" . scss-mode) ("less" . less-css-mode)
    ("graphql" graphql-mode)
    ;; Data and configuration
    ("yaml" yaml-ts-mode yaml-mode conf-colon-mode)
    ("yml" yaml-ts-mode yaml-mode conf-colon-mode)
    ("toml" toml-ts-mode conf-toml-mode)
    ("ini" . conf-windows-mode) ("conf" . conf-mode) ("cfg" . conf-mode)
    ("properties" . conf-javaprop-mode)
    ("proto" protobuf-mode) ("protobuf" protobuf-mode)
    ("terraform" terraform-mode hcl-mode) ("hcl" hcl-mode)
    ("dot" graphviz-dot-mode) ("graphviz" graphviz-dot-mode)
    ;; Systems languages
    ("c" . c-mode) ("h" . c-mode)
    ("cpp" . c++-mode) ("c++" . c++-mode) ("cc" . c++-mode)
    ("cxx" . c++-mode) ("hpp" . c++-mode) ("hh" . c++-mode)
    ("objc" . objc-mode) ("objective-c" . objc-mode)
    ("java" . java-mode)
    ("kotlin" kotlin-ts-mode kotlin-mode) ("kt" kotlin-ts-mode kotlin-mode)
    ("scala" scala-ts-mode scala-mode)
    ("groovy" groovy-mode) ("gradle" groovy-mode)
    ("csharp" csharp-ts-mode csharp-mode) ("cs" csharp-ts-mode csharp-mode)
    ("c#" csharp-ts-mode csharp-mode)
    ("go" go-ts-mode go-mode) ("golang" go-ts-mode go-mode)
    ("rust" rust-ts-mode rust-mode rustic-mode)
    ("rs" rust-ts-mode rust-mode rustic-mode)
    ("swift" swift-mode) ("dart" dart-mode) ("zig" zig-ts-mode zig-mode)
    ("asm" . asm-mode) ("nasm" nasm-mode asm-mode)
    ("fortran" . fortran-mode) ("f90" . f90-mode) ("pascal" . pascal-mode)
    ("ada" ada-mode) ("verilog" . verilog-mode) ("vhdl" . vhdl-mode)
    ("octave" . octave-mode) ("matlab" matlab-mode octave-mode)
    ;; Functional languages and proof assistants
    ("haskell" haskell-mode) ("hs" haskell-mode)
    ("ocaml" tuareg-mode caml-mode) ("ml" tuareg-mode caml-mode)
    ("fsharp" fsharp-mode) ("fs" fsharp-mode)
    ("sml" sml-mode) ("standard-ml" sml-mode)
    ("erlang" erlang-mode) ("erl" erlang-mode)
    ("elixir" elixir-ts-mode elixir-mode) ("ex" elixir-ts-mode elixir-mode)
    ("exs" elixir-ts-mode elixir-mode) ("heex" heex-ts-mode)
    ("lean" lean4-mode lean-mode) ("lean4" lean4-mode)
    ("coq" coq-mode) ("rocq" coq-mode)
    ("agda" agda2-mode) ("idris" idris-mode idris2-mode)
    ("idris2" idris2-mode idris-mode) ("prolog" . prolog-mode)
    ;; Markup and documents
    ("latex" . latex-mode) ("tex" . tex-mode)
    ("bibtex" . bibtex-mode) ("bib" . bibtex-mode)
    ("markdown" markdown-mode) ("md" markdown-mode)
    ("org" . org-mode) ("rst" . rst-mode) ("restructuredtext" . rst-mode)
    ("texinfo" . texinfo-mode)
    ("text" . nil) ("plain" . nil) ("plaintext" . nil) ("txt" . nil)
    ;; Build systems, tooling and databases
    ("makefile" . makefile-gmake-mode) ("make" . makefile-gmake-mode)
    ("mk" . makefile-gmake-mode)
    ("cmake" cmake-ts-mode cmake-mode)
    ("dockerfile" dockerfile-ts-mode dockerfile-mode)
    ("docker" dockerfile-ts-mode dockerfile-mode)
    ("diff" . diff-mode) ("patch" . diff-mode) ("udiff" . diff-mode)
    ("nix" nix-ts-mode nix-mode)
    ("sql" . sql-mode) ("mysql" . sql-mode) ("postgresql" . sql-mode)
    ("psql" . sql-mode) ("plpgsql" . sql-mode) ("sqlite" . sql-mode)
    ("vim" vimrc-mode) ("vimscript" vimrc-mode))
  "Alist mapping code block language names to major modes.
Keys are lower-case language names as written in the info string of a
fenced code block.  A value is a major mode symbol, a list of major mode
symbols tried in order, or nil for no highlighting.  A mode is used only
when it is defined (`fboundp'); a tree-sitter mode (whose name ends in
\"-ts-mode\") additionally requires its grammar to be installed
\(`treesit-ready-p'), so listing one never triggers a download or a
prompt.  An entry is authoritative: when none of its modes is available
the block is not highlighted.  Languages absent from this table resolve
to `LANG-ts-mode' when that grammar is ready, else to `LANG-mode' when it
is a major mode.  See `mdview-code-resolve-mode'."
  :type '(alist :key-type (string :tag "Language")
                :value-type (choice (const :tag "No highlighting" nil)
                                    (symbol :tag "Major mode")
                                    (repeat :tag "Candidates" symbol)))
  :group 'mdview)

(defcustom mdview-code-highlight-max-chars 100000
  "Code blocks longer than this many characters are not highlighted."
  :type 'integer
  :group 'mdview)

(defcustom mdview-code-material-theme t
  "Non-nil replaces the fontifying mode's faces with the Material faces.
Every face left by the major mode is translated through
`mdview-code-face-alist' (following face inheritance) to a `mdview-code-*'
face; faces that do not translate are dropped so that the block's default
text colour shows.  When nil the mode's own faces are kept and only the
block background is added by the renderer."
  :type 'boolean
  :group 'mdview)

(defcustom mdview-code-face-alist
  '((font-lock-keyword-face . mdview-code-keyword)
    (font-lock-builtin-face . mdview-code-builtin)
    (font-lock-function-name-face . mdview-code-function)
    (font-lock-function-call-face . mdview-code-function)
    (font-lock-variable-name-face . mdview-code-variable)
    (font-lock-variable-use-face . mdview-code-variable)
    (font-lock-type-face . mdview-code-type)
    (font-lock-constant-face . mdview-code-constant)
    (font-lock-string-face . mdview-code-string)
    (font-lock-regexp-face . mdview-code-escape)
    (font-lock-doc-face . mdview-code-doc)
    (font-lock-doc-markup-face . mdview-code-doc)
    (font-lock-comment-face . mdview-code-comment)
    (font-lock-comment-delimiter-face . mdview-code-comment)
    (font-lock-preprocessor-face . mdview-code-preprocessor)
    (font-lock-number-face . mdview-code-number)
    (font-lock-operator-face . mdview-code-operator)
    (font-lock-negation-char-face . mdview-code-operator)
    (font-lock-misc-punctuation-face . mdview-code-operator)
    (font-lock-punctuation-face . mdview-code-punctuation)
    (font-lock-bracket-face . mdview-code-punctuation)
    (font-lock-delimiter-face . mdview-code-punctuation)
    (font-lock-property-name-face . mdview-code-property)
    (font-lock-property-use-face . mdview-code-property)
    (font-lock-escape-face . mdview-code-escape)
    (font-lock-regexp-grouping-backslash . mdview-code-escape)
    (font-lock-regexp-grouping-construct . mdview-code-escape)
    (font-lock-warning-face . mdview-code-error)
    ;; Faces of built-in modes that do not inherit from font-lock faces,
    ;; coloured as Pygments colours the same tokens.
    (sh-heredoc . mdview-code-string)
    (sh-quoted-exec . mdview-code-escape)
    (diff-added . mdview-code-string)
    (diff-removed . mdview-code-error)
    (diff-header . mdview-code-string)
    (diff-file-header . mdview-code-string)
    (diff-hunk-header . mdview-code-operator))
  "Alist translating faces left by major modes to `mdview-code-*' faces.
Keys are face symbols; values are the faces to use instead, or nil to
drop the face.  A face absent from the table is looked up through its
`:inherit' attribute, so faces derived from a listed face translate too.
Tree-sitter modes use the same font-lock faces as classic modes."
  :type '(alist :key-type face :value-type (choice (const nil) face))
  :group 'mdview)

(defcustom mdview-code-indent-guides t
  "Non-nil draws indentation guides in code blocks."
  :type 'boolean
  :group 'mdview)

(defcustom mdview-code-indent-guide-width 4
  "Number of columns between indentation guides in code blocks."
  :type 'integer
  :group 'mdview)

(defcustom mdview-code-tab-width 4
  "Column width of a tab character in code blocks (Rich uses 4)."
  :type 'integer
  :group 'mdview)

;;;; Language resolution

(defconst mdview-code--ts-languages
  '((c++-ts-mode . cpp) (js-ts-mode . javascript))
  "Tree-sitter modes whose grammar name differs from the mode name prefix.")

(defconst mdview-code--root-modes '(fundamental-mode text-mode prog-mode)
  "Major modes that have no `derived-mode-parent' property.")

(defun mdview-code--normalize-lang (lang)
  "Return LANG as a trimmed lower-case string, or nil when blank.
LANG may be a string or a symbol."
  (let ((name (cond ((stringp lang) lang)
                    ((and lang (symbolp lang)) (symbol-name lang)))))
    (when name
      (setq name (downcase (string-trim name)))
      (unless (string-empty-p name) name))))

(defun mdview-code--ts-mode-p (mode)
  "Return non-nil when MODE is named like a tree-sitter major mode."
  (string-suffix-p "-ts-mode" (symbol-name mode)))

(defun mdview-code--ts-language (mode)
  "Return the tree-sitter language symbol that MODE needs."
  (or (cdr (assq mode mdview-code--ts-languages))
      (intern (string-remove-suffix "-ts-mode" (symbol-name mode)))))

(defun mdview-code--treesit-ready-p (language)
  "Return non-nil when the tree-sitter grammar for LANGUAGE is usable.
Checks quietly: never warns, prompts or installs anything."
  (and (fboundp 'treesit-available-p)
       (treesit-available-p)
       (require 'treesit nil t)
       (fboundp 'treesit-ready-p)
       (ignore-errors (treesit-ready-p language t))))

(defun mdview-code--mode-available-p (mode)
  "Return non-nil when the major mode MODE can be called for highlighting.
MODE must be a defined function; a tree-sitter mode also needs its
grammar, which is checked before its library is ever loaded."
  (and mode (symbolp mode)
       (fboundp mode)
       (or (not (mdview-code--ts-mode-p mode))
           (mdview-code--treesit-ready-p (mdview-code--ts-language mode)))))

(defun mdview-code--major-mode-p (mode)
  "Return non-nil when MODE is an available major mode.
Loads the autoload of MODE if needed, then requires MODE to have been
defined with `define-derived-mode' (or to be a root mode) and not to be
a minor mode.  This keeps a language name taken from a document from
calling arbitrary commands such as `describe-mode' or `server-mode'."
  (and (mdview-code--mode-available-p mode)
       (ignore-errors (autoload-do-load (symbol-function mode) mode) t)
       (not (memq mode minor-mode-list))
       (or (memq mode mdview-code--root-modes)
           (and (get mode 'derived-mode-parent) t))))

(defun mdview-code--first-available (candidates)
  "Return the first available major mode among CANDIDATES, or nil.
CANDIDATES is a mode symbol, a list of mode symbols, or nil."
  (seq-find #'mdview-code--mode-available-p
            (if (listp candidates) candidates (list candidates))))

(defun mdview-code--guess-mode (name)
  "Return a major mode for the language NAME by naming convention, or nil.
Tries `NAME-ts-mode' when its grammar is ready, then `NAME-mode'.  Only
symbols that already exist are considered (nothing is interned), and only
real major modes are returned; see `mdview-code--major-mode-p'."
  (let ((ts (intern-soft (concat name "-ts-mode")))
        (plain (intern-soft (concat name "-mode"))))
    (cond ((and ts (mdview-code--major-mode-p ts)) ts)
          ((and plain (mdview-code--major-mode-p plain)) plain))))

(defun mdview-code--remap (mode)
  "Return the mode the user prefers over MODE, or MODE itself.
Honours `major-mode-remap-alist' (Emacs 30) when the preferred mode is
available, with its grammar installed in the case of a tree-sitter mode."
  (let ((preferred (and (fboundp 'major-mode-remap) (major-mode-remap mode))))
    (if (and preferred (symbolp preferred) (not (eq preferred mode))
             (mdview-code--mode-available-p preferred))
        preferred
      mode)))

(defun mdview-code-resolve-mode (lang)
  "Return the major mode used to highlight code in language LANG, or nil.
LANG is the language name from the info string of a fenced code block,
compared case-insensitively; nil or a blank string means no mode.
`mdview-code-lang-modes' is consulted first; a language not listed there
resolves to `LANG-ts-mode' when its tree-sitter grammar is installed and
otherwise to `LANG-mode' when that is a major mode.  The result honours
`major-mode-remap-alist' where Emacs supports it.  No grammar is ever
downloaded and nothing prompts."
  (let ((name (mdview-code--normalize-lang lang)))
    (when name
      (let* ((entry (assoc name mdview-code-lang-modes))
             (mode (if entry
                       (mdview-code--first-available (cdr entry))
                     (mdview-code--guess-mode name))))
        (and mode (mdview-code--remap mode))))))

;;;; Face mapping

(defun mdview-code--map-symbol (face seen)
  "Translate the face symbol FACE through `mdview-code-face-alist'.
SEEN lists the faces already visited while following `:inherit', which
guards against cycles.  Return the Material face or nil."
  (cond
   ((or (null face) (memq face seen)) nil)
   ((assq face mdview-code-face-alist) (cdr (assq face mdview-code-face-alist)))
   ((memq face mdview-code-faces) face)
   ((facep face)
    (let ((inherit (face-attribute face :inherit)))
      (and inherit (not (eq inherit 'unspecified))
           (mdview-code--map-face inherit (cons face seen)))))))

(defun mdview-code--map-face (face seen)
  "Translate the `face' property value FACE to a Material face, or nil.
FACE may be a symbol, a face name string, a list of faces (the first one
that translates wins), an anonymous face plist (only its `:inherit' can
translate) or a (foreground-color . COLOR) style cons.  SEEN is passed
to `mdview-code--map-symbol'."
  (cond
   ((null face) nil)
   ((symbolp face) (mdview-code--map-symbol face seen))
   ((stringp face) (mdview-code--map-symbol (intern-soft face) seen))
   ((not (consp face)) nil)
   ((keywordp (car face))
    (mdview-code--map-face (plist-get face :inherit) seen))
   ((memq (car face) '(foreground-color background-color)) nil)
   (t (let (result)
        (while (and (consp face) (not result))
          (setq result (mdview-code--map-face (car face) seen)
                face (cdr face)))
        result))))

(defun mdview-code-map-face (face)
  "Return the `mdview-code-*' face that the `face' property value FACE maps to.
FACE may be a face symbol, a list of faces, an anonymous face plist or
nil.  The translation table is `mdview-code-face-alist'; faces that
inherit from a listed face translate as well, and in a list the first
face that translates wins.  Return nil when nothing applies."
  (mdview-code--map-face face nil))

(defun mdview-code--map-face-cached (face cache)
  "Return `mdview-code-map-face' of FACE, memoized in the hash table CACHE."
  (let ((hit (gethash face cache 'mdview-code--miss)))
    (if (eq hit 'mdview-code--miss)
        (puthash face (mdview-code-map-face face) cache)
      hit)))

;;;; Fontification

(defun mdview-code--collect-faces (code)
  "Return a copy of CODE with only the `face' properties of the current buffer.
The buffer must start with CODE, fontified; every other text property
is dropped.  Faces are translated with `mdview-code-map-face' when
`mdview-code-material-theme' is non-nil and kept as they are otherwise."
  (let* ((result (substring-no-properties code))
         (cache (make-hash-table :test #'equal))
         (start (point-min))
         (limit (+ (point-min) (length code))))
    (while (< start limit)
      (let ((end (next-single-property-change start 'face nil limit))
            (face (get-text-property start 'face)))
        (when face
          (let ((new (if mdview-code-material-theme
                         (mdview-code--map-face-cached face cache)
                       face)))
            (when new
              (put-text-property (- start (point-min)) (- end (point-min))
                                 'face new result))))
        (setq start end)))
    result))

(defun mdview-code--fontify-with-mode (code mode)
  "Return CODE fontified by the major mode MODE, or nil when that fails.
Works in a temporary buffer with the mode hooks delayed and the change
hooks suppressed, so that user configuration (language servers, linters,
...) never runs.  A newline is appended for the duration of the
fontification so that keywords anchored on line ends (as in `diff-mode')
match on the last line too.  Return nil if MODE altered the text."
  (with-temp-buffer
    (insert code "\n")
    (let ((inhibit-message t)
          (change-major-mode-hook nil)
          (after-change-major-mode-hook nil)
          (font-lock-mode-hook nil)
          (prog-mode-hook nil)
          (text-mode-hook nil))
      (delay-mode-hooks (funcall mode))
      (font-lock-ensure)
      (when (string= (buffer-substring-no-properties (point-min) (point-max))
                     (concat code "\n"))
        (mdview-code--collect-faces code)))))

(defun mdview-code-fontify (code lang)
  "Return CODE highlighted for the language LANG as a propertized string.
CODE is the text of a code block without its trailing newline; LANG is
the language name from the info string, or nil.  The result has exactly
the characters of CODE, carries `face' properties only and no background:
the renderer paints the whole block with `mdview-code-block'.  When
`mdview-code-material-theme' is non-nil the fontifying mode's faces are
replaced by the `mdview-code-*' faces (see `mdview-code-face-alist');
otherwise they are kept.  Plain text is returned when LANG resolves to no
mode (see `mdview-code-resolve-mode'), when CODE is longer than
`mdview-code-highlight-max-chars' or when highlighting fails for any
reason; such failures are demoted to messages."
  (let ((code (if (stringp code) code "")))
    (or (and (<= (length code) mdview-code-highlight-max-chars)
             (condition-case nil
                 (with-demoted-errors "mdview-code: highlighting failed: %S"
                   (let ((mode (mdview-code-resolve-mode lang)))
                     (and mode (mdview-code--fontify-with-mode code mode))))
               (error nil)))
        (substring-no-properties code))))

;;;; Indent guides

(defun mdview-code--leading-whitespace-end (line)
  "Return the index in LINE where its leading spaces and tabs end."
  (let ((i 0) (n (length line)))
    (while (and (< i n) (memq (aref line i) '(?\s ?\t)))
      (setq i (1+ i)))
    i))

(defun mdview-code--expand-indentation (line end)
  "Return the first END characters of LINE with tabs expanded to spaces.
A tab advances to the next multiple of `mdview-code-tab-width'.  Text
properties are preserved; the spaces replacing a tab get its properties."
  (let ((tab (max 1 mdview-code-tab-width)) (col 0) (parts nil) (i 0))
    (while (< i end)
      (if (eq (aref line i) ?\t)
          (let ((pad (- tab (mod col tab))))
            (push (apply #'propertize (make-string pad ?\s)
                         (text-properties-at i line))
                  parts)
            (setq col (+ col pad)))
        (push (substring line i (1+ i)) parts)
        (setq col (1+ col)))
      (setq i (1+ i)))
    (apply #'concat (nreverse parts))))

(defun mdview-code--guide-prefix (indent)
  "Return the string INDENT of spaces with guide glyphs drawn into it.
Every full run of `mdview-code-indent-guide-width' columns starts with
the `guide' glyph in face `mdview-code-indent-guide'; a trailing partial
run keeps its spaces, as Rich does."
  (let* ((step (max 1 mdview-code-indent-guide-width))
         (width (length indent))
         (guide (propertize (mdview-glyph 'guide)
                            'face 'mdview-code-indent-guide))
         (parts nil)
         (col 0))
    (while (<= (+ col step) width)
      (push guide parts)
      (push (substring indent (1+ col) (+ col step)) parts)
      (setq col (+ col step)))
    (push (substring indent col) parts)
    (apply #'concat (nreverse parts))))

(defun mdview-code-indent-guides (line)
  "Return LINE with indentation guides drawn in its leading whitespace.
Within the leading spaces and tabs of LINE (tabs expanded to multiples of
`mdview-code-tab-width'), each complete run of
`mdview-code-indent-guide-width' columns starts with the `guide' glyph of
`mdview-glyph' in face `mdview-code-indent-guide', i.e. a guide stands at
column 0, at the guide width, at twice it and so on, as long as a full
run fits in the indentation.  Other whitespace and the rest of the line,
text properties included, are unchanged.  LINE is returned as it is when
`mdview-code-indent-guides' is nil, when it is not indented and when it
is blank."
  (let ((end (mdview-code--leading-whitespace-end line)))
    (if (or (not mdview-code-indent-guides) (zerop end) (= end (length line)))
        line
      (concat (mdview-code--guide-prefix
               (mdview-code--expand-indentation line end))
              (substring line end)))))

(defun mdview-code-indent-guides-lines (lines)
  "Return the list of code LINES with indentation guides drawn.
Each line is processed with `mdview-code-indent-guides'; in addition a
blank line followed by an indented line receives the guides of that next
non-blank line, so that guides run through the blank lines of an
indented region as in Rich.  Trailing blank lines stay blank."
  (let ((result nil) (pending nil))
    (dolist (line lines)
      (let ((end (mdview-code--leading-whitespace-end line)))
        (if (= end (length line))
            (push line pending)
          (let ((drawn (mdview-code-indent-guides line)))
            (when pending
              (let ((prefix (substring drawn 0 (- (length drawn)
                                                  (- (length line) end)))))
                (dolist (blank pending)
                  (push (if (and mdview-code-indent-guides (> end 0))
                            prefix
                          blank)
                        result))
                (setq pending nil)))
            (push drawn result)))))
    (nconc (nreverse result) (nreverse pending))))

(provide 'mdview-code)
;;; mdview-code.el ends here
