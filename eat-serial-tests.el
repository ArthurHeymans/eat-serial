;;; eat-serial-tests.el --- Tests for eat-serial -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Arthur Heymans

;; Author: Arthur Heymans <arthur@aheymans.xyz>
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'eat-serial-codec)

(declare-function eat-serial "eat-serial")
(declare-function eat-serial--buffer-name "eat-serial")
(declare-function eat-serial--delete-foreign-buffer-processes "eat-serial")
(declare-function eat-serial--live-process-p "eat-serial")
(declare-function eat-serial--open-process "eat-serial")
(declare-function eat-serial-configure "eat-serial")

(defvar eat-serial--bytesize)
(defvar eat-serial--connection-state)
(defvar eat-serial--flowcontrol)
(defvar eat-serial--parity)
(defvar eat-serial--port)
(defvar eat-serial--process)
(defvar eat-serial--speed)
(defvar eat-serial--stopbits)

(defvar eat-serial-tests--eat-serial-available
  (condition-case nil
      (progn
        (require 'eat-serial)
        t)
    (error nil))
  "Non-nil when Eat is available for eat-serial integration tests.")

(defun eat-serial-tests--require-eat-serial ()
  "Skip the current test unless `eat-serial' can be loaded."
  (unless eat-serial-tests--eat-serial-available
    (ert-skip "Eat is not available")))

(defun eat-serial-tests--sleep-process (buffer)
  "Return a long-lived process attached to BUFFER."
  (make-process :name (generate-new-buffer-name "eat-serial-test-process")
                :buffer buffer
                :command '("sh" "-c" "sleep 30")
                :noquery t))

(defun eat-serial-tests--decode-chunks (chunks &optional policy)
  "Decode CHUNKS with optional invalid-byte POLICY."
  (let ((state (eat-serial-codec-make-state policy))
        (pieces nil))
    (dolist (chunk chunks)
      (push (eat-serial-codec-decode state chunk) pieces))
    (push (eat-serial-codec-flush state) pieces)
    (apply #'concat (nreverse pieces))))

(ert-deftest eat-serial-codec-valid-utf-8 ()
  (should (string=
           (eat-serial-tests--decode-chunks
            (list (concat "hello " (unibyte-string #xe2 #x98 #x83) "\n")))
           "hello ☃\n")))

(ert-deftest eat-serial-codec-split-utf-8 ()
  (should (string=
           (eat-serial-tests--decode-chunks
            (list (unibyte-string #xe2)
                  (unibyte-string #x98)
                  (unibyte-string #x83)))
           "☃")))

(ert-deftest eat-serial-codec-malformed-sequence-continues ()
  (should (string=
           (eat-serial-tests--decode-chunks
            (list (unibyte-string #xe2 ?x)))
           "�x")))

(ert-deftest eat-serial-codec-hex-policy ()
  (should (string=
           (eat-serial-tests--decode-chunks
            (list (unibyte-string #xff ?A #x80))
            'hex)
           "<FF>A<80>")))

(ert-deftest eat-serial-codec-latin-1-policy ()
  (should (string=
           (eat-serial-tests--decode-chunks
            (list (unibyte-string #xe9))
            'latin-1)
           "é")))

(ert-deftest eat-serial-codec-nul-is-preserved ()
  (should (string=
           (eat-serial-tests--decode-chunks
            (list (unibyte-string ?a 0 ?b)))
           (string ?a 0 ?b))))

(ert-deftest eat-serial-codec-escape-sequences-can-split ()
  (should (string=
           (eat-serial-tests--decode-chunks
            (list (unibyte-string #x1b ?\[) "31m"))
           "\e[31m")))

(ert-deftest eat-serial-codec-overlong-is-malformed ()
  (should (string=
           (eat-serial-tests--decode-chunks
            (list (unibyte-string #xc0 #xaf)))
           "��"))
  (should (string=
           (eat-serial-tests--decode-chunks
            (list (unibyte-string #xe0 #x80 #x80)))
           "���"))
  (should (string=
           (eat-serial-tests--decode-chunks
            (list (unibyte-string #xf0 #x80 #x80 #x80)))
           "����")))

(ert-deftest eat-serial-codec-invalid-prefix-is-not-buffered ()
  (dolist (chunk (list (unibyte-string #xe0 #x80)
                       (unibyte-string #xed #xa0)
                       (unibyte-string #xf0 #x80)
                       (unibyte-string #xf4 #x90)))
    (let ((state (eat-serial-codec-make-state)))
      (should (string= (eat-serial-codec-decode state chunk) "��"))
      (should (string= (eat-serial-codec-state-pending state) "")))))

(ert-deftest eat-serial-codec-unicode-boundaries ()
  (should (string=
           (eat-serial-tests--decode-chunks
            (list (unibyte-string #xf0 #x90 #x80 #x80)))
           (char-to-string #x10000)))
  (should (string=
           (eat-serial-tests--decode-chunks
            (list (unibyte-string #xf4 #x8f #xbf #xbf)))
           (char-to-string #x10ffff)))
  (should (string=
           (eat-serial-tests--decode-chunks
            (list (unibyte-string #xf4 #x90 #x80 #x80)))
           "����"))
  (should (string=
           (eat-serial-tests--decode-chunks
            (list (unibyte-string #xed #xa0 #x80)))
           "���")))

(ert-deftest eat-serial-codec-random-bytes-do-not-signal ()
  (let ((state (eat-serial-codec-make-state)))
    (dotimes (_ 64)
      (let ((chunk (make-string 32 0)))
        (dotimes (index (length chunk))
          (aset chunk index (random 256)))
        (should (stringp (eat-serial-codec-decode state chunk)))))
    (should (stringp (eat-serial-codec-flush state)))))

(ert-deftest eat-serial-reuses-live-process-and-reconfigures-speed ()
  (eat-serial-tests--require-eat-serial)
  (let* ((port "/tmp/eat-serial-test-port")
         (buffer (get-buffer-create (eat-serial--buffer-name port)))
         (process (eat-serial-tests--sleep-process buffer))
         configured opened)
    (unwind-protect
        (progn
          (with-current-buffer buffer
            (setq eat-serial--port port)
            (setq eat-serial--speed 9600)
            (setq eat-serial--bytesize 8)
            (setq eat-serial--parity nil)
            (setq eat-serial--stopbits 1)
            (setq eat-serial--flowcontrol nil)
            (setq eat-serial--process process))
          (cl-letf (((symbol-function 'eat-serial--setup-buffer)
                     (lambda (setup-port setup-speed)
                       (setq eat-serial--port setup-port)
                       (unless (eat-serial--live-process-p)
                         (setq eat-serial--speed setup-speed))))
                    ((symbol-function 'serial-process-configure)
                     (lambda (&rest args)
                       (setq configured args)))
                    ((symbol-function 'eat-serial--open-process)
                     (lambda ()
                       (setq opened t)))
                    ((symbol-function 'pop-to-buffer-same-window)
                     (lambda (&rest _) nil))
                    ((symbol-function 'eat-serial--resize-terminal-to-window)
                     (lambda (&rest _) nil)))
            (eat-serial port 115200))
          (with-current-buffer buffer
            (should (eq eat-serial--process process))
            (should (equal eat-serial--speed 115200)))
          (should-not opened)
          (should (equal (plist-get configured :process) process))
          (should (equal (plist-get configured :speed) 115200)))
      (when (process-live-p process)
        (delete-process process))
      (kill-buffer buffer))))

(ert-deftest eat-serial-configure-stores-settings-while-disconnected ()
  (eat-serial-tests--require-eat-serial)
  (let (called)
    (with-temp-buffer
      (setq eat-serial--port "/tmp/eat-serial-test-port")
      (setq eat-serial--process nil)
      (cl-letf (((symbol-function 'serial-process-configure)
                 (lambda (&rest _)
                   (setq called t))))
        (eat-serial-configure 57600 7 'even 2 'hw))
      (should-not called)
      (should (equal eat-serial--speed 57600))
      (should (equal eat-serial--bytesize 7))
      (should (eq eat-serial--parity 'even))
      (should (equal eat-serial--stopbits 2))
      (should (eq eat-serial--flowcontrol 'hw)))))

(ert-deftest eat-serial-open-failure-clears-stale-process-state ()
  (eat-serial-tests--require-eat-serial)
  (let* ((buffer (generate-new-buffer " *eat-serial-open-failure*"))
         (process (eat-serial-tests--sleep-process buffer)))
    (unwind-protect
        (with-current-buffer buffer
          (setq eat-serial--port "/tmp/eat-serial-test-port")
          (setq eat-serial--speed 9600)
          (setq eat-serial--process process)
          (setq eat-serial--connection-state 'connected)
          (cl-letf (((symbol-function 'make-serial-process)
                     (lambda (&rest _)
                       (error "open failed"))))
            (should-error (eat-serial--open-process)))
          (should-not eat-serial--process)
          (should (eq eat-serial--connection-state 'disconnected))
          (should-not (process-live-p process)))
      (when (process-live-p process)
        (delete-process process))
      (kill-buffer buffer))))

(ert-deftest eat-serial-delete-foreign-process-suppresses-sentinel ()
  (eat-serial-tests--require-eat-serial)
  (let* ((buffer (generate-new-buffer " *eat-serial-foreign-process*"))
         (process (eat-serial-tests--sleep-process buffer))
         sentinel-called)
    (unwind-protect
        (with-current-buffer buffer
          (setq eat-serial--process nil)
          (set-process-sentinel
           process (lambda (_process _message)
                     (setq sentinel-called t)))
          (eat-serial--delete-foreign-buffer-processes)
          (accept-process-output nil 0.05)
          (should-not sentinel-called)
          (should-not (process-live-p process)))
      (when (process-live-p process)
        (delete-process process))
      (kill-buffer buffer))))

(provide 'eat-serial-tests)

;;; eat-serial-tests.el ends here
