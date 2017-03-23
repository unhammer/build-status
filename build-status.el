;;; build-status.el --- Mode line build status indicator -*- lexical-binding: t; -*-

;; Copyright (C) 2017 Skye Shaw
;; Author: Skye Shaw <skye.shaw@gmail.com>
;; Version: 0.0.1
;; Keywords: mode-line, ci, circleci, travis-ci
;; Package-Requires: ((cl-lib "0.5"))
;; URL: http://github.com/sshaw/build-status

;; This file is NOT part of GNU Emacs.

;;; License:

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; Global minor mode that shows a buffer's build status in the mode line.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'url)

(defvar build-status-check-interval 300
  "Interval at which to check the build status.  Given in seconds, defaults to 300.")

(defvar build-status-circle-ci-token nil
  "CircleCI API token.
The API token can also be sit via: `git config --add build-status.api-token`.")

(defvar build-status-travis-ci-token nil
  "Travis CI API token.
The API token can also be sit via: `git config --add build-status.api-token`.")

(defvar build-status-circle-ci-status-mapping-alist
  '(("infrastructure_fail" . "failed")
    ("not_running" . "queued")
    ("success" . "passed")
    ("scheduled" . "queued")
    ("timedout" . "failed"))
  "Alist of CircleCI status to build-status statuses.
build-status statuses are: failed, passed, queued, running.
When set to the symbol `ignored' the status will be ignored")

(defvar build-status-travis-ci-status-mapping-alist
  '(("errored" . "failed")
    ("started" . "running")
    ("created" . "queued"))
  "Alist of TravsCI status to build-status statuses.
build-status statuses are: failed, passed, queued, running.
When set to the symbol `ignored' the status will be ignored")

(defvar build-status--project-status-alist '()
  "Alist of project roots and their build status.")

(defvar build-status--timer nil)
(defvar build-status--remote-regex
  "\\(github\\|bitbucket\\).com\\(?:/\\|:[0-9]*/?\\)\\([^/]+\\)/\\([^/]+?\\)\\(?:\\.git\\)?$")

(defvar build-status--mode-line-map (make-sparse-keymap))
(define-key build-status--mode-line-map [mode-line mouse-1] 'build-status-open)

(defgroup build-status nil
  "Mode line build status indicator"
  :group 'programming)

(defface build-status-face
  '((t . (:inherit 'mode-line)))
  "Faces for build status indicators"
  :group 'build-status)

(defface build-status-failed-face
  '((t . (:inherit 'build-status-face :background "red")))
  "Face for failed build indicator"
  :group 'build-status)

(defface build-status-passed-face
  '((t . (:inherit 'build-status-face :background "green")))
  "Face for passed build indicator"
  :group 'build-status)

(defface build-status-queued-face
  '((t . (:inherit 'build-status-face :background "yellow")))
  "Face for queued build indicator"
  :group 'build-status)

(defface build-status-running-face
  '((t . (:inherit 'build-status-face :background "yellow")))
  "Face for running build indicator"
  :group 'build-status)

(defface build-status-unknown-face
  '((t . (:inherit 'build-status-face)))
  "Face for unknown build status indicator"
  :group 'build-status)

(defun build-status--git(&rest args)
  (car (apply 'process-lines `("git" ,@(when args args)))))

(defun build-status--config (path setting)
  ;; Non-zero exit if config doesn't exist, ignore it.
  (ignore-errors (build-status--git "-C" path "config" "--get" setting)))

(defun build-status--remote (path branch)
  (let* ((get-remote (lambda (path branch)
                       (build-status--config path (format "branch.%s.remote" branch))))
         (remote (funcall get-remote path branch)))

    ;; From git-link.
    ;;
    ;; Git defaults to "." if the branch has no remote.
    ;; If the branch has no remote we try master's, which may be set.
    ;; Otherwise, we default to origin.
    (if (or (null remote)
            (and (string= remote ".")
                 (not (string= branch "master"))))
        (setq remote (funcall get-remote path "master")))

    (when (or (null remote)
              (string= remote "."))
      (setq remote "origin"))

    (build-status--config path (format "remote.%s.url" remote))))

(defun build-status--branch (path)
  (build-status--git "-C" path "symbolic-ref" "--short" "HEAD"))

(defun build-status--project-root (path looking-for)
  (when path
    (setq path (file-name-as-directory path))
    (if (file-exists-p (concat path looking-for))
        path
      ;; Make sure we're not at the root directory
      (when (not (string= path (directory-file-name path)))
        (build-status--project-root (file-name-directory (directory-file-name path))
                                    looking-for)))))

(defun build-status--any-open-buffers (root buffers)
  (stringp (cl-find root
                    buffers
                    :test (lambda (start-with buffer)
                            (eq t
                                ;; prefer compare-string as it's not strict with bounds like substring
                                (compare-strings start-with 0 (length start-with)
                                                 buffer 0 (length start-with)))))))

(defun build-status--project (filename)
  "Return a list containing information on `FILENAME''s CI project.
The list contains:
CI service, api token, project root directory, VCS service, username, project, branch.

If `FILENAME' is not part of a CI project return nil."
  (let (branch project remote root token)
    (cond
     ((setq root (build-status--circle-ci-project-root filename))
      (setq project 'circle-ci)
      (setq token build-status-circle-ci-token))
     ((setq root (build-status--travis-ci-project-root filename))
      (setq project 'travis-ci)
      (setq token build-status-travis-ci-token)))

    (when root
      (setq branch (build-status--branch root))
      (setq remote (build-status--remote root branch))
      (when (and remote (string-match build-status--remote-regex remote))
        (list project
              (or (build-status--config root "build-status.api-token") token)
              root
              (match-string 1 remote)
              (match-string 2 remote)
              (match-string 3 remote)
              branch)))))

(defun build-status--circle-ci-project-root (path)
  (build-status--project-root path "circle.yml"))

(defun build-status--travis-ci-project-root (path)
  (build-status--project-root path ".travis.yml"))

(defun build-status--circle-ci-url (project)
  (let ((root (if (string= "github" (nth 3 project)) "gh" "bb")))
    (format "https://circleci.com/%s/%s/%s/tree/%s"
            root
            (nth 4 project)
            (nth 5 project)
            (nth 6 project))))

(defun build-status--travis-ci-url (project success error)
  (build-status--travis-ci-branch-request
   project
   (lambda (json)
     (let ((build (cdr (assq 'id (assq 'branch json)))))
       (funcall success
                (format "https://travis-ci.org/%s/%s/builds/%s"
                        (nth 4 project)
                        (nth 5 project)
                        build))))
   error))

(defun build-status--http-request (url success error)
  "Make an HTTP request to `URL', parse the JSON response.
Call `SUCCESS' with the parsed response on success; call `ERROR'
with an error message and the status plist of `url-retrieve' if
the response does not contain an HTTP 200 status code."
  (condition-case e
      (url-retrieve
       url
       (lambda (status)
         ;; (message "%s\n%s" url (buffer-substring-no-properties 1 (point-max)))
         (goto-char (point-min))
         (if (and (search-forward-regexp "HTTP/1\\.[01] \\([0-9]\\{3\\}\\)")
                  (not (string= (match-string 1) "200")))
             (funcall error
                      (format "got HTTP status %s on retrieving %s" (match-string 1) url)
                      status)
           (search-forward-regexp "\n\n")
           (funcall success
                    (json-read)))))
    (error (funcall error
                    (format "got %s on retrieving %s" e url)
                    nil))))

(defun build-status--circle-ci-branch-request (project success error)
  "Get the Circle CI build status of `PROJECT'.
`SUCCESS' and `ERROR' passed on to `build-status--http-request'."
  (let* ((url (apply 'format "https://circleci.com/api/v1.1/project/%s/%s/%s/tree/%s?limit=1"
                     `(,@(cdddr project))))
         (url-request-method "GET")
         (url-request-extra-headers '(("Accept" . "application/json")))
         (token (nth 1 project)))

    (when token
      (setq url (format "%s&circle-token=%s" url token)))
    (build-status--http-request url success error)))

(defun build-status--circle-ci-handle (json)
  "Handle the Circle CI JSON respons."
  (let (status)

    ;; When branch is not found a 200 is returned but the array is empty
    (when (> (length json) 0)
      (setq status (or (cdr (assq 'outcome (elt json 0)))
                       (cdr (assq 'status (elt json 0)))))

      (or (cdr (assoc status build-status-circle-ci-status-mapping-alist))
          status))))

(defun build-status--travis-ci-request (url success error &optional token)
  "Generic Travis CI request to `URL'.
`SUCCESS' and `ERROR' passed on to `build-status--http-request'.
Uses `TOKEN' for authorization, if given."
  (let ((url-request-method "GET")
        (url-request-extra-headers '(("Accept" . "application/vnd.travis-ci.2+json"))))

    (when token
      (push (cons "Authorization" (format "token %s" token)) url-request-extra-headers))

    (build-status--http-request url success error)))

(defun build-status--travis-ci-branch-request (project success error)
  "Get the Travis CI build status of `PROJECT'.
`SUCCESS' and `ERROR' passed on to `build-status--http-request'."
  (let ((url (format "https://api.travis-ci.org/repos/%s/%s/branches/%s"
                     (nth 4 project)
                     (nth 5 project)
                     (nth 6 project)))
        (token (nth 1 project)))

    (build-status--travis-ci-request url success error token)))

(defun build-status--travis-ci-handle (json)
  "Handle the Travis CI JSON respons."
  (let ((status (cdr (assq 'state (assq 'branch json)))))
    (or (cdr (assoc status build-status-travis-ci-status-mapping-alist))
        status)))

(defun build-status--update-status ()
  "Update build status of all projects in `build-status--project-status-alist'."
  (let ((buffers (delq nil (mapcar 'buffer-file-name (buffer-list))))
        config
        project)

    (dolist (root (mapcar 'car build-status--project-status-alist))
      (setq config (assoc root build-status--project-status-alist))
      (setq project (build-status--project root))
      (if (and project (build-status--any-open-buffers root buffers))
          (let* ((handle-json (if (eq (car project) 'circle-ci)
                                  #'build-status--circle-ci-handle
                                #'build-status--travis-ci-handle))
                 (make-request (if (eq (car project) 'circle-ci)
                                   #'build-status--circle-ci-branch-request
                                 #'build-status--travis-ci-branch-request))
                 (handle-response (lambda (json)
                                    (let ((status (funcall handle-json json)))
                                      ;; Don't show queued state unless we have no prior state
                                      ;; Option to control this behavior?
                                      (when (and (not (eq status 'ignore))
                                                 (or (not (string= status "queued"))
                                                     (null (cdr config))))
                                        (setcdr config status)
                                        (force-mode-line-update t)))))
                 (handle-error (lambda (msg _url-status)
                                 (message "Failed to update status for %s: %s" root msg))))
            (funcall make-request project handle-response handle-error))
        (setq build-status--project-status-alist
              (delete config build-status--project-status-alist))))
  (setq build-status--timer
        (run-at-time build-status-check-interval nil 'build-status--update-status))))

(defun build-status--select-face (status)
  (let ((face (intern (format "build-status-%s-face"
                              (replace-regexp-in-string "[[:space:]]+" "-" status)))))
    (when (not (facep face))
      (setq face 'build-status-unknown-face))
    face))

(defun build-status--propertize (lighter status)
  (let ((face (build-status--select-face status)))
    (propertize (if (face-differs-from-default-p face) (concat " " lighter " ") lighter)
                'help-echo (concat "Build " status)
                'local-map build-status--mode-line-map
                'mouse-face 'mode-line-highlight
                'face face)))

(defun build-status--turn-on-when-global (root)
  (when (and root
             global-build-status-mode
             (not (build-status--activate-mode)))
    (build-status-mode 1)))

(defvar build-status-mode-line-string
  '(:eval
    (let ((root (or (build-status--circle-ci-project-root (buffer-file-name))
                    (build-status--travis-ci-project-root (buffer-file-name)))))
      (build-status--turn-on-when-global root)
      (let ((status (cdr (assoc root build-status--project-status-alist))))
        (if (null status)
            ""
          (concat " "
                  (cond
                   ((string= status "passed")
                    (build-status--propertize "P" status))
                   ((string= status "running")
                    (build-status--propertize "R" status))
                   ((string= status "failed")
                    (build-status--propertize "F" status))
                   ((string= status "queued")
                    (build-status--propertize "Q" status))
                   (t
                    (build-status--propertize "?" (replace-regexp-in-string "[^a-zA-Z0-9[:space:]]+" " "
                                                                            (or status "unknown"))))))))))
  "Build status mode line string.")
;;;###autoload (put 'build-status-mode-line-string 'risky-local-variable t)

(defun build-status--activate-mode ()
  (let ((root (nth 2 (build-status--project (buffer-file-name)))))
    (not (null (assoc root build-status--project-status-alist)))))

(defun build-status--toggle-mode (enable)
  (let* ((project (build-status--project (buffer-file-name)))
         (root    (nth 2 project)))

    (when (null project)
      (error "Not a CI project"))

    (when build-status--timer
      (cancel-timer build-status--timer))

    (if enable
        (progn
          (add-to-list 'global-mode-string 'build-status-mode-line-string t)
          (add-to-list 'build-status--project-status-alist (cons root nil)))

      (setq build-status--project-status-alist
            (delete (assoc root build-status--project-status-alist)
                    build-status--project-status-alist)))

    ;; Only remove from the mode line if there are no more projects
    (if (null build-status--project-status-alist)
        (delq 'build-status-mode-line-string global-mode-string)
      (build-status--update-status))))

(defun build-status-open ()
  "Open the CI service's web page for current project's branch."
  (interactive)
  (let ((project (build-status--project (buffer-file-name))))
    (when project
      (if (eq 'circle-ci (car project))
          (browse-url (build-status--circle-ci-url project))
        (build-status--travis-ci-url project #'browse-url #'message)))))

;;;###autoload
(define-minor-mode global-build-status-mode
  "Turn on `build-status-mode' everywhere possible."
  :init-value nil
  :global     t
  (if global-build-status-mode
      (add-to-list 'global-mode-string 'build-status-mode-line-string t)
    (delq 'build-status-mode-line-string global-mode-string)
    (cl-dolist (buf (buffer-list))
      (with-current-buffer buf
        (when (build-status--activate-mode)
          (build-status--toggle-mode nil))))))

;;;###autoload
(define-minor-mode build-status-mode
  "Monitor the build status of the buffer's project."
  :global t
  :variable ((build-status--activate-mode) . build-status--toggle-mode))

(provide 'build-status)
;;; build-status.el ends here
