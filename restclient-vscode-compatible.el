;;; restclient.el ---                                -*- lexical-binding: t; -*-

;; Copyright (C) 2020  toshiki kawai

;; Author: toshiki kawai <toshiki@aintek.xyz>
;; Keywords: http rest api

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:
;;
;; This is a tool to manually explore and test HTTP REST webserver.
;; Runs queries from a plain-text quert sheet, 
;; displays results as a pretty-printed XML, JSON and even images.
;; It's also compatible with vscode-restclient(https://github.com/Huachao/vscode-restclient)
;;
;; This code customize restclient(https://github.com/pashky/restclient.el/blob/master/restclient.el)
;; to use original variable '@my_value' compatiabled with vscode-restclient.
;;
;; feature works:
;; 1. switch default-mode and vscode-mode.
;;   default variable is :my_value,
;;   but variable has '@' at the beginning such as '@my_value' when vscode-mode.

;;; Code:

(require 'url)
(require 'json)
(require 'outline)

;; Which group should I beloing restclient(custom group) to?
(defgroup restclient nil
  "An interactive HTTP client for Emacs."
  :group 'tools)

(defcustom restclient-log-request t
  "Log restclient requests to *Messages*."
  :group 'restclient
  :type 'boolean)

(defcustom restclient-same-buffer-response t
  "Re-use same buffer for responses or create a new one each time."
  :group 'restclient
  :type 'boolean)

(defcustom restclient-same-buffer-response-name "*HTTP Response*"
  "Name for response buffer."
  :group 'restclient
  :type 'string)

(defcustom restclient-inhibit-cookies nil
  "Inhibit restclient from sending cookies implicitly."
  :group 'restclient
  :type 'boolean)

;; add Content-type if you want.
;; Refererence: https://developer.mozilla.org/ja/docs/Web/HTTP/Basics_of_HTTP/MIME_types
(defcustom restclient-content-type-modes '(("text/xml" . xml-mode)
                                           ("text/plain" . text-mode)
                                           ("text/html" . html-mode)
                                           ("application/xml" . xml-mode)
                                           ("application/json" . js-mode)
                                           ("image/png" . image-mode)
                                           ("image/jpeg" . image-mode)
                                           ("image/jpg" . image-mode)
                                           ("image/gif" . image-mode))
  "An association list mapping content types to buffer modes"
  :group 'restclient
  :type '(alist :key-type string :value-type symbol))


;; face settings.
(defgroup restclient-faces nil
  "Faces used in Restclient Mode"
  :group 'restclient
  :group 'faces)

(defface restclient-variable-name-face
  '((t (:inherit font-lock-preprocessor-face)))
  "Face for variable name."
  :group 'restclient-faces)

(defface restclient-variable-string-face
  '((t (:inherit font-lock-string-face)))
  "Face for variable value (string)."
  :group 'restclient-faces)

(defface restclient-variable-elisp-face
  '((t (:inherit font-lock-function-name-face)))
  "Face for variable value (Emacs lisp)."
  :group 'restclient-faces)

(defface restclient-variable-multiline-face
  '((t (:inherit font-lock-doc-face)))
  "Face for multi-line variable value marker."
  :group 'restclient-faces)

(defface restclient-variable-usage-face
  '((t (:inherit restclient-variable-name-face)))
  "Face for variable usage (only used when headers/body is represented as a single variable, not highlighted when variable appears in the middle of other text)."
  :group 'restclient-faces)

(defface restclient-method-face
  '((t (:inherit font-lock-keyword-face)))
  "Face for HTTP method."
  :group 'restclient-faces)

(defface restclient-url-face
  '((t (:inherit font-lock-function-name-face)))
  "Face for variable value (Emacs lisp)."
  :group 'restclient-faces)

(defface restclient-file-upload-face
  '((t (:inherit restclient-variable-multiline-face)))
  "Face for highlighting upload file paths."
  :group 'restclient-faces)

(defface restclient-header-name-face
  '((t (:inherit font-lock-variable-name-face)))
  "Face for HTTP header name."
  :group 'restclient-faces)

(defface restclient-header-value-face
  '((t (:inherit font-lock-string-face)))
  "Face for HTTP header value."
  :group 'restclient-faces)

(defvar restclient-within-call nil)

(defvar restclient-request-time-start nil)
(defvar restclient-request-time-end nil)

(defvar restclient-response-loaded-hook nil
  "Hook run after response buffer is formatted.")

(defvar restclient-http-do-hook nil
  "Hook to run before making request.")

(defvar restclient-response-received-hook nil
  "Hook run after data is loaded into response buffer.")

(defcustom restclient-vars-max-passes 10
  "Maximum number of recursive variable references. This is to prevent hanging if two variables reference each other directly or indirectly."
  :group 'restclient
  :type 'integer)

;; comment out regexp settings.
(defconst restclient-comment-separator "#")
(defconst restclient-comment-start-regexp (concat "^" restclient-comment-separator))
(defconst restclient-comment-not-regexp (concat "^[^" restclient-comment-separator "]"))
(defconst restclient-empty-line-regexp "^\\s-*$")

(defconst restclient-method-url-regexp
  "^\\(GET\\|POST\\|DELETE\\|PUT\\|HEAD\\|OPTIONS\\|PATCH\\) \\(.*\\)$")

(defconst restclient-header-regexp
  "^\\([^](),/:;@[\\{}= \t]+\\): \\(.*\\)$")

;; variable regexp settins.

;; for vscode compatible
(defconst restclient-var-regexp
  (concat "^\\(@[^@= ]+\\)[ \t]*\\(:?\\)=[ \t]*\\(<<[ \t]*\n\\(\\(.*\n\\)*?\\)" restclient-comment-separator "\\|\\([^<].*\\)$\\)"))

(defconst restclient-svar-regexp
  "^\\(@[^@= ]+\\)[ \t]*=[ \t]*\\(.+?\\)$")

(defconst restclient-evar-regexp
  "^\\(@[^@ ]+\\)[ \t]*:=[ \t]*\\(.+?\\)$")

(defconst restclient-mvar-regexp
  "^\\(@[^@ ]+\\)[ \t]*:?=[ \t]*\\(<<\\)[ \t]*$")

(defconst restclient-use-var-regexp
;;  "^\\(@[^@ \n]+\\)$")
  "{{\([^{ \n]+\)}}$")

;; file regexp settings.
(defconst restclient-file-regexp
  "^<[ \t]*\\([^<>\n\r]+\\)[ \t]*$")

;; content-type regexp settings.
(defconst restclient-content-type-regexp
  "^Content-[Tt]ype: \\(\\w+\\)/\\(?:[^\\+\r\n]*\\+\\)*\\([^;\r\n]+\\)")

;; The following disables the interactive request for user name and
;; password should an API call encounter a permission-denied response.
;; This API is meant to be usable without constant asking for username
;; and password.

(defadvice url-http-handle-authentication (around restclient-fix)
  (if restclient-within-call
      (setq ad-return-value t)
    ad-do-it))
(ad-activate 'url-http-handle-authentication)

(defadvice url-cache-extract (around restclient-fix-2)
  (unless restclient-within-call
    ad-do-it))
(ad-activate 'url-cache-extract)

(defadvice url-http-user-agent-string (around restclient-fix-3)
  (if restclient-within-call
      (setq ad-return-value nil)
    ad-do-it))
(ad-activate 'url-http-user-agent-string)

(defun restclient-http-do (method url headers entity &rest handle-args)
  "Send ENTITY and HEADERS to URL as a METHOD request."
  (if restclient-log-request
      (message "HTTP %s %s Headers:[%s] Body:[%s]" method url headers entity))
  (let ((url-request-method (encode-coding-string method 'us-ascii))
        (url-request-extra-headers '())
        (url-request-data (encode-coding-string entity 'utf-8))
        (url-mime-charset-string (url-mime-charset-string))
        (url-mime-language-string nil)
        (url-mime-encoding-string nil)
        (url-mime-accept-string nil)
        (url-personal-mail-address nil))

    (dolist (header headers)
      (let* ((mapped (assoc-string (downcase (car header))
                                   '(("from" . url-personal-mail-address)
                                     ("accept-encoding" . url-mime-encoding-string)
                                     ("accept-charset" . url-mime-charset-string)
                                     ("accept-language" . url-mime-language-string)
                                     ("accept" . url-mime-accept-string)))))

        (if mapped
            (set (cdr mapped) (encode-coding-string (cdr header) 'us-ascii))
          (let* ((hkey (encode-coding-string (car header) 'us-ascii))
                 (hvalue (encode-coding-string (cdr header) 'us-ascii)))
            (setq url-request-extra-headers (cons (cons hkey hvalue) url-request-extra-headers))))))

    (setq restclient-within-call t)
    (setq restclient-request-time-start (current-time))
    (run-hooks 'restclient-http-do-hook)
    (url-retrieve url 'restclient-http-handle-response
                  (append (list method url (if restclient-same-buffer-response
                                               restclient-same-buffer-response-name
                                             (format "*HTTP %s %s*" method url)))
                          handle-args)
                  nil restclient-inhibit-cookies)))

(defun restclient-prettify-response (method url)
  (save-excursion
    ;; parse headers.
    (let ((start (point)) (guessed-mode) (end-of-headers))
      (while (and (not (looking-at restclient-empty-line-regexp))
                  (eq (progn
                        (when (looking-at restclient-content-type-regexp)
                          (setq guessed-mode
                                (cdr (assoc-string (concat
                                                    (match-string-no-properties 1)
                                                    "/"
                                                    (match-string-no-properties 2))
                                                   restclient-content-type-modes
                                                   t))))
                        (forward-line))
                      0)))
      ;; move the cursor pointer.
      (setq end-of-headers (point))
      (while (and (looking-at restclient-empty-line-regexp)
                  (eq (forward-line) 0)))
      ;; set specific mode.
      (unless guessed-mode
        (setq guessed-mode
              (or (assoc-default nil
                                 ;; magic mode matches
                                 '(("<\\?xml " . xml-mode)
                                   ("{\\s-*\"" . js-mode))
                                 (lambda (re _dummy)
                                   (looking-at re)))
                  'js-mode)))
      ;; 
      (let ((headers (buffer-substring-no-properties start end-of-headers)))
        (when guessed-mode
          (delete-region start (point))
          (unless (eq guessed-mode 'image-mode)
            (apply guessed-mode '())
            (if (fboundp 'font-lock-flush)
                (font-lock-flush)
              (with-no-warnings
                (font-lock-fontify-buffer))))

          (cond
           ;; When contents is XML.
           ((eq guessed-mode 'xml-mode)
            (goto-char (point-min))
            (while (search-forward-regexp "\>[ \\t]*\<" nil t)
              (backward-char) (insert "\n"))
            (indent-region (point-min) (point-max)))
           ;; When contents is Image.
           ((eq guessed-mode 'image-mode)
            (let* ((img (buffer-string)))
              (delete-region (point-min) (point-max))
              (fundamental-mode)
              (insert-image (create-image img nil t))))
           ;; When contents is JSON.
           ((eq guessed-mode 'js-mode)
            (let ((json-special-chars (remq (assoc ?/ json-special-chars) json-special-chars))
		  ;; Emacs 27 json.el uses `replace-buffer-contents' for
		  ;; pretty-printing which is great because it keeps point and
		  ;; markers intact but can be very slow with huge minimalized
		  ;; JSON.  We don't need that here.
		  (json-pretty-print-max-secs 0))
              (ignore-errors (json-pretty-print-buffer)))
            (restclient-prettify-json-unicode)))

          (goto-char (point-max))
          (or (eq (point) (point-min)) (insert "\n"))
          (let ((hstart (point)))
            (insert method " " url "\n" headers)
            (insert (format "Request duration: %fs\n" (float-time (time-subtract restclient-request-time-end restclient-request-time-start))))
            (unless (member guessed-mode '(image-mode text-mode))
              (comment-region hstart (point)))))))))

(defun restclient-prettify-json-unicode ()
  (save-excursion
    (goto-char (point-min))
    (while (re-search-forward "\\\\[Uu]\\([0-9a-fA-F]\\{4\\}\\)" nil t)
      (replace-match (char-to-string (decode-char 'ucs (string-to-number (match-string 1) 16))) t nil))))

(defun restclient-http-handle-response (status method url bufname raw stay-in-window)
  "Switch to the buffer returned by `url-retreive'.
The buffer contains the raw HTTP response sent by the server."
  (setq restclient-within-call nil)
  (setq restclient-request-time-end (current-time))
  (if (= (point-min) (point-max))
      (signal (car (plist-get status :error)) (cdr (plist-get status :error)))
    (when (buffer-live-p (current-buffer))
      (with-current-buffer (restclient-decode-response
                            (current-buffer)
                            bufname
                            restclient-same-buffer-response)
        (run-hooks 'restclient-response-received-hook)
        (unless raw
          (restclient-prettify-response method url))
        (buffer-enable-undo)
	(restclient-response-mode)
        (run-hooks 'restclient-response-loaded-hook)
        (if stay-in-window
            (display-buffer (current-buffer) t)
          (switch-to-buffer-other-window (current-buffer)))))))

(defun restclient-decode-response (raw-http-response-buffer target-buffer-name same-name)
  "Decode the HTTP response using the charset (encoding) specified in the Content-Type header. If no charset is specified, default to UTF-8."
  (let* ((charset-regexp "^Content-Type.*charset=\\([-A-Za-z0-9]+\\)")
         (image? (save-excursion
                   (search-forward-regexp "^Content-Type.*[Ii]mage" nil t)))
         (encoding (if (save-excursion
                         (search-forward-regexp charset-regexp nil t))
                       (intern (downcase (match-string 1)))
                     'utf-8)))
    (if image?
        ;; Dont' attempt to decode. Instead, just switch to the raw HTTP response buffer and
        ;; rename it to target-buffer-name.
        (with-current-buffer raw-http-response-buffer
          ;; We have to kill the target buffer if it exists, or `rename-buffer'
          ;; will raise an error.
          (when (get-buffer target-buffer-name)
            (kill-buffer target-buffer-name))
          (rename-buffer target-buffer-name)
          raw-http-response-buffer)
      ;; Else, switch to the new, empty buffer that will contain the decoded HTTP
      ;; response. Set its encoding, copy the content from the unencoded
      ;; HTTP response buffer and decode.
      (let ((decoded-http-response-buffer
             (get-buffer-create
              (if same-name target-buffer-name (generate-new-buffer-name target-buffer-name)))))
        (with-current-buffer decoded-http-response-buffer
          (setq buffer-file-coding-system encoding)
          (save-excursion
            (erase-buffer)
            (insert-buffer-substring raw-http-response-buffer))
          (kill-buffer raw-http-response-buffer)
          (condition-case nil
              (decode-coding-region (point-min) (point-max) encoding)
            (error
             (message (concat "Error when trying to decode http response with encoding: "
                              (symbol-name encoding)))))
          decoded-http-response-buffer)))))

(defun restclient-current-min ()
  (save-excursion
    (beginning-of-line)
    (if (looking-at restclient-comment-start-regexp)
        (if (re-search-forward restclient-comment-not-regexp (point-max) t)
            (point-at-bol) (point-max))
      (if (re-search-backward restclient-comment-start-regexp (point-min) t)
          (point-at-bol 2)
        (point-min)))))

(defun restclient-current-max ()
  (save-excursion
    (if (re-search-forward restclient-comment-start-regexp (point-max) t)
        (max (- (point-at-bol) 1) 1)
      (progn (goto-char (point-max))
             (if (looking-at "^$") (- (point) 1) (point))))))

(defun restclient-replace-all-in-string (replacements string)
  (if replacements
      (let ((current string)
            (pass restclient-vars-max-passes)
            (continue t))
        (while (and continue (> pass 0))
          (setq pass (- pass 1))
          (setq current (replace-regexp-in-string (regexp-opt (mapcar 'car replacements))
                                                  (lambda (key)
                                                    (setq continue t)
                                                    (cdr (assoc key replacements)))
                                                  current t t)))
        current)
    string))

(defun restclient-replace-all-in-header (replacements header)
  (cons (car header)
        (restclient-replace-all-in-string replacements (cdr header))))

(defun restclient-chop (text)
  (if text (replace-regexp-in-string "\n$" "" text) nil))

(defun restclient-find-vars-before-point ()
  (let ((vars nil)
        (bound (point)))
    (save-excursion
      (goto-char (point-min))
      ;; search variable definitions.
      (while (search-forward-regexp restclient-var-regexp bound t)
        (let ((name (match-string-no-properties 1))
              (should-eval (> (length (match-string 2)) 0))
              (value (or (restclient-chop (match-string-no-properties 4)) (match-string-no-properties 3))))
          (setq vars (cons (cons name (if should-eval (restclient-eval-var value) value)) vars))))
      vars)))

(defun restclient-eval-var (string)
  (with-output-to-string (princ (eval (read string)))))

(defun restclient-make-header (&optional string)
  (cons (match-string-no-properties 1 string)
        (match-string-no-properties 2 string)))

(defun restclient-parse-headers (string)
  (let ((start 0)
        (headers '()))
    (while (string-match restclient-header-regexp string start)
      (setq headers (cons (restclient-make-header string) headers)
            start (match-end 0)))
    headers))

(defun restclient-read-file (path)
  (with-temp-buffer
    (insert-file-contents path)
    (buffer-string)))

(defun restclient-parse-body (entity vars)
  (if (= 0 (or (string-match restclient-file-regexp entity) 1))
      (restclient-read-file (match-string 1 entity))
    (restclient-replace-all-in-string vars entity)))

(defun restclient-http-parse-current-and-do (func &rest args)
  (save-excursion
    (goto-char (restclient-current-min))
    (when (re-search-forward restclient-method-url-regexp (point-max) t)
      (let ((method (match-string-no-properties 1))
            (url (match-string-no-properties 2))
            (vars (restclient-find-vars-before-point))
            (headers '()))
        (forward-line)
        (while (cond
                ((and (looking-at restclient-header-regexp) (not (looking-at restclient-empty-line-regexp)))
                 (setq headers (cons (restclient-replace-all-in-header vars (restclient-make-header)) headers)))
                ((looking-at restclient-use-var-regexp)
                 (setq headers (append headers (restclient-parse-headers (restclient-replace-all-in-string vars (match-string 1)))))))
          (forward-line))
        (when (looking-at restclient-empty-line-regexp)
          (forward-line))
        (let* ((cmax (restclient-current-max))
               (entity (restclient-parse-body (buffer-substring (min (point) cmax) cmax) vars))
               (url (restclient-replace-all-in-string vars url)))
          (apply func method url headers entity args))))))

(defun restclient-copy-curl-command ()
  "Formats the request as a curl command and copies the command to the clipboard."
  (interactive)
  (restclient-http-parse-current-and-do
   '(lambda (method url headers entity)
      (let ((header-args
             (apply 'append
                    (mapcar (lambda (header)
                              (list "-H" (format "%s: %s" (car header) (cdr header))))
                            headers))))
        (kill-new (concat "curl "
                          (mapconcat 'shell-quote-argument
                                     (append '("-i")
                                             header-args
                                             (list (concat "-X" method))
                                             (list url)
                                             (when (> (string-width entity) 0)
                                               (list "-d" entity)))
                                     " "))))
      (message "curl command copied to clipboard."))))

;;; ### autoload
(defun restclient-http-send-current (&optional raw stay-in-window)
  "Sends current request.
Optional argument RAW don't reformat response if t.
Optional argument STAY-IN-WINDOW do not move focus to response buffer if t."
  (interactive)
  (restclient-http-parse-current-and-do 'restclient-http-do raw stay-in-window))

;;; ### autoload
(defun restclient-http-send-current-raw ()
  "Sends current request and get raw result (no reformatting or syntax highlight of XML, JSON or images)."
  (interactive)
  (restclient-http-send-current t))

;;; ### autoload
(defun restclient-http-send-current-stay-in-window ()
  "Send current request and keep focus in request window."
  (interactive)
  (restclient-http-send-current nil t))

(defun restclient-jump-next ()
  "Jump to next request in buffer."
  (interactive)
  (let ((last-min nil))
    (while (not (eq last-min (goto-char (restclient-current-min))))
      (goto-char (restclient-current-min))
      (setq last-min (point))))
  (goto-char (+ (restclient-current-max) 1))
  (goto-char (restclient-current-min)))

(defun restclient-jump-prev ()
  "Jump to previous request in buffer."
  (interactive)
  (let* ((current-min (restclient-current-min))
         (end-of-entity
          (save-excursion
            (progn (goto-char (restclient-current-min))
                   (while (and (or (looking-at "^\s*\\(#.*\\)?$")
                                   (eq (point) current-min))
                               (not (eq (point) (point-min))))
                     (forward-line -1)
                     (beginning-of-line))
                   (point)))))
    (unless (eq (point-min) end-of-entity)
      (goto-char end-of-entity)
      (goto-char (restclient-current-min)))))

(defun restclient-mark-current ()
  "Mark current request."
  (interactive)
  (goto-char (restclient-current-min))
  (set-mark-command nil)
  (goto-char (restclient-current-max))
  (backward-char 1)
  (setq deactivate-mark nil))

(defun restclient-narrow-to-current ()
  "Narrow to region of current request"
  (interactive)
  (narrow-to-region (restclient-current-min) (restclient-current-max)))

(defun restclient-toggle-body-visibility ()
  (interactive)
  ;; If we are not on the HTTP call line, don't do anything
  (let ((at-header (save-excursion
                     (beginning-of-line)
                     (looking-at restclient-method-url-regexp))))
    (when at-header
      (save-excursion
        (end-of-line)
        ;; If the overlays at this point have 'invisible set, toggling
        ;; must make the region visible. Else it must hide the region
        
        ;; This part of code is from org-hide-block-toggle method of
        ;; Org mode
        (let ((overlays (overlays-at (point))))
          (if (memq t (mapcar
                       (lambda (o)
                         (eq (overlay-get o 'invisible) 'outline))
                       overlays))
              (outline-flag-region (point) (restclient-current-max) nil)
            (outline-flag-region (point) (restclient-current-max) t)))) t)))

(defun restclient-toggle-body-visibility-or-indent ()
  (interactive)
  (unless (restclient-toggle-body-visibility)
    (indent-for-tab-command)))

(defconst restclient-mode-keywords
  (list (list restclient-method-url-regexp '(1 'restclient-method-face) '(2 'restclient-url-face))
        (list restclient-svar-regexp '(1 'restclient-variable-name-face) '(2 'restclient-variable-string-face))
        (list restclient-evar-regexp '(1 'restclient-variable-name-face) '(2 'restclient-variable-elisp-face t))
        (list restclient-mvar-regexp '(1 'restclient-variable-name-face) '(2 'restclient-variable-multiline-face t))
        (list restclient-file-regexp '(0 'restclient-file-upload-face))
        (list restclient-header-regexp '(1 'restclient-header-name-face t) '(2 'restclient-header-value-face t))
        ))

(defconst restclient-mode-syntax-table
  (let ((table (make-syntax-table)))
    (modify-syntax-entry ?\# "<" table)
    (modify-syntax-entry ?\n ">#" table)
    table))

(defvar restclient-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") 'restclient-http-send-current)
    (define-key map (kbd "C-c C-r") 'restclient-http-send-current-raw)
    (define-key map (kbd "C-c C-v") 'restclient-http-send-current-stay-in-window)
    (define-key map (kbd "C-c C-n") 'restclient-jump-next)
    (define-key map (kbd "C-c C-p") 'restclient-jump-prev)
    (define-key map (kbd "C-c C-.") 'restclient-mark-current)
    (define-key map (kbd "C-c C-u") 'restclient-copy-curl-command)
    (define-key map (kbd "C-c n n") 'restclient-narrow-to-current)
    map)
  "Keymap for restclient-mode.")

(define-minor-mode restclient-outline-mode
  "Minor mode to allow show/hide of request bodies by TAB."
      :init-value nil
      :lighter nil
      :keymap '(("\t" . restclient-toggle-body-visibility-or-indent)
                ("\C-c\C-a" . restclient-toggle-body-visibility-or-indent))
      :group 'restclient)

(define-minor-mode restclient-response-mode
  "Minor mode to allow additional keybindings in restclient response buffer."
  :init-value nil
  :lighter nil
  :keymap '(("q" . (lambda ()
		     (interactive)
		     (quit-window (get-buffer-window (current-buffer))))))
  :group 'restclient)

;;; ### autoload
(define-derived-mode restclient-mode fundamental-mode "REST Client"
  "Turn on restclient mode."
  (set (make-local-variable 'comment-start) "# ")
  (set (make-local-variable 'comment-start-skip) "# *")
  (set (make-local-variable 'comment-column) 48)

  (set (make-local-variable 'font-lock-defaults) '(restclient-mode-keywords))
  ;; We use outline-mode's method outline-flag-region to hide/show the
  ;; body. As a part of it, it sets 'invisibility text property to
  ;; 'outline. To get ellipsis, we need 'outline to be in
  ;; buffer-invisibility-spec
  (add-to-invisibility-spec '(outline . t)))

(add-hook 'restclient-mode-hook 'restclient-outline-mode)

(provide 'restclient)
;;; restclient.el ends here
