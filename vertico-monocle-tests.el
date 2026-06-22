;;; vertico-monocle-tests.el --- Tests for vertico-monocle -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Nobuyuki Kamimoto

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:

(require 'ert)
(require 'vertico-monocle)

(ert-deftest vertico-monocle-restores-disabled-vertico-buffer-state ()
  "Disabling `vertico-monocle-mode' restores a previously disabled Vertico buffer."
  (let ((original-action '(display-buffer-same-window)))
    (unwind-protect
        (progn
          (vertico-monocle-mode -1)
          (vertico-buffer-mode -1)
          (setq vertico-buffer-display-action original-action)
          (vertico-monocle-mode 1)
          (should vertico-buffer-mode)
          (should (eq vertico-buffer-display-action
                      vertico-monocle-display-action))
          (vertico-monocle-mode -1)
          (should-not vertico-buffer-mode)
          (should (equal vertico-buffer-display-action original-action)))
      (vertico-monocle-mode -1))))

(ert-deftest vertico-monocle-restores-enabled-vertico-buffer-state ()
  "Disabling `vertico-monocle-mode' preserves a previously enabled Vertico buffer."
  (let ((original-action '(display-buffer-pop-up-window)))
    (unwind-protect
        (progn
          (vertico-monocle-mode -1)
          (vertico-buffer-mode 1)
          (setq vertico-buffer-display-action original-action)
          (vertico-monocle-mode 1)
          (should vertico-buffer-mode)
          (should (eq vertico-buffer-display-action
                      vertico-monocle-display-action))
          (vertico-monocle-mode -1)
          (should vertico-buffer-mode)
          (should (equal vertico-buffer-display-action original-action)))
      (vertico-monocle-mode -1)
      (vertico-buffer-mode -1))))

(ert-deftest vertico-monocle-installs-and-removes-consult-advice ()
  "Consult advice is installed once and removed when the mode is disabled."
  (unwind-protect
      (progn
        (vertico-monocle-mode -1)
        (vertico-monocle-mode 1)
        (vertico-monocle-mode 1)
        (should (advice-member-p #'vertico-monocle--original-window
                                 'consult--original-window))
        (should (advice-member-p #'vertico-monocle--with-preview-f
                                 'consult--with-preview-f))
        (vertico-monocle-mode -1)
        (should-not (advice-member-p #'vertico-monocle--original-window
                                     'consult--original-window))
        (should-not (advice-member-p #'vertico-monocle--with-preview-f
                                     'consult--with-preview-f)))
    (vertico-monocle-mode -1)))

(provide 'vertico-monocle-tests)
;;; vertico-monocle-tests.el ends here
