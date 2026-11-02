;;; mdview-ast-test.el --- Tests for mdview-ast  -*- lexical-binding: t; -*-

;; This file is part of mdview, distributed under the MIT license; see
;; LICENSE in the repository root.

;;; Commentary:

;; ERT tests for the AST helpers: node accessors, plain-text extraction,
;; GitHub-style slugs and HTML entity decoding (docs/DESIGN.md §3, §13).

;;; Code:

(require 'ert)
(require 'mdview-ast)

;;;; Nodes

(ert-deftest mdview-ast-node-shape ()
  "The constructor builds (TYPE PLIST . CHILDREN)."
  (should (equal (mdview-node 'paragraph '(:line 3) "a" "b")
                 '(paragraph (:line 3) "a" "b")))
  (should (equal (mdview-node 'thematic-break '(:line 1))
                 '(thematic-break (:line 1))))
  (should (equal (mdview-node 'hard-break nil) '(hard-break nil))))

(ert-deftest mdview-ast-node-type ()
  (should (eq (mdview-node-type "plain") 'text))
  (should (eq (mdview-node-type "") 'text))
  (should (eq (mdview-node-type (mdview-node 'heading '(:level 2) "x")) 'heading))
  (should (eq (mdview-node-type (mdview-node 'soft-break nil)) 'soft-break)))

(ert-deftest mdview-ast-node-props ()
  (let ((node (mdview-node 'heading '(:level 2 :id "x") "x")))
    (should (equal (mdview-node-props node) '(:level 2 :id "x")))
    (should (= (mdview-node-prop node :level) 2))
    (should (equal (mdview-node-prop node :id) "x"))
    (should-not (mdview-node-prop node :line)))
  (should-not (mdview-node-props "text"))
  (should-not (mdview-node-prop "text" :level))
  (should-not (mdview-node-props (mdview-node 'hard-break nil))))

(ert-deftest mdview-ast-node-children ()
  (let ((inner (mdview-node 'strong nil "b")))
    (should (equal (mdview-node-children (mdview-node 'paragraph nil "a" inner))
                   (list "a" inner))))
  (should-not (mdview-node-children "text"))
  (should-not (mdview-node-children (mdview-node 'thematic-break '(:line 1)))))

;;;; Plain text

(ert-deftest mdview-ast-node-text-string ()
  (should (equal (mdview-node-text "hello") "hello"))
  (should (equal (mdview-node-text "") ""))
  (should (equal (mdview-node-text nil) "")))

(ert-deftest mdview-ast-node-text-recursive ()
  (let ((node (mdview-node 'paragraph '(:line 1)
                           "a "
                           (mdview-node 'emphasis nil
                                        "b "
                                        (mdview-node 'strong nil "c"))
                           " "
                           (mdview-node 'link '(:url "u") "d"))))
    (should (equal (mdview-node-text node) "a b c d"))))

(ert-deftest mdview-ast-node-text-leaves ()
  "Code spans yield their string; breaks become space / newline."
  (should (equal (mdview-node-text (mdview-node 'code nil "x = 1")) "x = 1"))
  (should (equal (mdview-node-text (mdview-node 'soft-break nil)) " "))
  (should (equal (mdview-node-text (mdview-node 'hard-break nil)) "\n"))
  (should (equal (mdview-node-text
                  (mdview-node 'paragraph nil
                               "one" (mdview-node 'soft-break nil)
                               "two" (mdview-node 'hard-break nil) "three"))
                 "one two\nthree")))

(ert-deftest mdview-ast-node-text-image ()
  "Images contribute their :alt; the description is the fallback."
  (should (equal (mdview-node-text
                  (mdview-node 'image '(:url "p.png" :alt "a picture")
                               "ignored"))
                 "a picture"))
  (should (equal (mdview-node-text
                  (mdview-node 'image '(:url "p.png") "desc "
                               (mdview-node 'emphasis nil "text")))
                 "desc text"))
  (should (equal (mdview-node-text
                  (mdview-node 'paragraph nil "see "
                               (mdview-node 'image '(:url "u" :alt "alt"))))
                 "see alt")))

(ert-deftest mdview-ast-node-text-html-and-empty ()
  "Inline HTML is stripped; raw HTML blocks and empty nodes behave."
  (should (equal (mdview-node-text
                  (mdview-node 'paragraph nil "a"
                               (mdview-node 'html-inline nil "<b>") "b"))
                 "ab"))
  (should (equal (mdview-node-text (mdview-node 'html-block '(:line 1) "<div>"))
                 "<div>"))
  (should (equal (mdview-node-text
                  (mdview-node 'footnote-reference '(:label "x" :index 1)))
                 ""))
  (should (equal (mdview-node-text (mdview-node 'thematic-break '(:line 1))) "")))

(ert-deftest mdview-ast-node-text-document ()
  (let ((doc (mdview-node 'document '(:refs nil :footnotes nil)
                          (mdview-node 'heading '(:level 1) "Title")
                          (mdview-node 'paragraph nil "Body"))))
    (should (equal (mdview-node-text doc) "TitleBody"))))

;;;; Walking

(ert-deftest mdview-ast-map-preorder ()
  (let ((doc (mdview-node 'document nil
                          (mdview-node 'paragraph nil
                                       "a" (mdview-node 'strong nil "b"))
                          (mdview-node 'thematic-break nil))))
    (should (equal (mdview-ast-map #'mdview-node-type doc)
                   '(document paragraph text strong text thematic-break)))
    (should (equal (delq nil (mdview-ast-map
                              (lambda (n) (and (stringp n) n)) doc))
                   '("a" "b")))))

(ert-deftest mdview-ast-map-string-and-deep ()
  "A bare string is visited once; deep trees do not exhaust the stack."
  (should (equal (mdview-ast-map #'identity "s") '("s")))
  (let ((node "leaf"))
    (dotimes (_ 20000)
      (setq node (mdview-node 'blockquote nil node)))
    (should (= (length (mdview-ast-map #'ignore node)) 20001))))

;;;; Slugs

(ert-deftest mdview-slug-basic ()
  (should (equal (mdview-slug "Hello World") "hello-world"))
  (should (equal (mdview-slug "Hello, World!") "hello-world"))
  (should (equal (mdview-slug "UPPER lower") "upper-lower"))
  (should (equal (mdview-slug "1. Numbered item") "1-numbered-item"))
  (should (equal (mdview-slug "") "")))

(ert-deftest mdview-slug-punctuation ()
  "Only hyphens and underscores survive among punctuation; spaces stay as hyphens."
  (should (equal (mdview-slug "C++ and C#") "c-and-c"))
  (should (equal (mdview-slug "snake_case_name") "snake_case_name"))
  (should (equal (mdview-slug "a - b") "a---b"))
  (should (equal (mdview-slug "double  space") "double--space"))
  (should (equal (mdview-slug "`code` in heading") "code-in-heading"))
  (should (equal (mdview-slug "tabs\tand\ttabs") "tabsandtabs"))
  (should (equal (mdview-slug "What's up?") "whats-up"))
  (should (equal (mdview-slug "a/b.c:d") "abcd")))

(ert-deftest mdview-slug-unicode ()
  "Letters and digits of any script are kept and downcased; symbols go."
  (should (equal (mdview-slug "Über Straße") "über-straße"))
  (should (equal (mdview-slug "Привет Мир") "привет-мир"))
  (should (equal (mdview-slug "日本語 テスト") "日本語-テスト"))
  (should (equal (mdview-slug "Café naïve") "café-naïve"))
  (should (equal (mdview-slug "Emoji 😀 heading") "emoji--heading"))
  (should (equal (mdview-slug "Arrows → here") "arrows--here")))

(ert-deftest mdview-slug-no-dedupe ()
  "Duplicates are not disambiguated here (the parser does that)."
  (should (equal (mdview-slug "Same") (mdview-slug "Same"))))

;;;; Entities

(ert-deftest mdview-ast-entity-table-coverage ()
  (should (>= (hash-table-count mdview-ast-entity-table) 250))
  (dolist (name '("amp" "lt" "gt" "quot" "apos" "nbsp" "copy" "reg" "trade"
                  "mdash" "ndash" "hellip" "laquo" "raquo" "lsquo" "rsquo"
                  "ldquo" "rdquo" "bull" "middot" "deg" "plusmn" "times"
                  "divide" "frac12" "frac14" "frac34" "para" "sect" "dagger"
                  "euro" "pound" "yen" "cent" "larr" "rarr" "uarr" "darr"
                  "harr" "infin" "ne" "le" "ge" "sum" "prod" "radic"
                  "alpha" "beta" "gamma" "delta" "epsilon" "zeta" "eta"
                  "theta" "iota" "kappa" "lambda" "mu" "nu" "xi" "omicron"
                  "pi" "rho" "sigmaf" "sigma" "tau" "upsilon" "phi" "chi"
                  "psi" "omega" "Alpha" "Beta" "Gamma" "Delta" "Epsilon"
                  "Zeta" "Eta" "Theta" "Iota" "Kappa" "Lambda" "Mu" "Nu"
                  "Xi" "Omicron" "Pi" "Rho" "Sigma" "Tau" "Upsilon" "Phi"
                  "Chi" "Psi" "Omega"))
    (should (gethash name mdview-ast-entity-table)))
  ;; U+03A2 is unassigned: no capitalized final sigma.
  (should-not (gethash "Sigmaf" mdview-ast-entity-table)))

(ert-deftest mdview-ast-entity-table-values ()
  (should (= (gethash "amp" mdview-ast-entity-table) ?&))
  (should (= (gethash "nbsp" mdview-ast-entity-table) #xA0))
  (should (= (gethash "yuml" mdview-ast-entity-table) #xFF))
  (should (= (gethash "times" mdview-ast-entity-table) ?×))
  (should (= (gethash "divide" mdview-ast-entity-table) ?÷))
  (should (= (gethash "alpha" mdview-ast-entity-table) ?α))
  (should (= (gethash "Omega" mdview-ast-entity-table) ?Ω))
  (should (= (gethash "sigmaf" mdview-ast-entity-table) ?ς))
  (should (= (gethash "frac12" mdview-ast-entity-table) ?½))
  (should (= (gethash "euro" mdview-ast-entity-table) ?€))
  (should (= (gethash "rarr" mdview-ast-entity-table) ?→)))

(ert-deftest mdview-ast-decode-named ()
  (should (equal (mdview-ast-decode-entities "&amp;") "&"))
  (should (equal (mdview-ast-decode-entities "a &lt; b &gt; c") "a < b > c"))
  (should (equal (mdview-ast-decode-entities "&quot;q&quot; &apos;a&apos;")
                 "\"q\" 'a'"))
  (should (equal (mdview-ast-decode-entities "x&nbsp;y") "x y"))
  (should (equal (mdview-ast-decode-entities "&copy; 2026 &mdash; &hellip;")
                 "© 2026 — …"))
  (should (equal (mdview-ast-decode-entities "&frac12;&frac14;&frac34;") "½¼¾"))
  (should (equal (mdview-ast-decode-entities "&Omega;&omega;&alpha;") "Ωωα"))
  (should (equal (mdview-ast-decode-entities "&larr;&rarr;&uarr;&darr;&harr;")
                 "←→↑↓↔"))
  (should (equal (mdview-ast-decode-entities "&ne;&le;&ge;&infin;&sum;&prod;&radic;")
                 "≠≤≥∞∑∏√"))
  (should (equal (mdview-ast-decode-entities "&auml;&Eacute;&szlig;") "äÉß"))
  (should (equal (mdview-ast-decode-entities "&AMP;&LT;") "&<")))

(ert-deftest mdview-ast-decode-numeric ()
  (should (equal (mdview-ast-decode-entities "&#35;") "#"))
  (should (equal (mdview-ast-decode-entities "&#1234;") "Ӓ"))
  (should (equal (mdview-ast-decode-entities "&#992;") "Ϡ"))
  (should (equal (mdview-ast-decode-entities "&#X22;") "\""))
  (should (equal (mdview-ast-decode-entities "&#XD06;") "ആ"))
  (should (equal (mdview-ast-decode-entities "&#xcab;") "ಫ"))
  (should (equal (mdview-ast-decode-entities "&#x1F600;") "😀"))
  (should (equal (mdview-ast-decode-entities "&#0000065;") "A")))

(ert-deftest mdview-ast-decode-invalid-codepoints ()
  "Zero, surrogates and out-of-range values become U+FFFD."
  (should (equal (mdview-ast-decode-entities "&#0;") "�"))
  (should (equal (mdview-ast-decode-entities "&#x0;") "�"))
  (should (equal (mdview-ast-decode-entities "&#xD800;") "�"))
  (should (equal (mdview-ast-decode-entities "&#xDFFF;") "�"))
  (should (equal (mdview-ast-decode-entities "&#1234567;") "�"))
  (should (equal (mdview-ast-decode-entities "&#x110000;") "�"))
  (should (equal (mdview-ast-decode-entities "&#xFFFFFF;") "�")))

(ert-deftest mdview-ast-decode-not-entities ()
  "Malformed or unknown references are left untouched."
  (dolist (s '("&nosuch;" "&Amp;" "&amp" "&;" "&#;" "&#x;" "&#12345678;"
               "&#xABCDEF1;" "&#x1F600" "& amp;" "&a;" "&1a;"
               "&ThisNameIsFarTooLongToBeAnEntityNameAtAll;"))
    (should (equal (mdview-ast-decode-entities s) s))))

(ert-deftest mdview-ast-decode-mixed ()
  (should (equal (mdview-ast-decode-entities "Tom &amp; Jerry &#8212; &nosuch; &#x26;")
                 "Tom & Jerry — &nosuch; &"))
  (should (equal (mdview-ast-decode-entities "&amp;amp;") "&amp;"))
  (should (equal (mdview-ast-decode-entities "&amp;&amp;") "&&"))
  (should (equal (mdview-ast-decode-entities "no entities here")
                 "no entities here")))

(ert-deftest mdview-ast-decode-preserves-properties ()
  "Text properties outside the replaced spans survive."
  (let* ((in (concat (propertize "ab" 'face 'bold) " &amp; "
                     (propertize "cd" 'face 'italic)))
         (out (mdview-ast-decode-entities in)))
    (should (equal (substring-no-properties out) "ab & cd"))
    (should (eq (get-text-property 0 'face out) 'bold))
    (should (eq (get-text-property 5 'face out) 'italic))))

(provide 'mdview-ast-test)
;;; mdview-ast-test.el ends here
