;;; mdview-image.el --- Image display for mdview  -*- lexical-binding: t; -*-

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
;; `url-queue-retrieve'; when the bytes arrive the placeholder is swapped
;; for the image, provided the view buffer and the placeholder still
;; exist.  Raw bytes are cached per URL in `mdview-image-cache' so that a
;; re-rendered view shows remote images immediately.
;;
;; Everything degrades to placeholders in `emacs -nw' and `--batch': no
;; display-dependent primitive (`image-size', `frame-char-width',
;; `frame-pixel-height') runs unless the display is graphical.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'url-parse)
(require 'url-util)
(require 'url-queue)
(require 'mdview-faces)

(defvar url-http-response-status)       ; url-http.el, local to responses

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

(defcustom mdview-image-timeout 10
  "Seconds to wait for a remote image before keeping its placeholder."
  :type 'number
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

;; The faces `mdview-image-placeholder' and `mdview-image-caption' are
;; defined in mdview-faces.el together with the rest of the palette.

;;;; State

(defvar mdview-image-cache (make-hash-table :test #'equal)
  "Session cache of remote images: URL → raw image bytes (a unibyte string).
Filled by successful fetches; `mdview-image-clear-cache' empties it.")

(cl-defstruct (mdview-image--job (:constructor mdview-image--make-job)
                                 (:copier nil))
  "A placeholder waiting for the bytes of a remote image."
  id url alt overlay max-width max-height inline)

(defvar mdview-image--pending (make-hash-table)
  "Pending remote images: identifier → `mdview-image--job'.")

(defvar mdview-image--inflight (make-hash-table :test #'equal)
  "URLs being fetched → the watchdog timer enforcing `mdview-image-timeout'.")

(defvar mdview-image--counter 0
  "Source of unique identifiers for pending placeholders.")

(defconst mdview-image--own-properties
  '(face display mdview-link help-echo mouse-face keymap rear-nonsticky
    inhibit-isearch mdview-image-pending)
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

(defun mdview-image-label (url alt)
  "Return the text labelling the image URL: ALT, or a name derived from URL.
When ALT is nil or blank, the file name part of URL is used (query and
fragment stripped, percent-escapes decoded); for unsupported schemes the
scheme name is used, e.g. \"data image\"."
  (cond
   ((and alt (string-match-p "[^[:space:]]" alt)) alt)
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
`help-echo' and `mouse-face', so it behaves like a link."
  (let* ((url (or url ""))
         (label (mdview-image-label url (or alt "")))
         (text (condition-case nil
                   (format (mdview-image--format) label)
                 (error (concat (mdview-glyph 'image) " " label)))))
    (propertize text
                'face 'mdview-image-placeholder
                'mdview-link url
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

(defun mdview-image-displayable-p (url &optional base-dir)
  "Return non-nil when the image at URL can be shown as a real image.
This is nil in batch mode, on a text terminal, when `mdview-display-images'
is nil, for unsupported schemes such as data:, and for local files that
are missing or whose image type is not available in this Emacs.  Remote
http(s) images are displayable when `mdview-display-remote-images' is
non-nil; their type is checked once the data arrives.  Relative paths
resolve against BASE-DIR (default `default-directory')."
  (and mdview-display-images
       (mdview-image--graphic-p)
       (pcase (mdview-image-url-kind url)
         ('remote (and mdview-display-remote-images t))
         ('local (let ((type (mdview-image--file-type
                              (mdview-image-local-path url base-dir))))
                   (and type (image-type-available-p type) t)))
         (_ nil))))

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

;;;; Creating and inserting images

(defun mdview-image--create (source type data-p max-width max-height inline)
  "Return an image spec for SOURCE, a file name or (when DATA-P) raw bytes.
TYPE is the image type, or nil to let Emacs detect it.  MAX-WIDTH and
MAX-HEIGHT limit the displayed size in pixels when non-nil.  Non-nil
INLINE centres the image vertically on the text line."
  (apply #'create-image source type data-p
         (append (and max-width (list :max-width max-width))
                 (and max-height (list :max-height max-height))
                 (and inline (list :ascent 'center)))))

(defun mdview-image--from-data (data max-width max-height inline)
  "Return an image spec for the raw bytes DATA, or nil if they are no image.
MAX-WIDTH, MAX-HEIGHT and INLINE are as in `mdview-image--create'."
  (let ((type (image-type-from-data data)))
    (and type
         (image-type-available-p type)
         (ignore-errors
           (mdview-image--create data type t max-width max-height inline)))))

(defun mdview-image--columns (image)
  "Return the number of text columns IMAGE occupies on the selected frame.
Signal an error when IMAGE cannot be loaded or the frame has no window
system."
  (let ((pixels (car (image-size image t))))
    (max 1 (ceiling (/ pixels (float (frame-char-width)))))))

(defun mdview-image--insert-image (image url alt)
  "Insert IMAGE at point and return the number of columns it occupies.
The underlying text is the label of URL and ALT, so copying the region
yields the alt text.  The text gets `mdview-link', `help-echo' and
`mouse-face'; the `keymap' that `insert-image' adds is removed so that
the mode's own bindings apply on images."
  (let ((columns (mdview-image--columns image))
        (label (mdview-image-label url alt))
        (start (point)))
    (insert-image image (if (string-empty-p label) " " label))
    (remove-list-of-text-properties start (point) '(keymap))
    (add-text-properties
     start (point)
     (list 'mdview-link url
           'help-echo (if (string-empty-p alt) url (concat alt "\n" url))
           'mouse-face 'highlight))
    columns))

(defun mdview-image--try-insert (image url alt)
  "Insert IMAGE for URL and ALT at point; return (COLUMNS . image) or nil.
IMAGE may be nil.  Any error (unsupported data, no window system, ...)
yields nil and leaves the buffer unchanged."
  (when image
    (let ((start (point)))
      (condition-case nil
          (cons (mdview-image--insert-image image url alt) 'image)
        (error (delete-region start (point)) nil)))))

(defun mdview-image--insert-placeholder (url alt)
  "Insert the placeholder for URL and ALT; return (COLUMNS . placeholder)."
  (let ((text (mdview-image-placeholder url alt)))
    (insert text)
    (cons (string-width text) 'placeholder)))

(defun mdview-image--insert-local (url alt base-dir max-width max-height
                                      inline)
  "Insert the local image URL at point; return (COLUMNS . image) or nil.
ALT, BASE-DIR, MAX-WIDTH, MAX-HEIGHT and INLINE are as in
`mdview-image-insert'."
  (let ((file (mdview-image-local-path url base-dir)))
    (mdview-image--try-insert
     (ignore-errors
       (mdview-image--create file (mdview-image--file-type file) nil
                             max-width max-height inline))
     url alt)))

(defun mdview-image--insert-remote (url alt max-width max-height inline)
  "Insert the remote image URL from the cache, or a placeholder awaiting it.
Return (COLUMNS . image), (COLUMNS . pending), or nil when the cached
data cannot be displayed.  ALT, MAX-WIDTH, MAX-HEIGHT and INLINE are as
in `mdview-image-insert'."
  (let ((data (gethash url mdview-image-cache)))
    (if data
        (mdview-image--try-insert
         (mdview-image--from-data data max-width max-height inline) url alt)
      (mdview-image--insert-pending url alt max-width max-height inline))))

(cl-defun mdview-image-insert (url alt &key base-dir max-width-px
                                   max-height-px inline)
  "Insert the image URL with ALT text at point, or a placeholder for it.
Relative URLs resolve against BASE-DIR (default `default-directory').
MAX-WIDTH-PX and MAX-HEIGHT-PX limit the displayed size in pixels; the
height defaults to `mdview-image-max-height' and the width is further
limited by `mdview-image-max-width'.  Non-nil INLINE marks an image
inside running text, which is vertically centred on its line.

Local images that are displayable (see `mdview-image-displayable-p') are
inserted immediately.  Remote images are inserted as a placeholder that
is replaced asynchronously when the data arrives, unless the URL is
already in `mdview-image-cache', in which case the image is inserted at
once.  Everything else gets the placeholder of `mdview-image-placeholder'.

Return (COLUMNS . KIND): COLUMNS is the width in text columns of what
was inserted and KIND is `image', `placeholder' or `pending'."
  (let ((url (or url ""))
        (alt (or alt "")))
    (or (and (mdview-image-displayable-p url base-dir)
             (let ((max-width (mdview-image-max-width-px max-width-px))
                   (max-height (mdview-image-max-height-px max-height-px)))
               (if (eq (mdview-image-url-kind url) 'local)
                   (mdview-image--insert-local url alt base-dir
                                               max-width max-height inline)
                 (mdview-image--insert-remote url alt
                                              max-width max-height inline))))
        (mdview-image--insert-placeholder url alt))))

;;;; Remote images: placeholders awaiting data

(defun mdview-image--insert-pending (url alt max-width max-height inline)
  "Insert a placeholder for the remote image URL and start fetching it.
ALT, MAX-WIDTH, MAX-HEIGHT and INLINE are as in `mdview-image-insert' and
are remembered for the eventual display.  Return (COLUMNS . pending)."
  (let* ((id (cl-incf mdview-image--counter))
         (text (propertize (mdview-image-placeholder url alt)
                           'mdview-image-pending id))
         (start (point)))
    (insert text)
    (let ((overlay (make-overlay start (point))))
      (overlay-put overlay 'mdview-image-id id)
      (overlay-put overlay 'mdview-image-url url)
      (overlay-put overlay 'mdview-image-max-width max-width)
      (overlay-put overlay 'mdview-image-max-height max-height)
      (puthash id (mdview-image--make-job :id id :url url :alt alt
                                          :overlay overlay
                                          :max-width max-width
                                          :max-height max-height
                                          :inline inline)
               mdview-image--pending))
    (mdview-image--fetch url)
    (cons (string-width text) 'pending)))

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
The overlay locates it when alive; otherwise buffers in `mdview-mode' are
searched for the `mdview-image-pending' property, which survives when
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
                         (with-current-buffer buf
                           (derived-mode-p 'mdview-mode))
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

(defun mdview-image--replace (job region data)
  "Show the image bytes DATA in place of JOB's placeholder at REGION.
REGION is (BUFFER START END).  Text properties the renderer put on the
placeholder (such as `mdview-source-line') are carried over.  When the
data cannot be displayed the placeholder is left alone."
  (pcase-let ((`(,buffer ,start ,end) region))
    (with-current-buffer buffer
      (let ((image (mdview-image--from-data data
                                            (mdview-image--job-max-width job)
                                            (mdview-image--job-max-height job)
                                            (mdview-image--job-inline job)))
            (props (mdview-image--foreign-properties start)))
        (when image
          (with-silent-modifications
            (save-excursion
              (goto-char start)
              (when (mdview-image--try-insert image (mdview-image--job-url job)
                                              (mdview-image--job-alt job))
                (let ((new-end (point)))
                  (delete-region new-end (+ new-end (- end start)))
                  (add-text-properties start new-end props))))))))))

(defun mdview-image--job-done (job data)
  "Finish JOB: show the image bytes DATA (or nil) on its placeholder if possible.
The job is forgotten and its overlay deleted in every case."
  (remhash (mdview-image--job-id job) mdview-image--pending)
  (let ((region (and data (mdview-image--job-region job))))
    (when (and region (mdview-image--graphic-p))
      (mdview-image--replace job region data)))
  (let ((overlay (mdview-image--job-overlay job)))
    (when (overlay-buffer overlay)
      (delete-overlay overlay))))

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
Stop the watchdog timer and complete every job waiting for URL."
  (let ((timer (gethash url mdview-image--inflight)))
    (when (timerp timer)
      (cancel-timer timer))
    (remhash url mdview-image--inflight))
  (dolist (job (mdview-image--jobs-for url))
    (mdview-image--job-done job data)))

;;;; Remote images: fetching

(defun mdview-image--fetch (url)
  "Start fetching URL asynchronously unless a fetch is already in flight.
The result arrives in `mdview-image--on-retrieve'; a watchdog timer
enforces `mdview-image-timeout' because `url-queue' only checks its own
`url-queue-timeout' when the queue is poked."
  (unless (gethash url mdview-image--inflight)
    (puthash url (run-at-time mdview-image-timeout nil
                              #'mdview-image--on-timeout url)
             mdview-image--inflight)
    (let ((url-request-method "GET")
          (url-queue-timeout mdview-image-timeout))
      (url-queue-retrieve url #'mdview-image--on-retrieve (list url) t t))))

(defun mdview-image--queue-jobs (url)
  "Return the entries of `url-queue' that fetch URL for this module."
  (seq-filter (lambda (job)
                (and (eq (url-queue-callback job) #'mdview-image--on-retrieve)
                     (equal (url-queue-cbargs job) (list url))))
              url-queue))

(defun mdview-image--kill-fetch (url)
  "Abort the fetch of URL, if any, keeping its placeholders.
Running or queued `url-queue' jobs are killed, which reports an error to
`mdview-image--on-retrieve'; the fetch is forgotten in any case."
  (dolist (job (mdview-image--queue-jobs url))
    (setq url-queue (delq job url-queue))
    (url-queue-kill-job job))
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
      (mdview-image--job-done job nil))
    (when kill
      (dolist (url (seq-uniq (mapcar #'mdview-image--job-url jobs)))
        (unless (mdview-image--jobs-for url)
          (mdview-image--kill-fetch url))))
    (length jobs)))

(defun mdview-image-clear-cache ()
  "Forget all cached remote image data."
  (interactive)
  (clrhash mdview-image-cache)
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
