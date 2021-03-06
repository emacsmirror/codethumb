;;; codethumb.el --- Show code thumbnail

;; Copyright (C) 2012 Takafumi Arakaki

;; Author: Takafumi Arakaki <aka.tkf at gmail.com>

;; This file is NOT part of GNU Emacs.

;; codethumb.el is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; codethumb.el is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with codethumb.el.
;; If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;;

;;; Code:

(eval-when-compile (require 'cl))
(require 'epc)


(defgroup codethumb nil
  "Auto-completion for Python."
  :group 'completion
  :prefix "codethumb:")

(defvar codethumb:source-dir (if load-file-name
                            (file-name-directory load-file-name)
                          default-directory))

(defvar codethumb:epc nil)

(defvar codethumb:server-script
  (expand-file-name "codethumbepcserver.py" codethumb:source-dir)
  "Full path to Codethumb server script file ``codethumbepcserver.py``.")

(defvar codethumb:buffer "*codethumb*")


;;; Configuration variables

(defcustom codethumb:server-command
  (list (let ((py (expand-file-name "env/bin/python" codethumb:source-dir)))
          (if (file-exists-p py) py "python"))
        codethumb:server-script)
  "Command used to run Codethumb server.

If you setup Codethumb requirements using ``make requirements`` command,
`codethumb:server-command' should be automatically set to::

    '(\"CODETHUMB:SOURCE-DIR/env/bin/python\"
      \"CODETHUMB:SOURCE-DIR/codethumbepcserver.py\")

Otherwise, it should be set to::

    '(\"python\" \"CODETHUMB:SOURCE-DIR/codethumbepcserver.py\")

If you want to use your favorite Python executable, set
`codethumb:server-command' using::

    (setq codethumb:server-command
          (list \"YOUR-FAVORITE-PYTHON\" codethumb:server-script))

If you want to pass some arguments to the Codethumb server command,
use `codethumb:server-command'."
  :group 'codethumb)

(defcustom codethumb:server-args nil
  "Command line arguments to be appended to `codethumb:server-command'.

If you want to add some special `sys.path' when starting Codethumb
server, do something like this::

    (setq codethumb:server-args
          '(\"--sys-path\" \"MY/SPECIAL/PATH\"
            \"--sys-path\" \"MY/OTHER/SPECIAL/PATH\"))

To see what other arguments Codethumb server can take, execute the
following command::

    python codethumbepcserver.py --help"
  :group 'codethumb)

(defcustom codethumb:modes '(prog-mode)
  "Modes to draw thumbnail."
  :group 'codethumb)

(defcustom codethumb:draw-delay 0.1
  "Seconds to wait before start drawing code thumbnail."
  :group 'codethumb)

(defcustom codethumb:font-name nil
  "Font name.
Run the program ``fc-list`` to see usable font names."
  :group 'codethumb)


;;; Server management

(defun codethumb:start-server ()
  (if codethumb:epc
      (message "Codethumb server is already started!")
    (let ((default-directory codethumb:source-dir))
      (setq codethumb:epc (epc:start-epc (car codethumb:server-command)
                                         (append (cdr codethumb:server-command)
                                                 codethumb:server-args))))
    (set-process-query-on-exit-flag
     (epc:connection-process (epc:manager-connection codethumb:epc)) nil)
    (set-process-query-on-exit-flag
     (epc:manager-server-process codethumb:epc) nil))
  (when codethumb:font-name
    (epc:call-deferred codethumb:epc 'set_font_name
                       (list codethumb:font-name)))
  codethumb:epc)

(defun codethumb:stop-server ()
  "Stop Codethumb server.  Use this command when you want to restart
Codethumb server (e.g., when you changed `codethumb:server-command' or
`codethumb:server-args').  Codethumb srever will be restarted automatically
later when it is needed."
  (interactive)
  (if codethumb:epc
      (epc:stop-epc codethumb:epc)
    (message "Codethumb server is already killed."))
  (setq codethumb:epc nil))

(defun codethumb:get-epc ()
  (or codethumb:epc (codethumb:start-server)))


;;; Main

(defvar codethumb:draw--d nil)

(defun codethumb:draw-1 ()
  (let* ((point-min (point-min))
         (code (buffer-substring-no-properties point-min (point-max)))
         line-min
         line-max
         window)
    (when (and
           ;; drawing job is not running, and
           (not codethumb:draw--d)
           ;; buffer is visible.
           (setq window
                 (get-buffer-window (get-buffer-create codethumb:buffer))))
      (save-excursion
        (move-to-window-line 0)
        (setq line-min (1+ (count-lines point-min (point))))
        (move-to-window-line -1)
        (setq line-max (1+ (count-lines point-min (point)))))
      (setq codethumb:draw--d
            (deferred:try
              (deferred:$
                (epc:call-deferred
                 (codethumb:get-epc) 'make_thumb
                 (let ((height-px
                        (destructuring-bind (left top right bottom)
                            (window-pixel-edges window)
                          (- bottom top))))
                   (list code buffer-file-name line-min line-max
                         height-px)))
                (deferred:nextc it #'base64-decode-string)
                (deferred:nextc it
                  (lambda (data) (create-image data 'png t)))
                (deferred:nextc it
                  (lambda (png)
                    (with-current-buffer (get-buffer-create codethumb:buffer)
                      (let ((window (get-buffer-window (current-buffer))))
                        (when window
                          (erase-buffer)
                          (insert-image png)
                          ;; avoid surrounding image with cursor color
                          (setq cursor-type nil)))))))
              :finally
              (lexical-let ((last-point (point)))
                (lambda ()
                  (setq codethumb:draw--d nil)
                  (unless (= (point) last-point)
                    ;; refresh when the point is moved.
                    (codethumb:draw)))))))))

(defun codethumb:draw ()
  (when (codethumb:draw-p)
    (codethumb:draw-1)))

(defun codethumb:draw-p ()
  "Decide if thumbnail should be drawn for the current buffer."
  (apply #'derived-mode-p codethumb:modes))

;;;###autoload
(defun codethumb:show ()
  (interactive)
  (let ((buffer (get-buffer-create codethumb:buffer)))
    (display-buffer buffer)
    (with-current-buffer buffer
      (erase-buffer)
      (insert "Drawing thumbnail..."))
    (codethumb:start-timer)
    (codethumb:draw)))

(defvar codethumb:idle-timer nil)

;;;###autoload
(defun codethumb:start-timer ()
  (interactive)
  (get-buffer-create codethumb:buffer)
  (unless codethumb:idle-timer
    (setq codethumb:idle-timer
          (run-with-idle-timer codethumb:draw-delay t #'codethumb:draw))))

;;;###autoload
(defun codethumb:stop-timer ()
  (interactive)
  (cancel-timer codethumb:idle-timer)
  (setq codethumb:idle-timer nil))

;;;###autoload
(defun codethumb:stop ()
  (interactive)
  (codethumb:stop-timer)
  (codethumb:stop-server))

(provide 'codethumb)

;;; codethumb.el ends here
