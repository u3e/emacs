;;; quickurl.el --- Insert an URL based on text at point in buffer.

;; Copyright (C) 1999 Free Software Foundation, Inc.

;; Author: Dave Pearson <davep@hagbard.demon.co.uk>
;; Maintainer: Dave Pearson <davep@hagbard.demon.co.uk>
;; Created: 1999-05-28
;; Keywords: hypermedia

;; This file is part of GNU emacs.

;; GNU Emacs is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 2, or (at your option)
;; any later version.

;; GNU Emacs is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs; see the file COPYING.  If not, write to the
;; Free Software Foundation, Inc., 59 Temple Place - Suite 330,
;; Boston, MA 02111-1307, USA.

;;; Commentary:
;;
;; This package provides a simple method of inserting an URL based on the
;; text at point in the current buffer. This is part of an on-going effort
;; to increase the information I provide people while reducing the ammount
;; of typing I need to do. No-doubt there are undiscovered Emacs packages
;; out there that do all of this and do it better, feel free to point me to
;; them, in the mean time I'm having fun playing with Emacs Lisp.
;;
;; The URLs are stored in an external file as a list of either cons cells,
;; or lists. A cons cell entry looks like this:
;;
;;    (<Lookup> . <URL>)
;;
;; where <Lookup> is a string that acts as the keyword lookup and <URL> is
;; the URL associated with it. An example might be:
;;
;;    ("GNU" . "http://www.gnu.org/")
;;
;; A list entry looks like:
;;
;;    (<Lookup> <URL> <Comment>)
;;
;; where <Lookup> and <URL> are the same as with the cons cell and <Comment>
;; is any text you like that describes the URL. This description will be
;; used when presenting a list of URLS using `quickurl-list'. An example
;; might be:
;;
;;    ("FSF" "http://www.fsf.org/" "The Free Software Foundation")
;;
;; Given the above, your quickurl file might look like:
;;
;; (("GNU"    . "http://www.gnu.org/")
;;  ("FSF"      "http://www.fsf.org/" "The Free Software Foundation")
;;  ("emacs"  . "http://www.emacs.org/")
;;  ("hagbard"  "http://www.hagbard.demon.co.uk" "Hagbard's World"))
;;
;; In case you're wondering about the mixture of cons cells and lists,
;; quickurl started life using just the cons cells, there were no comments.
;; URL comments are a later addition and so there is a mixture to keep
;; backward compatibility with existing URL lists.
;;
;; The name and location of the file is up to you, the default name used by
;; `quickurl' is stored in `quickurl-url-file'.
;;
;; quickurl is always available from:
;;
;;   <URL:http://www.hagbard.demon.co.uk/archives/quickurl.el>
;;   <URL:http://www.acemake.com/hagbard/archives/quickurl.el>

;;; TODO:
;;
;; o The quickurl-browse-url* functions pretty much duplicate their non
;;   browsing friends. It would feel better if a more generic solution could
;;   be found.

;;; Code:

;; Things we need:

(eval-when-compile
  (require 'cl))
(require 'thingatpt)
(require 'pp)
(require 'browse-url)

;; Attempt to handle older/other emacs.
(eval-and-compile
  ;; If customize isn't available just use defvar instead.
  (unless (fboundp 'defgroup)
    (defmacro defgroup  (&rest rest) nil)
    (defmacro defcustom (symbol init docstring &rest rest)
      `(defvar ,symbol ,init ,docstring))))

;; `caddr' is a function in cl and so might not always be available
;; (remembering the general rule that says cl functions should not be used,
;; only cl macros). So, to make use of `caddr' without forcing the load of
;; cl-seq we'll define our own.

(eval-when (load eval)
  (unless (fboundp 'caddr)
    (defun caddr (l)
      "Return the `car' of the `cddr' of L."
      (car (cddr l)))))

;; Customize options.

(defgroup quickurl nil
  "Insert an URL based on text at point in buffer."
  :group  'abbrev
  :prefix "quickurl-")

(defcustom quickurl-url-file "~/.quickurls"
  "*File that contains the URL list."
  :type  'file
  :group 'quickurl)

(defcustom quickurl-format-function (lambda (url) (format "<URL:%s>" url))
  "*Function to format the URL before insertion into the current buffer."
  :type  'function
  :group 'quickurl)

(defcustom quickurl-sort-function (lambda (list)
                                    (sort list
                                          (lambda (x y)
                                            (string<
                                             (downcase (quickurl-url-description x))
                                             (downcase (quickurl-url-description y))))))
  "*Function to sort the URL list."
  :type  'function
  :group 'quickurl)

(defcustom quickurl-grab-lookup-function #'current-word
  "*Function to grab the thing to lookup."
  :type  'function
  :group 'quickurl)

(defcustom quickurl-assoc-function #'assoc-ignore-case
  "*Function to use for alist lookup into `quickurl-urls'."
  :type  'function
  :group 'quickurl)

(defcustom quickurl-prefix ";; -*- lisp -*-\n\n"
  "*Text to write to `quickurl-url-file' before writing the URL list."
  :type  'string
  :group 'quickurl)

(defcustom quickurl-postfix ""
  "*Text to write to `quickurl-url-file' after writing the URL list.

See the constant `quickurl-reread-hook-postfix' for some example text that
could be used here."
  :type  'string
  :group 'quickurl)

(defcustom quickurl-list-mode-hook nil
  "*Hooks for `quickurl-list-mode'."
  :type  'hook
  :group 'quickurl)

;; Constants.

;;;###autoload
(defconst quickurl-reread-hook-postfix
    "
;; Local Variables:
;; eval: (progn (require 'quickurl) (add-hook 'local-write-file-hooks (lambda () (quickurl-read) nil)))
;; End:
"
  "Example `quickurl-postfix' text that adds a local variable to the
`quickurl-url-file' so that if you edit it by hand it will ensure that
`quickurl-urls' is updated with the new URL list.

To make use of this do something like:

  (setq quickurl-postfix quickurl-reread-hook-postfix)

in your ~/.emacs (after loading/requiring quickurl).")

;; Non-customize variables.

(defvar quickurl-urls nil
  "URL alist for use with `quickurl' and `quickurl-ask'.")

(defvar quickurl-list-mode-map nil
  "Local keymap for a `quickurl-list-mode' buffer.")

(defvar quickurl-list-buffer-name "*quickurl-list*"
  "Name for the URL listinig buffer.")

(defvar quickurl-list-last-buffer nil
  "`current-buffer' when `quickurl-list' was called.")

;; Functions for working with an URL entry.

(defun quickurl-url-commented-p (url)
  "Does the URL have a comment?"
  (listp (cdr url)))

(defun quickurl-make-url (keyword url &optional comment)
  "Create an URL from KEYWORD, URL and (optionaly) COMMENT."
  (if (and comment (not (zerop (length comment))))
      (list keyword url comment)
    (cons keyword url)))

(defun quickurl-url-keyword (url)
  "Return the keyword for the URL.

Note that this function is a setfable place."
  (car url))

(defsetf quickurl-url-keyword (url) (store)
  `(setf (car ,url) ,store))

(defun quickurl-url-url (url)
  "Return the actual URL of the URL.

Note that this function is a setfable place."
  (if (quickurl-url-commented-p url)
      (cadr url)
    (cdr url)))

(defsetf quickurl-url-url (url) (store)
  `
  (if (quickurl-url-commented-p ,url)
      (setf (cadr ,url) ,store)
    (setf (cdr ,url) ,store)))

(defun quickurl-url-comment (url)
  "Get the comment from an URL.

If the URL has no comment an empty string is returned. Also note that this
function is a setfable place."
  (if (quickurl-url-commented-p url)
      (caddr url)
    ""))

(defsetf quickurl-url-comment (url) (store)
  `
  (if (quickurl-url-commented-p ,url)
      (if (zerop (length ,store))
          (setf (cdr ,url) (cadr ,url))
        (setf (caddr ,url) ,store))
    (unless (zerop (length ,store))
      (setf (cdr ,url) (list (cdr ,url) ,store)))))

(defun quickurl-url-description (url)
  "Return a description for the URL.

If the URL has a comment then this is returned, otherwise the keyword is
returned."
  (let ((desc (quickurl-url-comment url)))
    (if (zerop (length desc))
        (quickurl-url-keyword url)
      desc)))

;; Main code:

(defun* quickurl-read (&optional (buffer (current-buffer)))
  "`read' the URL list from BUFFER into `quickurl-urls'.

Note that this function moves point to `point-min' before doing the `read'
It also restores point after the `read'."
  (save-excursion
    (setf (point) (point-min))
    (setq quickurl-urls (funcall quickurl-sort-function (read buffer)))))
                       
(defun quickurl-load-urls ()
  "Load the contents of `quickurl-url-file' into `quickurl-urls'."
  (when (file-exists-p quickurl-url-file)
    (with-temp-buffer
      (insert-file-contents quickurl-url-file)
      (quickurl-read))))

(defun quickurl-save-urls ()
  "Save the contents of `quickurl-urls' to `quickurl-url-file'."
  (with-temp-buffer
    (let ((standard-output (current-buffer)))
      (princ quickurl-prefix)
      (pp quickurl-urls)
      (princ quickurl-postfix)
      (write-region (point-min) (point-max) quickurl-url-file nil 0))))
  
(defun quickurl-find-url (lookup)
  "Return URL associated with key LOOKUP.

The lookup is done by looking in the alist `quickurl-urls' and the `cons'
for the URL is returned. The actual method used to look into the alist
depends on the setting of the variable `quickurl-assoc-function'."
  (funcall quickurl-assoc-function lookup quickurl-urls))

(defun quickurl-insert (url &optional silent)
  "Insert URL, formatted using `quickurl-format-function'.

Also display a `message' saying what the URL was unless SILENT is non-nil."
  (insert (funcall quickurl-format-function (quickurl-url-url url)))
  (unless silent
    (message "Found %s" (quickurl-url-url url))))

;;;###autoload
(defun* quickurl (&optional (lookup (funcall quickurl-grab-lookup-function)))
  "Insert an URL based on LOOKUP.

If not supplied LOOKUP is taken to be the word at point in the current
buffer, this default action can be modifed via
`quickurl-grab-lookup-function'."
  (interactive)
  (when lookup
    (quickurl-load-urls)
    (let ((url (quickurl-find-url lookup)))
      (if (null url)
          (error "No URL associated with \"%s\"" lookup)
        (when (looking-at "\\w")
          (skip-syntax-forward "\\w"))
        (insert " ")
        (quickurl-insert url)))))

;;;###autoload
(defun quickurl-ask (lookup)
  "Insert an URL, with `completing-read' prompt, based on LOOKUP."
  (interactive
   (list
    (progn
      (quickurl-load-urls)
      (completing-read "Lookup: " quickurl-urls nil t))))
  (let ((url (quickurl-find-url lookup)))
    (when url
      (quickurl-insert url))))
   
(defun quickurl-grab-url ()
  "Attempt to grab a word/url pair from point in the current buffer.

Point should be somewhere on the URL and the word is taken to be the thing
that is returned from calling `quickurl-grab-lookup-function' once a
`backward-word' has been issued at the start of the URL.

It is assumed that the URL is either \"unguarded\" or is wrapped inside an
<URL:...> wrapper."
  (let ((url (thing-at-point 'url)))
    (when url
      (save-excursion
        (beginning-of-thing 'url)
        ;; `beginning-of-thing' doesn't take you to the start of a marked-up
        ;; URL, only to the start of the URL within the "markup". So, we
        ;; need to do a little more work to get to where we want to be.
        (when (thing-at-point-looking-at thing-at-point-markedup-url-regexp)
          (search-backward "<URL:"))
        (backward-word 1)
        (let ((word (funcall quickurl-grab-lookup-function)))
          (when word
            (quickurl-make-url
             ;; The grab function may return the word with properties. I don't
             ;; want the properties. I couldn't find a method of stripping
             ;; them from a "string" so this will have to do. If you know of
             ;; a better method of doing this I'd love to know.
             (with-temp-buffer
               (insert word)
               (buffer-substring-no-properties (point-min) (point-max)))
             url)))))))

;;;###autoload
(defun quickurl-add-url (word url comment)
  "Allow the user to interactively add a new URL associated with WORD.

See `quickurl-grab-url' for details on how the default word/url combination
is decided."
  (interactive (let ((word-url (quickurl-grab-url)))
                 (list (read-string "Word: "    (quickurl-url-keyword word-url))
                       (read-string "URL: "     (quickurl-url-url word-url))
                       (read-string "Comment: " (quickurl-url-comment word-url)))))
  (if (zerop (length word))
      (error "You must specify a WORD for lookup")  
    (quickurl-load-urls)
    (let* ((current-url (quickurl-find-url word))
           (add-it      (if current-url
                            (if (interactive-p)
                                (y-or-n-p (format "\"%s\" exists, replace URL? " word))
                              t)
                          t)))
      (when add-it
        (if current-url
            (progn
              (setf (quickurl-url-url current-url) url)
              (setf (quickurl-url-comment current-url) comment))
          (push (quickurl-make-url word url comment) quickurl-urls))
        (setq quickurl-urls (funcall quickurl-sort-function quickurl-urls))
        (quickurl-save-urls)
        (when (get-buffer quickurl-list-buffer-name)
          (quickurl-list-populate-buffer))
        (when (interactive-p)
          (message "Added %s" url))))))

;;;###autoload
(defun* quickurl-browse-url (&optional (lookup (funcall quickurl-grab-lookup-function)))
  "Browse the URL associated with LOOKUP.

If not supplied LOOKUP is taken to be the word at point in the
current buffer, this default action can be modifed via
`quickurl-grab-lookup-function'."
  (interactive)
  (when lookup
    (quickurl-load-urls)
    (let ((url (quickurl-find-url lookup)))
      (if url
          (browse-url (quickurl-url-url url))
        (error "No URL associated with \"%s\"" lookup)))))

;;;###autoload
(defun quickurl-browse-url-ask (lookup)
  "Browse the URL, with `completing-read' prompt, associated with LOOKUP."
  (interactive (list
                (progn
                  (quickurl-load-urls)
                  (completing-read "Browse: " quickurl-urls nil t))))
  (let ((url (quickurl-find-url lookup)))
    (when url
      (browse-url (quickurl-url-url url)))))

;;;###autoload
(defun quickurl-edit-urls ()
  "Pull `quickurl-url-file' into a buffer for hand editing."
  (interactive)
  (find-file quickurl-url-file))

;; quickurl-list mode.

(unless quickurl-list-mode-map
  (let ((map (make-sparse-keymap)))
    (suppress-keymap map t)
    (define-key map "a"           #'quickurl-list-add-url)
    (define-key map [(control m)] #'quickurl-list-insert-url)
    (define-key map "u"           #'quickurl-list-insert-naked-url)
    (define-key map " "           #'quickurl-list-insert-with-lookup)
    (define-key map "l"           #'quickurl-list-insert-lookup)
    (define-key map "d"           #'quickurl-list-insert-with-desc)
    (define-key map [(control g)] #'quickurl-list-quit)
    (define-key map "q"           #'quickurl-list-quit)
    (define-key map [mouse-2]     #'quickurl-list-mouse-select)
    (define-key map "?"           #'describe-mode)
    (setq quickurl-list-mode-map map)))

(put 'quickurl-list-mode 'mode-class 'special)

;;;###autoload
(defun quickurl-list-mode ()
  "A mode for browsing the quickurl URL list.

The key bindings for `quickurl-list-mode' are:

\\{quickurl-list-mode-map}"
  (interactive)
  (kill-all-local-variables)
  (use-local-map quickurl-list-mode-map)
  (setq major-mode 'quickurl-list-mode
        mode-name  "quickurl list")
  (run-hooks 'quickurl-list-mode-hook)
  (setq buffer-read-only t
        truncate-lines   t))

;;;###autoload
(defun quickurl-list ()
  "Display `quickurl-list' as a formatted list using `quickurl-list-mode'."
  (interactive)
  (quickurl-load-urls)
  (unless (string= (buffer-name) quickurl-list-buffer-name)
    (setq quickurl-list-last-buffer (current-buffer)))
  (pop-to-buffer quickurl-list-buffer-name)
  (quickurl-list-populate-buffer)
  (quickurl-list-mode))

(defun quickurl-list-populate-buffer ()
  "Populate the `quickurl-list' buffer."
  (with-current-buffer (get-buffer quickurl-list-buffer-name)
    (let ((buffer-read-only nil)
          (fmt (format "%%-%ds %%s\n"
                       (apply #'max (or (loop for url in quickurl-urls
                                              collect (length (quickurl-url-description url)))
                                        (list 20))))))
      (setf (buffer-string) "")
      (loop for url in quickurl-urls
            do (let ((start (point)))
                 (insert (format fmt (quickurl-url-description url)
                                 (quickurl-url-url url)))
                 (put-text-property start (1- (point))
                                    'mouse-face 'highlight)))
      (setf (point) (point-min)))))

(defun quickurl-list-add-url (word url comment)
  "Wrapper for `quickurl-add-url' that doesn't guess the parameters."
  (interactive "sWord: \nsURL: \nsComment: ")
  (quickurl-add-url word url comment))

(defun quickurl-list-quit ()
  "Kill the buffer named `quickurl-list-buffer-name'."
  (interactive)
  (kill-buffer quickurl-list-buffer-name)
  (switch-to-buffer quickurl-list-last-buffer)
  (delete-other-windows))

(defun quickurl-list-mouse-select (event)
  "Select the URL under the mouse click."
  (interactive "e")
  (setf (point) (posn-point (event-end event)))
  (quickurl-list-insert-url))

(defun quickurl-list-focused-line ()
  "Work out the line containing point."
  (save-excursion
    (beginning-of-line)
    (let ((point (point)))
      (setf (point) (point-min))
      (loop while (< (point) point) sum 1 do (next-line 1)))))

(defun quickurl-list-insert (type)
  "Insert the URL under cursor into `quickurl-list-last-buffer'.
TYPE dictates what will be inserted, options are:
  `url'         - Insert the URL as <URL:url>
  `naked-url'   - Insert the URL with no formatting
  `with-lookup' - Insert \"lookup <URL:url>\"
  `with-desc'   - Insert \"description <URL:url>\"
  `lookup'      - Insert the lookup for that URL"
  (let ((url (nth (quickurl-list-focused-line) quickurl-urls)))
    (if url
        (with-current-buffer quickurl-list-last-buffer
          (insert
           (case type
             ('url         (format "<URL:%s>" (quickurl-url-url url)))
             ('naked-url   (quickurl-url-url url))
             ('with-lookup (format "%s <URL:%s>"
                                   (quickurl-url-keyword url)
                                   (quickurl-url-url url)))
             ('with-desc   (format "%S <URL:%s>"
                                   (quickurl-url-description url)
                                   (quickurl-url-url url)))
             ('lookup      (quickurl-url-keyword url)))))
      (error "No URL details on that line"))
    url))

(defmacro quickurl-list-make-inserter (type)
  "Macro to make a key-response function for use in `quickurl-list-mode-map'."
  `(defun ,(intern (format "quickurl-list-insert-%S" type)) ()
    ,(format "Insert the result of calling `quickurl-list-insert' with `%s'." type)
    (interactive)
    (when (quickurl-list-insert ',type)
      (quickurl-list-quit))))

(quickurl-list-make-inserter url)
(quickurl-list-make-inserter naked-url)
(quickurl-list-make-inserter with-lookup)
(quickurl-list-make-inserter with-desc)
(quickurl-list-make-inserter lookup)
  
(provide 'quickurl)

;;; quickurl.el ends here
