;;; cucumber-goto-step.el --- Jump to cucumber step definition
;; Copyright (C) 2013 Glen Stampoultzis <gstamp@gmail.com>

;;; Author: Glen Stampoultzis <gstamp@gmail.com>
;;; Homepage: http://orthogonal.me
;;; Version: 0.0.1
;;; Package-Requires: ((pcre2el "1.5"))
;;; URL: https://github.com/gstamp/cucumber-goto-step

;; This file is NOT part of GNU Emacs.
;;
;; Permission is hereby granted, free of charge, to any person obtaining a copy of
;; this software and associated documentation files (the "Software"), to deal in
;; the Software without restriction, including without limitation the rights to
;; use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies
;; of the Software, and to permit persons to whom the Software is furnished to do
;; so, subject to the following conditions:
;;
;; The above copyright notice and this permission notice shall be included in all
;; copies or substantial portions of the Software.
;;
;; THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
;; IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
;; FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
;; AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
;; LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
;; OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
;; SOFTWARE.

;;; Commentary:
;;
;; cucumber-goto-step.el is a simple helper package that navigates
;; from a step in a feature file to the step definition.  While this
;; functionality exists in cucumber.el is requires external tools.
;; This package allows the user to go directly to the step definition
;; without the use of any external tools.  It does this by finding the
;; project root then searching "/features/**/*_steps.rb" for
;; potentially matching candidates.  It relies on pcre2el to convert
;; perl style regular expressions to Emacs regular expressions.
;;
;; The easiest way to install cucumber-goto-step.el is to use a package
;; manager.  To install it manually simply add it to your load path
;; then require it.
;;
;;     (add-to-list 'load-path "/path/to/ack-and-a-half")
;;     (require 'ack-and-a-half)
;;
;; Once installed cucumber-goto-step can be invoked using:
;;
;;     M-x jump-to-cucumber-step
;;
;; There are a few variables you may wish to customize depending on
;; your environment.  To do this enter:
;;
;;     M-x customize-group cucumber-goto-step
;;
;; These variables include:
;; - cgs-root-markers: a list of files/directories that are found
;;   at the root of your project.
;; - cgs-step-search-path: a file global that cucumber-goto-step
;;   will search for step files.  This defaults to "/features/**/*_steps.rb".
;; - cgs-find-project-functions: a list of functions used to locate the
;;   project root.  A default function is provided however you may
;;   optionally override this is you have any special requirements.
;;

;;; Code:
(require 'pcre2el)
(require 'xref)

(defgroup cucumber-goto-step nil
  "Automatically find an open the cucumber step on the current line."
  :tag "cucumber"
  :group 'tools)

(defvar *cgs-default-root-markers* '(".git" ".svn" ".hg" ".bzr")
  "A list of files/directories to look for that mark a project root.")

(defcustom cgs-root-markers *cgs-default-root-markers*
  "A list of files or directories that are found at the root of a project."
  :type    '(repeat string)
  :group   'cucumber-goto-step)

(defcustom cgs-visit-in-read-only nil
  "If non-nil then visit the file with the step definition in read only."
  :type 'boolean
  :group 'cucumber-goto-step)

(defcustom cgs-regexp-anchor-left "(/\\^"
  "Regexp matching the beginning of a step definition (right after the Gherkin word).
For instance, in this step definition
Given(/^I do something$)
we would match the string `(/^'."
  :type 'string
  :group 'cucumber-goto-step)

(defcustom cgs-regexp-anchor-right "\\$/)"
  "Regexp matching the end of a step definition.
For instance, in this step definition
Given(/^I do something$/)
we would match the string `$/)'."
  :type 'string
  :group 'cucumber-goto-step)

(defvar-local cgs-cache-def-positions nil
  "File lines of previously visited definitions.
It is a list of elements (STEP (FULLNAME LINE)).")

(defcustom cgs-gherkin-keywords '(And When Then Given)
  "List of supported Gherkin keywords."
  :type 'string
  :group 'cucumber-goto-step)

(defcustom cgs-step-search-path "/features/**/*_steps.rb"
  "The file glob that is used to search for cucumber steps.  Defaults to /features/**/*_steps.rb."
  :type 'string
  :group 'cucumber-goto-step)

(defcustom cgs-find-project-functions '(cgs-root)
  "Set to a function to find the top level project directory."
  :type '(repeat function)
  :group 'cucumber-goto-step)

(defun cgs-next-line-pos ()
  (forward-line)
  (point))

(defun cgs-match (text step)
  (ignore-errors
    (let* ((elisp-text (rxt-pcre-to-elisp text))
           (match ))
      (string-match elisp-text step))))

(defun cgs-loop-through-file (step pos)
  (let* ((match      (cgs-find-step pos))
         (text       (car match))
         (step-pos   (cdr match))
         (found-line nil))
    (while (and step-pos
                (> step-pos pos)
                (not found-line))

      (let* ((match (cgs-match text step)))
        (goto-char step-pos)
        (if (and match (>= match 0))
            (setq found-line (line-number-at-pos))
          (progn
            (setq match (cgs-find-step (cgs-next-line-pos)))
            (setq text (car match))
            (setq step-pos (cdr match))))))
    found-line))

(defun cgs-match-in-file (file-path step)
  (with-temp-buffer
    (insert-file-contents file-path)
    (cgs-loop-through-file step 1)))

(defun cgs-find-step (from)
  (condition-case ex
      (progn
        (goto-char from)
        (let* ((gherkin-regexp (format "\\(%s\\)%s"
                                       (substring (mapconcat #'identity (mapcar (lambda (sym) (concat (symbol-name sym) "\\|")) cgs-gherkin-keywords) "") 0 -2)
                                       cgs-regexp-anchor-left))
               (end   (progn
                        (re-search-forward
                         (format "%s.+/.*" gherkin-regexp cgs-regexp-anchor-right)
                         (point-max))
                        (re-search-backward cgs-regexp-anchor-right))) ; drop anchor
               (start (progn
                        (re-search-backward cgs-regexp-anchor-left)
                        (re-search-forward cgs-regexp-anchor-left))) ; drop anchor
               (match (buffer-substring-no-properties start end))
               (match (replace-regexp-in-string "\\\\" "\\" match nil 't nil)))
          (cons match start)))
    ('error nil)))

(defun cgs-chomp (str)
  "Chomp leading and tailing whitespace from STR."
  (while (string-match "\\`\n+\\|^\\s-+\\|\\s-+$\\|\n+\\'"
                       str)
    (setq str (replace-match "" t t str)))
  str)

(defun cgs-root ()
  "Locate the root of the project by walking up the directory tree.
The first directory containing one of cgs-root-markers is the root.
If no root marker is found, the current working directory is used."
  (let ((cwd (if (buffer-file-name)
                 (directory-file-name
                  (file-name-directory (buffer-file-name)))
               (file-truename "."))))
    (or (cgs-find-root cwd cgs-root-markers)
        cwd)))

(defun cgs-anyp (pred seq)
  "True if any value in SEQ matches PRED."
  (catch 'found
    (cl-map nil (lambda (v)
                  (when (funcall pred v)
                    (throw 'found v)))
            seq)))

(defun cgs-root-p (path root-markers)
  "Predicate to check if the given directory is a project root."
  (let ((dir (file-name-as-directory path)))
    (cgs-anyp (lambda (marker)
                  (file-exists-p (concat dir marker)))
                root-markers)))

(defun cgs-find-root (path root-markers)
  "Tail-recursive part of project-root."
  (let* ((this-dir (file-name-as-directory (file-truename path)))
         (parent-dir (expand-file-name (concat this-dir "..")))
         (system-root-dir (expand-file-name "/")))
    (cond
     ((cgs-root-p path root-markers) this-dir)
     ((equal system-root-dir this-dir) nil)
     (t (cgs-find-root parent-dir root-markers)))))

;; TODO: write a backend for xref.  
(defun cgs-visit-definition (file line)
  (xref-push-marker-stack)
  (if cgs-visit-in-read-only
      (find-file-read-only file)
    (find-file file))
  (goto-char (point-min)) (forward-line (1- line))
  (recenter)
  (message "Found step definition"))

;;;###autoload
(defun jump-to-cucumber-step (&optional ignore-cache)
  "Jumps to a step definition.
Interactively with a prefix, ignore the cached values."
  (interactive "P")

  (let ((dir (run-hook-with-args-until-success 'cgs-find-project-functions)))
    (when dir
      (let* ((from      (save-excursion (beginning-of-line) (point)))
             (to        (save-excursion (end-of-line) (point)))
             (line-text (cgs-chomp (buffer-substring-no-properties from to)))
             (regexp (format "^\\(%s\\)" (substring (mapconcat #'identity (mapcar (lambda (sym) (concat (symbol-name sym) " \\|")) cgs-gherkin-keywords) "") 0 -2)))
             (match     (string-match regexp line-text))
             (step-text (cgs-chomp (replace-match "" t t line-text))))
        (when match
          (let ((matched-data
                 (catch '--found-def
                   (dolist-with-progress-reporter (file (file-expand-wildcards (expand-file-name cgs-step-search-path dir))) "Searching step definition..."
                     (when (and (not ignore-cache) (assoc step-text cgs-cache-def-positions))
                       (throw '--found-def (cdr (assoc step-text cgs-cache-def-positions))))
                     (let* ((matched-line (cgs-match-in-file file step-text)))
                       (when matched-line
                         (push (list step-text file matched-line) cgs-cache-def-positions)
                         (throw '--found-def (cdr (assoc step-text cgs-cache-def-positions)))))))))
            (if matched-data
                (apply #'cgs-visit-definition matched-data)
              (user-error "No match found for this step"))))))))

      (provide 'cucumber-goto-step)
;;; cucumber-goto-step.el ends here
