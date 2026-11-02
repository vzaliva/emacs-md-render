;;; mdview-image-test.el --- Tests for mdview-image  -*- lexical-binding: t; -*-

;; This file is part of mdview, distributed under the MIT license; see
;; LICENSE in the repository root.

;;; Commentary:

;; ERT tests for mdview-image.el (docs/DESIGN.md §6 "Images", §9, §13).
;; Everything runs headless: the display is faked with `cl-letf' where a
;; test needs the "graphical" code paths and the network is never
;; touched (`url-queue-retrieve' is stubbed and asserted on).

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'url-queue)
(require 'mdview-image)

(defconst mdview-image-test-dir
  (file-name-directory (or load-file-name buffer-file-name
                           (expand-file-name "mdview-image-test.el")))
  "Directory of this test file.")

(defconst mdview-image-test-source
  (expand-file-name "../mdview-image.el" mdview-image-test-dir)
  "The module under test.")

(defconst mdview-image-test-fixtures
  (expand-file-name "fixtures/images/" mdview-image-test-dir)
  "Directory with sample images.")

(defconst mdview-image-test-url "https://example.invalid/pics/photo.png"
  "A remote URL used by the pending-image tests; never fetched.")

(defvar mdview-image-test-calls nil
  "Arguments of every stubbed `url-queue-retrieve' call, newest first.")

(defun mdview-image-test-png-bytes ()
  "Return the bytes of the sample PNG fixture as a unibyte string."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally
     (expand-file-name "sample.png" mdview-image-test-fixtures))
    (buffer-string)))

(defun mdview-image-test-reset ()
  "Forget all pending images, in-flight fetches and cached data."
  (maphash (lambda (_url timer) (when (timerp timer) (cancel-timer timer)))
           mdview-image--inflight)
  (clrhash mdview-image--inflight)
  (maphash (lambda (_id job)
             (let ((ov (mdview-image--job-overlay job)))
               (when (overlay-buffer ov) (delete-overlay ov))))
           mdview-image--pending)
  (clrhash mdview-image--pending)
  (clrhash mdview-image-cache))

(defmacro mdview-image-test-with-graphics (&rest body)
  "Run BODY as if the display were graphical, with the network stubbed.
`url-queue-retrieve' records its arguments in `mdview-image-test-calls'
and does nothing; `frame-pixel-height' reports 1000 pixels.  All module
state is reset before and after BODY."
  (declare (indent 0) (debug t))
  `(cl-letf (((symbol-function 'mdview-image--graphic-p) (lambda () t))
             ((symbol-function 'frame-pixel-height) (lambda (&optional _f) 1000))
             ((symbol-function 'url-queue-retrieve)
              (lambda (&rest args) (push args mdview-image-test-calls) nil)))
     (setq mdview-image-test-calls nil)
     (mdview-image-test-reset)
     (unwind-protect
         (progn ,@body)
       (mdview-image-test-reset))))

(defun mdview-image-test-respond (url body &optional status)
  "Deliver BODY as the HTTP response for URL to the module's callback.
STATUS is the HTTP status code (default 200).  Return non-nil when the
response buffer was killed by the callback, as it must be."
  (let ((buffer (generate-new-buffer " *mdview-image-test-response*")))
    (with-current-buffer buffer
      (set-buffer-multibyte nil)
      (insert (format "HTTP/1.1 %d Whatever\r\nContent-Type: x\r\n\r\n"
                      (or status 200)))
      (insert body)
      (setq-local url-http-response-status (or status 200))
      (mdview-image--on-retrieve nil url))
    (not (buffer-live-p buffer))))

;;;; Options and faces

(ert-deftest mdview-image-options-defined ()
  "The image options exist with the documented defaults, in group `mdview'."
  (should (eq mdview-display-images t))
  (should (eq mdview-display-remote-images t))
  (should (equal mdview-image-max-height 0.6))
  (should (null mdview-image-max-width))
  (should (equal mdview-image-timeout 10))
  (should (null mdview-image-captions))
  (should (null mdview-image-placeholder-format))
  (dolist (option '(mdview-display-images mdview-display-remote-images
                    mdview-image-max-height mdview-image-max-width
                    mdview-image-timeout mdview-image-captions
                    mdview-image-placeholder-format))
    (should (custom-variable-p option))
    (should (assq option (get 'mdview 'custom-group))))
  (should (facep 'mdview-image-placeholder))
  (should (facep 'mdview-image-caption))
  (should (hash-table-p mdview-image-cache)))

;;;; Placeholders

(ert-deftest mdview-image-placeholder-alt ()
  "The placeholder shows the glyph and the alt text with link-like properties."
  (let* ((url "images/sample.png")
         (text (mdview-image-placeholder url "A sample")))
    (should (equal text (concat (mdview-glyph 'image) " A sample")))
    (should (equal (substring-no-properties text) "🖼 A sample"))
    (should (eq (get-text-property 0 'face text) 'mdview-image-placeholder))
    (should (equal (get-text-property 0 'mdview-link text) url))
    (should (equal (get-text-property 0 'help-echo text) url))
    (should (eq (get-text-property 0 'mouse-face text) 'highlight))
    ;; Properties cover the whole string.
    (should (eq (get-text-property (1- (length text)) 'face text)
                'mdview-image-placeholder))
    (should-not (get-text-property 0 'mdview-image-pending text))))

(ert-deftest mdview-image-placeholder-empty-alt-uses-file-name ()
  "An empty or blank alt falls back to the file name part of the URL."
  (should (equal (substring-no-properties
                  (mdview-image-placeholder "images/sample.png" ""))
                 "🖼 sample.png"))
  (should (equal (substring-no-properties
                  (mdview-image-placeholder "images/sample.png" "   "))
                 "🖼 sample.png"))
  (should (equal (substring-no-properties
                  (mdview-image-placeholder "images/sample.png" nil))
                 "🖼 sample.png"))
  (should (equal (substring-no-properties
                  (mdview-image-placeholder
                   "https://example.com/a/b/photo.jpg?raw=1#x" ""))
                 "🖼 photo.jpg"))
  (should (equal (substring-no-properties
                  (mdview-image-placeholder "file:///tmp/my%20pic.png" ""))
                 "🖼 my pic.png"))
  (should (equal (substring-no-properties
                  (mdview-image-placeholder "data:image/png;base64,AAAA" ""))
                 "🖼 data image")))

(ert-deftest mdview-image-placeholder-format-and-glyphs ()
  "`mdview-image-placeholder-format' and the ASCII glyph profile are honoured."
  (let ((mdview-image-placeholder-format "[image: %s]"))
    (should (equal (substring-no-properties
                    (mdview-image-placeholder "x.png" "Alt"))
                   "[image: Alt]")))
  (let ((mdview-use-ascii-glyphs t))
    (should (equal (substring-no-properties
                    (mdview-image-placeholder "x.png" "Alt"))
                   "[img] Alt")))
  ;; A broken format never signals.
  (let ((mdview-image-placeholder-format "%d %s"))
    (should (stringp (mdview-image-placeholder "x.png" "Alt")))))

(ert-deftest mdview-image-label ()
  "`mdview-image-label' prefers the alt text and otherwise derives a name."
  (should (equal (mdview-image-label "x.png" "Alt text") "Alt text"))
  (should (equal (mdview-image-label "dir/x.png" "") "x.png"))
  (should (equal (mdview-image-label "/abs/dir/x.png" nil) "x.png"))
  (should (equal (mdview-image-label "https://h/x.png?q#f" "") "x.png"))
  (should (equal (mdview-image-label "https://h/" "") "https://h/")))

;;;; URL classification and path resolution

(ert-deftest mdview-image-url-kind ()
  "Schemes are classified as remote, local or unsupported."
  (should (eq (mdview-image-url-kind "http://h/x.png") 'remote))
  (should (eq (mdview-image-url-kind "https://h/x.png") 'remote))
  (should (eq (mdview-image-url-kind "HTTPS://h/x.png") 'remote))
  (should (eq (mdview-image-url-kind "images/x.png") 'local))
  (should (eq (mdview-image-url-kind "/abs/x.png") 'local))
  (should (eq (mdview-image-url-kind "~/x.png") 'local))
  (should (eq (mdview-image-url-kind "file:///abs/x.png") 'local))
  (should (eq (mdview-image-url-kind "C:\\pics\\x.png") 'local))
  (should (null (mdview-image-url-kind "data:image/png;base64,AAAA")))
  (should (null (mdview-image-url-kind "mailto:someone@example.com")))
  (should (null (mdview-image-url-kind "ftp://h/x.png"))))

(ert-deftest mdview-image-local-path-relative ()
  "Relative paths resolve against the base directory or `default-directory'."
  (should (equal (mdview-image-local-path "images/a.png" "/tmp/docs/")
                 "/tmp/docs/images/a.png"))
  (should (equal (mdview-image-local-path "images/a.png" "/tmp/docs")
                 "/tmp/docs/images/a.png"))
  (should (equal (mdview-image-local-path "../a.png" "/tmp/docs/sub/")
                 "/tmp/docs/a.png"))
  (let ((default-directory "/tmp/dd/"))
    (should (equal (mdview-image-local-path "images/a.png")
                   "/tmp/dd/images/a.png"))))

(ert-deftest mdview-image-local-path-absolute-tilde-file ()
  "Absolute, `~' and file:// paths ignore the base directory."
  (should (equal (mdview-image-local-path "/abs/a.png" "/tmp/docs/")
                 "/abs/a.png"))
  (should (equal (mdview-image-local-path "~/a.png" "/tmp/docs/")
                 (expand-file-name "~/a.png")))
  (should (equal (mdview-image-local-path "file:///tmp/a.png" "/tmp/docs/")
                 "/tmp/a.png"))
  (should (equal (mdview-image-local-path "file://localhost/tmp/a.png" "/x/")
                 "/tmp/a.png"))
  (should (equal (mdview-image-local-path "file:///tmp/a%20b.png" "/x/")
                 "/tmp/a b.png"))
  (should (equal (mdview-image-local-path "caf%C3%A9.png" "/tmp/docs/")
                 "/tmp/docs/café.png")))

(ert-deftest mdview-image-local-path-non-local ()
  "Remote and unsupported URLs have no local path."
  (should (null (mdview-image-local-path "https://h/x.png" "/tmp/")))
  (should (null (mdview-image-local-path "data:image/png;base64,AA" "/tmp/"))))

(ert-deftest mdview-image-local-path-prefers-existing-literal-name ()
  "A file whose name literally contains %20 wins over the decoded name."
  (let* ((dir (make-temp-file "mdview-image-test" t))
         (literal (expand-file-name "a%20b.png" dir)))
    (unwind-protect
        (progn
          (should (equal (mdview-image-local-path "a%20b.png" dir)
                         (expand-file-name "a b.png" dir)))
          (with-temp-file literal (insert "x"))
          (should (equal (mdview-image-local-path "a%20b.png" dir) literal)))
      (delete-directory dir t))))

;;;; Displayability

(ert-deftest mdview-image-not-displayable-in-batch ()
  "Nothing is displayable in batch mode, not even an existing PNG."
  (should (null (mdview-image--graphic-p)))
  (should (null (mdview-image-displayable-p "sample.png"
                                            mdview-image-test-fixtures)))
  (should (null (mdview-image-displayable-p mdview-image-test-url)))
  (should (null (mdview-image-displayable-p "data:image/png;base64,AA"))))

(ert-deftest mdview-image-displayable-with-graphics ()
  "With a (faked) graphical display the options and file checks apply."
  (mdview-image-test-with-graphics
    (should (mdview-image-displayable-p "sample.png"
                                        mdview-image-test-fixtures))
    (should (mdview-image-displayable-p
             (expand-file-name "sample.png" mdview-image-test-fixtures)))
    (should (eq (mdview-image-displayable-p "sample.svg"
                                            mdview-image-test-fixtures)
                (image-type-available-p 'svg)))
    (should (mdview-image-displayable-p mdview-image-test-url))
    (should-not (mdview-image-displayable-p "does-not-exist.png"
                                            mdview-image-test-fixtures))
    (should-not (mdview-image-displayable-p "data:image/png;base64,AA"))
    (should-not (mdview-image-displayable-p mdview-image-test-dir))
    (let ((txt (make-temp-file "mdview-image-test" nil ".txt" "plain")))
      (unwind-protect
          (should-not (mdview-image-displayable-p txt))
        (delete-file txt)))
    (let ((mdview-display-remote-images nil))
      (should-not (mdview-image-displayable-p mdview-image-test-url))
      (should (mdview-image-displayable-p "sample.png"
                                          mdview-image-test-fixtures)))
    (let ((mdview-display-images nil))
      (should-not (mdview-image-displayable-p mdview-image-test-url))
      (should-not (mdview-image-displayable-p "sample.png"
                                              mdview-image-test-fixtures)))))

;;;; Sizes

(ert-deftest mdview-image-max-height-integer-and-float ()
  "Integer heights are pixels, floats are fractions of the frame height."
  (cl-letf (((symbol-function 'frame-pixel-height)
             (lambda (&optional _frame) 1000)))
    (let ((mdview-image-max-height 300))
      (should (equal (mdview-image-max-height-px) 300))
      (should (equal (mdview-image-max-height-px 123) 123)))
    (let ((mdview-image-max-height 0.5))
      (should (equal (mdview-image-max-height-px) 500)))
    (let ((mdview-image-max-height 0.6))
      (should (equal (mdview-image-max-height-px) 600)))
    (let ((mdview-image-max-height 0.0001))
      (should (equal (mdview-image-max-height-px) 1)))))

(ert-deftest mdview-image-max-width ()
  "The width limit is the content width, lowered by `mdview-image-max-width'."
  (let ((mdview-image-max-width nil))
    (should (equal (mdview-image-max-width-px 800) 800))
    (should (null (mdview-image-max-width-px nil))))
  (let ((mdview-image-max-width 400))
    (should (equal (mdview-image-max-width-px 800) 400))
    (should (equal (mdview-image-max-width-px 300) 300))
    (should (equal (mdview-image-max-width-px nil) 400))))

;;;; Insertion

(ert-deftest mdview-image-insert-placeholder-in-batch ()
  "In batch `mdview-image-insert' inserts the placeholder and counts columns."
  (with-temp-buffer
    (let* ((url "images/sample.png")
           (expected (mdview-image-placeholder url "Sample image"))
           (result (mdview-image-insert url "Sample image"
                                        :base-dir mdview-image-test-fixtures
                                        :max-width-px 800)))
      (should (equal result (cons (string-width expected) 'placeholder)))
      (should (equal (buffer-string) expected))
      (should (equal (get-text-property 1 'mdview-link) url))
      (should (eq (get-text-property 1 'face) 'mdview-image-placeholder))
      (should-not (get-text-property 1 'mdview-image-pending))
      (should-not (overlays-in (point-min) (point-max))))))

(ert-deftest mdview-image-insert-placeholder-wide-chars-and-inline ()
  "Column counts use `string-width'; INLINE and nil alt are accepted."
  (with-temp-buffer
    (let ((result (mdview-image-insert "x.png" "日本語" :inline t)))
      (should (eq (cdr result) 'placeholder))
      (should (equal (car result) (string-width (buffer-string))))
      (should (> (car result) (length "日本語")))))
  (with-temp-buffer
    (let ((result (mdview-image-insert "dir/pic.png" nil)))
      (should (equal (cdr result) 'placeholder))
      (should (equal (substring-no-properties (buffer-string)) "🖼 pic.png")))))

(ert-deftest mdview-image-insert-remote-in-batch-no-network ()
  "A remote image in batch becomes a placeholder without touching the network."
  (setq mdview-image-test-calls nil)
  (cl-letf (((symbol-function 'url-queue-retrieve)
             (lambda (&rest args) (push args mdview-image-test-calls) nil)))
    (with-temp-buffer
      (let ((result (mdview-image-insert mdview-image-test-url "Photo")))
        (should (eq (cdr result) 'placeholder))
        (should (equal (substring-no-properties (buffer-string)) "🖼 Photo"))
        (should-not (get-text-property 1 'mdview-image-pending))))
    (should (null mdview-image-test-calls))
    (should (zerop (hash-table-count mdview-image--pending)))
    (should (zerop (hash-table-count mdview-image--inflight)))))

(ert-deftest mdview-image-insert-remote-disabled-no-network ()
  "With `mdview-display-remote-images' nil no fetch starts, even with graphics."
  (mdview-image-test-with-graphics
    (let ((mdview-display-remote-images nil))
      (with-temp-buffer
        (should (eq (cdr (mdview-image-insert mdview-image-test-url "Photo"))
                    'placeholder)))
      (should (null mdview-image-test-calls)))))

(ert-deftest mdview-image-insert-unsupported-scheme ()
  "data: URLs always get a placeholder, even with graphics."
  (mdview-image-test-with-graphics
    (with-temp-buffer
      (let ((result (mdview-image-insert "data:image/png;base64,AAAA" "")))
        (should (eq (cdr result) 'placeholder))
        (should (equal (substring-no-properties (buffer-string))
                       "🖼 data image"))))
    (should (null mdview-image-test-calls))))

(ert-deftest mdview-image-insert-local-falls-back-without-window-system ()
  "A displayable local image that cannot be measured yields the placeholder.
In batch `image-size' signals, so the fallback path is exercised."
  (mdview-image-test-with-graphics
    (with-temp-buffer
      (let ((result (mdview-image-insert "sample.png" "Sample"
                                         :base-dir mdview-image-test-fixtures
                                         :max-width-px 640)))
        (should (eq (cdr result) 'placeholder))
        (should (equal (substring-no-properties (buffer-string)) "🖼 Sample"))))))

;;;; Pending remote images

(ert-deftest mdview-image-insert-remote-pending ()
  "With graphics a remote image gets a pending placeholder and one fetch."
  (mdview-image-test-with-graphics
    (with-temp-buffer
      (let* ((mdview-image-max-height 0.5)
             (result (mdview-image-insert mdview-image-test-url "Photo"
                                          :max-width-px 640))
             (id (get-text-property 1 'mdview-image-pending))
             (overlays (overlays-in (point-min) (point-max))))
        (should (eq (cdr result) 'pending))
        (should (equal (car result) (string-width (buffer-string))))
        (should (equal (substring-no-properties (buffer-string)) "🖼 Photo"))
        (should (integerp id))
        (should (equal (get-text-property (1- (point-max)) 'mdview-image-pending)
                       id))
        (should (= (length overlays) 1))
        (should (equal (overlay-get (car overlays) 'mdview-image-id) id))
        (should (equal (overlay-get (car overlays) 'mdview-image-url)
                       mdview-image-test-url))
        (should (equal (overlay-get (car overlays) 'mdview-image-max-width) 640))
        (should (equal (overlay-get (car overlays) 'mdview-image-max-height) 500))
        ;; One fetch: silent, no cookies, our callback with the URL.
        (should (= (length mdview-image-test-calls) 1))
        (pcase-let ((`(,url ,callback ,cbargs ,silent ,inhibit-cookies)
                     (car mdview-image-test-calls)))
          (should (equal url mdview-image-test-url))
          (should (eq callback #'mdview-image--on-retrieve))
          (should (equal cbargs (list mdview-image-test-url)))
          (should silent)
          (should inhibit-cookies))
        (should (timerp (gethash mdview-image-test-url mdview-image--inflight)))
        (should (= (hash-table-count mdview-image--pending) 1))
        ;; A second placeholder for the same URL shares the fetch.
        (insert " ")
        (let ((second (mdview-image-insert mdview-image-test-url "Again")))
          (should (eq (cdr second) 'pending)))
        (should (= (length mdview-image-test-calls) 1))
        (should (= (hash-table-count mdview-image--pending) 2))
        (should (equal (sort (mdview-image--pending-ids (current-buffer)) #'<)
                       (sort (mapcar #'mdview-image--job-id
                                     (mdview-image--jobs-for
                                      mdview-image-test-url))
                             #'<)))))))

(ert-deftest mdview-image-pending-ids-unique ()
  "Every pending placeholder gets its own identifier."
  (mdview-image-test-with-graphics
    (with-temp-buffer
      (mdview-image-insert "https://example.invalid/a.png" "a")
      (insert "\n")
      (mdview-image-insert "https://example.invalid/b.png" "b")
      (let ((ids (mdview-image--pending-ids (current-buffer))))
        (should (= (length ids) 2))
        (should-not (= (car ids) (cadr ids))))
      (should (= (length mdview-image-test-calls) 2)))))

(ert-deftest mdview-image-retrieve-error-keeps-placeholder ()
  "An error status keeps the placeholder, drops the job, caches nothing."
  (mdview-image-test-with-graphics
    (with-temp-buffer
      (mdview-image-insert mdview-image-test-url "Photo")
      (let ((before (buffer-string))
            (temp (generate-new-buffer " *mdview-image-test-error*")))
        (with-current-buffer temp
          (mdview-image--on-retrieve
           (list :error (list 'error 'http 404)) mdview-image-test-url))
        (should-not (buffer-live-p temp))
        (should (equal (buffer-string) before))
        (should-not (overlays-in (point-min) (point-max)))
        (should (zerop (hash-table-count mdview-image--pending)))
        (should (zerop (hash-table-count mdview-image--inflight)))
        (should-not (gethash mdview-image-test-url mdview-image-cache))))))

(ert-deftest mdview-image-retrieve-success-caches-bytes ()
  "A 2xx response with image bytes is cached; the job is finished."
  (mdview-image-test-with-graphics
    (let ((bytes (mdview-image-test-png-bytes)))
      (with-temp-buffer
        (mdview-image-insert mdview-image-test-url "Photo")
        (should (mdview-image-test-respond mdview-image-test-url bytes))
        (let ((cached (gethash mdview-image-test-url mdview-image-cache)))
          (should (stringp cached))
          (should-not (multibyte-string-p cached))
          (should (equal cached bytes)))
        ;; Without a window system the image cannot be measured, so the
        ;; placeholder stays; the job is nevertheless complete.
        (should (equal (substring-no-properties (buffer-string)) "🖼 Photo"))
        (should-not (overlays-in (point-min) (point-max)))
        (should (zerop (hash-table-count mdview-image--pending)))
        (should (zerop (hash-table-count mdview-image--inflight)))))))

(ert-deftest mdview-image-retrieve-non-image-or-bad-status-not-cached ()
  "HTML bodies and non-2xx statuses are not cached and keep the placeholder."
  (mdview-image-test-with-graphics
    (with-temp-buffer
      (mdview-image-insert mdview-image-test-url "Photo")
      (should (mdview-image-test-respond mdview-image-test-url
                                         "<html><body>Not found</body></html>"))
      (should-not (gethash mdview-image-test-url mdview-image-cache))
      (should (equal (substring-no-properties (buffer-string)) "🖼 Photo"))
      (should (zerop (hash-table-count mdview-image--pending))))
    (with-temp-buffer
      (mdview-image-insert mdview-image-test-url "Photo")
      (should (mdview-image-test-respond mdview-image-test-url
                                         (mdview-image-test-png-bytes) 404))
      (should-not (gethash mdview-image-test-url mdview-image-cache))
      (should (zerop (hash-table-count mdview-image--pending))))))

(ert-deftest mdview-image-response-image-parsing ()
  "The body after the header block is returned only when it is an image."
  (let ((bytes (mdview-image-test-png-bytes)))
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (insert "HTTP/1.1 200 OK\nContent-Length: 5\n\n" bytes)
      (should (equal (mdview-image--response-image) bytes)))
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (insert "HTTP/1.1 200 OK\r\n\r\n" bytes)
      (setq-local url-http-response-status 204)
      (should (equal (mdview-image--response-image) bytes))
      (setq-local url-http-response-status 500)
      (should-not (mdview-image--response-image)))
    (with-temp-buffer
      (insert "HTTP/1.1 200 OK\r\n\r\n")
      (should-not (mdview-image--response-image)))
    (with-temp-buffer
      (insert "no header separator at all")
      (should-not (mdview-image--response-image)))))

(ert-deftest mdview-image-cached-url-displayed-synchronously ()
  "A cached remote URL never starts a fetch; display is attempted at once."
  (mdview-image-test-with-graphics
    (puthash mdview-image-test-url (mdview-image-test-png-bytes)
             mdview-image-cache)
    (with-temp-buffer
      (let ((result (mdview-image-insert mdview-image-test-url "Photo")))
        ;; No window system: the synchronous attempt falls back to the
        ;; placeholder, but no fetch is queued and nothing is pending.
        (should (eq (cdr result) 'placeholder))
        (should (equal (substring-no-properties (buffer-string)) "🖼 Photo"))))
    (should (null mdview-image-test-calls))
    (should (zerop (hash-table-count mdview-image--pending)))))

(ert-deftest mdview-image-timeout-gives-up ()
  "The watchdog forgets the fetch and keeps the placeholder."
  (mdview-image-test-with-graphics
    (with-temp-buffer
      (mdview-image-insert mdview-image-test-url "Photo")
      (let ((url-queue nil))
        (mdview-image--on-timeout mdview-image-test-url))
      (should (equal (substring-no-properties (buffer-string)) "🖼 Photo"))
      (should (zerop (hash-table-count mdview-image--pending)))
      (should (zerop (hash-table-count mdview-image--inflight)))
      ;; A second timeout for the same URL is a harmless no-op.
      (mdview-image--on-timeout mdview-image-test-url))))

(ert-deftest mdview-image-timeout-kills-queued-job ()
  "A queued `url-queue' job for the URL is killed and reported as an error."
  (mdview-image-test-with-graphics
    (with-temp-buffer
      (mdview-image-insert mdview-image-test-url "Photo")
      (let* ((job (make-url-queue :url mdview-image-test-url
                                  :callback #'mdview-image--on-retrieve
                                  :cbargs (list mdview-image-test-url)))
             (other (make-url-queue :url "https://example.invalid/other"
                                    :callback #'ignore))
             (url-queue (list job other)))
        (mdview-image--on-timeout mdview-image-test-url)
        (should (equal url-queue (list other))))
      (should (equal (substring-no-properties (buffer-string)) "🖼 Photo"))
      (should (zerop (hash-table-count mdview-image--pending)))
      (should (zerop (hash-table-count mdview-image--inflight)))
      (should-not (gethash mdview-image-test-url mdview-image-cache)))))

(ert-deftest mdview-image-job-region-survives-copying ()
  "A placeholder copied into an mdview-mode buffer is still found by its id."
  (mdview-image-test-with-graphics
    (let ((copy (generate-new-buffer " *mdview-image-test-copy*"))
          text job)
      (unwind-protect
          (progn
            (with-temp-buffer
              (mdview-image-insert mdview-image-test-url "Photo")
              (setq text (buffer-string))
              (setq job (car (mdview-image--jobs-for mdview-image-test-url)))
              ;; Alive overlay: region is found through it.
              (should (equal (mdview-image--job-region job)
                             (list (current-buffer) 1 (point-max)))))
            ;; The temp buffer is dead; nothing is found yet.
            (should-not (mdview-image--job-region job))
            (with-current-buffer copy
              (setq major-mode 'mdview-mode)
              (insert "prefix " text " suffix"))
            (should (equal (mdview-image--job-region job)
                           (list copy 8 (+ 8 (length text))))))
        (kill-buffer copy)))))

(ert-deftest mdview-image-foreign-properties ()
  "Only properties the module did not set are carried over on replacement."
  (let ((text (propertize "x" 'face 'bold 'mdview-link "u" 'help-echo "h"
                          'mouse-face 'highlight 'mdview-image-pending 7
                          'mdview-source-line 12 'mdview-heading-id "hid")))
    (with-temp-buffer
      (insert text)
      (let ((props (mdview-image--foreign-properties 1)))
        (should (equal (plist-get props 'mdview-source-line) 12))
        (should (equal (plist-get props 'mdview-heading-id) "hid"))
        (should (= (length props) 4))))))

;;;; Cancelling and the cache

(ert-deftest mdview-image-cancel-pending-no-op ()
  "Cancelling in a buffer without pending images does nothing and returns 0."
  (with-temp-buffer
    (insert "no images here")
    (should (equal (mdview-image-cancel-pending) 0))
    (should (equal (mdview-image-cancel-pending (current-buffer) t) 0)))
  (let ((dead (generate-new-buffer " *mdview-image-test-dead*")))
    (kill-buffer dead)
    (should (equal (mdview-image-cancel-pending dead) 0))))

(ert-deftest mdview-image-cancel-pending-forgets-and-kills ()
  "Cancelling drops the buffer's jobs; KILL also aborts unshared fetches."
  (mdview-image-test-with-graphics
    (let ((other (generate-new-buffer " *mdview-image-test-other*")))
      (unwind-protect
          (with-temp-buffer
            (mdview-image-insert mdview-image-test-url "One")
            (insert "\n")
            (mdview-image-insert mdview-image-test-url "Two")
            (with-current-buffer other
              (mdview-image-insert mdview-image-test-url "Elsewhere"))
            (should (= (hash-table-count mdview-image--pending) 3))
            (let ((before (buffer-string)))
              ;; Without KILL the fetch survives for the other buffer.
              (should (equal (mdview-image-cancel-pending) 2))
              (should (equal (buffer-string) before))
              (should-not (overlays-in (point-min) (point-max)))
              (should (= (hash-table-count mdview-image--pending) 1))
              (should (gethash mdview-image-test-url mdview-image--inflight))
              ;; Cancelling again finds nothing.
              (should (equal (mdview-image-cancel-pending) 0))
              ;; KILL in the last waiting buffer aborts the fetch.
              (should (equal (mdview-image-cancel-pending other t) 1))
              (should (zerop (hash-table-count mdview-image--pending)))
              (should (zerop (hash-table-count mdview-image--inflight)))))
        (kill-buffer other)))))

(ert-deftest mdview-image-cancel-pending-kill-shared-fetch-kept ()
  "KILL leaves a fetch alone while another buffer still waits for it."
  (mdview-image-test-with-graphics
    (let ((other (generate-new-buffer " *mdview-image-test-other*")))
      (unwind-protect
          (with-temp-buffer
            (mdview-image-insert mdview-image-test-url "One")
            (with-current-buffer other
              (mdview-image-insert mdview-image-test-url "Elsewhere"))
            (should (equal (mdview-image-cancel-pending (current-buffer) t) 1))
            (should (= (hash-table-count mdview-image--pending) 1))
            (should (gethash mdview-image-test-url mdview-image--inflight)))
        (kill-buffer other)))))

(ert-deftest mdview-image-clear-cache ()
  "`mdview-image-clear-cache' empties the cache."
  (mdview-image-test-with-graphics
    (puthash "https://example.invalid/a.png" "bytes" mdview-image-cache)
    (puthash "https://example.invalid/b.png" "bytes" mdview-image-cache)
    (should (= (hash-table-count mdview-image-cache) 2))
    (should (commandp 'mdview-image-clear-cache))
    (mdview-image-clear-cache)
    (should (zerop (hash-table-count mdview-image-cache)))))

;;;; Opening images

(ert-deftest mdview-image-open-dispatch ()
  "Local images open with `find-file', remote ones with `browse-url'."
  (let ((opened nil)
        (browsed nil)
        (file (make-temp-file "mdview-image-test" nil ".png" "not really")))
    (unwind-protect
        (cl-letf (((symbol-function 'find-file)
                   (lambda (f &rest _) (setq opened f)))
                  ((symbol-function 'browse-url)
                   (lambda (u &rest _) (setq browsed u))))
          (mdview-image-open (file-name-nondirectory file)
                             (file-name-directory file))
          (should (equal opened (expand-file-name file)))
          (should (null browsed))
          (mdview-image-open mdview-image-test-url)
          (should (equal browsed mdview-image-test-url))
          (should-error (mdview-image-open "missing.png" (file-name-directory file))
                        :type 'user-error)
          (should-error (mdview-image-open "data:image/png;base64,AAAA")
                        :type 'user-error))
      (delete-file file))))

;;;; Hygiene

(ert-deftest mdview-image-compiles-clean ()
  "The module byte-compiles without warnings."
  (should (file-exists-p mdview-image-test-source))
  (let* ((dest (make-temp-file "mdview-image-test" nil ".elc"))
         (byte-compile-dest-file-function (lambda (_) dest))
         (byte-compile-error-on-warn t)
         (byte-compile-verbose nil))
    (unwind-protect
        (should (byte-compile-file mdview-image-test-source))
      (ignore-errors (delete-file dest)))))

(ert-deftest mdview-image-api-signatures ()
  "The public API of DESIGN.md §15 exists with the agreed arities."
  (should (fboundp 'mdview-image-displayable-p))
  (should (fboundp 'mdview-image-insert))
  (should (fboundp 'mdview-image-placeholder))
  (should (fboundp 'mdview-image-clear-cache))
  (should (fboundp 'mdview-image-cancel-pending))
  (should (fboundp 'mdview-image-open))
  (should (equal (func-arity 'mdview-image-displayable-p) '(1 . 2)))
  (should (equal (func-arity 'mdview-image-placeholder) '(2 . 2)))
  (should (equal (func-arity 'mdview-image-open) '(1 . 2)))
  (should (equal (func-arity 'mdview-image-clear-cache) '(0 . 0)))
  (should (eq (cdr (func-arity 'mdview-image-insert)) 'many)))

(provide 'mdview-image-test)
;;; mdview-image-test.el ends here
