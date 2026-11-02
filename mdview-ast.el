;;; mdview-ast.el --- AST nodes and shared helpers for mdview  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Vadim Zaliva

;; Author: Vadim Zaliva
;; Keywords: text, docs
;; Package-Requires: ((emacs "29.1"))

;; This file is part of mdview, distributed under the MIT license; see
;; LICENSE in the repository root.

;;; Commentary:

;; The AST contract shared by the parser and the renderer (docs/DESIGN.md
;; section 3).  A node is a list (TYPE PLIST . CHILDREN); a plain string
;; is a text node.  This file provides the constructor, the accessors, the
;; recursive plain-text extraction used for heading anchors and image alt
;; text, GitHub-style slugs, and HTML entity decoding.  It has no
;; dependencies on the rest of the package.

;;; Code:

;;;; Nodes

(defun mdview-node (type plist &rest children)
  "Construct an AST node of TYPE with property list PLIST and CHILDREN.
TYPE is a symbol such as `paragraph' or `emphasis'.  PLIST holds the
node's properties (see `mdview-node-prop').  Each of CHILDREN is either
another node or a string (a text node).  The result has the shape
\(TYPE PLIST . CHILDREN)."
  (cons type (cons plist children)))

(defun mdview-node-type (node)
  "Return the type symbol of NODE.
A string NODE is a text node and has type `text'."
  (if (stringp node) 'text (car node)))

(defun mdview-node-props (node)
  "Return the property list of NODE; nil for a text node (a string)."
  (if (stringp node) nil (cadr node)))

(defun mdview-node-prop (node key)
  "Return the value of property KEY of NODE, or nil.
KEY is a keyword such as `:level' or `:url'."
  (plist-get (mdview-node-props node) key))

(defun mdview-node-children (node)
  "Return the list of children of NODE; nil for a text node (a string)."
  (if (stringp node) nil (cddr node)))

(defun mdview-node-text (node)
  "Return the plain-text content of NODE, recursively.
A string is returned as is.  `code' spans and `html-block' nodes yield
their raw string child.  An `image' contributes its `:alt' property (or
the text of its description when `:alt' is absent).  A `soft-break' is a
single space, a `hard-break' a newline, and `html-inline' tags contribute
nothing.  Everything else is the concatenation of its children.  The
result carries no text properties beyond those of the input strings."
  (cond
   ((stringp node) node)
   ((null node) "")
   (t (pcase (mdview-node-type node)
        ('soft-break " ")
        ('hard-break "\n")
        ('html-inline "")
        ('image (or (mdview-node-prop node :alt)
                    (mdview-ast--children-text node)))
        (_ (mdview-ast--children-text node))))))

(defun mdview-ast--children-text (node)
  "Concatenate the plain text of the children of NODE."
  (mapconcat #'mdview-node-text (mdview-node-children node) ""))

(defun mdview-ast-map (function node)
  "Call FUNCTION on NODE and on each of its descendants, depth-first.
The walk is pre-order (a node before its children) and visits text
nodes (strings) too.  Return the list of FUNCTION's results in visit
order.  The walk uses an explicit stack, so arbitrarily deep trees are
safe."
  (let ((stack (list node))
        (results nil))
    (while stack
      (let ((current (pop stack)))
        (push (funcall function current) results)
        (unless (stringp current)
          (setq stack (append (mdview-node-children current) stack)))))
    (nreverse results)))

;;;; Slugs

(defun mdview-slug (string)
  "Return the GitHub-style anchor slug of heading text STRING.
The text is downcased; every character that is not a letter, a digit, a
combining mark (any script), a space, a hyphen or an underscore is
removed; spaces become hyphens.  Nothing is trimmed or collapsed, and no
uniqueness suffix is added -- the parser appends -1, -2 ... to duplicate
slugs within a document."
  (subst-char-in-string
   ?\s ?-
   (replace-regexp-in-string "[^[:alnum:]_ -]+" "" (downcase string) t t)))

;;;; HTML entities

(defconst mdview-ast--latin1-entity-names
  ["nbsp" "iexcl" "cent" "pound" "curren" "yen" "brvbar" "sect" "uml" "copy"
   "ordf" "laquo" "not" "shy" "reg" "macr" "deg" "plusmn" "sup2" "sup3"
   "acute" "micro" "para" "middot" "cedil" "sup1" "ordm" "raquo" "frac14" "frac12"
   "frac34" "iquest" "Agrave" "Aacute" "Acirc" "Atilde" "Auml" "Aring" "AElig" "Ccedil"
   "Egrave" "Eacute" "Ecirc" "Euml" "Igrave" "Iacute" "Icirc" "Iuml" "ETH" "Ntilde"
   "Ograve" "Oacute" "Ocirc" "Otilde" "Ouml" "times" "Oslash" "Ugrave" "Uacute" "Ucirc"
   "Uuml" "Yacute" "THORN" "szlig" "agrave" "aacute" "acirc" "atilde" "auml" "aring"
   "aelig" "ccedil" "egrave" "eacute" "ecirc" "euml" "igrave" "iacute" "icirc" "iuml"
   "eth" "ntilde" "ograve" "oacute" "ocirc" "otilde" "ouml" "divide" "oslash" "ugrave"
   "uacute" "ucirc" "uuml" "yacute" "thorn" "yuml"]
  "Entity names for the code points U+00A0 through U+00FF, in order.")

(defconst mdview-ast--greek-entity-names
  ["alpha" "beta" "gamma" "delta" "epsilon" "zeta" "eta" "theta" "iota"
   "kappa" "lambda" "mu" "nu" "xi" "omicron" "pi" "rho" "sigmaf" "sigma"
   "tau" "upsilon" "phi" "chi" "psi" "omega"]
  "Lower-case Greek entity names for U+03B1 through U+03C9, in order.
The capitalized names map to U+0391 onwards; U+03A2 (the position of
`sigmaf') is unassigned and has no capitalized entity.")

(defconst mdview-ast--entity-alist
  '(;; XML and ASCII punctuation
    ("amp" . 38) ("AMP" . 38) ("lt" . 60) ("LT" . 60) ("gt" . 62) ("GT" . 62)
    ("quot" . 34) ("QUOT" . 34) ("apos" . 39) ("Tab" . 9) ("NewLine" . 10)
    ("excl" . 33) ("num" . 35) ("dollar" . 36) ("percnt" . 37) ("lpar" . 40)
    ("rpar" . 41) ("ast" . 42) ("midast" . 42) ("plus" . 43) ("comma" . 44)
    ("period" . 46) ("sol" . 47) ("colon" . 58) ("semi" . 59) ("equals" . 61)
    ("quest" . 63) ("commat" . 64) ("lsqb" . 91) ("lbrack" . 91) ("bsol" . 92)
    ("rsqb" . 93) ("rbrack" . 93) ("Hat" . 94) ("lowbar" . 95) ("UnderBar" . 95)
    ("grave" . 96) ("DiacriticalGrave" . 96) ("lcub" . 123) ("lbrace" . 123)
    ("verbar" . 124) ("vert" . 124) ("VerticalLine" . 124) ("rcub" . 125)
    ("rbrace" . 125)
    ;; HTML5 aliases for Latin-1 characters
    ("NonBreakingSpace" . 160) ("COPY" . 169) ("REG" . 174) ("circledR" . 174)
    ("pm" . 177) ("PlusMinus" . 177) ("centerdot" . 183) ("CenterDot" . 183)
    ("half" . 189) ("angst" . 197) ("div" . 247)
    ;; Latin Extended, spacing modifiers
    ("OElig" . 338) ("oelig" . 339) ("Scaron" . 352) ("scaron" . 353)
    ("Yuml" . 376) ("fnof" . 402) ("circ" . 710) ("tilde" . 732)
    ("DiacriticalTilde" . 732)
    ;; Greek variants
    ("thetasym" . 977) ("thetav" . 977) ("upsih" . 978) ("Upsi" . 978)
    ("phiv" . 981) ("varphi" . 981) ("piv" . 982) ("varpi" . 982)
    ("epsiv" . 1013) ("varepsilon" . 1013) ("ohm" . 937)
    ;; General punctuation
    ("ensp" . 8194) ("emsp" . 8195) ("emsp13" . 8196) ("emsp14" . 8197)
    ("numsp" . 8199) ("puncsp" . 8200) ("thinsp" . 8201) ("ThinSpace" . 8201)
    ("hairsp" . 8202) ("VeryThinSpace" . 8202) ("ZeroWidthSpace" . 8203)
    ("zwnj" . 8204) ("zwj" . 8205) ("lrm" . 8206) ("rlm" . 8207)
    ("hyphen" . 8208) ("dash" . 8208) ("ndash" . 8211) ("mdash" . 8212)
    ("horbar" . 8213) ("Verbar" . 8214) ("Vert" . 8214)
    ("lsquo" . 8216) ("OpenCurlyQuote" . 8216) ("rsquo" . 8217) ("rsquor" . 8217)
    ("CloseCurlyQuote" . 8217) ("sbquo" . 8218) ("lsquor" . 8218)
    ("ldquo" . 8220) ("OpenCurlyDoubleQuote" . 8220) ("rdquo" . 8221)
    ("rdquor" . 8221) ("CloseCurlyDoubleQuote" . 8221) ("bdquo" . 8222)
    ("ldquor" . 8222) ("dagger" . 8224) ("Dagger" . 8225) ("ddagger" . 8225)
    ("bull" . 8226) ("bullet" . 8226) ("nldr" . 8229) ("hellip" . 8230)
    ("mldr" . 8230) ("permil" . 8240) ("pertenk" . 8241) ("prime" . 8242)
    ("Prime" . 8243) ("tprime" . 8244) ("bprime" . 8245) ("backprime" . 8245)
    ("lsaquo" . 8249) ("rsaquo" . 8250) ("oline" . 8254) ("OverBar" . 8254)
    ("caret" . 8257) ("hybull" . 8259) ("frasl" . 8260) ("bsemi" . 8271)
    ("qprime" . 8279) ("MediumSpace" . 8287) ("NoBreak" . 8288)
    ;; Currency and letter-like symbols
    ("euro" . 8364) ("hbar" . 8463) ("planck" . 8463) ("image" . 8465)
    ("Im" . 8465) ("ell" . 8467) ("naturals" . 8469) ("numero" . 8470)
    ("copysr" . 8471) ("weierp" . 8472) ("wp" . 8472) ("primes" . 8473)
    ("rationals" . 8474) ("real" . 8476) ("Re" . 8476) ("reals" . 8477)
    ("trade" . 8482) ("TRADE" . 8482) ("integers" . 8484) ("mho" . 8487)
    ("complexes" . 8450) ("alefsym" . 8501) ("aleph" . 8501)
    ;; Fractions
    ("frac13" . 8531) ("frac23" . 8532) ("frac15" . 8533) ("frac25" . 8534)
    ("frac35" . 8535) ("frac45" . 8536) ("frac16" . 8537) ("frac56" . 8538)
    ("frac18" . 8539) ("frac38" . 8540) ("frac58" . 8541) ("frac78" . 8542)
    ;; Arrows
    ("larr" . 8592) ("leftarrow" . 8592) ("LeftArrow" . 8592) ("uarr" . 8593)
    ("uparrow" . 8593) ("UpArrow" . 8593) ("rarr" . 8594) ("rightarrow" . 8594)
    ("RightArrow" . 8594) ("darr" . 8595) ("downarrow" . 8595)
    ("DownArrow" . 8595) ("harr" . 8596) ("leftrightarrow" . 8596)
    ("LeftRightArrow" . 8596) ("varr" . 8597) ("updownarrow" . 8597)
    ("nwarr" . 8598) ("nearr" . 8599) ("searr" . 8600) ("swarr" . 8601)
    ("map" . 8614) ("mapsto" . 8614) ("crarr" . 8629) ("lArr" . 8656)
    ("Leftarrow" . 8656) ("uArr" . 8657) ("Uparrow" . 8657) ("rArr" . 8658)
    ("Rightarrow" . 8658) ("Implies" . 8658) ("dArr" . 8659) ("Downarrow" . 8659)
    ("hArr" . 8660) ("Leftrightarrow" . 8660) ("iff" . 8660)
    ("longleftarrow" . 10229) ("longrightarrow" . 10230)
    ("Longleftarrow" . 10232) ("Longrightarrow" . 10233)
    ;; Mathematical operators
    ("forall" . 8704) ("ForAll" . 8704) ("comp" . 8705) ("part" . 8706)
    ("PartialD" . 8706) ("exist" . 8707) ("Exists" . 8707) ("nexist" . 8708)
    ("empty" . 8709) ("emptyset" . 8709) ("varnothing" . 8709) ("nabla" . 8711)
    ("Del" . 8711) ("isin" . 8712) ("isinv" . 8712) ("in" . 8712)
    ("Element" . 8712) ("notin" . 8713) ("NotElement" . 8713) ("ni" . 8715)
    ("niv" . 8715) ("prod" . 8719) ("Product" . 8719) ("coprod" . 8720)
    ("sum" . 8721) ("Sum" . 8721) ("minus" . 8722) ("mp" . 8723)
    ("MinusPlus" . 8723) ("setminus" . 8726) ("smallsetminus" . 8726)
    ("lowast" . 8727) ("compfn" . 8728) ("radic" . 8730) ("Sqrt" . 8730)
    ("prop" . 8733) ("propto" . 8733) ("infin" . 8734) ("ang" . 8736)
    ("angle" . 8736) ("mid" . 8739) ("parallel" . 8741) ("and" . 8743)
    ("wedge" . 8743) ("or" . 8744) ("vee" . 8744) ("cap" . 8745) ("cup" . 8746)
    ("int" . 8747) ("Integral" . 8747) ("there4" . 8756) ("therefore" . 8756)
    ("because" . 8757) ("sim" . 8764) ("Tilde" . 8764) ("cong" . 8773)
    ("asymp" . 8776) ("approx" . 8776) ("ne" . 8800) ("NotEqual" . 8800)
    ("equiv" . 8801) ("Congruent" . 8801) ("le" . 8804) ("leq" . 8804)
    ("ge" . 8805) ("geq" . 8805) ("ll" . 8810) ("gg" . 8811) ("sub" . 8834)
    ("subset" . 8834) ("sup" . 8835) ("supset" . 8835) ("nsub" . 8836)
    ("sube" . 8838) ("subseteq" . 8838) ("supe" . 8839) ("supseteq" . 8839)
    ("oplus" . 8853) ("otimes" . 8855) ("perp" . 8869) ("bottom" . 8869)
    ("sdot" . 8901) ("lceil" . 8968) ("rceil" . 8969) ("lfloor" . 8970)
    ("rfloor" . 8971) ("lang" . 10216) ("langle" . 10216) ("rang" . 10217)
    ("rangle" . 10217)
    ;; Miscellaneous symbols
    ("squ" . 9633) ("square" . 9633) ("squf" . 9642) ("blacksquare" . 9642)
    ("utri" . 9653) ("rtri" . 9657) ("dtri" . 9663) ("ltri" . 9667)
    ("loz" . 9674) ("lozenge" . 9674) ("cir" . 9675) ("starf" . 9733)
    ("bigstar" . 9733) ("star" . 9734) ("phone" . 9742) ("female" . 9792)
    ("male" . 9794) ("spades" . 9824) ("spadesuit" . 9824) ("clubs" . 9827)
    ("clubsuit" . 9827) ("hearts" . 9829) ("heartsuit" . 9829) ("diams" . 9830)
    ("diamondsuit" . 9830) ("sung" . 9834) ("flat" . 9837) ("natural" . 9838)
    ("sharp" . 9839) ("check" . 10003) ("checkmark" . 10003) ("cross" . 10007)
    ("malt" . 10016) ("maltese" . 10016) ("sext" . 10038))
  "Named HTML entities (beyond Latin-1 and Greek) and their code points.
The Latin-1 block comes from `mdview-ast--latin1-entity-names' and the
Greek letters from `mdview-ast--greek-entity-names'.")

(defun mdview-ast--build-entity-table ()
  "Return a hash table mapping every known entity name to its code point."
  (let ((table (make-hash-table :test #'equal :size 600)))
    (dotimes (i (length mdview-ast--latin1-entity-names))
      (puthash (aref mdview-ast--latin1-entity-names i) (+ 160 i) table))
    (dotimes (i (length mdview-ast--greek-entity-names))
      (let ((name (aref mdview-ast--greek-entity-names i)))
        (puthash name (+ #x3B1 i) table)
        (unless (string= name "sigmaf")
          (puthash (capitalize name) (+ #x391 i) table))))
    (pcase-dolist (`(,name . ,code) mdview-ast--entity-alist)
      (puthash name code table))
    table))

(defconst mdview-ast-entity-table (mdview-ast--build-entity-table)
  "Hash table from HTML entity name (string, without & and ;) to code point.")

(defconst mdview-ast--entity-regexp
  (concat "&\\(?:"
          "#[xX]\\([[:xdigit:]]\\{1,6\\}\\)"        ; 1: hexadecimal
          "\\|#\\([0-9]\\{1,7\\}\\)"                ; 2: decimal
          "\\|\\([A-Za-z][A-Za-z0-9]\\{1,31\\}\\)"  ; 3: named
          "\\);")
  "Regexp matching one HTML entity or numeric character reference.
The bounded repetitions follow CommonMark's limits, so matching is linear.")

(defun mdview-ast--codepoint-string (code)
  "Return the string for code point CODE, or U+FFFD when CODE is invalid.
As in CommonMark, zero, surrogates and values above U+10FFFF are invalid."
  (if (or (<= code 0)
          (> code #x10FFFF)
          (<= #xD800 code #xDFFF))
      (string #xFFFD)
    (string code)))

(defun mdview-ast--decode-entity-match (match)
  "Return the replacement for the entity text MATCH, or MATCH itself.
Called from `replace-regexp-in-string' with the match data set."
  (cond
   ((match-beginning 1)
    (mdview-ast--codepoint-string (string-to-number (match-string 1 match) 16)))
   ((match-beginning 2)
    (mdview-ast--codepoint-string (string-to-number (match-string 2 match))))
   (t
    (let ((code (gethash (match-string 3 match) mdview-ast-entity-table)))
      (if code (mdview-ast--codepoint-string code) match)))))

(defun mdview-ast-decode-entities (string)
  "Decode HTML entities and numeric character references in STRING.
Named entities (\"&amp;\", \"&copy;\" ...) are looked up in
`mdview-ast-entity-table'; unknown names are left untouched.  Decimal
\(\"&#123;\") and hexadecimal (\"&#x1F;\") references are decoded; code
point zero, surrogates and values above U+10FFFF become U+FFFD, as
CommonMark requires.  Text properties of STRING are preserved outside the
replaced spans."
  (if (not (string-search "&" string))
      string
    (replace-regexp-in-string mdview-ast--entity-regexp
                              #'mdview-ast--decode-entity-match
                              string t t)))

(provide 'mdview-ast)
;;; mdview-ast.el ends here
