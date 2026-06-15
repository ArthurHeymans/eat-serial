;;; eat-serial.el --- Eat-backed serial terminal -*- lexical-binding: t; -*-

;; Copyright (C) 2026  eat-serial contributors

;; Author: Arthur <arthur@localhost>
;; Keywords: terminals, serial, processes
;; Package-Requires: ((emacs "30.1") (eat "0.9.4"))
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; eat-serial uses Eat's terminal renderer and input modes with an Emacs
;; serial process backend.  Serial input is opened with `no-conversion' and
;; decoded by `eat-serial-codec' so split UTF-8 and malformed bytes do not
;; corrupt the terminal parser.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'format-spec)
(require 'eat)
(require 'eat-serial-codec)

(defgroup eat-serial nil
  "Eat-backed serial terminal."
  :group 'terminals
  :prefix "eat-serial-")

(defcustom eat-serial-default-speed 115200
  "Default serial port speed used by `eat-serial'."
  :type 'integer
  :group 'eat-serial)

(defcustom eat-serial-default-coding-system 'utf-8-unix
  "Coding system used to encode text sent to the serial port."
  :type 'coding-system
  :group 'eat-serial)

(defcustom eat-serial-default-input-mode 'semi-char
  "Eat input mode selected when a new serial terminal is created."
  :type '(choice (const semi-char)
                 (const char)
                 (const line)
                 (const emacs))
  :group 'eat-serial)

(defcustom eat-serial-buffer-name-format "*eat-serial %p*"
  "Format used to create serial terminal buffer names.

The format specifier %p expands to the serial port path."
  :type 'string
  :group 'eat-serial)

(defcustom eat-serial-read-chunk-latency nil
  "Reserved compatibility knob for future serial read latency tuning.

When nil, Eat's normal output queue latency variables are used."
  :type '(choice (const nil) number)
  :group 'eat-serial)

(defcustom eat-serial-break-duration 0
  "Default duration argument passed to `tcsendbreak' by `eat-serial-send-break'.

A value of 0 asks the operating system to use its default break length."
  :type 'integer
  :group 'eat-serial)

(defcustom eat-serial-send-break-function nil
  "Optional function used by `eat-serial-send-break'.

The function is called with PROCESS and DURATION.  When nil,
`eat-serial-send-break' tries a best-effort Python `termios.tcsendbreak'
helper that opens the port path separately."
  :type '(choice (const nil) function)
  :group 'eat-serial)

(defvar-local eat-serial--port nil)
(defvar-local eat-serial--speed nil)
(defvar-local eat-serial--bytesize 8)
(defvar-local eat-serial--parity nil)
(defvar-local eat-serial--stopbits 1)
(defvar-local eat-serial--flowcontrol nil)
(defvar-local eat-serial--process nil)
(defvar-local eat-serial--codec-state nil)
(defvar-local eat-serial--connection-state 'disconnected)
(defvar-local eat-serial--mode-line-process nil)

(defvar eat-serial-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-k") #'eat-serial-disconnect)
    (define-key map (kbd "C-c C-s r") #'eat-serial-reconnect)
    (define-key map (kbd "C-c C-s d") #'eat-serial-disconnect)
    (define-key map (kbd "C-c C-s c") #'eat-serial-configure)
    (define-key map (kbd "C-c C-s b") #'eat-serial-send-break)
    (define-key map (kbd "C-c C-s x") #'eat-serial-send-byte)
    map)
  "Keymap for serial-specific commands in Eat serial buffers.")

(define-minor-mode eat-serial-mode
  "Minor mode for serial-specific Eat terminal commands."
  :lighter " EatSerial"
  :keymap eat-serial-mode-map)

(defun eat-serial--buffer-name (port)
  "Return the buffer name for PORT."
  (format-spec eat-serial-buffer-name-format `((?p . ,port))))

(defun eat-serial--read-port ()
  "Read a serial port path from the minibuffer."
  (read-file-name "Serial port: " "/dev/" nil t))

(defun eat-serial--live-process-p (&optional process)
  "Return non-nil if PROCESS, or the current serial process, is live."
  (let ((proc (or process eat-serial--process)))
    (and (processp proc)
         (memq (process-status proc)
               '(run stop open listen connect)))))

(defun eat-serial--require-process ()
  "Return the current live serial process or signal a user error."
  (unless (eat-serial--live-process-p)
    (user-error "No live eat-serial process in this buffer"))
  eat-serial--process)

(defun eat-serial--mode-line-string ()
  "Return mode-line text for the current serial connection."
  (when eat-serial--port
    (format " [%s %s %s]"
            eat-serial--port
            (or eat-serial--speed "unconfigured")
            eat-serial--connection-state)))

(defun eat-serial--install-mode-line ()
  "Append serial status to Eat's mode line in the current buffer."
  (unless eat-serial--mode-line-process
    (setq eat-serial--mode-line-process mode-line-process)
    (setq mode-line-process
          (append mode-line-process
                  '((:eval (eat-serial--mode-line-string)))))))

(defun eat-serial--set-terminal-parameter-if-bound (parameter function)
  "Set Eat terminal PARAMETER to FUNCTION if FUNCTION is defined."
  (when (and eat-terminal (fboundp function))
    (setf (eat-term-parameter eat-terminal parameter) function)))

(defun eat-serial--set-terminal-process (process)
  "Tell Eat that PROCESS is the process for the current terminal."
  (when eat-terminal
    (setf (eat-term-parameter eat-terminal 'eat--process) process)
    (setf (eat-term-parameter eat-terminal 'eat--input-process) process)
    (setf (eat-term-parameter eat-terminal 'eat--output-process) process)))

(defun eat-serial--buffer-processes (&optional buffer)
  "Return processes whose process buffer is BUFFER.

BUFFER defaults to the current buffer.  Emacs permits more than one
process to target the same buffer; Eat output queues are buffer-local, so
that must not happen for an eat-serial terminal."
  (let ((buffer (or buffer (current-buffer))))
    (cl-remove-if-not
     (lambda (process)
       (eq (process-buffer process) buffer))
     (process-list))))

(defun eat-serial--delete-foreign-buffer-processes ()
  "Delete non-current processes targeting the current buffer."
  (dolist (process (eat-serial--buffer-processes))
    (unless (eq process eat-serial--process)
      (when (process-live-p process)
        (message "eat-serial: deleting foreign process %s in %s"
                 (process-name process) (buffer-name))
        (delete-process process)))))

(defun eat-serial--serial-terminal-p ()
  "Return non-nil if the current Eat terminal belongs to eat-serial."
  (and eat-terminal
       (ignore-errors
         (eat-term-parameter eat-terminal 'eat-serial))))

(defun eat-serial--reset-foreign-terminal ()
  "Stop reusing an Eat terminal object created by another backend."
  (when (and eat-terminal
             (not (eat-serial--serial-terminal-p)))
    (let ((inhibit-read-only t))
      (ignore-errors (eat-emacs-mode))
      (ignore-errors (eat-term-delete eat-terminal))
      (setq eat-terminal nil)
      (goto-char (point-max))
      (unless (or (= (point-min) (point-max))
                  (= (char-before (point-max)) ?\n))
        (insert ?\n))
      (insert "\n"))))

(defun eat-serial--install-terminal-functions (&optional process)
  "Install Eat terminal callbacks and PROCESS in the current buffer."
  (unless eat-terminal
    (error "No Eat terminal in current buffer"))
  (setf (eat-term-parameter eat-terminal 'eat-serial) t)
  (setf (eat-term-parameter eat-terminal 'eat-serial-port)
        eat-serial--port)
  (setf (eat-term-parameter eat-terminal 'input-function)
        #'eat-serial--send-input)
  (eat-serial--set-terminal-parameter-if-bound
   'set-cursor-function 'eat--set-cursor)
  (eat-serial--set-terminal-parameter-if-bound
   'grab-mouse-function 'eat--grab-mouse)
  (eat-serial--set-terminal-parameter-if-bound
   'manipulate-selection-function 'eat--manipulate-kill-ring)
  (eat-serial--set-terminal-parameter-if-bound
   'ring-bell-function 'eat--bell)
  (eat-serial--set-terminal-parameter-if-bound
   'set-cwd-function 'eat--set-cwd)
  (eat-serial--set-terminal-parameter-if-bound
   'ui-command-function 'eat--handle-uic)
  (when (fboundp 'eat--set-term-sixel-params)
    (eat--set-term-sixel-params))
  (eat-serial--set-terminal-process process))

(defun eat-serial--select-default-input-mode ()
  "Switch to `eat-serial-default-input-mode'."
  (pcase eat-serial-default-input-mode
    ('emacs (eat-emacs-mode))
    ('char (eat-char-mode))
    ('line (eat-line-mode))
    (_ (eat-semi-char-mode))))

(defun eat-serial--ensure-terminal ()
  "Ensure the current Eat buffer has a terminal object."
  (unless eat-terminal
    (let ((inhibit-read-only t))
      (goto-char (point-max))
      (unless (or (= (point-min) (point-max))
                  (= (char-before (point-max)) ?\n))
        (insert ?\n))
      (unless (= (point-min) (point-max))
        (insert ?\n))
      (setq eat-terminal (eat-term-make (current-buffer) (point)))
      (when-let ((window (get-buffer-window nil t)))
        (with-selected-window window
          (eat-term-resize eat-terminal
                           (window-max-chars-per-line window)
                           (floor (window-screen-lines)))))
      (eat-serial--install-terminal-functions)
      (eat-serial--select-default-input-mode)
      (eat-term-redisplay eat-terminal))))

(defun eat-serial--setup-buffer (port speed)
  "Prepare current buffer as an Eat serial terminal for PORT and SPEED."
  (unless (eq major-mode 'eat-mode)
    (eat-mode))
  (eat-serial--delete-foreign-buffer-processes)
  (eat-serial--reset-foreign-terminal)
  (eat-serial-mode 1)
  (eat-serial--install-mode-line)
  (setq eat-serial--port port)
  (setq eat-serial--speed speed)
  (setq eat-serial--codec-state
        (eat-serial-codec-make-state eat-serial-invalid-byte-policy))
  (eat-serial--ensure-terminal))

(defun eat-serial--process-arguments ()
  "Return keyword arguments for `make-serial-process'."
  (append (list :name (format "eat-serial-%s" eat-serial--port)
                :buffer (current-buffer)
                :port eat-serial--port
                :speed eat-serial--speed
                :coding 'no-conversion
                :noquery t
                :filter #'eat-serial--filter
                :sentinel #'eat-serial--sentinel)
          (when eat-serial--bytesize
            (list :bytesize eat-serial--bytesize))
          (list :parity eat-serial--parity)
          (when eat-serial--stopbits
            (list :stopbits eat-serial--stopbits))
          (list :flowcontrol eat-serial--flowcontrol)))

(defun eat-serial--open-process ()
  "Open the serial process for the current buffer."
  (when (eat-serial--live-process-p)
    (delete-process eat-serial--process))
  (setq eat-serial--codec-state
        (eat-serial-codec-make-state eat-serial-invalid-byte-policy))
  (let ((process (apply #'make-serial-process
                        (eat-serial--process-arguments))))
    (setq eat-serial--process process)
    (setq eat-serial--connection-state 'connected)
    (set-marker (process-mark process) (point-max))
    (eat-serial--install-terminal-functions process)
    (force-mode-line-update)
    process))

(defun eat-serial--queue-output (process text)
  "Queue decoded TEXT from PROCESS for Eat to render."
  (when (> (length text) 0)
    (if (fboundp 'eat--filter)
        (eat--filter process text)
      (let ((inhibit-read-only t)
            (buffer-undo-list t))
        (eat-term-process-output eat-terminal text)
        (eat-term-redisplay eat-terminal)))))

(defun eat-serial--filter (process chunk)
  "Decode raw serial CHUNK from PROCESS and feed it to Eat."
  (when (buffer-live-p (process-buffer process))
    (with-current-buffer (process-buffer process)
      (when (and eat-terminal
                 (eq process eat-serial--process))
        (unless eat-serial--codec-state
          (setq eat-serial--codec-state
                (eat-serial-codec-make-state
                 eat-serial-invalid-byte-policy)))
        (let ((text (eat-serial-codec-decode
                     eat-serial--codec-state chunk)))
          (eat-serial--queue-output process text))))))

(defun eat-serial--sentinel (process message)
  "Handle serial PROCESS state changes described by MESSAGE."
  (let ((buffer (process-buffer process)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (when (eq process eat-serial--process)
          (unless (eat-serial--live-process-p process)
            (when eat-serial--codec-state
              (let ((tail (eat-serial-codec-flush eat-serial--codec-state)))
                (when (and eat-terminal (> (length tail) 0))
                  (eat-serial--queue-output process tail))))
            (setq eat-serial--connection-state 'disconnected)
            (setq eat-serial--process nil)
            (eat-serial--set-terminal-process nil)
            (force-mode-line-update)
            (message "eat-serial %s: %s"
                     (or eat-serial--port process)
                     (string-trim message))))))))

(defun eat-serial--send-raw-string (process bytes)
  "Send raw BYTES to PROCESS, chunking large writes."
  (if (fboundp 'eat--send-string)
      (eat--send-string process bytes)
    (let ((index 0)
          (chunk-size (if (boundp 'eat-input-chunk-size)
                          eat-input-chunk-size
                        1024)))
      (while (< index (length bytes))
        (process-send-string
         process
         (substring bytes index (min (+ index chunk-size)
                                     (length bytes))))
        (accept-process-output process 0)
        (setq index (+ index chunk-size))))))

(defun eat-serial--send-input (_terminal input)
  "Encode terminal INPUT and send it to the current serial process."
  (let ((process (or eat-serial--process
                     (and eat-terminal
                          (eat-term-parameter eat-terminal
                                              'eat--process)))))
    (unless (eat-serial--live-process-p process)
      (user-error "No live eat-serial process in this buffer"))
    (eat-serial--send-raw-string
     process
     (encode-coding-string input eat-serial-default-coding-system t))))

;;;###autoload
(defun eat-serial (port &optional speed)
  "Open an Eat-backed serial terminal for PORT at SPEED."
  (interactive
   (list (eat-serial--read-port)
         (read-number "Speed: " eat-serial-default-speed)))
  (let ((buffer (get-buffer-create (eat-serial--buffer-name port))))
    (with-current-buffer buffer
      (eat-serial--setup-buffer port (or speed eat-serial-default-speed))
      (unless (eat-serial--live-process-p)
        (eat-serial--open-process)))
    (pop-to-buffer-same-window buffer)))

;;;###autoload
(defun eat-serial-reconnect ()
  "Close and reopen the serial process for the current Eat serial buffer."
  (interactive)
  (unless eat-serial--port
    (user-error "This buffer is not an eat-serial buffer"))
  (eat-serial--delete-foreign-buffer-processes)
  (when (eat-serial--live-process-p)
    (delete-process eat-serial--process))
  (eat-serial--open-process)
  (message "Reconnected %s at %s" eat-serial--port eat-serial--speed))

;;;###autoload
(defun eat-serial-disconnect ()
  "Delete the serial process without killing the current buffer."
  (interactive)
  (if (eat-serial--live-process-p)
      (progn
        (delete-process eat-serial--process)
        (setq eat-serial--connection-state 'disconnected)
        (setq eat-serial--process nil)
        (eat-serial--set-terminal-process nil)
        (force-mode-line-update)
        (message "Disconnected %s" eat-serial--port))
    (message "No live eat-serial process")))

(defun eat-serial--read-choice (prompt choices current)
  "Read PROMPT as one of CHOICES, defaulting to CURRENT."
  (let* ((default (or current (car choices)))
         (answer (completing-read
                  (format-prompt prompt default)
                  choices nil t nil nil default)))
    answer))

;;;###autoload
(defun eat-serial-configure (speed bytesize parity stopbits flowcontrol)
  "Configure the current serial process.

SPEED, BYTESIZE, PARITY, STOPBITS, and FLOWCONTROL are passed to
`serial-process-configure'."
  (interactive
   (let ((speed (read-number "Speed: " eat-serial--speed))
         (bytesize (string-to-number
                    (eat-serial--read-choice
                     "Byte size" '("8" "7")
                     (number-to-string (or eat-serial--bytesize 8)))))
         (parity (eat-serial--read-choice
                  "Parity" '("none" "odd" "even")
                  (pcase eat-serial--parity
                    ('odd "odd")
                    ('even "even")
                    (_ "none"))))
         (stopbits (string-to-number
                    (eat-serial--read-choice
                     "Stop bits" '("1" "2")
                     (number-to-string (or eat-serial--stopbits 1)))))
         (flowcontrol (eat-serial--read-choice
                       "Flow control" '("none" "hw" "sw")
                       (pcase eat-serial--flowcontrol
                         ('hw "hw")
                         ('sw "sw")
                         (_ "none")))))
     (list speed bytesize
           (pcase parity
             ("odd" 'odd)
             ("even" 'even)
             (_ nil))
           stopbits
           (pcase flowcontrol
             ("hw" 'hw)
             ("sw" 'sw)
             (_ nil)))))
  (let ((process (eat-serial--require-process)))
    (serial-process-configure :process process
                              :speed speed
                              :bytesize bytesize
                              :parity parity
                              :stopbits stopbits
                              :flowcontrol flowcontrol)
    (setq eat-serial--speed speed)
    (setq eat-serial--bytesize bytesize)
    (setq eat-serial--parity parity)
    (setq eat-serial--stopbits stopbits)
    (setq eat-serial--flowcontrol flowcontrol)
    (force-mode-line-update)
    (message "Configured %s at %s" eat-serial--port eat-serial--speed)))

(defun eat-serial--parse-byte (string)
  "Parse STRING as a byte value."
  (let ((trimmed (string-trim string)))
    (cond
     ((string-match-p "\\`0[xX][0-9a-fA-F]+\\'" trimmed)
      (string-to-number (substring trimmed 2) 16))
     ((string-match-p "\\`[0-9]+\\'" trimmed)
      (string-to-number trimmed 10))
     ((= (length trimmed) 1)
      (aref trimmed 0))
     (t
      (user-error "Enter a byte as decimal, hex (0x1b), or one character")))))

(defun eat-serial--read-byte ()
  "Read a byte value from the minibuffer."
  (let ((byte (eat-serial--parse-byte
               (read-string "Send byte (decimal, 0xNN, or char): "))))
    (unless (and (integerp byte) (<= 0 byte #xff))
      (user-error "Byte must be in range 0..255"))
    byte))

;;;###autoload
(defun eat-serial-send-byte (byte)
  "Send BYTE, an integer 0..255, to the serial port exactly."
  (interactive (list (eat-serial--read-byte)))
  (process-send-string (eat-serial--require-process)
                       (unibyte-string byte)))

(defun eat-serial--python-send-break (process duration)
  "Use Python to send a serial break for PROCESS lasting DURATION units."
  (unless (executable-find "python3")
    (user-error "No `python3' found; customize `eat-serial-send-break-function'"))
  (let* ((contact (process-contact process))
         (port (or (plist-get contact :port) eat-serial--port))
         (status (call-process
                  "python3" nil nil nil "-c"
                  "import os, sys, termios\nfd = os.open(sys.argv[1], os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)\ntry:\n    termios.tcsendbreak(fd, int(sys.argv[2]))\nfinally:\n    os.close(fd)\n"
                  port (number-to-string duration))))
    (unless (equal status 0)
      (user-error "Python tcsendbreak helper failed with status %s"
                  status))))

;;;###autoload
(defun eat-serial-send-break (&optional duration)
  "Send a serial break to the current port.

DURATION defaults to `eat-serial-break-duration'.  Emacs does not
currently expose a serial-break primitive, so the default implementation
uses a best-effort Python `termios.tcsendbreak' helper."
  (interactive)
  (let ((process (eat-serial--require-process))
        (duration (or duration eat-serial-break-duration)))
    (if eat-serial-send-break-function
        (funcall eat-serial-send-break-function process duration)
      (eat-serial--python-send-break process duration))
    (message "Sent serial break on %s" eat-serial--port)))

(provide 'eat-serial)

;;; eat-serial.el ends here
