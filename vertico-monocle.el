;;; vertico-monocle.el --- Full-frame Vertico with side-by-side Consult preview -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Nobuyuki Kamimoto

;; Author: kn66
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (vertico "2.8"))
;; Keywords: convenience, minibuffer
;; URL: https://github.com/kn66/vertico-monocle
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
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

;; `vertico-monocle-mode' shows Vertico's `vertico-buffer-mode' candidate
;; window as a single full-frame window ("monocle"), and reveals a second pane
;; only while Consult is previewing a candidate.  It uses ordinary Emacs
;; windows, not child frames.
;;
;; Layout:
;;   - No Consult preview  -> the Vertico candidate window fills the whole frame
;;                            and the window count is minimized to one.
;;   - Consult previewing  -> the frame splits into candidates (one side) and
;;                            preview (the other side).
;;
;; How it works:
;;   `vertico-buffer-mode' renders the candidates in a real window.  This mode
;;   installs a `vertico-buffer-display-action' that makes that window fill the
;;   frame, reusing an existing Vertico window for recursive minibuffers so the
;;   recursion also stays in one window.
;;
;;   Consult previews into the window returned by `consult--original-window'.
;;   This mode advises that function: while a Vertico minibuffer is active it
;;   lazily splits the candidate window and returns the new window, so Consult
;;   draws its preview there.  When preview stops (a `preview' action with a nil
;;   candidate) or the minibuffer exits, that window is deleted and the
;;   candidate window expands back to the full frame.
;;
;;   Because the preview window is created on demand and deleted when unused,
;;   non-preview sessions (plain `M-x', `find-file', ...) never split and the
;;   candidate window stays truly full-frame.
;;
;; Known limitation:
;;   For Consult commands whose preview is deferred behind a key (e.g. some
;;   `consult-ripgrep' setups), the preview window is created at preview setup
;;   time and may briefly show the original buffer until you trigger a preview.
;;   Immediate-preview commands (`consult-line', `consult-buffer',
;;   `consult-imenu', ...) behave as intended.
;;
;; Compatibility:
;;   Do not enable `vertico-buffer-frame-mode' at the same time.  Both advise
;;   Consult's preview path and manage the candidate display; enable only one.

;;; Code:

(require 'vertico)
(require 'vertico-buffer)

(defgroup vertico-monocle nil
  "Full-frame Vertico with a side-by-side Consult preview pane."
  :group 'vertico
  :prefix "vertico-monocle-")

(defcustom vertico-monocle-display-action
  '(vertico-monocle--display-buffer)
  "Display action installed into `vertico-buffer-display-action'.
The default makes the candidate window fill the frame, reusing an existing
Vertico window for recursive minibuffers; the Consult preview window is split
off on demand."
  :type 'sexp)

(defcustom vertico-monocle-side 'auto
  "Side of the candidate window on which the preview window is created.
When set to `auto', create the preview below candidates on portrait frames,
and to the right of candidates otherwise."
  :type '(choice (const auto)
                 (const right) (const left)
                 (const above) (const below)))

(declare-function consult--original-window "consult")
(declare-function consult--with-preview-f "consult")
(defvar consult--buffer-display)
(defvar vertico-monocle-mode)

(defvar vertico-monocle--saved-display-action nil
  "Previous value of `vertico-buffer-display-action'.")

(defvar vertico-monocle--saved-vertico-buffer-mode nil
  "Previous enabled state of `vertico-buffer-mode'.")

(defvar vertico-monocle--saved-state nil
  "Non-nil when `vertico-monocle-mode' has saved Vertico state.")

;; Only one preview window is tracked at a time.  Recursive minibuffers with
;; simultaneous Consult previews are rare and out of scope.
(defvar vertico-monocle--preview-window nil
  "The window currently used to show the Consult preview, or nil.")

;;;; Full-frame display (with recursive-minibuffer reuse)

(defun vertico-monocle--existing-vertico-window ()
  "Return an existing Vertico candidate window on the selected frame, or nil.
A Vertico candidate window is a non-minibuffer window that displays a
minibuffer buffer and carries the `no-delete-other-windows' marker set by
`vertico-buffer--setup'."
  (catch 'found
    (dolist (win (window-list nil 'no-minibuf))
      (when (and (window-live-p win)
                 (window-parameter win 'no-delete-other-windows)
                 (minibufferp (window-buffer win)))
        (throw 'found win)))
    nil))

(defun vertico-monocle--display-buffer (buffer alist)
  "Display BUFFER as a single full-frame Vertico window.
For a recursive minibuffer, reuse the outer Vertico window so the recursion
stays in one window instead of splitting; otherwise fall back to
`display-buffer-full-frame'."
  (let ((vw (vertico-monocle--existing-vertico-window)))
    (if (window-live-p vw)
        (progn
          ;; Drop any preview split from the outer session and make the
          ;; existing Vertico window the only one, then host BUFFER there.
          (let ((ignore-window-parameters t))
            (ignore-errors (delete-other-windows vw)))
          (setq vertico-monocle--preview-window nil)
          (set-window-dedicated-p vw nil)
          (window--display-buffer buffer vw 'reuse alist))
      (display-buffer-full-frame buffer alist))))

;;;; Window helpers

(defun vertico-monocle--candidate-window ()
  "Return the live window currently showing Vertico candidates, or nil."
  (when-let* ((mb (active-minibuffer-window))
              ((window-live-p mb))
              (buf (window-buffer mb))
              ((buffer-live-p buf)))
    (with-current-buffer buf
      (and (bound-and-true-p vertico--candidates-ov)
           (overlayp vertico--candidates-ov)
           (let ((win (overlay-get vertico--candidates-ov 'window)))
             (and (window-live-p win) win))))))

(defun vertico-monocle--preview-side ()
  "Return the effective side for the preview window."
  (if (eq vertico-monocle-side 'auto)
      (if (> (frame-pixel-height) (frame-pixel-width))
          'below
        'right)
    vertico-monocle-side))

(defun vertico-monocle--ensure-preview-window ()
  "Return the preview window, splitting the candidate window if needed."
  (or (and (window-live-p vertico-monocle--preview-window)
           vertico-monocle--preview-window)
      (when-let* ((vw (vertico-monocle--candidate-window)))
        (setq vertico-monocle--preview-window
              (ignore-errors
                (split-window vw nil (vertico-monocle--preview-side)))))))

(defun vertico-monocle--delete-preview-window ()
  "Delete the preview window so the candidate window fills the frame again."
  (when (window-live-p vertico-monocle--preview-window)
    (ignore-errors (delete-window vertico-monocle--preview-window)))
  (setq vertico-monocle--preview-window nil))

;;;; Consult integration

(defun vertico-monocle--consult-same-window-p ()
  "Non-nil when Consult would preview in the original (same) window.
Other-window/-frame/-tab commands (e.g. `consult-buffer-other-window') split a
window themselves, so this mode must not also split; in those cases Consult's
own window becomes the preview pane."
  (or (not (boundp 'consult--buffer-display))
      (null consult--buffer-display)
      (eq consult--buffer-display #'switch-to-buffer)))

(defun vertico-monocle--original-window (orig &rest args)
  "Around advice for `consult--original-window'.
While a Vertico minibuffer is active and Consult would preview in the same
window, return the on-demand preview window so Consult draws its preview into
the split instead of the full-frame candidate window.  For commands that open
their own window (other-window/-frame/-tab) the real original window is
returned so Consult manages the second window itself.  ORIG is the original
function and ARGS its arguments."
  (or (and vertico-monocle-mode
           (active-minibuffer-window)
           (vertico-monocle--consult-same-window-p)
           (vertico-monocle--candidate-window)
           (vertico-monocle--ensure-preview-window))
      (apply orig args)))

(defun vertico-monocle--wrap-state (state)
  "Wrap a Consult preview STATE function to manage the preview window."
  (lambda (action cand)
    (prog1 (funcall state action cand)
      (pcase action
        ('preview (unless cand
                    (vertico-monocle--delete-preview-window)))
        ('exit (vertico-monocle--delete-preview-window))))))

(defun vertico-monocle--with-preview-f
    (orig preview-key state transform candidate save-input body)
  "Around advice for `consult--with-preview-f'.
Wrap STATE so the preview window is torn down when preview stops.  ORIG and
the remaining arguments are forwarded unchanged."
  (funcall orig
           preview-key
           (and state (vertico-monocle--wrap-state state))
           transform
           candidate
           save-input
           body))

;;;; Safety net

(defun vertico-monocle--minibuffer-exit ()
  "Forget any stale preview window when a minibuffer exits."
  (setq vertico-monocle--preview-window nil))

;;;; Mode

(defun vertico-monocle--install-consult-advice ()
  "Install advice on Consult's preview entry points."
  (unless (advice-member-p #'vertico-monocle--original-window
                           'consult--original-window)
    (advice-add 'consult--original-window :around
                #'vertico-monocle--original-window))
  (unless (advice-member-p #'vertico-monocle--with-preview-f
                           'consult--with-preview-f)
    (advice-add 'consult--with-preview-f :around
                #'vertico-monocle--with-preview-f)))

(defun vertico-monocle--remove-consult-advice ()
  "Remove advice installed on Consult's preview entry points."
  (advice-remove 'consult--original-window
                 #'vertico-monocle--original-window)
  (advice-remove 'consult--with-preview-f
                 #'vertico-monocle--with-preview-f))

(defun vertico-monocle--save-vertico-state ()
  "Save Vertico state before `vertico-monocle-mode' changes it."
  (unless vertico-monocle--saved-state
    (setq vertico-monocle--saved-display-action
          vertico-buffer-display-action
          vertico-monocle--saved-vertico-buffer-mode
          vertico-buffer-mode
          vertico-monocle--saved-state t)))

(defun vertico-monocle--restore-vertico-state ()
  "Restore Vertico state saved by `vertico-monocle-mode'."
  (when vertico-monocle--saved-state
    (setq vertico-buffer-display-action
          vertico-monocle--saved-display-action)
    (unless vertico-monocle--saved-vertico-buffer-mode
      (vertico-buffer-mode -1))
    (setq vertico-monocle--saved-display-action nil
          vertico-monocle--saved-vertico-buffer-mode nil
          vertico-monocle--saved-state nil)))

;;;###autoload
(define-minor-mode vertico-monocle-mode
  "Show Vertico full-frame, splitting only for a Consult preview.
With no active Consult preview the candidate window fills the frame and the
window count is minimized to one; while a candidate is previewed the frame
splits into candidates and preview."
  :global t
  :group 'vertico-monocle
  (if vertico-monocle-mode
      (progn
        (vertico-monocle--save-vertico-state)
        (setq vertico-buffer-display-action
              vertico-monocle-display-action)
        (vertico-buffer-mode 1)
        (add-hook 'minibuffer-exit-hook
                  #'vertico-monocle--minibuffer-exit)
        (vertico-monocle--install-consult-advice))
    (remove-hook 'minibuffer-exit-hook
                 #'vertico-monocle--minibuffer-exit)
    (vertico-monocle--remove-consult-advice)
    (vertico-monocle--delete-preview-window)
    (vertico-monocle--restore-vertico-state)))

(provide 'vertico-monocle)
;;; vertico-monocle.el ends here
