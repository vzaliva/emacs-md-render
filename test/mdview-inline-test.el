;;; mdview-inline-test.el --- Tests for mdview-inline  -*- lexical-binding: t; -*-

;; This file is part of mdview, distributed under the MIT license; see
;; LICENSE in the repository root.

;;; Commentary:

;; ERT tests for the inline parser (docs/DESIGN.md sections 3, 4 and 15):
;; backslash escapes, entities, code spans, the emphasis delimiter
;; algorithm, strikethrough, inline and reference links, images,
;; autolinks (angle brackets and the GFM bare forms, on and off), raw
;; inline HTML, hard and soft breaks, footnote references, text merging,
;; Unicode, robustness on pathological inputs, and source positions
;; (`mdview-pos' on text, `:pos' on code spans and raw HTML).
;;
;; Results are compared as compact s-expressions produced by
;; `mdview-inline-test--sexp': a text node is its string, every other
;; node is (TYPE PROPS CHILDREN...) where PROPS keeps only the non-nil
;; properties of the AST contract (`:url', `:title', `:alt', `:label',
;; `:autolink').  The expected values follow the CommonMark 0.31.2 and
;; GFM specifications; cmark / cmark-gfm behaviour is the tie breaker.
;;
;; A test may be marked `:expected-result :failed' to document a genuine
;; parser bug (with a comment above it); fix the parser and flip the
;; marker.  The timing tests bound pathological inputs generously so
;; that they pass interpreted as well as byte-compiled.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'mdview-ast)
(require 'mdview-inline)

;;;; Helpers

(defconst mdview-inline-test--root
  (expand-file-name
   ".." (file-name-directory (or load-file-name buffer-file-name default-directory)))
  "The repository root.")

(defconst mdview-inline-test--kept-props '(:url :title :alt :label :autolink)
  "Node properties kept by `mdview-inline-test--sexp'.")

(defun mdview-inline-test--sexp (node)
  "Return NODE as a compact s-expression.
A string is returned as is; a node becomes (TYPE PROPS CHILDREN...) where
PROPS is the plist of the non-nil interesting properties, in the order
of `mdview-inline-test--kept-props', or nil."
  (if (stringp node)
      node
    (let ((props (mdview-node-props node))
          (kept nil))
      (dolist (key mdview-inline-test--kept-props)
        (let ((value (plist-get props key)))
          (when value (setq kept (append kept (list key value))))))
      (append (list (mdview-node-type node) kept)
              (mapcar #'mdview-inline-test--sexp (mdview-node-children node))))))

(defun mdview-inline-test--parse (string &optional refs)
  "Parse STRING with REFS and return the compact s-expression list."
  (mapcar #'mdview-inline-test--sexp (mdview-inline-parse string refs)))

(defun mdview-inline-test--refs (&rest entries)
  "Build a reference map from ENTRIES, each (LABEL URL &optional TITLE).
Keys are normalized with `mdview-inline-normalize-label', the convention
the block parser uses for the document's `:refs' table."
  (let ((refs (make-hash-table :test 'equal)))
    (dolist (entry entries)
      (puthash (mdview-inline-normalize-label (nth 0 entry))
               (cons (nth 1 entry) (nth 2 entry))
               refs))
    refs))

(defmacro mdview-inline-test--check (string expected &optional refs)
  "Assert that parsing STRING with REFS yields the literal EXPECTED list."
  (declare (indent 1))
  `(should (equal (mdview-inline-test--parse ,string ,refs) ',expected)))

(defun mdview-inline-test--seconds (string)
  "Return the wall-clock seconds needed to parse STRING."
  (let ((start (float-time)))
    (mdview-inline-parse string nil)
    (- (float-time) start)))

(defun mdview-inline-test--well-formed-p (node)
  "Return non-nil when NODE follows the inline node contract of DESIGN.md."
  (or (stringp node)
      (and (consp node)
           (listp (mdview-node-props node))
           (pcase (mdview-node-type node)
             ((or 'code 'html-inline)
              (and (= (length (mdview-node-children node)) 1)
                   (stringp (car (mdview-node-children node)))))
             ((or 'hard-break 'soft-break)
              (null (mdview-node-children node)))
             ('footnote-reference
              (and (stringp (mdview-node-prop node :label))
                   (null (mdview-node-children node))))
             ('link
              (and (stringp (mdview-node-prop node :url))
                   (cl-every #'mdview-inline-test--well-formed-p
                             (mdview-node-children node))))
             ('image
              (and (stringp (mdview-node-prop node :url))
                   (stringp (mdview-node-prop node :alt))
                   (cl-every #'mdview-inline-test--well-formed-p
                             (mdview-node-children node))))
             ((or 'emphasis 'strong 'strikethrough)
              (cl-every #'mdview-inline-test--well-formed-p
                        (mdview-node-children node)))
             (_ nil)))))

(defun mdview-inline-test--repeat (string n)
  "Return STRING repeated N times."
  (mapconcat (lambda (_) string) (number-sequence 1 n) ""))

;;;; Backslash escapes

(ert-deftest mdview-inline-test-escape-ascii-punctuation ()
  "Any ASCII punctuation character can be backslash-escaped."
  (mdview-inline-test--check "\\*not emphasis\\* \\[not a link\\](/x) \\`not code\\` \\# \\_ \\~ \\< \\> \\|"
    ("*not emphasis* [not a link](/x) `not code` # _ ~ < > |")))

(ert-deftest mdview-inline-test-escape-all-ascii-punctuation-characters ()
  "Every character of !\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~ is escapable."
  (let* ((punct "!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~")
         (escaped (mapconcat (lambda (c) (string ?\\ c)) punct "")))
    (should (equal (mdview-inline-test--parse escaped) (list punct)))))

(ert-deftest mdview-inline-test-escape-non-punctuation-kept ()
  "A backslash before anything else stays literal (`\\a', letters, digits, Unicode)."
  (mdview-inline-test--check "\\a \\1 \\é \\→ \\ x"
    ("\\a \\1 \\é \\→ \\ x")))

(ert-deftest mdview-inline-test-escape-backslash-itself-and-at-end ()
  "`\\\\' is one backslash; a trailing backslash is literal."
  (mdview-inline-test--check "\\\\*emphasis*" ("\\" (emphasis nil "emphasis")))
  (mdview-inline-test--check "foo\\" ("foo\\")))

(ert-deftest mdview-inline-test-escape-entity-not-reinterpreted ()
  "`\\&amp;' yields the literal text `&amp;', not `&'."
  (mdview-inline-test--check "\\&amp; &amp;" ("&amp; &")))

(ert-deftest mdview-inline-test-escape-inside-code-span-and-autolink-literal ()
  "Backslash escapes do not work in code spans or autolink URIs."
  (mdview-inline-test--check "`` \\[\\` `` <https://example.com?find=\\*>"
    ((code nil "\\[\\`") " "
     (link (:url "https://example.com?find=\\*" :autolink t)
           "https://example.com?find=\\*"))))

(ert-deftest mdview-inline-test-escape-works-in-destination-and-title ()
  "Backslash escapes are resolved inside link destinations and titles."
  (mdview-inline-test--check "[foo](/bar\\* \"ti\\*tle\")"
    ((link (:url "/bar*" :title "ti*tle") "foo"))))

;;;; Entities

(ert-deftest mdview-inline-test-entity-named ()
  "Common named entities are decoded."
  (mdview-inline-test--check "&amp; &lt; &gt; &quot; &copy; &nbsp;x &ouml; &AMP;"
    ("& < > \" © \u00a0x ö &")))

(ert-deftest mdview-inline-test-entity-numeric-decimal ()
  "Decimal character references are decoded."
  (mdview-inline-test--check "&#35; &#1234; &#992; &#128512;"
    ("# Ӓ Ϡ 😀")))

(ert-deftest mdview-inline-test-entity-numeric-hex ()
  "Hexadecimal character references are decoded, with either X or x."
  (mdview-inline-test--check "&#x22; &#X41; &#xcab; &#x1F600;"
    ("\" A ಫ 😀")))

(ert-deftest mdview-inline-test-entity-invalid-codepoints-become-replacement ()
  "Code point 0, surrogates and values above U+10FFFF decode to U+FFFD."
  (mdview-inline-test--check "&#0; &#xD800; &#1114112; &#x110000;"
    ("\uFFFD \uFFFD \uFFFD \uFFFD")))

(ert-deftest mdview-inline-test-entity-unknown-name-kept ()
  "Unknown entity names stay as literal text."
  (mdview-inline-test--check "&foobarbaz; &ThisIsNotDefined; &hi?;"
    ("&foobarbaz; &ThisIsNotDefined; &hi?;")))

(ert-deftest mdview-inline-test-entity-malformed-kept ()
  "Entities without a semicolon or with too many digits are literal."
  (mdview-inline-test--check "&nbsp &x; &#; &#x; &#87654321; &#xFFFFFFF; &amp a&b"
    ("&nbsp &x; &#; &#x; &#87654321; &#xFFFFFFF; &amp a&b")))

(ert-deftest mdview-inline-test-entity-literal-in-code-span-kept-in-html ()
  "Entities are not decoded inside code spans or raw HTML."
  (mdview-inline-test--check "`&amp;` <a href=\"&ouml;\">"
    ((code nil "&amp;") " " (html-inline nil "<a href=\"&ouml;\">"))))

(ert-deftest mdview-inline-test-entity-in-destination-and-title ()
  "Entities are decoded in link destinations and titles."
  (mdview-inline-test--check "[foo](/f&ouml;&ouml; \"f&ouml;&ouml;\")"
    ((link (:url "/föö" :title "föö") "foo"))))

;;;; Code spans

(ert-deftest mdview-inline-test-code-span-simple ()
  "A code span is a `code' node with one string child."
  (mdview-inline-test--check "a `b c` d" ("a " (code nil "b c") " d")))

(ert-deftest mdview-inline-test-code-span-backtick-run-matching ()
  "The closing run must have exactly the length of the opening run."
  (mdview-inline-test--check "`` foo ` bar ``" ((code nil "foo ` bar")))
  (mdview-inline-test--check "`foo``bar``" ("`foo" (code nil "bar")))
  (mdview-inline-test--check "```foo``" ("```foo``"))
  (mdview-inline-test--check "`foo`bar`" ((code nil "foo") "bar`")))

(ert-deftest mdview-inline-test-code-span-inner-backticks ()
  "Backtick runs of a different length are content."
  (mdview-inline-test--check "` `` `" ((code nil "``")))
  (mdview-inline-test--check "`` ` ``" ((code nil "`")))
  (mdview-inline-test--check "`  ``  `" ((code nil " `` "))))

(ert-deftest mdview-inline-test-code-span-space-stripping ()
  "One leading and one trailing space are stripped when both are present."
  (mdview-inline-test--check "` foo `" ((code nil "foo")))
  (mdview-inline-test--check "`  foo  `" ((code nil " foo ")))
  (mdview-inline-test--check "` a`" ((code nil " a")))
  (mdview-inline-test--check "`a `" ((code nil "a "))))

(ert-deftest mdview-inline-test-code-span-only-spaces-not-stripped ()
  "A code span consisting only of spaces is not stripped."
  (mdview-inline-test--check "` `" ((code nil " ")))
  (mdview-inline-test--check "`  `" ((code nil "  "))))

(ert-deftest mdview-inline-test-code-span-newline-becomes-space ()
  "Line endings inside a code span become spaces; other spaces are kept."
  (mdview-inline-test--check "``\nfoo\nbar  \nbaz\n``" ((code nil "foo bar   baz")))
  (mdview-inline-test--check "`foo   bar \nbaz`" ((code nil "foo   bar  baz")))
  (mdview-inline-test--check "``\nfoo \n``" ((code nil "foo "))))

(ert-deftest mdview-inline-test-code-span-unmatched-opener-is-literal ()
  "A backtick run without a matching closer is literal text."
  (mdview-inline-test--check "`foo" ("`foo"))
  (mdview-inline-test--check "foo`" ("foo`"))
  (mdview-inline-test--check "``foo`" ("``foo`")))

(ert-deftest mdview-inline-test-code-span-beats-emphasis-links-and-html ()
  "Code spans take precedence over emphasis, links, HTML and autolinks."
  (mdview-inline-test--check "*foo`*`" ("*foo" (code nil "*")))
  (mdview-inline-test--check "[not a `link](/foo`)" ("[not a " (code nil "link](/foo") ")"))
  (mdview-inline-test--check "`<a href=\"`\">`" ((code nil "<a href=\"") "\">`"))
  (mdview-inline-test--check "`<https://foo.bar.`baz>`" ((code nil "<https://foo.bar.") "baz>`")))

;;;; Emphasis and strong emphasis

(ert-deftest mdview-inline-test-emphasis-strong-inside-emphasis ()
  "Strong nests inside emphasis: *foo**bar**baz*."
  (mdview-inline-test--check "*foo**bar**baz*"
    ((emphasis nil "foo" (strong nil "bar") "baz"))))

(ert-deftest mdview-inline-test-emphasis-emphasis-inside-strong ()
  "Emphasis nests inside strong: **foo*bar*baz**."
  (mdview-inline-test--check "**foo*bar*baz**"
    ((strong nil "foo" (emphasis nil "bar") "baz"))))

(ert-deftest mdview-inline-test-emphasis-underscore-intraword-ignored ()
  "_foo_bar_baz_ is one emphasis: intraword underscores are not delimiters."
  (mdview-inline-test--check "_foo_bar_baz_" ((emphasis nil "foo_bar_baz")))
  (mdview-inline-test--check "__foo__bar__baz__" ((strong nil "foo__bar__baz"))))

(ert-deftest mdview-inline-test-emphasis-strong-in-parens ()
  "*(**foo**)* works thanks to the punctuation flanking rules."
  (mdview-inline-test--check "*(**foo**)*"
    ((emphasis nil "(" (strong nil "foo") ")")))
  (mdview-inline-test--check "_(_foo_)_"
    ((emphasis nil "(" (emphasis nil "foo") ")"))))

(ert-deftest mdview-inline-test-emphasis-star-intraword ()
  "Intraword emphasis with * is allowed: foo*bar*."
  (mdview-inline-test--check "foo*bar*" ("foo" (emphasis nil "bar")))
  (mdview-inline-test--check "*foo*bar" ((emphasis nil "foo") "bar"))
  (mdview-inline-test--check "**foo**bar" ((strong nil "foo") "bar")))

(ert-deftest mdview-inline-test-emphasis-not-left-flanking ()
  "A delimiter followed by whitespace cannot open: a * foo bar*."
  (mdview-inline-test--check "a * foo bar*" ("a * foo bar*"))
  (mdview-inline-test--check "* a *" ("* a *")))

(ert-deftest mdview-inline-test-emphasis-not-right-flanking ()
  "A delimiter preceded by whitespace cannot close: *foo bar *, **foo bar **."
  (mdview-inline-test--check "*foo bar *" ("*foo bar *"))
  (mdview-inline-test--check "**foo bar **" ("**foo bar **"))
  (mdview-inline-test--check "*foo bar\n*" ("*foo bar" (soft-break nil) "*")))

(ert-deftest mdview-inline-test-emphasis-mismatched-delimiter-characters ()
  "_foo* does not close: the delimiter characters must match."
  (mdview-inline-test--check "_foo*" ("_foo*"))
  (mdview-inline-test--check "*foo_" ("*foo_"))
  (mdview-inline-test--check "*foo__bar*__" ((emphasis nil "foo__bar") "__")))

(ert-deftest mdview-inline-test-emphasis-triple-delimiters ()
  "Triple runs give emphasis containing strong; mixed closers split the run."
  (mdview-inline-test--check "***foo***" ((emphasis nil (strong nil "foo"))))
  (mdview-inline-test--check "foo***bar***baz" ("foo" (emphasis nil (strong nil "bar")) "baz"))
  (mdview-inline-test--check "***foo* bar**" ((strong nil (emphasis nil "foo") " bar")))
  (mdview-inline-test--check "***foo** bar*" ((emphasis nil (strong nil "foo") " bar"))))

(ert-deftest mdview-inline-test-emphasis-multiple-of-three-rule ()
  "Rule 9: a 1-run and a 2-run whose sum is 3 cannot match, as in *foo**bar*."
  (mdview-inline-test--check "*foo**bar*" ((emphasis nil "foo**bar")))
  (mdview-inline-test--check "**foo*bar**" ((strong nil "foo*bar")))
  ;; Both runs multiples of 3: the rule does not apply.
  (mdview-inline-test--check "foo***bar***baz" ("foo" (emphasis nil (strong nil "bar")) "baz")))

(ert-deftest mdview-inline-test-emphasis-underscore-intraword-not-emphasis ()
  "Intraword _ is never emphasis, also for non-ASCII letters."
  (mdview-inline-test--check "foo_bar_" ("foo_bar_"))
  (mdview-inline-test--check "пристаням_стремятся_" ("пристаням_стремятся_"))
  (mdview-inline-test--check "中文_强调_中文" ("中文_强调_中文"))
  (mdview-inline-test--check "__foo__bar" ("__foo__bar"))
  (mdview-inline-test--check "foo-_(bar)_" ("foo-" (emphasis nil "(bar)"))))

(ert-deftest mdview-inline-test-emphasis-nested-same-character ()
  "Runs of the same character nest: *foo *bar** and **foo **bar****."
  (mdview-inline-test--check "*foo *bar**" ((emphasis nil "foo " (emphasis nil "bar"))))
  (mdview-inline-test--check "**foo **bar****" ((strong nil "foo " (strong nil "bar"))))
  (mdview-inline-test--check "*foo **bar** baz*" ((emphasis nil "foo " (strong nil "bar") " baz"))))

(ert-deftest mdview-inline-test-emphasis-unicode-punctuation-and-symbols ()
  "Unicode punctuation counts for the flanking rules; `$' is punctuation too."
  (mdview-inline-test--check "*«foo»*" ((emphasis nil "«foo»")))
  (mdview-inline-test--check "a*“foo”*" ("a*“foo”*"))
  (mdview-inline-test--check "*$*alpha." ("*$*alpha."))
  (mdview-inline-test--check "*foo*—bar" ((emphasis nil "foo") "—bar")))

(ert-deftest mdview-inline-test-emphasis-unicode-whitespace ()
  "No-break space (category Zs) is whitespace for the flanking rules."
  (mdview-inline-test--check "*foo\u00a0*" ("*foo\u00a0*"))
  (mdview-inline-test--check "\u00a0*foo*" ("\u00a0" (emphasis nil "foo"))))

(ert-deftest mdview-inline-test-emphasis-around-and-across-links ()
  "Emphasis may contain links; links are resolved before outer emphasis."
  (mdview-inline-test--check "*foo [bar](/url)*"
    ((emphasis nil "foo " (link (:url "/url") "bar"))))
  (mdview-inline-test--check "*[bar*](/url)" ("*" (link (:url "/url") "bar*")))
  (mdview-inline-test--check "**a<https://foo.bar/?q=**>"
    ("**a" (link (:url "https://foo.bar/?q=**" :autolink t) "https://foo.bar/?q=**"))))

(ert-deftest mdview-inline-test-emphasis-spans-soft-break ()
  "Emphasis may span line endings."
  (mdview-inline-test--check "*foo\nbar*" ((emphasis nil "foo" (soft-break nil) "bar")))
  (mdview-inline-test--check "**Gomphocarpus (*Gomphocarpus physocarpus*, syn.\n*Asclepias physocarpa*)**"
    ((strong nil "Gomphocarpus (" (emphasis nil "Gomphocarpus physocarpus") ", syn."
             (soft-break nil) (emphasis nil "Asclepias physocarpa") ")"))))

(ert-deftest mdview-inline-test-emphasis-interleaved-with-strikethrough ()
  "Delimiters left between a matched pair are dropped (no interleaving)."
  (mdview-inline-test--check "*foo~~bar*baz~~" ((emphasis nil "foo~~bar") "baz~~"))
  (mdview-inline-test--check "~~foo*bar~~baz*" ((strikethrough nil "foo*bar") "baz*")))

;;;; Strikethrough

(ert-deftest mdview-inline-test-strikethrough-double-and-single ()
  "~~x~~ and ~x~ both produce `strikethrough'."
  (mdview-inline-test--check "~~Hi~~ Hello, ~there~ world!"
    ((strikethrough nil "Hi") " Hello, " (strikethrough nil "there") " world!")))

(ert-deftest mdview-inline-test-strikethrough-mismatched-runs ()
  "~~a~ and ~a~~ are not strikethrough: runs must have equal length."
  (mdview-inline-test--check "~~a~" ("~~a~"))
  (mdview-inline-test--check "~a~~" ("~a~~"))
  (mdview-inline-test--check "~~a~b~~" ((strikethrough nil "a~b"))))

(ert-deftest mdview-inline-test-strikethrough-three-tildes-literal ()
  "Runs of three or more tildes are literal text."
  (mdview-inline-test--check "~~~a~~~" ("~~~a~~~"))
  (mdview-inline-test--check "~~~a~~" ("~~~a~~")))

(ert-deftest mdview-inline-test-strikethrough-nests-with-emphasis ()
  "Strikethrough and emphasis nest in either order."
  (mdview-inline-test--check "~~*a*~~" ((strikethrough nil (emphasis nil "a"))))
  (mdview-inline-test--check "*~~a~~*" ((emphasis nil (strikethrough nil "a"))))
  (mdview-inline-test--check "~~**a** b~~" ((strikethrough nil (strong nil "a") " b"))))

(ert-deftest mdview-inline-test-strikethrough-flanking ()
  "Tilde runs obey the flanking rules like *."
  (mdview-inline-test--check "~~ a~~" ("~~ a~~"))
  (mdview-inline-test--check "a~~b~~c" ("a" (strikethrough nil "b") "c")))

;;;; Inline links

(ert-deftest mdview-inline-test-link-inline-with-and-without-title ()
  "Inline links carry `:url', `:title' (or nil) and no `:autolink'."
  (mdview-inline-test--check "[link](/uri \"title\")" ((link (:url "/uri" :title "title") "link")))
  (mdview-inline-test--check "[link](/uri)" ((link (:url "/uri") "link")))
  (let ((link (car (mdview-inline-parse "[link](/uri)" nil))))
    (should (eq (mdview-node-type link) 'link))
    (should (null (mdview-node-prop link :title)))
    (should (null (mdview-node-prop link :autolink)))))

(ert-deftest mdview-inline-test-link-empty-destination ()
  "[link]() and [link](<>) are links with an empty destination."
  (mdview-inline-test--check "[link]()" ((link (:url "") "link")))
  (mdview-inline-test--check "[link](<>)" ((link (:url "") "link")))
  (mdview-inline-test--check "[](/url)" ((link (:url "/url")))))

(ert-deftest mdview-inline-test-link-angle-bracket-destination ()
  "<...> destinations may contain spaces and parens but not line endings."
  (mdview-inline-test--check "[link](</my uri>)" ((link (:url "/my uri") "link")))
  (mdview-inline-test--check "[a](<b)c>)" ((link (:url "b)c") "a")))
  (mdview-inline-test--check "[link](<foo(and(bar)>)" ((link (:url "foo(and(bar)") "link")))
  (mdview-inline-test--check "[link](<foo\\>)" ("[link](<foo>)"))
  (mdview-inline-test--check "[a](<b)c\n[a](<b)c>" ("[a](<b)c" (soft-break nil) "[a](<b)c>")))

(ert-deftest mdview-inline-test-link-destination-parens ()
  "Bare destinations may contain balanced or escaped parens only."
  (mdview-inline-test--check "[link](foo(and(bar)))" ((link (:url "foo(and(bar))") "link")))
  (mdview-inline-test--check "[link](foo(and(bar))" ("[link](foo(and(bar))"))
  (mdview-inline-test--check "[link](foo\\(and\\(bar\\))" ((link (:url "foo(and(bar)") "link")))
  (mdview-inline-test--check "[link](foo\\)\\:)" ((link (:url "foo):") "link")))
  (mdview-inline-test--check "[link](#fragment) [a](http://example.com?foo=3#frag)"
    ((link (:url "#fragment") "link") " "
     (link (:url "http://example.com?foo=3#frag") "a"))))

(ert-deftest mdview-inline-test-link-destination-whitespace-rules ()
  "Spaces and one line ending are allowed around the destination, not inside."
  (mdview-inline-test--check "[link](   /uri\n  \"title\"  )" ((link (:url "/uri" :title "title") "link")))
  (mdview-inline-test--check "[link](foo\nbar)" ("[link](foo" (soft-break nil) "bar)"))
  (mdview-inline-test--check "[link](/uri bar)" ("[link](/uri bar)"))
  (mdview-inline-test--check "[link] (/uri)" ("[link] (/uri)")))

(ert-deftest mdview-inline-test-link-titles-three-quoting-styles ()
  "Titles may be delimited by \", ' or parens."
  (mdview-inline-test--check "[link](/url \"title\")" ((link (:url "/url" :title "title") "link")))
  (mdview-inline-test--check "[link](/url 'title')" ((link (:url "/url" :title "title") "link")))
  (mdview-inline-test--check "[link](/url (title))" ((link (:url "/url" :title "title") "link")))
  (mdview-inline-test--check "[link](/url 'title \"and\" title')"
    ((link (:url "/url" :title "title \"and\" title") "link"))))

(ert-deftest mdview-inline-test-link-title-escapes-entities-and-errors ()
  "Titles decode escapes and entities; a malformed title breaks the link."
  (mdview-inline-test--check "[link](/url \"title \\\"&quot;\")"
    ((link (:url "/url" :title "title \"\"") "link")))
  (mdview-inline-test--check "[link](/url \"title\"\")" ("[link](/url \"title\"\")"))
  (mdview-inline-test--check "[link](/url \"title \"and\" title\")"
    ("[link](/url \"title \"and\" title\")")))

(ert-deftest mdview-inline-test-link-text-nested-brackets ()
  "Balanced brackets are allowed in link text; unbalanced ones are not."
  (mdview-inline-test--check "[link [foo [bar]]](/uri)" ((link (:url "/uri") "link [foo [bar]]")))
  (mdview-inline-test--check "[link] bar](/uri)" ("[link] bar](/uri)"))
  (mdview-inline-test--check "[link [bar](/uri)" ("[link " (link (:url "/uri") "bar")))
  (mdview-inline-test--check "[link \\[bar](/uri)" ((link (:url "/uri") "link [bar"))))

(ert-deftest mdview-inline-test-link-text-inline-markup ()
  "Link text may contain emphasis, code spans and other inline content."
  (mdview-inline-test--check "[link *foo **bar** `#`*](/uri)"
    ((link (:url "/uri") "link " (emphasis nil "foo " (strong nil "bar") " " (code nil "#")))))
  (mdview-inline-test--check "[foo *bar](baz*)" ((link (:url "baz*") "foo *bar")))
  (mdview-inline-test--check "[a &amp; \\]b](/u)" ((link (:url "/u") "a & ]b"))))

(ert-deftest mdview-inline-test-link-no-link-inside-link ()
  "Links may not contain other links; the inner one wins."
  (mdview-inline-test--check "[foo [bar](/uri)](/uri)"
    ("[foo " (link (:url "/uri") "bar") "](/uri)"))
  (mdview-inline-test--check "[foo *[bar [baz](/uri)](/uri)*](/uri)"
    ("[foo " (emphasis nil "[bar " (link (:url "/uri") "baz") "](/uri)") "](/uri)")))

(ert-deftest mdview-inline-test-link-image-inside-link ()
  "An image may appear inside a link."
  (mdview-inline-test--check "[![moon](moon.jpg)](/uri)"
    ((link (:url "/uri") (image (:url "moon.jpg" :alt "moon") "moon"))))
  (mdview-inline-test--check "[text ![alt *x*](i.png) more](/uri \"t\")"
    ((link (:url "/uri" :title "t") "text "
           (image (:url "i.png" :alt "alt x") "alt " (emphasis nil "x")) " more"))))

(ert-deftest mdview-inline-test-link-precedence-of-other-constructs ()
  "Code spans, raw HTML and autolinks bind tighter than link brackets."
  (mdview-inline-test--check "[foo <bar attr=\"](baz)\">"
    ("[foo " (html-inline nil "<bar attr=\"](baz)\">")))
  (mdview-inline-test--check "[foo`](/uri)`" ("[foo" (code nil "](/uri)")))
  (mdview-inline-test--check "[foo<https://example.com/?search=](uri)>"
    ("[foo" (link (:url "https://example.com/?search=](uri)" :autolink t)
                  "https://example.com/?search=](uri)"))))

;;;; Reference links

(ert-deftest mdview-inline-test-link-reference-full ()
  "[text][label] resolves through REFS."
  (let ((refs (mdview-inline-test--refs '("foo" "/url" "title") '("bar" "/bar"))))
    (mdview-inline-test--check "[link][foo]" ((link (:url "/url" :title "title") "link")) refs)
    (mdview-inline-test--check "[link][bar]" ((link (:url "/bar") "link")) refs)
    (mdview-inline-test--check "[*text* `x`][foo]"
      ((link (:url "/url" :title "title") (emphasis nil "text") " " (code nil "x"))) refs)))

(ert-deftest mdview-inline-test-link-reference-label-normalization ()
  "Labels are case-folded and their whitespace collapsed before lookup."
  (let ((refs (mdview-inline-test--refs '("Foo Bar" "/fb") '("äö" "/umlaut"))))
    (should (equal (mdview-inline-normalize-label "  foo \n  BAR ") "FOO BAR"))
    (mdview-inline-test--check "[x][FOO BAR]" ((link (:url "/fb") "x")) refs)
    (mdview-inline-test--check "[x][  foo \n bar ]" ((link (:url "/fb") "x")) refs)
    (mdview-inline-test--check "[Foo\nBar]" ((link (:url "/fb") "Foo" (soft-break nil) "Bar")) refs)
    (mdview-inline-test--check "[ÄÖ]" ((link (:url "/umlaut") "ÄÖ")) refs)
    (mdview-inline-test--check "[Äö][]" ((link (:url "/umlaut") "Äö")) refs)))

(ert-deftest mdview-inline-test-link-reference-collapsed ()
  "[text][] uses the text as the label."
  (let ((refs (mdview-inline-test--refs '("foo" "/url" "title") '("*foo* bar" "/emph"))))
    (mdview-inline-test--check "[foo][]" ((link (:url "/url" :title "title") "foo")) refs)
    (mdview-inline-test--check "[Foo][]" ((link (:url "/url" :title "title") "Foo")) refs)
    (mdview-inline-test--check "[*foo* bar][]" ((link (:url "/emph") (emphasis nil "foo") " bar")) refs)
    (mdview-inline-test--check "[foo] \n[]" ((link (:url "/url" :title "title") "foo") (soft-break nil) "[]") refs)))

(ert-deftest mdview-inline-test-link-reference-shortcut ()
  "[text] alone is a shortcut reference."
  (let ((refs (mdview-inline-test--refs '("foo" "/url" "title") '("bar baz" "/bb"))))
    (mdview-inline-test--check "[foo]" ((link (:url "/url" :title "title") "foo")) refs)
    (mdview-inline-test--check "[foo] bar" ((link (:url "/url" :title "title") "foo") " bar") refs)
    (mdview-inline-test--check "[bar   baz]" ((link (:url "/bb") "bar   baz")) refs)
    (mdview-inline-test--check "[[foo]]" ("[" (link (:url "/url" :title "title") "foo") "]") refs)
    (mdview-inline-test--check "*[foo*]" ((emphasis nil "[foo") "]") refs)))

(ert-deftest mdview-inline-test-link-reference-undefined-stays-text ()
  "Undefined references remain literal text in every form, also with nil REFS."
  (let ((refs (mdview-inline-test--refs '("foo" "/url"))))
    (mdview-inline-test--check "[undefined]" ("[undefined]") refs)
    (mdview-inline-test--check "[undefined][]" ("[undefined][]") refs)
    (mdview-inline-test--check "[foo][undefined]" ("[foo][undefined]") refs)
    (mdview-inline-test--check "[foo]" ("[foo]") nil)
    (mdview-inline-test--check "[foo][foo]" ("[foo][foo]") nil)
    (mdview-inline-test--check "[*foo* bar][]" ("[" (emphasis nil "foo") " bar][]") refs)))

(ert-deftest mdview-inline-test-link-reference-full-form-takes-precedence ()
  "[foo][bar][baz]: a following label is used even when undefined."
  (let ((refs (mdview-inline-test--refs '("foo" "/url2") '("baz" "/url1"))))
    (mdview-inline-test--check "[foo][bar][baz]"
      ("[foo]" (link (:url "/url1") "bar")) refs))
  (let ((refs (mdview-inline-test--refs '("bar" "/url2") '("baz" "/url1"))))
    (mdview-inline-test--check "[foo][bar][baz]"
      ((link (:url "/url2") "foo") (link (:url "/url1") "baz")) refs)))

(ert-deftest mdview-inline-test-link-reference-empty-label-not-a-link ()
  "An empty or blank label cannot be a reference."
  (let ((refs (mdview-inline-test--refs '("foo" "/url"))))
    (mdview-inline-test--check "[]" ("[]") refs)
    (mdview-inline-test--check "[ ]" ("[ ]") refs)
    (mdview-inline-test--check "[][]" ("[][]") refs)
    (mdview-inline-test--check "[][foo]" ((link (:url "/url"))) refs)))

(ert-deftest mdview-inline-test-link-reference-versus-inline ()
  "Inline syntax after a defined shortcut wins; non-link parens stay text."
  (let ((refs (mdview-inline-test--refs '("foo" "/url" "title"))))
    (mdview-inline-test--check "[foo]()" ((link (:url "") "foo")) refs)
    (mdview-inline-test--check "[foo](not a link)"
      ((link (:url "/url" :title "title") "foo") "(not a link)") refs)
    (mdview-inline-test--check "[foo]: bar"
      ((link (:url "/url" :title "title") "foo") ": bar") refs)))

(ert-deftest mdview-inline-test-link-reference-escaped-brackets ()
  "Escaped brackets do not close a label; labels match on their raw text."
  (let ((refs (mdview-inline-test--refs '("foo" "/url") '("foo\\]" "/esc"))))
    (mdview-inline-test--check "[\\]]" ("[]]") refs)
    (mdview-inline-test--check "[foo\\]" ("[foo]") refs)
    (mdview-inline-test--check "[foo\\]]" ((link (:url "/esc") "foo]")) refs)))

;; BUG (mdview-inline.el, `mdview-inline--lookup-reference'): the 999
;; character limit of link labels is enforced by `mdview-inline--scan-link-label'
;; for the full form `[text][label]' but not when the bracketed text itself
;; is used as the label (collapsed and shortcut forms), so an over-long
;; shortcut still resolves when REFS holds such a key.  Per the spec (and
;; cmark's reference lookup) the bracket is not a label at all and the whole
;; thing stays text.  Only reachable through the public API: the block
;; parser's definition scanner already applies the limit.
(ert-deftest mdview-inline-test-link-reference-label-too-long ()
  "Labels longer than 999 characters are not references in any form."
  (let* ((long (make-string 1001 ?a))
         (refs (mdview-inline-test--refs (list long "/long") '("x" "/x"))))
    ;; The over-long bracket is not a label, so [x] is a shortcut reference.
    (should (equal (mdview-inline-test--parse (concat "[x][" long "]") refs)
                   (list '(link (:url "/x") "x") (concat "[" long "]"))))
    (mdview-inline-test--check "[x][]" ((link (:url "/x") "x")) refs)
    (should (equal (mdview-inline-test--parse (concat "[" long "]") refs)
                   (list (concat "[" long "]"))))
    (should (equal (mdview-inline-test--parse (concat "[" long "][]") refs)
                   (list (concat "[" long "][]"))))))

;;;; Images

(ert-deftest mdview-inline-test-image-alt-is-plain-text-of-description ()
  "An image's `:alt' is the plain text of its description."
  (mdview-inline-test--check "![foo *bar*](/url \"title\")"
    ((image (:url "/url" :title "title" :alt "foo bar") "foo " (emphasis nil "bar"))))
  (mdview-inline-test--check "![foo &amp; \\*bar\\* `co*de`](/u)"
    ((image (:url "/u" :alt "foo & *bar* co*de") "foo & *bar* " (code nil "co*de")))))

(ert-deftest mdview-inline-test-image-nested-image-and-link-in-description ()
  "Images and links are allowed inside an image description."
  (mdview-inline-test--check "![foo ![bar](/url)](/url2)"
    ((image (:url "/url2" :alt "foo bar") "foo " (image (:url "/url" :alt "bar") "bar"))))
  (mdview-inline-test--check "![foo [bar](/url)](/url2)"
    ((image (:url "/url2" :alt "foo bar") "foo " (link (:url "/url") "bar"))))
  (mdview-inline-test--check "![[[foo](uri1)](uri2)](uri3)"
    ((image (:url "uri3" :alt "[foo](uri2)") "[" (link (:url "uri1") "foo") "](uri2)"))))

(ert-deftest mdview-inline-test-image-reference-forms ()
  "Images support full, collapsed and shortcut references."
  (let ((refs (mdview-inline-test--refs '("foo" "/url" "title") '("bar" "/bar"))))
    (mdview-inline-test--check "![foo]" ((image (:url "/url" :title "title" :alt "foo") "foo")) refs)
    (mdview-inline-test--check "![Foo][]" ((image (:url "/url" :title "title" :alt "Foo") "Foo")) refs)
    (mdview-inline-test--check "![*foo* bar][foo]"
      ((image (:url "/url" :title "title" :alt "foo bar") (emphasis nil "foo") " bar")) refs)
    (mdview-inline-test--check "![x][bar]" ((image (:url "/bar" :alt "x") "x")) refs)
    (mdview-inline-test--check "![nope]" ("![nope]") refs)))

(ert-deftest mdview-inline-test-image-empty-and-angle-destination ()
  "An empty description gives an empty `:alt'; <...> destinations work."
  (mdview-inline-test--check "![](/url)" ((image (:url "/url" :alt ""))))
  (mdview-inline-test--check "![foo](<url>)" ((image (:url "url" :alt "foo") "foo")))
  (mdview-inline-test--check "![foo](train.jpg)" ((image (:url "train.jpg" :alt "foo") "foo"))))

(ert-deftest mdview-inline-test-image-escaped-bang-and-bracket ()
  "Escaping the ! or the [ prevents the image."
  (let ((refs (mdview-inline-test--refs '("foo" "/url" "title"))))
    (mdview-inline-test--check "!\\[foo]" ("![foo]") refs)
    (mdview-inline-test--check "\\![foo]" ("!" (link (:url "/url" :title "title") "foo")) refs)
    (mdview-inline-test--check "! [foo](/u)" ("! " (link (:url "/u") "foo")))))

;;;; Angle-bracket autolinks

(ert-deftest mdview-inline-test-autolink-uri ()
  "<scheme:...> is a link with `:autolink' and the URI as text."
  (mdview-inline-test--check "<https://x>" ((link (:url "https://x" :autolink t) "https://x")))
  (mdview-inline-test--check "<made-up-scheme://foo,bar>"
    ((link (:url "made-up-scheme://foo,bar" :autolink t) "made-up-scheme://foo,bar")))
  (mdview-inline-test--check "<https://example.com/\\[\\>"
    ((link (:url "https://example.com/\\[\\" :autolink t) "https://example.com/\\[\\"))))

(ert-deftest mdview-inline-test-autolink-mailto-and-email ()
  "<mailto:...> is a URI autolink; <addr@host> gets a mailto: URL."
  (mdview-inline-test--check "<mailto:a@b>" ((link (:url "mailto:a@b" :autolink t) "mailto:a@b")))
  (mdview-inline-test--check "<a@b.c>" ((link (:url "mailto:a@b.c" :autolink t) "a@b.c")))
  (mdview-inline-test--check "<a@b>" ((link (:url "mailto:a@b" :autolink t) "a@b")))
  (mdview-inline-test--check "<foo@bar.example.com>"
    ((link (:url "mailto:foo@bar.example.com" :autolink t) "foo@bar.example.com"))))

(ert-deftest mdview-inline-test-autolink-rejected-forms ()
  "Spaces, short schemes, missing schemes and escapes are not autolinks."
  (let ((mdview-inline-extended-autolinks nil))
    (mdview-inline-test--check "<https://foo.bar/baz bim>" ("<https://foo.bar/baz bim>"))
    (mdview-inline-test--check "<m:abc>" ("<m:abc>"))
    (mdview-inline-test--check "<foo.bar.baz>" ("<foo.bar.baz>"))
    (mdview-inline-test--check "<foo\\+@bar.example.com>" ("<foo+@bar.example.com>"))
    (mdview-inline-test--check "< https://foo.bar >" ("< https://foo.bar >"))
    (mdview-inline-test--check "<>" ("<>"))
    (mdview-inline-test--check "https://example.com" ("https://example.com"))))

(ert-deftest mdview-inline-test-autolink-text-child-is-plain ()
  "The text inside an autolink is a single string, never re-linked."
  (let ((link (car (mdview-inline-parse "<https://www.example.com/x>" nil))))
    (should (equal (mdview-node-children link) '("https://www.example.com/x")))
    (should (eq (mdview-node-prop link :autolink) t))))

;;;; GFM extended autolinks

(ert-deftest mdview-inline-test-gfm-www-autolink ()
  "A www.-prefixed domain becomes an http:// link."
  (mdview-inline-test--check "www.commonmark.org"
    ((link (:url "http://www.commonmark.org" :autolink t) "www.commonmark.org")))
  (mdview-inline-test--check "Visit www.commonmark.org/help for more information."
    ("Visit " (link (:url "http://www.commonmark.org/help" :autolink t) "www.commonmark.org/help")
     " for more information.")))

(ert-deftest mdview-inline-test-gfm-autolink-trailing-punctuation ()
  "Trailing ? ! . , : * _ ~ ' \" are excluded from the link."
  (mdview-inline-test--check "www.commonmark.org, ok"
    ((link (:url "http://www.commonmark.org" :autolink t) "www.commonmark.org") ", ok"))
  (mdview-inline-test--check "https://commonmark.org/."
    ((link (:url "https://commonmark.org/" :autolink t) "https://commonmark.org/") "."))
  (mdview-inline-test--check "Visit www.commonmark.org/a.b."
    ("Visit " (link (:url "http://www.commonmark.org/a.b" :autolink t) "www.commonmark.org/a.b") "."))
  (mdview-inline-test--check "see https://x.y/z! and https://x.y/q\" and 'https://x.y/w'"
    ("see " (link (:url "https://x.y/z" :autolink t) "https://x.y/z") "! and "
     (link (:url "https://x.y/q" :autolink t) "https://x.y/q") "\" and 'https://x.y/w'"))
  (mdview-inline-test--check "see https://x.y/z, ok"
    ("see " (link (:url "https://x.y/z" :autolink t) "https://x.y/z") ", ok")))

;; A period that ends the sentence right after the domain is scanned as a
;; domain character; it must not make the domain invalid (GFM example
;; 622 expects the link followed by a literal "."): like cmark-gfm, the
;; parser leaves it to the trailing-punctuation rule.
(ert-deftest mdview-inline-test-gfm-autolink-trailing-period-after-domain ()
  "A sentence-ending period right after the domain is not part of the URL."
  (mdview-inline-test--check "Visit www.commonmark.org."
    ("Visit " (link (:url "http://www.commonmark.org" :autolink t) "www.commonmark.org") "."))
  (mdview-inline-test--check "http://commonmark.org."
    ((link (:url "http://commonmark.org" :autolink t) "http://commonmark.org") "."))
  (mdview-inline-test--check "see www.commonmark.org... and https://x.y.."
    ("see " (link (:url "http://www.commonmark.org" :autolink t) "www.commonmark.org")
     "... and " (link (:url "https://x.y" :autolink t) "https://x.y") ".."))
  ;; A period before the path stays in the URL, as in cmark-gfm.
  (mdview-inline-test--check "www.x.com./p"
    ((link (:url "http://www.x.com./p" :autolink t) "www.x.com./p")))
  ;; Only periods are backed over: "www.a." still lacks a second segment.
  (mdview-inline-test--check "www.a." ("www.a.")))

(ert-deftest mdview-inline-test-gfm-autolink-parens ()
  "Balanced parens are kept; unbalanced trailing ) are excluded."
  (mdview-inline-test--check "www.google.com/search?q=Markup+(business)"
    ((link (:url "http://www.google.com/search?q=Markup+(business)" :autolink t)
           "www.google.com/search?q=Markup+(business)")))
  (mdview-inline-test--check "www.google.com/search?q=Markup+(business)))"
    ((link (:url "http://www.google.com/search?q=Markup+(business)" :autolink t)
           "www.google.com/search?q=Markup+(business)") "))"))
  (mdview-inline-test--check "(www.google.com/search?q=Markup+(business))"
    ("(" (link (:url "http://www.google.com/search?q=Markup+(business)" :autolink t)
               "www.google.com/search?q=Markup+(business)") ")"))
  (mdview-inline-test--check "www.google.com/search?q=(business))+ok"
    ((link (:url "http://www.google.com/search?q=(business))+ok" :autolink t)
           "www.google.com/search?q=(business))+ok")))
  (mdview-inline-test--check "(Visit https://encrypted.google.com/search?q=Markup+(business))"
    ("(Visit " (link (:url "https://encrypted.google.com/search?q=Markup+(business)" :autolink t)
                     "https://encrypted.google.com/search?q=Markup+(business)") ")")))

(ert-deftest mdview-inline-test-gfm-autolink-entity-tail-and-lt ()
  "A trailing entity-like tail is excluded; < ends the URL."
  (mdview-inline-test--check "www.google.com/search?q=commonmark&hl;"
    ((link (:url "http://www.google.com/search?q=commonmark" :autolink t)
           "www.google.com/search?q=commonmark") "&hl;"))
  (mdview-inline-test--check "www.google.com/search?q=commonmark&hl;es"
    ((link (:url "http://www.google.com/search?q=commonmark&hl;es" :autolink t)
           "www.google.com/search?q=commonmark&hl;es")))
  (mdview-inline-test--check "www.commonmark.org/he<lp"
    ((link (:url "http://www.commonmark.org/he" :autolink t) "www.commonmark.org/he") "<lp")))

(ert-deftest mdview-inline-test-gfm-url-schemes ()
  "Bare http://, https:// and ftp:// URLs are recognised; other schemes are not."
  (mdview-inline-test--check "http://commonmark.org"
    ((link (:url "http://commonmark.org" :autolink t) "http://commonmark.org")))
  (mdview-inline-test--check "ftp://x.y/z" ((link (:url "ftp://x.y/z" :autolink t) "ftp://x.y/z")))
  (mdview-inline-test--check "http://localhost/x"
    ((link (:url "http://localhost/x" :autolink t) "http://localhost/x")))
  (mdview-inline-test--check "gopher://x.y/z irc://x.y" ("gopher://x.y/z irc://x.y")))

(ert-deftest mdview-inline-test-gfm-email-autolink ()
  "Bare e-mail addresses become mailto: links per the GFM rules."
  (mdview-inline-test--check "foo@bar.baz" ((link (:url "mailto:foo@bar.baz" :autolink t) "foo@bar.baz")))
  (mdview-inline-test--check "hello@mail+xyz.example isn't valid, but hello+xyz@mail.example is."
    ("hello@mail+xyz.example isn't valid, but "
     (link (:url "mailto:hello+xyz@mail.example" :autolink t) "hello+xyz@mail.example") " is."))
  (mdview-inline-test--check "a.b-c_d@a.b" ((link (:url "mailto:a.b-c_d@a.b" :autolink t) "a.b-c_d@a.b")))
  (mdview-inline-test--check "a.b-c_d@a.b."
    ((link (:url "mailto:a.b-c_d@a.b" :autolink t) "a.b-c_d@a.b") "."))
  (mdview-inline-test--check "a.b-c_d@a.b-" ("a.b-c_d@a.b-"))
  (mdview-inline-test--check "a.b-c_d@a.b_" ("a.b-c_d@a.b_")))

(ert-deftest mdview-inline-test-gfm-autolink-boundaries-and-domains ()
  "URLs start only after whitespace, * _ ~ ( or at the start; domain rules."
  (mdview-inline-test--check "xwww.example.com" ("xwww.example.com"))
  (mdview-inline-test--check "*www.example.com*"
    ((emphasis nil (link (:url "http://www.example.com" :autolink t) "www.example.com"))))
  (mdview-inline-test--check "**www.x.y**"
    ((strong nil (link (:url "http://www.x.y" :autolink t) "www.x.y"))))
  (mdview-inline-test--check "www.xxx.yyy._zzz" ("www.xxx.yyy._zzz"))
  (mdview-inline-test--check "www._xxx.yyy.zzz"
    ((link (:url "http://www._xxx.yyy.zzz" :autolink t) "www._xxx.yyy.zzz")))
  (mdview-inline-test--check "www.example.com/a_b_c"
    ((link (:url "http://www.example.com/a_b_c" :autolink t) "www.example.com/a_b_c")))
  (mdview-inline-test--check "https://x.y/z\nwww.x.y"
    ((link (:url "https://x.y/z" :autolink t) "https://x.y/z") (soft-break nil)
     (link (:url "http://www.x.y" :autolink t) "www.x.y"))))

(ert-deftest mdview-inline-test-gfm-autolink-not-inside-links-or-code ()
  "Bare URLs inside links, images, code spans and autolinks stay text."
  (mdview-inline-test--check "[www.example.com](/url)" ((link (:url "/url") "www.example.com")))
  (mdview-inline-test--check "[see http://a.b and x@y.z](/url)"
    ((link (:url "/url") "see http://a.b and x@y.z")))
  (mdview-inline-test--check "![www.x.y](/i)" ((image (:url "/i" :alt "www.x.y") "www.x.y")))
  (mdview-inline-test--check "`www.example.com`" ((code nil "www.example.com")))
  (mdview-inline-test--check "<https://www.x.y>"
    ((link (:url "https://www.x.y" :autolink t) "https://www.x.y")))
  (mdview-inline-test--check "<p>www.x.y</p>"
    ((html-inline nil "<p>") (link (:url "http://www.x.y" :autolink t) "www.x.y")
     (html-inline nil "</p>"))))

(ert-deftest mdview-inline-test-gfm-autolinks-disabled ()
  "With `mdview-inline-extended-autolinks' nil only <...> autolinks remain."
  (let ((mdview-inline-extended-autolinks nil))
    (mdview-inline-test--check "www.commonmark.org" ("www.commonmark.org"))
    (mdview-inline-test--check "http://commonmark.org foo@bar.baz" ("http://commonmark.org foo@bar.baz"))
    (mdview-inline-test--check "<https://x> and www.x.y"
      ((link (:url "https://x" :autolink t) "https://x") " and www.x.y"))
    (mdview-inline-test--check "*www.x.y*" ((emphasis nil "www.x.y")))))

(ert-deftest mdview-inline-test-gfm-autolinks-enabled-by-default ()
  "The option defaults to t."
  (should (eq (default-value 'mdview-inline-extended-autolinks) t)))

;;;; Raw inline HTML

(ert-deftest mdview-inline-test-html-open-tag-with-attributes ()
  "Open tags with quoted, single-quoted and unquoted attributes are raw HTML."
  (mdview-inline-test--check "<a href=\"x\" title='y' data-z=w>"
    ((html-inline nil "<a href=\"x\" title='y' data-z=w>")))
  (mdview-inline-test--check "<a\nhref=\"x\">" ((html-inline nil "<a\nhref=\"x\">")))
  (mdview-inline-test--check "<a href=\"x\"  >" ((html-inline nil "<a href=\"x\"  >")))
  (mdview-inline-test--check "<a foo bar=baz>" ((html-inline nil "<a foo bar=baz>"))))

(ert-deftest mdview-inline-test-html-close-tag ()
  "Closing tags are raw HTML, with optional whitespace before >."
  (mdview-inline-test--check "</div>" ((html-inline nil "</div>")))
  (mdview-inline-test--check "</div >" ((html-inline nil "</div >")))
  (mdview-inline-test--check "</a href=\"x\">" ("</a href=\"x\">")))

(ert-deftest mdview-inline-test-html-comment ()
  "Comments, including the <!--> and <!---> forms, are raw HTML."
  (mdview-inline-test--check "<!-- comment -->" ((html-inline nil "<!-- comment -->")))
  (mdview-inline-test--check "<!-->" ((html-inline nil "<!-->")))
  (mdview-inline-test--check "<!--->" ((html-inline nil "<!--->")))
  (mdview-inline-test--check "foo <!-- not a comment -- two hyphens -->"
    ("foo " (html-inline nil "<!-- not a comment -- two hyphens -->")))
  (mdview-inline-test--check "<!-- not -- closed" ("<!-- not -- closed")))

(ert-deftest mdview-inline-test-html-self-closing ()
  "<br/> and <br /> are raw HTML."
  (mdview-inline-test--check "a<br/>b" ("a" (html-inline nil "<br/>") "b"))
  (mdview-inline-test--check "<br />" ((html-inline nil "<br />")))
  (mdview-inline-test--check "<a/><b2/>" ((html-inline nil "<a/>") (html-inline nil "<b2/>"))))

(ert-deftest mdview-inline-test-html-invalid-stays-text ()
  "Malformed tags are literal text."
  (mdview-inline-test--check "<a b=" ("<a b="))
  (mdview-inline-test--check "<a href=\"x>" ("<a href=\"x>"))
  (mdview-inline-test--check "<33> <__>" ("<33> <__>"))
  (mdview-inline-test--check "< a>" ("< a>"))
  (mdview-inline-test--check "<a foo=bar=baz>" ("<a foo=bar=baz>"))
  (mdview-inline-test--check "<a href='b'title=\"c\">" ("<a href='b'title=\"c\">"))
  (mdview-inline-test--check "<a href=\"\\\"\">" ("<a href=\"\"\">"))
  (mdview-inline-test--check "<a <b>" ("<a " (html-inline nil "<b>"))))

(ert-deftest mdview-inline-test-html-declaration-cdata-and-processing ()
  "Declarations, CDATA sections and processing instructions are raw HTML."
  (mdview-inline-test--check "<?php echo $a; ?>" ((html-inline nil "<?php echo $a; ?>")))
  (mdview-inline-test--check "<![CDATA[>&<]]>" ((html-inline nil "<![CDATA[>&<]]>")))
  (mdview-inline-test--check "<!DOCTYPE html>" ((html-inline nil "<!DOCTYPE html>"))))

(ert-deftest mdview-inline-test-html-surrounding-markup ()
  "Markup between tags is still parsed; tag contents are kept raw."
  (mdview-inline-test--check "<a>*b*</a>"
    ((html-inline nil "<a>") (emphasis nil "b") (html-inline nil "</a>")))
  (mdview-inline-test--check "<a href=\"&amp;\">x</a>"
    ((html-inline nil "<a href=\"&amp;\">") "x" (html-inline nil "</a>")))
  (mdview-inline-test--check "<a href=\"foo  \nbar\">" ((html-inline nil "<a href=\"foo  \nbar\">"))))

;;;; Hard and soft breaks

(ert-deftest mdview-inline-test-hard-break-two-spaces ()
  "Two or more spaces before a line ending make a hard break."
  (mdview-inline-test--check "foo  \nbar" ("foo" (hard-break nil) "bar"))
  (mdview-inline-test--check "foo       \nbar" ("foo" (hard-break nil) "bar")))

(ert-deftest mdview-inline-test-hard-break-backslash ()
  "A backslash before a line ending makes a hard break."
  (mdview-inline-test--check "foo\\\nbar" ("foo" (hard-break nil) "bar"))
  (mdview-inline-test--check "foo\\\\\nbar" ("foo\\" (soft-break nil) "bar")))

(ert-deftest mdview-inline-test-hard-break-strips-leading-spaces-of-next-line ()
  "Spaces at the start of the next line are ignored after a break."
  (mdview-inline-test--check "foo  \n     bar" ("foo" (hard-break nil) "bar"))
  (mdview-inline-test--check "foo\\\n     bar" ("foo" (hard-break nil) "bar")))

(ert-deftest mdview-inline-test-hard-break-inside-emphasis ()
  "Hard breaks may occur inside emphasis."
  (mdview-inline-test--check "*foo  \nbar*" ((emphasis nil "foo" (hard-break nil) "bar")))
  (mdview-inline-test--check "*foo\\\nbar*" ((emphasis nil "foo" (hard-break nil) "bar"))))

(ert-deftest mdview-inline-test-hard-break-not-in-code-or-html ()
  "Line endings in code spans and HTML tags are not hard breaks."
  (mdview-inline-test--check "`code  \nspan`" ((code nil "code   span")))
  (mdview-inline-test--check "`code\\\nspan`" ((code nil "code\\ span")))
  (should (equal (mapcar #'mdview-node-type (mdview-inline-parse "<a href=\"foo  \nbar\">" nil))
                 '(html-inline))))

(ert-deftest mdview-inline-test-hard-break-not-at-end-of-string ()
  "Trailing spaces or a trailing backslash without a line ending are not breaks."
  (let ((nodes (mdview-inline-parse "foo  " nil)))
    (should-not (memq 'hard-break (mapcar #'mdview-node-type nodes)))
    (should (equal (string-trim (mdview-node-text (cons 'paragraph (cons nil nodes)))) "foo")))
  (mdview-inline-test--check "foo\\" ("foo\\")))

(ert-deftest mdview-inline-test-soft-break ()
  "A plain line ending is a soft break; surrounding spaces are dropped."
  (mdview-inline-test--check "foo\nbaz" ("foo" (soft-break nil) "baz"))
  (mdview-inline-test--check "foo \n baz" ("foo" (soft-break nil) "baz"))
  (mdview-inline-test--check "foo\n\tbaz" ("foo" (soft-break nil) "baz"))
  (mdview-inline-test--check "a\n\nb" ("a" (soft-break nil) (soft-break nil) "b")))

(ert-deftest mdview-inline-test-soft-break-text-is-space ()
  "`mdview-node-text' renders a soft break as a space and a hard break as a newline."
  (let ((nodes (mdview-inline-parse "foo\nbar  \nbaz" nil)))
    (should (equal (mdview-node-text (cons 'paragraph (cons nil nodes))) "foo bar\nbaz"))))

;;;; Footnote references

(ert-deftest mdview-inline-test-footnote-reference-label ()
  "[^label] is a `footnote-reference' with `:label'."
  (mdview-inline-test--check "[^1]" ((footnote-reference (:label "1"))))
  (mdview-inline-test--check "[^a-b_c.d]" ((footnote-reference (:label "a-b_c.d"))))
  (mdview-inline-test--check "[^1][^2]"
    ((footnote-reference (:label "1")) (footnote-reference (:label "2")))))

(ert-deftest mdview-inline-test-footnote-reference-in-text ()
  "Footnote references sit between text nodes and inside emphasis."
  (mdview-inline-test--check "text[^note]more" ("text" (footnote-reference (:label "note")) "more"))
  (mdview-inline-test--check "*a[^1]*" ((emphasis nil "a" (footnote-reference (:label "1")))))
  (mdview-inline-test--check "[^1]: not a definition inline"
    ((footnote-reference (:label "1")) ": not a definition inline")))

(ert-deftest mdview-inline-test-footnote-reference-invalid-forms ()
  "[^ x], [^] and ![^1] are not footnote references."
  (mdview-inline-test--check "[^ note]" ("[^ note]"))
  (mdview-inline-test--check "[^]" ("[^]"))
  (mdview-inline-test--check "![^1]" ("![^1]"))
  (mdview-inline-test--check "\\[^1]" ("[^1]")))

(ert-deftest mdview-inline-test-footnote-reference-not-a-link ()
  "A footnote reference followed by (url) is not an inline link."
  (mdview-inline-test--check "[^1](/url)" ((footnote-reference (:label "1")) "(/url)"))
  (let ((refs (mdview-inline-test--refs '("^1" "/url"))))
    (mdview-inline-test--check "[^1]" ((footnote-reference (:label "1"))) refs)))

;;;; Text merging

(ert-deftest mdview-inline-test-text-merging-adjacent-strings ()
  "Adjacent text pieces (escapes, entities, literals) merge into one string."
  (mdview-inline-test--check "foo\\*bar" ("foo*bar"))
  (mdview-inline-test--check "a&amp;b" ("a&b"))
  (mdview-inline-test--check "a<b&c]d!e" ("a<b&c]d!e"))
  (mdview-inline-test--check "x\\*&amp;y*z" ("x*&y*z")))

(ert-deftest mdview-inline-test-text-merging-unmatched-delimiters ()
  "Unmatched delimiter runs and brackets merge with the surrounding text."
  (mdview-inline-test--check "a * b" ("a * b"))
  (mdview-inline-test--check "*foo bar *" ("*foo bar *"))
  (mdview-inline-test--check "[foo *bar][]" ("[foo *bar][]"))
  (mdview-inline-test--check "~a **b _c" ("~a **b _c")))

(ert-deftest mdview-inline-test-text-merging-around-nodes ()
  "Text on either side of a node is a single string; no empty strings remain."
  (let ((nodes (mdview-inline-parse "a\\*b *c* d&amp;e `f` g" nil)))
    (should (equal (mapcar #'mdview-inline-test--sexp nodes)
                   '("a*b " (emphasis nil "c") " d&e " (code nil "f") " g")))
    (should-not (seq-some (lambda (n) (and (stringp n) (string-empty-p n))) nodes))
    (should-not (cl-loop for (a b) on nodes thereis (and (stringp a) (stringp b))))))

;;;; Unicode

(ert-deftest mdview-inline-test-unicode-cjk ()
  "CJK text passes through intact, with * emphasis working intraword."
  (mdview-inline-test--check "日本語 **太字** テスト" ("日本語 " (strong nil "太字") " テスト"))
  (mdview-inline-test--check "中文*强调*中文" ("中文" (emphasis nil "强调") "中文"))
  (mdview-inline-test--check "[链接](/路径 \"标题\")" ((link (:url "/路径" :title "标题") "链接"))))

(ert-deftest mdview-inline-test-unicode-emoji ()
  "Emoji, including multi-code-point sequences, are preserved."
  (mdview-inline-test--check "😀 *a* 👍🏽" ("😀 " (emphasis nil "a") " 👍🏽"))
  (mdview-inline-test--check "`👨‍👩‍👧`" ((code nil "👨‍👩‍👧")))
  (mdview-inline-test--check "**🇺🇦**" ((strong nil "🇺🇦"))))

(ert-deftest mdview-inline-test-unicode-combining-marks ()
  "Combining marks stay attached to their base characters."
  (mdview-inline-test--check "e\u0301 *e\u0301* \u0915\u094d\u0937"
    ("e\u0301 " (emphasis nil "e\u0301") " \u0915\u094d\u0937"))
  (should (equal (mdview-node-text (car (mdview-inline-parse "![n\u0303](/x)" nil)))
                 "n\u0303")))

;;;; Contract and robustness

(ert-deftest mdview-inline-test-contract-shapes ()
  "Nodes follow the (TYPE PLIST . CHILDREN) shape of DESIGN.md section 3."
  (let ((nodes (mdview-inline-parse
                (concat "a *b **c** d* ~~e~~ `f` [g](/h \"i\") ![j *k*](/l) <m:n> "
                        "<br/> o  \np\\\nq\nr [^1] www.s.t u@v.w")
                nil)))
    (should (cl-every #'mdview-inline-test--well-formed-p nodes))
    (should (equal (delete-dups (mapcar #'mdview-node-type nodes))
                   '(text emphasis strikethrough code link image html-inline
                          hard-break soft-break footnote-reference)))))

(ert-deftest mdview-inline-test-contract-empty-and-whitespace ()
  "The empty string parses to nil; whitespace-only strings are text."
  (should (null (mdview-inline-parse "" nil)))
  (should (null (mdview-inline-parse "" (mdview-inline-test--refs))))
  (mdview-inline-test--check " " (" "))
  (mdview-inline-test--check "\t" ("\t")))

(ert-deftest mdview-inline-test-nasty-many-stars ()
  "100k asterisks terminate quickly and never signal."
  (should (< (mdview-inline-test--seconds (make-string 100000 ?*)) 2))
  (should (< (mdview-inline-test--seconds (mdview-inline-test--repeat "*a" 50000)) 5))
  (should (< (mdview-inline-test--seconds (mdview-inline-test--repeat "**a " 20000)) 5))
  (should (< (mdview-inline-test--seconds (mdview-inline-test--repeat "*a **b " 20000)) 5))
  (should (< (mdview-inline-test--seconds (mdview-inline-test--repeat "_a" 50000)) 5))
  (should (< (mdview-inline-test--seconds (make-string 100000 ?~)) 2)))

(ert-deftest mdview-inline-test-nasty-many-brackets ()
  "10k open brackets, balanced brackets and image openers never signal."
  (should (equal (mdview-inline-parse (make-string 10000 ?\[) nil)
                 (list (make-string 10000 ?\[))))
  (should (equal (mdview-inline-parse (make-string 10000 ?\]) nil)
                 (list (make-string 10000 ?\]))))
  (should (< (mdview-inline-test--seconds
              (concat (make-string 10000 ?\[) "a" (make-string 10000 ?\])))
             5))
  (should (< (mdview-inline-test--seconds (mdview-inline-test--repeat "![" 10000)) 5))
  (should (< (mdview-inline-test--seconds (mdview-inline-test--repeat "[a]" 10000)) 5))
  (should (< (mdview-inline-test--seconds (mdview-inline-test--repeat "[a](<b" 10000)) 5)))

(ert-deftest mdview-inline-test-nasty-unterminated-constructs ()
  "Unterminated code spans, HTML, autolinks and entities never signal."
  (dolist (input (list (concat "`" (make-string 100000 ?a))
                       (make-string 10000 ?`)
                       (concat "<!--" (make-string 100000 ?-))
                       (mdview-inline-test--repeat "<!--" 5000)
                       (mdview-inline-test--repeat "<a " 10000)
                       (make-string 10000 ?<)
                       (concat "<https://" (make-string 100000 ?x))
                       (concat "<![CDATA[" (make-string 100000 ?x))
                       (make-string 50000 ?&)
                       (make-string 50000 ?\\)
                       (mdview-inline-test--repeat "&#x" 10000)
                       (mdview-inline-test--repeat "[a](b \"" 5000)
                       (make-string 10000 ?\n)
                       (mdview-inline-test--repeat "a  \n" 10000)
                       (mdview-inline-test--repeat "[^" 10000)))
    (should (< (mdview-inline-test--seconds input) 5))
    (should (cl-every #'mdview-inline-test--well-formed-p
                      (mdview-inline-parse input nil)))))

(ert-deftest mdview-inline-test-nasty-autolink-candidates ()
  "Pathological bare-URL and e-mail candidates never signal."
  (dolist (input (list (mdview-inline-test--repeat "www." 20000)
                       (mdview-inline-test--repeat "http://" 20000)
                       (make-string 20000 ?@)
                       (mdview-inline-test--repeat "a@" 20000)
                       (concat "www.a.b/" (make-string 20000 ?\() (make-string 20000 ?\)))
                       (concat "www.a.b/" (mdview-inline-test--repeat "&a;" 10000))))
    (should (< (mdview-inline-test--seconds input) 5))))

;; The bare destination scanner gives up after 32 unclosed parens, as
;; cmark does (its pathological test "unclosed links B"); without the
;; limit every `]' of "[a](b[a](b..." rescanned to the end of the string.
(ert-deftest mdview-inline-test-nasty-unclosed-inline-links-linear ()
  "Repeated unclosed inline links parse in linear-ish time.
Quadratic scanning took 18 s for this input; linear takes 0.2 s compiled."
  (should (< (mdview-inline-test--seconds (mdview-inline-test--repeat "[a](b" 20000)) 5)))

(ert-deftest mdview-inline-test-link-destination-paren-nesting-limit ()
  "A bare destination may nest parens 32 deep but not 33 (cmark's limit)."
  (let ((ok (concat "[a](" (make-string 32 ?\() "b" (make-string 32 ?\)) ")"))
        (deep (concat "[a](" (make-string 33 ?\() "b" (make-string 33 ?\)) ")")))
    (should (equal (mdview-inline-test--parse ok)
                   (list (list 'link
                               (list :url (concat (make-string 32 ?\() "b"
                                                  (make-string 32 ?\))))
                               "a"))))
    (should (equal (mdview-inline-test--parse deep) (list deep)))))

;; The unbalanced-paren rule of the autolink trimming counts the parens
;; once; recounting them for every stripped `)' was quadratic.
(ert-deftest mdview-inline-test-nasty-autolink-trailing-parens-linear ()
  "A bare URL followed by many closing parens parses in linear-ish time.
Recounting took 21 s for 40000 parens; counting once takes milliseconds."
  (should (< (mdview-inline-test--seconds (concat "www.a.b/" (make-string 40000 ?\)))) 5))
  (should (< (mdview-inline-test--seconds (concat "http://x.com/" (make-string 40000 ?\)))) 5))
  ;; The count stays right while trimming.
  (mdview-inline-test--check "www.a.b/(x))))"
    ((link (:url "http://www.a.b/(x)" :autolink t) "www.a.b/(x)") ")))"))
  (mdview-inline-test--check "www.a.b/((x)).)"
    ((link (:url "http://www.a.b/((x))" :autolink t) "www.a.b/((x))") ".)")))

;; A failed e-mail match is not retried from every character of its
;; local part: the domain after the `@' is the same for all of them.
(ert-deftest mdview-inline-test-nasty-email-local-part-linear ()
  "A long word before an `@' that is not an address parses in linear time.
Retrying from every character took 57 s for 40000 characters."
  (should (< (mdview-inline-test--seconds (concat (make-string 40000 ?a) "@")) 5))
  (should (< (mdview-inline-test--seconds (concat (make-string 40000 ?a) "@b")) 5))
  (should (< (mdview-inline-test--seconds
              (concat (mdview-inline-test--repeat "a." 20000) "@"))
             5))
  ;; Later addresses are still found after a dead `@'.
  (mdview-inline-test--check "aaaa@ and me@x.y"
    ("aaaa@ and " (link (:url "mailto:me@x.y" :autolink t) "me@x.y")))
  (mdview-inline-test--check "a@b c@d.e"
    ("a@b " (link (:url "mailto:c@d.e" :autolink t) "c@d.e"))))

;; The scheme and `www.' prefix tests are anchored; an unanchored search
;; for "www." scanned to the end of the text for every http URL.
(ert-deftest mdview-inline-test-nasty-many-urls-linear ()
  "Tens of thousands of short URLs in one text parse in linear-ish time.
The unanchored search took 17 s for 60000 URLs; anchored, 0.2 s compiled."
  (should (< (mdview-inline-test--seconds (mdview-inline-test--repeat "https://a " 60000)) 5))
  (should (< (mdview-inline-test--seconds (mdview-inline-test--repeat "http://a.b " 20000)) 5))
  (should (< (mdview-inline-test--seconds (mdview-inline-test--repeat "ftp://a.b " 20000)) 5))
  (mdview-inline-test--check "HTTP://x.y wwW.x.y httpx://x.y"
    ("HTTP://x.y wwW.x.y httpx://x.y")))

;; Closing a link deactivates the earlier openers; the walk stops at the
;; first opener that is already inactive instead of visiting them all.
(ert-deftest mdview-inline-test-nasty-openers-before-links-linear ()
  "Many unclosed `[' followed by many links parse in linear-ish time.
Walking the whole bracket stack per link took 21 s for this input."
  (should (< (mdview-inline-test--seconds
              (concat (make-string 20000 ?\[) (mdview-inline-test--repeat "[a](b)" 20000)))
             5))
  ;; Links after unclosed openers still do not nest in them.
  (mdview-inline-test--check "[[[a](b) c](d)"
    ("[[" (link (:url "b") "a") " c](d)"))
  (mdview-inline-test--check "[x ![a](b) [c](d)](e)"
    ("[x " (image (:url "b" :alt "a") "a") " " (link (:url "d") "c") "](e)")))

;; Terminator searches for raw HTML are memoized per parse: once "-->"
;; (or "]]>", ">", "?>") is known to be absent, later openers are
;; rejected without rescanning the text.
(ert-deftest mdview-inline-test-nasty-unclosed-html-linear ()
  "Many unclosed comments, declarations, PIs and CDATA parse in linear time.
Rescanning per opener took 7 to 15 s for each of these inputs."
  (dolist (input (list (concat "a " (mdview-inline-test--repeat "<!-- " 50000))
                       (concat "a " (mdview-inline-test--repeat "<!A " 50000))
                       (concat "a " (mdview-inline-test--repeat "<? " 50000))
                       (concat "a " (mdview-inline-test--repeat "<![CDATA[ " 50000))))
    (should (< (mdview-inline-test--seconds input) 5))))

(ert-deftest mdview-inline-test-html-terminator-memo-correctness ()
  "An absent terminator of one kind does not hide the others."
  (mdview-inline-test--check "<? a <!-- b --> c"
    ("<? a " (html-inline nil "<!-- b -->") " c"))
  (mdview-inline-test--check "<!-- a <? b ?> c"
    ("<!-- a " (html-inline nil "<? b ?>") " c"))
  (mdview-inline-test--check "<!-- a <!-- b --> c <!-- d"
    ((html-inline nil "<!-- a <!-- b -->") " c <!-- d"))
  (mdview-inline-test--check "<![CDATA[ a <!A b> c"
    ("<![CDATA[ a " (html-inline nil "<!A b>") " c"))
  (mdview-inline-test--check "<!A a <![CDATA[ b ]]> c"
    ((html-inline nil "<!A a <![CDATA[ b ]]>") " c")))

;; The search for a code span closer is memoized as in cmark (the last
;; run of every length, and whether a scan reached the end of the text).
(ert-deftest mdview-inline-test-nasty-backtick-runs-linear ()
  "cmark's pathological backtick input parses in linear-ish time.
Without the memo this 1.1 MB input took about 8 s (x8 per doubling)."
  (should (< (mdview-inline-test--seconds
              (mapconcat (lambda (i) (concat "e" (make-string i ?`)))
                         (number-sequence 1 1500) ""))
             5)))

(ert-deftest mdview-inline-test-code-span-closer-memo-correctness ()
  "Memoized closer searches give the same code spans as a plain scan."
  (mdview-inline-test--check "`a``b`" ((code nil "a``b")))
  (mdview-inline-test--check "``x` y``z`" ((code nil "x` y") "z`"))
  (mdview-inline-test--check "`a` `b` ``c`` `d"
    ((code nil "a") " " (code nil "b") " " (code nil "c") " `d"))
  (mdview-inline-test--check "``a`" ("``a`"))
  (mdview-inline-test--check "`a``" ("`a``"))
  (mdview-inline-test--check "``a`b``c`" ((code nil "a`b") "c`"))
  (mdview-inline-test--check "```x`` `y` ``z```" ((code nil "x`` `y` ``z")))
  (mdview-inline-test--check "` `` ``` `` `" ((code nil "`` ``` ``"))))

;; Nesting deeper than `mdview-inline-max-depth' degrades the whole text
;; to one text node, so no consumer of the tree can exhaust the stack.
(ert-deftest mdview-inline-test-nesting-depth-cap ()
  "Nesting up to the cap is parsed; deeper nesting yields the raw text."
  (let ((mdview-inline-max-depth 3))
    (mdview-inline-test--check "*a **b *c* b** a*"
      ((emphasis nil "a " (strong nil "b " (emphasis nil "c") " b") " a")))
    (mdview-inline-test--check "*a **b *c **d** c* b** a*"
      ("*a **b *c **d** c* b** a*"))
    ;; Links and images count as levels too.
    (mdview-inline-test--check "[*a **[b](c)**  a*](d)"
      ("[" (emphasis nil "a " (strong nil (link (:url "c") "b")) "  a") "](d)"))
    (mdview-inline-test--check "*a **b *c [d](e) c* b** a*"
      ("*a **b *c [d](e) c* b** a*"))
    (mdview-inline-test--check "*a **b *c ![d](e) c* b** a*"
      ("*a **b *c ![d](e) c* b** a*")))
  ;; The default cap keeps 100 nested strong nodes and rejects 101.
  (let* ((ok (concat (make-string 200 ?*) "a" (make-string 200 ?*)))
         (deep (concat (make-string 202 ?*) "a" (make-string 202 ?*)))
         (nodes (mdview-inline-parse ok nil))
         (depth 0) (node (car nodes)))
    (should (= (length nodes) 1))
    (while (consp node)
      (setq depth (1+ depth) node (car (mdview-node-children node))))
    (should (= depth 100))
    (should (equal node "a"))
    (should (equal (mdview-inline-parse deep nil) (list deep))))
  (should (equal (mdview-inline-parse
                  (concat (make-string 5900 ?*) "a" (make-string 5900 ?*)) nil)
                 (list (concat (make-string 5900 ?*) "a" (make-string 5900 ?*))))))

;; The parser scans in one hidden buffer that every call reuses instead
;; of a fresh temporary buffer per paragraph, heading and table cell.
(ert-deftest mdview-inline-test-scratch-buffer-reused ()
  "Parsing creates no buffers, survives the loss of its buffer, is case sensitive."
  (mdview-inline-parse "warm up" nil)
  (let ((count (length (buffer-list))))
    (dotimes (_ 100) (mdview-inline-parse "x *y* `z` [a](b)" nil))
    (should (= (length (buffer-list)) count))
    (should (buffer-live-p mdview-inline--buffer))
    (should (string-prefix-p " " (buffer-name mdview-inline--buffer))))
  (kill-buffer mdview-inline--buffer)
  (mdview-inline-test--check "**ok**" ((strong nil "ok")))
  ;; Leftovers of one parse never leak into the next.
  (mdview-inline-test--check "`unclosed" ("`unclosed"))
  (mdview-inline-test--check "`a`" ((code nil "a")))
  (mdview-inline-test--check "<!-- open" ("<!-- open"))
  (mdview-inline-test--check "<!-- a -->" ((html-inline nil "<!-- a -->")))
  ;; Case folding of the caller's buffer does not affect the scan.
  (with-temp-buffer
    (setq-local case-fold-search t)
    (mdview-inline-test--check "<![cdata[x]]>" ("<![cdata[x]]>"))
    (mdview-inline-test--check "<![CDATA[x]]>" ((html-inline nil "<![CDATA[x]]>")))))

(ert-deftest mdview-inline-test-nasty-fixture-slices-never-signal ()
  "Random slices and mutations of the showcase fixture never signal."
  (let* ((file (expand-file-name "test/fixtures/showcase.md" mdview-inline-test--root))
         (text (with-temp-buffer (insert-file-contents file) (buffer-string)))
         (len (length text))
         (specials "*_~`[]()!<>&\\\"' \n^#:@.")
         (refs (mdview-inline-test--refs '("foo" "/url" "title") '("bar" "/bar"))))
    (should (> len 100))
    (random "mdview-inline-test")
    (dotimes (_ 300)
      (let* ((a (random len))
             (b (min len (+ a 1 (random 400))))
             (slice (substring text a b)))
        (dotimes (_ (random 6))
          (let ((pos (random (1+ (length slice)))))
            (setq slice (concat (substring slice 0 pos)
                                (string (aref specials (random (length specials))))
                                (substring slice pos)))))
        (dolist (hash (list nil refs))
          (let ((nodes (mdview-inline-parse slice hash)))
            (should (cl-every #'mdview-inline-test--well-formed-p nodes))
            (should (stringp (mdview-node-text (cons 'paragraph (cons nil nodes)))))))))))

;;;; Source positions

;; Text strings carry `mdview-pos', the content offset (index into the
;; parsed string) of the first source character of each run; `code' and
;; `html-inline' nodes carry `:pos' (docs/DESIGN.md section 3, invariant
;; R1).  The oracle below checks every run of every text string against
;; the input.

(defun mdview-inline-test--stretches (string)
  "Return the `mdview-pos' stretches of STRING as (START END VALUE) lists.
A stretch is a maximal range of equal values; characters without the
property form stretches with VALUE nil."
  (let ((start 0) (out nil) (len (length string)))
    (while (< start len)
      (let ((end (or (next-single-property-change start 'mdview-pos string) len)))
        (push (list start end (get-text-property start 'mdview-pos string)) out)
        (setq start end)))
    (nreverse out)))

(defun mdview-inline-test--positioned (nodes)
  "Return the positioned pieces of NODES in document order.
Each is (STRING) for a text string, or (TYPE POS TEXT) for a `code' or
`html-inline' node."
  (let ((out nil))
    (dolist (node nodes)
      (cond
       ((stringp node) (push (list node) out))
       ((memq (mdview-node-type node) '(code html-inline))
        (push (list (mdview-node-type node) (mdview-node-prop node :pos)
                    (car (mdview-node-children node)))
              out))
       (t (setq out (append (reverse (mdview-inline-test--positioned
                                      (mdview-node-children node)))
                            out)))))
    (nreverse out)))

(defun mdview-inline-test--source-matches-p (input value text)
  "Return non-nil when TEXT is what INPUT holds at offset VALUE.
TEXT must be INPUT's characters from VALUE on, except that a run whose
source starts with an entity reference must be exactly that entity
decoded.  A backslash escape points at the escaped character, so it
matches as is."
  (or (and (<= (+ value (length text)) (length input))
           (string= text (substring-no-properties
                          input value (+ value (length text)))))
      (and (< value (length input))
           (eq (aref input value) ?&)
           (eq (string-match mdview-inline--entity-regexp input value) value)
           (string= text (mdview-ast-decode-entities (match-string 0 input))))))

(defun mdview-inline-test--check-positions (input &optional refs)
  "Assert the source positions of parsing INPUT with REFS.
Every character of every text string has `mdview-pos'; every stretch
reads the input at its offset (see `mdview-inline-test--source-matches-p');
`code' and `html-inline' `:pos' point at their text; and the offsets
grow strictly in document order."
  (let ((last -1))
    (dolist (piece (mdview-inline-test--positioned (mdview-inline-parse input refs)))
      (if (null (cdr piece))
          (dolist (stretch (mdview-inline-test--stretches (car piece)))
            (pcase-let* ((`(,start ,end ,value) stretch)
                         (text (substring-no-properties (car piece) start end)))
              (should (equal (list input text (natnump value))
                             (list input text t)))
              (should (equal (list input text value
                                   (and (mdview-inline-test--source-matches-p
                                         input value text)
                                        t))
                             (list input text value t)))
              (should (equal (list input text (> value last)) (list input text t)))
              (setq last value)))
        (pcase-let ((`(,type ,pos ,text) piece))
          (should (equal (list input type (natnump pos)) (list input type t)))
          (should (equal (list input type
                               (subst-char-in-string
                                ?\n ?\s (substring input pos
                                                   (min (length input)
                                                        (+ pos (length text))))))
                         (list input type text)))
          (should (> pos last))
          (setq last pos))))))

(defconst mdview-inline-test--position-inputs
  '("plain text"
    "*emphasis* and _more_ text"
    "**strong** and __strong__"
    "***both*** and *a **b** c* and **a *b* c**"
    "***foo**" "**foo***" "*foo**" "**foo*" "***foo* bar**" "*a* **b *c***"
    "a * b ** c _ d" "*foo bar *" "foo*bar*baz" "_foo_bar_" "**x*y*z**"
    "~~strike~~ and ~one~ and ~~~three~~~"
    "[link](/url \"title\") and [link 2](</a b> 'single')"
    "[*emph* `code` link](/u (paren title))"
    "![image *alt*](/i.png \"t\") and ![](/empty)"
    "[ref] and [full][ref] and [coll][] and [Ref]"
    "[a [b] c](/u)" "[a](b) ]] [[ ! ![ x" "[unclosed *em* link" "[link](/u)x"
    "`code` and `` co`de `` and ` ` and `  ` and `a\nb`"
    "`unclosed and ``also"
    "&amp; &copy; &#35; &#x22; &nosuch; & alone &amp"
    "\\*not\\* \\\\ \\a \\` \\[x\\] \\&amp; end\\"
    "hard  \nbreak and back\\\nslash and soft\n   break"
    "trailing   \n  lead"
    "<http://example.com/a?b> and <mailto:x@y.z> and <me@example.org>"
    "<a href=\"x\">tag</a> <br/> <!-- c --> <?pi?> <!D x> <![CDATA[y]]>"
    "a < b and <notatag and <3"
    "see www.example.com, http://a.b/c?d (and https://x.y/z) or me@ex.org."
    "*www.inside.em* and [www.in.link](/u) and `www.code`"
    "ftp://f.example/x www.a_b.c www.x.org.)"
    "foot[^1] note [^note] and [^bad label]"
    "mixed: *a [b `c` d](/u) e* &lt;f&gt; \\_g\\_ <h> **i**"
    "日本語 **太字** テスト 😀 *a* 👍🏽"
    "")
  "Inputs for the position oracle.")

(defun mdview-inline-test--position-refs ()
  "Return the reference map used with `mdview-inline-test--position-inputs'."
  (mdview-inline-test--refs '("ref" "/ref" "Ref title") '("coll" "/coll")
                            '("full" "/full")))

(ert-deftest mdview-inline-test-positions-oracle ()
  "Every run of every text string maps back to the input it came from."
  (let ((refs (mdview-inline-test--position-refs)))
    (dolist (autolinks '(t nil))
      (let ((mdview-inline-extended-autolinks autolinks))
        (dolist (input mdview-inline-test--position-inputs)
          (mdview-inline-test--check-positions input)
          (mdview-inline-test--check-positions input refs))))))

(ert-deftest mdview-inline-test-positions-oracle-fixtures ()
  "The oracle holds for every paragraph-sized chunk of the fixtures."
  (let ((refs (mdview-inline-test--position-refs)))
    (dolist (file (directory-files
                   (expand-file-name "test/fixtures" mdview-inline-test--root)
                   t "\\.md\\'"))
      (dolist (chunk (split-string
                      (with-temp-buffer (insert-file-contents file) (buffer-string))
                      "\n\n+" t))
        (mdview-inline-test--check-positions chunk refs)))))

(ert-deftest mdview-inline-test-positions-text-runs ()
  "Text runs, escapes, entities and literal characters get exact offsets."
  (pcase-let ((`(,s) (mdview-inline-parse "a\\*b&amp;c\\d<e" nil)))
    ;; a=0, \*=1-2 (the `*' at 2), b=3, &amp;=4-8, c=9, \=10, d=11, <=12, e=13.
    (should (equal (substring-no-properties s) "a*b&c\\d<e"))
    (should (equal (mapcar #'caddr (mdview-inline-test--stretches s))
                   '(0 2 3 4 9 10 11 12 13)))
    (should (equal (mapcar (lambda (i) (mdview-ast-pos-at i s)) (number-sequence 0 8))
                   '(0 2 3 4 9 10 11 12 13))))
  (pcase-let ((`(,s) (mdview-inline-parse "hello world" nil)))
    (should (equal (mdview-inline-test--stretches s) '((0 11 0))))
    (should (= (mdview-ast-pos-at 6 s) 6))))

(ert-deftest mdview-inline-test-positions-emphasis-leftovers ()
  "Delimiter runs cut by emphasis keep exact offsets.
The used delimiters are the inner ones: an opener loses its end, a
closer its start."
  (pcase-let ((`(,star (strong nil ,foo)) (mdview-inline-parse "***foo**" nil)))
    (should (equal star "*"))
    (should (= (get-text-property 0 'mdview-pos star) 0))
    (should (= (get-text-property 0 'mdview-pos foo) 3)))
  (pcase-let ((`((strong nil ,foo) ,star) (mdview-inline-parse "**foo***" nil)))
    (should (equal star "*"))
    (should (= (get-text-property 0 'mdview-pos foo) 2))
    (should (= (get-text-property 0 'mdview-pos star) 7)))
  (pcase-let ((`((emphasis nil ,foo) ,rest) (mdview-inline-parse "*foo***x" nil)))
    (should (equal rest "**x"))
    (should (= (get-text-property 0 'mdview-pos foo) 1))
    (should (equal (mapcar #'caddr (mdview-inline-test--stretches rest)) '(5 7))))
  ;; The closer `***' is used up by two matches; one `*' of the opener
  ;; is left over at its start.
  (pcase-let ((`(,star (strong nil ,a (emphasis nil ,b)))
               (mdview-inline-parse "***a *b***" nil)))
    (should (equal star "*"))
    (should (= (get-text-property 0 'mdview-pos star) 0))
    (should (= (get-text-property 0 'mdview-pos a) 3))
    (should (= (get-text-property 0 'mdview-pos b) 6))))

(ert-deftest mdview-inline-test-positions-code-span ()
  "`code' nodes carry `:pos', the offset of their first content character."
  (should (equal (mdview-inline-parse "a `b c`" nil) '("a " (code (:pos 3) "b c"))))
  (should (equal (mdview-node-props (cadr (mdview-inline-parse "a `b c`" nil)))
                 '(:pos 3)))
  ;; One space stripped on each side: the content starts one further.
  (should (equal (mdview-node-props (car (mdview-inline-parse "`` a ``" nil)))
                 '(:pos 3)))
  (should (equal (mdview-node-props (car (mdview-inline-parse "` `` `" nil)))
                 '(:pos 2)))
  ;; Only spaces, or a space on one side only: nothing is stripped.
  (should (equal (mdview-node-props (car (mdview-inline-parse "`  `" nil)))
                 '(:pos 1)))
  (should (equal (mdview-node-props (car (mdview-inline-parse "` a`" nil)))
                 '(:pos 1)))
  ;; A line ending becomes a space and keeps the length.
  (should (equal (mdview-node-props (nth 2 (mdview-inline-parse "x\n`a\nb`" nil)))
                 '(:pos 3)))
  ;; An unmatched run is text at its first backtick.
  (pcase-let ((`(,s ,_) (mdview-inline-parse "a ``b`c`" nil)))
    (should (equal (mapcar #'caddr (mdview-inline-test--stretches s)) '(0 2 4)))))

(ert-deftest mdview-inline-test-positions-html-inline ()
  "`html-inline' nodes carry `:pos', the offset of their `<'."
  (should (equal (mapcar (lambda (n) (and (consp n) (mdview-node-prop n :pos)))
                         (mdview-inline-parse "a <b>c</b> <!-- d -->" nil))
                 '(nil 2 nil 6 nil 11))))

(ert-deftest mdview-inline-test-positions-links-and-breaks ()
  "Link text, autolinks, brackets and text after breaks get exact offsets."
  (pcase-let ((`((link ,_ ,text) ,rest) (mdview-inline-parse "[ab](/u) ]" nil)))
    (should (= (get-text-property 0 'mdview-pos text) 1))
    (should (equal (mapcar #'caddr (mdview-inline-test--stretches rest)) '(8 9))))
  (pcase-let ((`((link ,_ ,uri) ,_ (link ,_ ,mail))
               (mdview-inline-parse "<http://a.b> <me@x.org>" nil)))
    (should (= (get-text-property 0 'mdview-pos uri) 1))
    (should (= (get-text-property 0 'mdview-pos mail) 14)))
  (pcase-let ((`(,a ,_ ,b) (mdview-inline-parse "a  \nb" nil)))
    (should (equal (list a b) '("a" "b")))
    (should (equal (list (get-text-property 0 'mdview-pos a)
                         (get-text-property 0 'mdview-pos b))
                   '(0 4))))
  (pcase-let ((`(,_ ,_ ,b) (mdview-inline-parse "a\\\n   b" nil)))
    (should (= (get-text-property 0 'mdview-pos b) 6)))
  (pcase-let ((`(,a ,_ ,b) (mdview-inline-parse "x[^1] y" nil)))
    (should (equal (list (get-text-property 0 'mdview-pos a)
                         (get-text-property 0 'mdview-pos b))
                   '(0 5)))))

(ert-deftest mdview-inline-test-positions-autolink-split ()
  "Bare URLs split out of a text run are re-based on both sides."
  (let ((mdview-inline-extended-autolinks t))
    (pcase-let ((`(,a ,_ ,b (link ,props ,url) ,c (link ,_ ,mail) ,d)
                 (mdview-inline-parse "x *y* see www.ex.org, or me@ex.org." nil)))
      (should (equal (list a b c d) '("x " " see " ", or " ".")))
      (should (equal (plist-get props :url) "http://www.ex.org"))
      ;; The link's URL is a plain string; only text carries positions.
      (should-not (text-properties-at 0 (plist-get props :url)))
      (should (equal (mapcar (lambda (s) (get-text-property 0 'mdview-pos s))
                             (list a b url c mail d))
                     '(0 5 10 20 25 34)))
      (should (equal (mdview-inline-test--stretches url) '((0 10 10))))
      (should (= (mdview-ast-pos-at 3 c) 23)))))

(ert-deftest mdview-inline-test-positions-degraded ()
  "Input nested too deeply degrades to one string with `mdview-pos' 0."
  (let* ((mdview-inline-max-depth 2)
         (input "*a **b *c* d** e*")
         (nodes (mdview-inline-parse input nil)))
    (should (equal nodes (list input)))
    (should (equal (mdview-inline-test--stretches (car nodes))
                   (list (list 0 (length input) 0))))
    (should (= (mdview-ast-pos-at 7 (car nodes)) 7))))

(provide 'mdview-inline-test)
;;; mdview-inline-test.el ends here
