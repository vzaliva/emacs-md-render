;;; mdview-image.el --- Image display for mdview  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Vadim Zaliva

;; Author: Vadim Zaliva
;; Keywords: text, docs
;; Package-Requires: ((emacs "29.1"))

;; This file is part of mdview, distributed under the MIT license; see
;; LICENSE in the repository root.

;;; Commentary:

;; Images for mdview (docs/DESIGN.md §6 "Images", §9 and §15).
;;
;; `mdview-image-insert' puts either a real image or a textual
;; placeholder ("🖼 ALT", styled like a link) at point and reports how
;; many columns it occupies.  Local images are resolved against the
;; document's directory and shown synchronously.  Remote http(s) images
;; get a placeholder first and are fetched asynchronously with
;; `url-retrieve' through a small queue of this module's own, which
;; limits the number of parallel fetches (`mdview-image-max-parallel')
;; and gives up after `mdview-image-timeout' seconds.  When the bytes
;; arrive the placeholder is swapped for the image, provided the view
;; buffer and the placeholder still exist; the line keeps its width
;; because the difference between the placeholder and the image is taken
;; from the line's trailing padding.  Views whose placeholders were
;; replaced are announced on `mdview-image-update-functions' so that the
;; viewer can re-flow paragraphs around inline images.  Raw bytes are
;; cached per URL in `mdview-image-cache' so that a re-rendered view
;; shows remote images immediately.
;;
;; Images follow the size of the text (`mdview-image-scale'): the
;; renderer passes the factor of `mdview-image-scale-factor', which
;; compares the height of the buffer's default face -- the frame's font,
;; enlarged or shrunk by `text-scale-mode' -- with the base height of
;; `mdview-image-base-height', so that zooming the frame or the buffer
;; scales the images along with the text.
;;
;; Everything degrades to placeholders in `emacs -nw' and `--batch': no
;; display-dependent primitive (`image-size', `frame-char-width',
;; `frame-pixel-height') runs unless the display is graphical.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'url)
(require 'url-parse)
(require 'url-util)
(require 'mdview-faces)

(defvar url-http-response-status)       ; url-http.el, local to responses
(defvar mdview-mode)                    ; mdview.el, on in rendered buffers
(defvar global-text-scale-adjust--default-height) ; face-remap.el

;;;; Options

(defcustom mdview-display-images t
  "Non-nil means display images inline in graphical Emacs.
When nil, or whenever the display cannot show images, a textual
placeholder (see `mdview-image-placeholder-format') is inserted instead."
  :type 'boolean
  :group 'mdview)

(defcustom mdview-display-remote-images t
  "Non-nil means fetch and display http(s) images referenced by a document.
Remote images are fetched asynchronously and a placeholder is shown
until the data arrives.  When nil only the placeholder is shown and no
network connection is made."
  :type 'boolean
  :group 'mdview)

(defcustom mdview-image-max-height 0.6
  "Maximum height of a displayed image.
An integer is a height in pixels; a float is a fraction of the frame's
pixel height (`frame-pixel-height').  Taller images are scaled down,
keeping their aspect ratio."
  :type '(choice (integer :tag "Pixels")
                 (float :tag "Fraction of the frame height"))
  :group 'mdview)

(defcustom mdview-image-max-width nil
  "Maximum width of a displayed image in pixels, or nil for no extra limit.
Images are always limited to the content width; this option lowers that
limit further."
  :type '(choice (const :tag "Content width" nil)
                 (integer :tag "Pixels"))
  :group 'mdview)

(defcustom mdview-image-scale 'text
  "How displayed images are scaled.
`text' means that images follow the size of the text: an image is shown
at its natural size when the buffer's text has its base size (see
`mdview-image-base-height') and grows or shrinks with the text, whether
the frame's font is changed (`set-frame-font', `global-text-scale-adjust',
zoom-frm's commands) or the buffer is scaled with `text-scale-mode'.  A
number is a fixed factor; 1.0 shows images at their natural size.  nil
leaves the scaling to Emacs (`image-scaling-factor').  The content width
and `mdview-image-max-height' limit the displayed size in every case."
  :type '(choice (const :tag "Follow the size of the text" text)
                 (number :tag "Fixed factor")
                 (const :tag "Emacs default (`image-scaling-factor')" nil))
  :group 'mdview)

(defcustom mdview-image-base-height nil
  "Height of the text at which images are shown at their natural size.
The value is in units of 1/10 point, like the `:height' attribute of
faces (120 means 12 pt).  nil means the height the text had before any
zooming: the height `global-text-scale-adjust' resets to once it has
been used, otherwise the height of the `default' face for new frames
when the configuration sets one, otherwise the height of the frame's
default face the first time an image is scaled in the session.  Only
used when `mdview-image-scale' is `text'."
  :type '(choice (const :tag "Automatic" nil)
                 (integer :tag "Height in 1/10 pt"))
  :group 'mdview)

(defcustom mdview-image-timeout 10
  "Seconds to wait for a remote image before keeping its placeholder.
The time counts from the moment the fetch starts (see
`mdview-image-max-parallel'); it is enforced by this module's own
watchdog and does not depend on `url-queue-timeout'."
  :type 'number
  :group 'mdview)

(defcustom mdview-image-max-parallel 6
  "Maximum number of remote images fetched at the same time.
Further images wait in a queue until a fetch completes or times out."
  :type 'natnum
  :group 'mdview)

(defcustom mdview-image-placeholder-format nil
  "Format of the text shown in place of an image, with one %s for the label.
The label is the image's alt text or, when that is empty, the file name
part of its URL.  nil means the image glyph of the active glyph profile
\(`mdview-glyph' with key `image') followed by a space and the label,
i.e. \"🖼 %s\", or \"[img] %s\" on terminals that need ASCII glyphs."
  :type '(choice (const :tag "Image glyph and label" nil)
                 (string :tag "Format string"))
  :group 'mdview)

(defcustom mdview-image-captions nil
  "Non-nil means the renderer draws the alt text as a caption under images.
Captions use the face `mdview-image-caption'.  This module only exposes
the option; `mdview-render' decides what to draw."
  :type 'boolean
  :group 'mdview)

(defvar mdview-image-update-functions nil
  "Abnormal hook run after remote images were shown in a view buffer.
Each function is called with one argument, the buffer in which one or
more placeholders were just replaced by images.  Replacing a placeholder
keeps the width of its line (the difference is taken from the trailing
padding) but cannot re-wrap a paragraph around an inline image, so a
viewer may use this hook to schedule a re-rendering of the buffer; the
image bytes are in `mdview-image-cache' by then, so the re-rendering
shows them at once.  The hook runs from the retrieval callback: do the
work from a timer rather than inline.")

;; The faces `mdview-image-placeholder' and `mdview-image-caption' are
;; defined in mdview-faces.el together with the rest of the palette.

;;;; State

(defvar mdview-image-cache (make-hash-table :test #'equal)
  "Session cache of remote images: URL → raw image bytes (a unibyte string).
Filled by successful fetches; `mdview-image-clear-cache' empties it.")

(cl-defstruct (mdview-image--fit (:constructor mdview-image--make-fit)
                                 (:copier nil))
  "How an image is to be displayed: its size limits, scale and column width."
  (max-width nil :documentation "Pixel width limit, or nil.")
  (max-height nil :documentation "Pixel height limit, or nil.")
  (inline nil :documentation "Non-nil centres the image on its text line.")
  (scale nil :documentation "Factor on the natural size; nil: Emacs's default.")
  (char-width nil :documentation "Pixels per text column; nil: `frame-char-width'."))

(cl-defstruct (mdview-image--job (:constructor mdview-image--make-job)
                                 (:copier nil))
  "A placeholder waiting for the bytes of a remote image.
FIT is the `mdview-image--fit' the image is displayed with."
  id url alt overlay fit)

(defvar mdview-image--pending (make-hash-table)
  "Pending remote images: identifier → `mdview-image--job'.")

(defvar mdview-image--inflight (make-hash-table :test #'equal)
  "URLs whose fetch was requested and has not concluded.
The value is the symbol `waiting' while the URL sits in
`mdview-image--waiting' and the watchdog timer enforcing
`mdview-image-timeout' once the retrieval has started.")

(defvar mdview-image--waiting nil
  "URLs queued behind `mdview-image-max-parallel' running fetches, oldest first.")

(defvar mdview-image--running (make-hash-table :test #'equal)
  "URLs being retrieved → the buffer `url-retrieve' returned for them.")

(defvar mdview-image--counter 0
  "Source of unique identifiers for pending placeholders.")

(defvar mdview-image--size-cache (make-hash-table :test #'equal)
  "Memo of `mdview-image--columns': (CHAR-WIDTH . IMAGE) → (TIME . COLUMNS).
Entries older than `mdview-image--size-cache-ttl' seconds are recomputed,
and the table is emptied when it holds `mdview-image--size-cache-limit'
entries, so that it never grows without bound.")

(defconst mdview-image--size-cache-ttl 30
  "Seconds for which a memoized image size is trusted.")

(defconst mdview-image--size-cache-limit 512
  "Number of entries at which `mdview-image--size-cache' is emptied.")

(defvar mdview-image--base-height-seen nil
  "Height of the default face first seen by `mdview-image-base-height'.
In 1/10 pt; the session's base height when nothing else defines one.")

(defconst mdview-image--unavailable-note " (unavailable)"
  "Suffix added to the `help-echo' of a placeholder whose fetch failed.")

(defconst mdview-image--own-properties
  '(face display mdview-link mdview-image-url help-echo mouse-face keymap
    rear-nonsticky inhibit-isearch mdview-image-pending)
  "Text properties this module puts on placeholders and images.")

;;;; URL classification and path resolution

(defun mdview-image-url-kind (url)
  "Classify the image URL: `remote' for http(s), `local' for files, else nil.
Plain relative paths, `~' paths, absolute paths, Windows drive paths and
file:// URLs are `local'.  Other schemes (data:, mailto:, ...) are not
supported and yield nil."
  (let ((scheme (url-type (url-generic-parse-url url))))
    (cond ((null scheme) 'local)
          ((member (downcase scheme) '("http" "https")) 'remote)
          ((or (string-equal-ignore-case scheme "file")
               (= (length scheme) 1))
           'local)
          (t nil))))

(defun mdview-image--decode-path (path)
  "Return PATH with percent-escapes decoded as UTF-8."
  (if (string-match-p "%[[:xdigit:]][[:xdigit:]]" path)
      (decode-coding-string (url-unhex-string path) 'utf-8)
    path))

(defun mdview-image-local-path (url &optional base-dir)
  "Return the absolute file name denoted by the local image URL, or nil.
nil means URL is remote or unsupported (see `mdview-image-url-kind').
Relative paths resolve against BASE-DIR, defaulting to `default-directory';
`~' and absolute paths work as usual and file:// URLs are converted.
Percent-escapes are decoded unless a file with the literal name exists."
  (when (eq (mdview-image-url-kind url) 'local)
    (let* ((parsed (url-generic-parse-url url))
           (raw (if (and (url-type parsed)
                         (string-equal-ignore-case (url-type parsed) "file"))
                    (url-filename parsed)
                  url))
           (dir (or base-dir default-directory))
           (literal (expand-file-name raw dir))
           (decoded (expand-file-name (mdview-image--decode-path raw) dir)))
      (if (or (equal literal decoded) (not (file-exists-p literal)))
          decoded
        literal))))

;;;; Placeholders

(defun mdview-image--collapse-space (text)
  "Return TEXT with every run of whitespace, newlines included, as one space.
Leading and trailing whitespace is removed.  Alt text may contain hard
breaks and the renderer keeps lines intact only for single-line labels."
  (string-trim (replace-regexp-in-string "[ \t\n\r\f]+" " " text t t)))

(defun mdview-image-label (url alt)
  "Return the text labelling the image URL: ALT, or a name derived from URL.
Whitespace in ALT, including newlines from hard breaks, is collapsed to
single spaces so that the label always stays on one line.  When ALT is
nil or blank, the file name part of URL is used (query and fragment
stripped, percent-escapes decoded); for unsupported schemes the scheme
name is used, e.g. \"data image\"."
  (cond
   ((and alt (string-match-p "[^ \t\n\r\f]" alt))
    (mdview-image--collapse-space alt))
   ((null (mdview-image-url-kind url))
    (format "%s image" (url-type (url-generic-parse-url url))))
   (t
    (let* ((parsed (url-generic-parse-url url))
           (path (if (and (url-type parsed) (> (length (url-type parsed)) 1))
                     (or (url-filename parsed) "")
                   url))
           (name (file-name-nondirectory
                  (directory-file-name (car (split-string path "[?#]"))))))
      (if (string-empty-p name) url (mdview-image--decode-path name))))))

(defun mdview-image--format ()
  "Return the placeholder format string in effect."
  (or mdview-image-placeholder-format
      (concat (mdview-glyph 'image) " %s")))

(defun mdview-image-placeholder (url alt)
  "Return the propertized placeholder for the image URL with ALT text.
The text is `mdview-image-placeholder-format' applied to the label of
URL and ALT (see `mdview-image-label').  It carries the face
`mdview-image-placeholder' and the text properties `mdview-link' (URL),
`help-echo' and `mouse-face', so it behaves like a link, and
`mdview-image-url' (URL as well), which survives when the renderer
replaces `mdview-link' by the target of a link wrapped around the image."
  (let* ((url (or url ""))
         (label (mdview-image-label url (or alt "")))
         (text (condition-case nil
                   (format (mdview-image--format) label)
                 (error (concat (mdview-glyph 'image) " " label)))))
    (propertize text
                'face 'mdview-image-placeholder
                'mdview-link url
                'mdview-image-url url
                'help-echo url
                'mouse-face 'highlight)))

;;;; Displayability

(defun mdview-image--graphic-p ()
  "Return non-nil when the selected frame can display images.
Always nil in batch mode and on text terminals."
  (and (not noninteractive)
       (display-graphic-p)
       (display-images-p)))

(defun mdview-image--file-type (file)
  "Return the image type of FILE, detected from its name or its header.
Return nil when FILE is nil, unreadable, a directory or not an image."
  (and file
       (file-readable-p file)
       (not (file-directory-p file))
       (or (image-supported-file-p file)
           (ignore-errors (image-type-from-file-header file)))))

(defun mdview-image--local-image (url base-dir)
  "Return (FILE . TYPE) for the local image URL when Emacs can display it.
FILE is the absolute file name resolved against BASE-DIR and TYPE its
available image type.  Return nil for a missing or unreadable file, a
file that is not an image, or an image type this Emacs lacks."
  (let* ((file (mdview-image-local-path url base-dir))
         (type (mdview-image--file-type file)))
    (and type (image-type-available-p type) (cons file type))))

(defun mdview-image--displayable (url base-dir)
  "Return how the image URL can be shown as a real image, or nil.
The value is `remote' for a fetchable http(s) URL and (FILE . TYPE) for
a displayable local file resolved against BASE-DIR (see
`mdview-image--local-image'); nil means the placeholder must be used.
The display, `mdview-display-images' and `mdview-display-remote-images'
are checked first, so no file is touched unless images can be shown at
all."
  (and mdview-display-images
       (mdview-image--graphic-p)
       (pcase (mdview-image-url-kind url)
         ('remote (and mdview-display-remote-images 'remote))
         ('local (mdview-image--local-image url base-dir))
         (_ nil))))

(defun mdview-image-displayable-p (url &optional base-dir)
  "Return non-nil when the image at URL can be shown as a real image.
This is nil in batch mode, on a text terminal, when `mdview-display-images'
is nil, for unsupported schemes such as data:, and for local files that
are missing or whose image type is not available in this Emacs.  Remote
http(s) images are displayable when `mdview-display-remote-images' is
non-nil; their type is checked once the data arrives.  Relative paths
resolve against BASE-DIR (default `default-directory')."
  (and (mdview-image--displayable url base-dir) t))

;;;; Sizes

(defun mdview-image-max-height-px (&optional override)
  "Return the pixel height limit for displayed images, at least 1.
OVERRIDE, when non-nil, is used as is.  Otherwise an integer
`mdview-image-max-height' is returned and a float one is multiplied by
the pixel height of the selected frame (`frame-pixel-height')."
  (let ((value (or override mdview-image-max-height)))
    (max 1 (if (integerp value)
               value
             (floor (* (if (numberp value) value 0.6)
                       (frame-pixel-height)))))))

(defun mdview-image-max-width-px (&optional width)
  "Return the pixel width limit for displayed images, or nil for none.
WIDTH is the width available for the image in pixels, or nil;
`mdview-image-max-width', when set, lowers the limit further."
  (if (and width mdview-image-max-width)
      (min width mdview-image-max-width)
    (or width mdview-image-max-width)))

;;;; The size of the text

(defun mdview-image--positive-integer (value)
  "Return VALUE when it is a positive integer, else nil."
  (and (integerp value) (> value 0) value))

(defun mdview-image--face-height (frame)
  "Return the height of the `default' face on FRAME in 1/10 pt, or nil.
FRAME may be t for the default of new frames.  Only an absolute height
\(a positive integer) counts."
  (mdview-image--positive-integer (face-attribute 'default :height frame)))

(defun mdview-image-base-height (&optional frame)
  "Return the height of the text, in 1/10 pt, at which images are not scaled.
This is `mdview-image-base-height' when set; otherwise the height that
`global-text-scale-adjust' resets to, once it has been used; otherwise
the height of the `default' face for new frames, when the configuration
specifies one; otherwise the height of the default face of FRAME
\(default: the selected frame) the first time this function needs it,
remembered for the session.  Return nil when none of these is known."
  (or (mdview-image--positive-integer mdview-image-base-height)
      (mdview-image--positive-integer
       (bound-and-true-p global-text-scale-adjust--default-height))
      (mdview-image--face-height t)
      mdview-image--base-height-seen
      (setq mdview-image--base-height-seen
            (mdview-image--face-height (or frame (selected-frame))))))

(defun mdview-image--font-size (window height)
  "Return the pixel width, or with HEIGHT non-nil the height, of the text.
The text is that of the current buffer's `default' face, as remapped by
`text-scale-mode': measured in WINDOW when it shows the current buffer
\(`window-font-width'), else on the selected frame (`default-font-width')."
  (if (and window (eq (window-buffer window) (current-buffer)))
      (if height
          (window-font-height window 'default)
        (window-font-width window 'default))
    (if height (default-font-height) (default-font-width))))

(defun mdview-image-char-width (&optional window)
  "Return the width in pixels of a column of text in the current buffer, or nil.
This is the width of the buffer's `default' face, which `text-scale-mode'
may have changed, measured in WINDOW when it shows the buffer and on the
selected frame otherwise.  Return nil without a graphical display."
  (let ((frame (if window (window-frame window) (selected-frame))))
    (and (display-graphic-p frame)
         (mdview-image--positive-integer
          (mdview-image--font-size window nil)))))

(defun mdview-image-scale-factor (&optional window)
  "Return the factor applied to the natural size of images, or nil.
With `mdview-image-scale' set to `text' the factor follows the size of
the text in the current buffer: the height of its `default' face -- the
frame's font, enlarged or shrunk by `text-scale-mode' -- divided by the
base height of `mdview-image-base-height', rounded to three decimals,
and 1.0 without a graphical display.  The text is measured in WINDOW
when it shows the buffer and on the selected frame otherwise.  A number
in `mdview-image-scale' is returned as is, and nil means that Emacs's
own `image-scaling-factor' applies."
  (cond ((numberp mdview-image-scale) mdview-image-scale)
        ((eq mdview-image-scale 'text) (mdview-image--text-scale window))
        (t nil)))

(defun mdview-image--text-scale (window)
  "Return the size of the text in the current buffer relative to its base size.
See `mdview-image-scale-factor'; WINDOW is as there."
  (let ((frame (if window (window-frame window) (selected-frame))))
    (if (not (display-graphic-p frame))
        1.0
      (let* ((base (mdview-image-base-height frame))
             (height (mdview-image--face-height frame))
             (char-height (mdview-image--positive-integer
                           (frame-char-height frame)))
             (text-height (mdview-image--positive-integer
                           (mdview-image--font-size window t)))
             (factor (* (if (and base height) (/ (float height) base) 1.0)
                        (if (and char-height text-height)
                            (/ (float text-height) char-height)
                          1.0))))
        (max 0.001 (/ (round (* factor 1000)) 1000.0))))))

;;;; Creating and inserting images

(defun mdview-image--create (source type data-p fit)
  "Return an image spec for SOURCE, a file name or (when DATA-P) raw bytes.
TYPE is the image type, or nil to let Emacs detect it.  FIT is a
`mdview-image--fit': its scale, when non-nil, multiplies the natural
size of the image (nil leaves the scaling to Emacs's
`image-scaling-factor'), its limits then bound the displayed size in
pixels, and its inline flag centres the image vertically on the line."
  (let ((max-width (mdview-image--fit-max-width fit))
        (max-height (mdview-image--fit-max-height fit))
        (scale (mdview-image--fit-scale fit)))
    (apply #'create-image source type data-p
           (append (and max-width (list :max-width max-width))
                   (and max-height (list :max-height max-height))
                   (and scale (list :scale scale))
                   (and (mdview-image--fit-inline fit)
                        (list :ascent 'center))))))

(defun mdview-image--from-data (data fit)
  "Return an image spec for the raw bytes DATA, or nil if they are no image.
FIT is as in `mdview-image--create'."
  (let ((type (image-type-from-data data)))
    (and type
         (image-type-available-p type)
         (ignore-errors
           (mdview-image--create data type t fit)))))

(defun mdview-image--columns (image &optional char-width)
  "Return the number of text columns IMAGE occupies on the selected frame.
A column is CHAR-WIDTH pixels wide (default `frame-char-width').  Signal
an error when IMAGE cannot be loaded or the frame has no window system.
The size of a given image spec is memoized for a while in
`mdview-image--size-cache', because a document repeating the same image
hundreds of times would otherwise pay for `image-size' every time."
  (let* ((char-width (or char-width (frame-char-width)))
         (key (cons char-width image))
         (hit (gethash key mdview-image--size-cache))
         (now (float-time)))
    (if (and hit (< (- now (car hit)) mdview-image--size-cache-ttl))
        (cdr hit)
      (let* ((pixels (car (image-size image t)))
             (columns (max 1 (ceiling (/ pixels (float char-width))))))
        (when (>= (hash-table-count mdview-image--size-cache)
                  mdview-image--size-cache-limit)
          (clrhash mdview-image--size-cache))
        (puthash key (cons now columns) mdview-image--size-cache)
        columns))))

(defun mdview-image--insert-image (image url alt &optional char-width)
  "Insert IMAGE at point and return the number of columns it occupies.
A column is CHAR-WIDTH pixels wide (default `frame-char-width').  The
underlying text is the label of URL and ALT, so copying the region
yields the alt text.  The text gets `mdview-link', `mdview-image-url'
\(both URL), `help-echo' and `mouse-face'; the `keymap' that
`insert-image' adds is removed so that the mode's own bindings apply on
images."
  (let ((columns (mdview-image--columns image char-width))
        (label (mdview-image-label url alt))
        (start (point)))
    (insert-image image (if (string-empty-p label) " " label))
    (remove-list-of-text-properties start (point) '(keymap))
    (add-text-properties
     start (point)
     (list 'mdview-link url
           'mdview-image-url url
           'help-echo (if (string-blank-p alt)
                          url
                        (concat (mdview-image--collapse-space alt) "\n" url))
           'mouse-face 'highlight))
    columns))

(defun mdview-image--try-insert (image url alt &optional char-width)
  "Insert IMAGE for URL and ALT at point; return (COLUMNS . image) or nil.
IMAGE may be nil.  CHAR-WIDTH is as in `mdview-image--insert-image'.
Any error (unsupported data, no window system, ...) yields nil and
leaves the buffer unchanged."
  (when image
    (let ((start (point)))
      (condition-case nil
          (cons (mdview-image--insert-image image url alt char-width) 'image)
        (error (delete-region start (point)) nil)))))

(defun mdview-image--insert-placeholder (url alt)
  "Insert the placeholder for URL and ALT; return (COLUMNS . placeholder)."
  (let ((text (mdview-image-placeholder url alt)))
    (insert text)
    (cons (string-width text) 'placeholder)))

(defun mdview-image--insert-local (file type url alt fit)
  "Insert the local image FILE of image TYPE; return (COLUMNS . image) or nil.
URL is the image's URL in the document and ALT its alt text; FIT is the
`mdview-image--fit' to display it with."
  (mdview-image--try-insert
   (ignore-errors (mdview-image--create file type nil fit))
   url alt (mdview-image--fit-char-width fit)))

(defun mdview-image--insert-remote (url alt fit)
  "Insert the remote image URL from the cache, or a placeholder awaiting it.
Return (COLUMNS . image), (COLUMNS . pending), or nil when the cached
data cannot be displayed.  ALT and FIT are as in
`mdview-image--insert-local'."
  (let ((data (gethash url mdview-image-cache)))
    (if data
        (mdview-image--try-insert (mdview-image--from-data data fit) url alt
                                  (mdview-image--fit-char-width fit))
      (mdview-image--insert-pending url alt fit))))

(cl-defun mdview-image-insert (url alt &key base-dir max-width-px
                                   max-height-px inline scale char-width)
  "Insert the image URL with ALT text at point, or a placeholder for it.
Relative URLs resolve against BASE-DIR (default `default-directory').
MAX-WIDTH-PX and MAX-HEIGHT-PX limit the displayed size in pixels; the
height defaults to `mdview-image-max-height' and the width is further
limited by `mdview-image-max-width'.  Non-nil INLINE marks an image
inside running text, which is vertically centred on its line.  SCALE
multiplies the natural size of the image before the limits apply (see
`mdview-image-scale-factor'); nil leaves the scaling to Emacs
\(`image-scaling-factor').  CHAR-WIDTH is the width in pixels of a text
column where the rendering is shown (see `mdview-image-char-width'),
which decides how many columns an image counts for; nil means
`frame-char-width'.

Local images that are displayable (see `mdview-image-displayable-p') are
inserted immediately.  Remote images are inserted as a placeholder that
is replaced asynchronously when the data arrives, unless the URL is
already in `mdview-image-cache', in which case the image is inserted at
once.  Everything else gets the placeholder of `mdview-image-placeholder'.

Return (COLUMNS . KIND): COLUMNS is the width in text columns of what
was inserted and KIND is `image', `placeholder' or `pending'."
  (let* ((url (or url ""))
         (alt (or alt ""))
         (how (mdview-image--displayable url base-dir)))
    (or (and how
             (let ((fit (mdview-image--make-fit
                         :max-width (mdview-image-max-width-px max-width-px)
                         :max-height (mdview-image-max-height-px max-height-px)
                         :inline inline :scale scale :char-width char-width)))
               (if (consp how)
                   (mdview-image--insert-local (car how) (cdr how) url alt fit)
                 (mdview-image--insert-remote url alt fit))))
        (mdview-image--insert-placeholder url alt))))

;;;; Remote images: placeholders awaiting data

(defun mdview-image--insert-pending (url alt fit)
  "Insert a placeholder for the remote image URL and start fetching it.
ALT is the alt text and FIT the `mdview-image--fit' remembered for the
eventual display.  Return (COLUMNS . pending), or (COLUMNS . placeholder)
when the fetch fails before this returns."
  (let* ((id (cl-incf mdview-image--counter))
         (text (propertize (mdview-image-placeholder url alt)
                           'mdview-image-pending id))
         (start (point)))
    (insert text)
    (let ((overlay (make-overlay start (point))))
      (overlay-put overlay 'mdview-image-id id)
      (overlay-put overlay 'mdview-image-url url)
      (overlay-put overlay 'mdview-image-max-width
                   (mdview-image--fit-max-width fit))
      (overlay-put overlay 'mdview-image-max-height
                   (mdview-image--fit-max-height fit))
      (puthash id (mdview-image--make-job :id id :url url :alt alt
                                          :overlay overlay :fit fit)
               mdview-image--pending))
    (mdview-image--fetch url)
    (cons (string-width text)
          (if (gethash id mdview-image--pending) 'pending 'placeholder))))

(defun mdview-image--pending-region (id buffer &optional from)
  "Return (START . END) of the placeholder with pending ID in BUFFER, or nil.
Search from FROM, defaulting to the beginning of the buffer."
  (with-current-buffer buffer
    (let ((start (text-property-any (or from (point-min)) (point-max)
                                    'mdview-image-pending id)))
      (and start
           (cons start
                 (or (text-property-not-all start (point-max)
                                            'mdview-image-pending id)
                     (point-max)))))))

(defun mdview-image--job-region (job)
  "Return (BUFFER START END) of JOB's placeholder, or nil if it is gone.
The overlay locates it when alive; otherwise buffers where `mdview-mode'
is on are searched for the `mdview-image-pending' property, which survives when
the renderer copies the placeholder text into another buffer."
  (let* ((overlay (mdview-image--job-overlay job))
         (id (mdview-image--job-id job))
         (buffer (overlay-buffer overlay)))
    (or (and buffer
             (let ((region (mdview-image--pending-region
                            id buffer (overlay-start overlay))))
               (and region (list buffer (car region) (cdr region)))))
        (seq-some (lambda (buf)
                    (and (buffer-live-p buf)
                         (local-variable-p 'mdview-mode buf)
                         (buffer-local-value 'mdview-mode buf)
                         (let ((region (mdview-image--pending-region id buf)))
                           (and region (list buf (car region) (cdr region))))))
                  (buffer-list)))))

(defun mdview-image--foreign-properties (pos)
  "Return the text properties at POS not set by this module, as a plist."
  (let ((props (text-properties-at pos))
        result)
    (while props
      (unless (memq (car props) mdview-image--own-properties)
        (setq result (cons (car props) (cons (cadr props) result))))
      (setq props (cddr props)))
    result))

(defun mdview-image--adjust-padding (pos delta)
  "Absorb DELTA columns in the trailing spaces of the line containing POS.
POS is where the text that grew by DELTA columns ends.  The renderer
pads every line with spaces to the content width (followed by a suffix
of further spaces inside block quotes), so a replacement that is DELTA
columns wider than the placeholder removes DELTA of those spaces, taken
from the start of the run, and a narrower one inserts spaces carrying the
padding's properties there.  More columns than the run holds are left
to overflow; nothing before POS is touched."
  (unless (zerop delta)
    (save-excursion
      (goto-char pos)
      (let* ((eol (line-end-position))
             (run-start (progn (goto-char eol)
                               (skip-chars-backward " " pos)
                               (point))))
        (if (> delta 0)
            (delete-region run-start (min eol (+ run-start delta)))
          (goto-char run-start)
          (insert (apply #'propertize (make-string (- delta) ?\s)
                         (and (< run-start eol)
                              (text-properties-at run-start)))))))))

(defun mdview-image--replace (job region data)
  "Show the image bytes DATA in place of JOB's placeholder at REGION.
REGION is (BUFFER START END).  Text properties the renderer put on the
placeholder (such as `mdview-source-line') are carried over, and the
line keeps its width: the difference in columns between the image and
the placeholder is taken from or added to the line's trailing padding
\(see `mdview-image--adjust-padding').  Return non-nil when the image was
inserted; when the data cannot be displayed the placeholder is left
alone and nil is returned."
  (pcase-let ((`(,buffer ,start ,end) region))
    (with-current-buffer buffer
      (let* ((fit (mdview-image--job-fit job))
             (image (mdview-image--from-data data fit))
             (props (mdview-image--foreign-properties start))
             (old-columns (string-width
                           (buffer-substring-no-properties start end))))
        (when image
          (with-silent-modifications
            (save-excursion
              (goto-char start)
              (let ((result (mdview-image--try-insert
                             image (mdview-image--job-url job)
                             (mdview-image--job-alt job)
                             (mdview-image--fit-char-width fit))))
                (when result
                  (let ((new-end (point)))
                    (delete-region new-end (+ new-end (- end start)))
                    (add-text-properties start new-end props)
                    (mdview-image--adjust-padding
                     new-end (- (car result) old-columns)))
                  t)))))))))

(defun mdview-image--mark-unavailable (region)
  "Record on the placeholder at REGION that its image will not arrive.
REGION is (BUFFER START END).  The `mdview-image-pending' property is
removed, so that nothing waits for the placeholder any longer, and
`mdview-image--unavailable-note' is appended to its `help-echo'; the
`mdview-link' stays so that RET still opens the URL."
  (pcase-let ((`(,buffer ,start ,end) region))
    (with-current-buffer buffer
      (with-silent-modifications
        (remove-list-of-text-properties start end '(mdview-image-pending))
        (let ((echo (get-text-property start 'help-echo)))
          (when (and (stringp echo)
                     (not (string-suffix-p mdview-image--unavailable-note echo)))
            (put-text-property start end 'help-echo
                               (concat echo mdview-image--unavailable-note))))))))

(defun mdview-image--job-done (job data &optional cancel)
  "Finish JOB: show the image bytes DATA (or nil) on its placeholder if possible.
When the placeholder still exists but gets no image, because DATA is nil
\(the fetch failed), the display is not graphical or the bytes are not a
displayable image, it is marked with `mdview-image--mark-unavailable' so
that it no longer looks pending -- unless CANCEL is non-nil, in which
case the placeholder is left untouched because its buffer is about to
be re-rendered or killed.  The job is forgotten and its overlay deleted
in every case.  Return the buffer in which an image was shown, or nil."
  (remhash (mdview-image--job-id job) mdview-image--pending)
  (prog1
      (let ((region (and (not cancel) (mdview-image--job-region job))))
        (when region
          (if (and data
                   (mdview-image--graphic-p)
                   (mdview-image--replace job region data))
              (car region)
            (mdview-image--mark-unavailable region)
            nil)))
    (let ((overlay (mdview-image--job-overlay job)))
      (when (overlay-buffer overlay)
        (delete-overlay overlay)))))

(defun mdview-image--jobs-for (url)
  "Return the pending jobs waiting for URL, oldest first."
  (let (jobs)
    (maphash (lambda (_id job)
               (when (equal (mdview-image--job-url job) url)
                 (push job jobs)))
             mdview-image--pending)
    (sort jobs (lambda (a b) (< (mdview-image--job-id a)
                                (mdview-image--job-id b))))))

(defun mdview-image--finish (url data)
  "Conclude the fetch of URL with the image bytes DATA (nil on failure).
Stop the watchdog timer, forget the fetch, complete every job waiting
for URL, run `mdview-image-update-functions' for each buffer in which an
image was shown, and start the next waiting fetch."
  (let ((timer (gethash url mdview-image--inflight)))
    (when (timerp timer)
      (cancel-timer timer))
    (remhash url mdview-image--inflight)
    (remhash url mdview-image--running)
    (setq mdview-image--waiting (delete url mdview-image--waiting)))
  (let (buffers)
    (dolist (job (mdview-image--jobs-for url))
      (let ((buffer (mdview-image--job-done job data)))
        (when (and buffer (not (memq buffer buffers)))
          (push buffer buffers))))
    (dolist (buffer (nreverse buffers))
      (when (buffer-live-p buffer)
        (run-hook-with-args 'mdview-image-update-functions buffer))))
  (mdview-image--run-queue))

;;;; Remote images: fetching

(defun mdview-image--fetch (url)
  "Queue URL for fetching unless a fetch of it is already in flight.
The retrieval starts at once when fewer than `mdview-image-max-parallel'
fetches are running and otherwise when one of them concludes; its result
arrives in `mdview-image--on-retrieve' or, after `mdview-image-timeout'
seconds, in `mdview-image--on-timeout'."
  (unless (gethash url mdview-image--inflight)
    (puthash url 'waiting mdview-image--inflight)
    (setq mdview-image--waiting (append mdview-image--waiting (list url)))
    (mdview-image--run-queue)))

(defun mdview-image--run-queue ()
  "Start waiting fetches while fewer than `mdview-image-max-parallel' run."
  (while (and mdview-image--waiting
              (< (hash-table-count mdview-image--running)
                 (max 1 mdview-image-max-parallel)))
    (mdview-image--start (pop mdview-image--waiting))))

(defun mdview-image--start (url)
  "Retrieve URL asynchronously with `url-retrieve' and arm its watchdog.
A retrieval that fails before it even starts (an error signalled by
`url-retrieve') concludes the fetch at once as a failure."
  (puthash url (run-at-time mdview-image-timeout nil
                            #'mdview-image--on-timeout url)
           mdview-image--inflight)
  (let ((buffer (condition-case nil
                    (let ((url-request-method "GET")
                          (url-request-noninteractive t))
                      (url-retrieve url #'mdview-image--on-retrieve
                                    (list url) t t))
                  (error nil))))
    (cond ((not (gethash url mdview-image--inflight)))
          ;; `url-retrieve' may have concluded the fetch synchronously;
          ;; then there is nothing left to track.
          ((bufferp buffer) (puthash url buffer mdview-image--running))
          (t (mdview-image--finish url nil)))))

(defun mdview-image--kill-fetch (url)
  "Abort the fetch of URL, if any, keeping its placeholders.
A running retrieval has its process deleted silently and its buffer
killed, so that `mdview-image--on-retrieve' never runs for it; the fetch
is forgotten in any case and its jobs conclude without an image."
  (let ((buffer (gethash url mdview-image--running)))
    (when (buffer-live-p buffer)
      (let (process)
        (while (setq process (get-buffer-process buffer))
          (set-process-sentinel process #'ignore)
          (ignore-errors (delete-process process))))
      (let ((kill-buffer-query-functions nil))
        (ignore-errors (kill-buffer buffer)))))
  (mdview-image--finish url nil))

(defun mdview-image--on-timeout (url)
  "Give up on URL after `mdview-image-timeout' seconds."
  (when (gethash url mdview-image--inflight)
    (mdview-image--kill-fetch url)))

(defun mdview-image--response-image ()
  "Return the image bytes in the current HTTP response buffer, or nil.
nil when the HTTP status is not 2xx or the body is not a recognised
image format."
  (let ((status (and (boundp 'url-http-response-status)
                     url-http-response-status)))
    (when (or (null status) (<= 200 status 299))
      (save-excursion
        (goto-char (point-min))
        (when (re-search-forward "\r?\n\r?\n" nil t)
          (let ((body (buffer-substring-no-properties (point) (point-max))))
            (when (multibyte-string-p body)
              (setq body (encode-coding-string body 'raw-text)))
            (and (> (length body) 0)
                 (image-type-from-data body)
                 body)))))))

(defun mdview-image--on-retrieve (status url)
  "Handle the retrieval of URL, completed in the current response buffer.
STATUS is the plist `url-retrieve' passes to its callback.  Image bytes
are cached and shown on the waiting placeholders; on any error, or when
the body is not an image, the placeholders are kept.  The response
buffer is killed afterwards."
  (let ((buffer (current-buffer)))
    (unwind-protect
        (with-demoted-errors "mdview-image: %S"
          (let ((data (and (not (plist-get status :error))
                           (mdview-image--response-image))))
            (when data
              (puthash url data mdview-image-cache))
            (mdview-image--finish url data)))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

;;;; Housekeeping commands and helpers

(defun mdview-image--pending-ids (buffer)
  "Return the pending identifiers found as text properties in BUFFER."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (let ((pos (point-min))
            ids)
        (while pos
          (let ((id (get-text-property pos 'mdview-image-pending)))
            (when id (push id ids)))
          (setq pos (next-single-property-change pos 'mdview-image-pending)))
        ids))))

(defun mdview-image-cancel-pending (&optional buffer kill)
  "Stop waiting for the remote images of BUFFER (default: current buffer).
Their placeholders are left in place and are never replaced afterwards.
Retrievals keep running so that their data lands in `mdview-image-cache'
and a re-rendered view attaches to them, unless KILL is non-nil, in which
case retrievals that no other buffer waits for are aborted.  Return the
number of placeholders forgotten.  Call this before re-rendering a view
and, with KILL, when killing it."
  (let* ((buffer (or buffer (current-buffer)))
         (ids (mdview-image--pending-ids buffer))
         jobs)
    (maphash (lambda (id job)
               (when (or (memq id ids)
                         (eq (overlay-buffer (mdview-image--job-overlay job))
                             buffer))
                 (push job jobs)))
             mdview-image--pending)
    (dolist (job jobs)
      (mdview-image--job-done job nil t))
    (when kill
      (dolist (url (seq-uniq (mapcar #'mdview-image--job-url jobs)))
        (unless (mdview-image--jobs-for url)
          (mdview-image--kill-fetch url))))
    (length jobs)))

(defun mdview-image-clear-cache ()
  "Forget all cached remote image data and memoized image sizes."
  (interactive)
  (clrhash mdview-image-cache)
  (clrhash mdview-image--size-cache)
  nil)

(defun mdview-image-open (url &optional base-dir)
  "Open the image URL: local files with `find-file', remote ones in a browser.
Relative paths resolve against BASE-DIR (default `default-directory').
Signal a `user-error' for missing files and unsupported URLs."
  (pcase (mdview-image-url-kind url)
    ('remote (browse-url url))
    ('local (let ((file (mdview-image-local-path url base-dir)))
              (if (file-exists-p file)
                  (find-file file)
                (user-error "Image file not found: %s" file))))
    (_ (user-error "Cannot open image %s"
                   (truncate-string-to-width url 60 nil nil "…")))))

(provide 'mdview-image)
;;; mdview-image.el ends here
