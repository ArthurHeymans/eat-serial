;;; eat-serial.el --- Eat-backed serial terminal -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Arthur Heymans

;; Author: Arthur Heymans <arthur@aheymans.xyz>
;; Maintainer: Arthur Heymans <arthur@aheymans.xyz>
;; Version: 0.1.0
;; Keywords: terminals, serial, processes
;; Package-Requires: ((emacs "30.1") (eat "0.9.4"))
;; URL: https://github.com/ArthurHeymans/eat-serial
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

(defcustom eat-serial-speed-history
  '(9600 19200 38400 57600 115200 230400 460800 921600)
  "Serial port speeds offered by the mode-line speed menu."
  :type '(repeat integer)
  :group 'eat-serial)

(defcustom eat-serial-buffer-name-format "*eat-serial %p*"
  "Format used to create serial terminal buffer names.

The format specifier %p expands to the serial port path."
  :type 'string
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
    (concat
     " ["
     (eat-serial--mode-line-item
      eat-serial--port
      "mouse-1: serial actions"
      #'eat-serial-mode-line-connection-menu)
     " "
     (eat-serial--mode-line-item
      (eat-serial--speed-string)
      "mouse-1: change serial speed"
      #'eat-serial-mode-line-speed-menu)
     " "
     (eat-serial--mode-line-item
      (eat-serial--configuration-summary)
      "mouse-1: change serial framing/flow control"
      #'eat-serial-mode-line-config-menu)
     " "
     (eat-serial--mode-line-item
      (symbol-name eat-serial--connection-state)
      "mouse-1: serial actions"
      #'eat-serial-mode-line-connection-menu)
     "]")))

(defun eat-serial--mode-line-item (text help-echo command)
  "Return mode-line TEXT with HELP-ECHO and mouse COMMAND."
  (propertize text
              'help-echo help-echo
              'mouse-face 'mode-line-highlight
              'local-map `(keymap (mode-line keymap
                                              (down-mouse-1 . ,command)))))

(defun eat-serial--speed-string ()
  "Return human-readable speed text for the mode line."
  (if eat-serial--speed
      (format "%s" eat-serial--speed)
    "port-default"))

(defun eat-serial--configuration-summary ()
  "Return compact serial framing and flow-control summary."
  (concat
   (format "%s%s%s"
           (or eat-serial--bytesize 8)
           (pcase eat-serial--parity
             ('odd "O")
             ('even "E")
             (_ "N"))
           (or eat-serial--stopbits 1))
   (pcase eat-serial--flowcontrol
     ('hw "+RTS/CTS")
     ('sw "+XON/XOFF")
     (_ ""))))

(defun eat-serial--popup-mode-line-menu (event keymap)
  "Popup KEYMAP for mode-line EVENT and run the selected command."
  (save-selected-window
    (when-let ((window (and event (posn-window (event-start event)))))
      (when (windowp window)
        (select-window window)))
    (let* ((selection (x-popup-menu event keymap))
           (binding (and selection
                         (lookup-key keymap (vconcat selection)))))
      (when binding
        (call-interactively binding)))))

(defun eat-serial--install-mode-line ()
  "Append serial status to Eat's mode line in the current buffer."
  (unless eat-serial--mode-line-process
    (setq eat-serial--mode-line-process mode-line-process)
    (setq mode-line-process
          (append mode-line-process
                  '((:eval (eat-serial--mode-line-string)))))))

(defun eat-serial--display-window ()
  "Return a window that should determine the current terminal size."
  (or (and (eq (window-buffer) (current-buffer))
           (selected-window))
      (car (sort (get-buffer-window-list (current-buffer) nil t)
                 (lambda (left right)
                   (> (* (window-total-width left)
                         (window-total-height left))
                      (* (window-total-width right)
                         (window-total-height right))))))))

(defun eat-serial--resize-terminal-to-window (&rest _)
  "Resize the Eat terminal to the window displaying this buffer."
  (when (and eat-terminal (get-buffer-window (current-buffer) t))
    (when-let ((window (eat-serial--display-window)))
      (with-selected-window window
        (let* ((width (max (window-max-chars-per-line window) 1))
               (height (max (floor (window-screen-lines)) 1))
               (size (eat-term-size eat-terminal)))
          (unless (and (= width (car size))
                       (= height (cdr size)))
            (let ((inhibit-read-only t))
              (eat-term-resize eat-terminal width height)
              (eat-term-redisplay eat-terminal))))))))

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
        (set-process-sentinel process #'ignore)
        (set-process-buffer process nil)
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
  (add-hook 'window-configuration-change-hook
            #'eat-serial--resize-terminal-to-window nil t)
  (eat-serial--install-mode-line)
  (setq eat-serial--port port)
  (unless (eat-serial--live-process-p)
    (setq eat-serial--speed speed))
  (setq eat-serial--codec-state
        (eat-serial-codec-make-state eat-serial-invalid-byte-policy))
  (eat-serial--ensure-terminal))

(defun eat-serial--set-configuration (speed bytesize parity stopbits flowcontrol)
  "Store serial configuration values in the current buffer."
  (setq eat-serial--speed speed)
  (setq eat-serial--bytesize bytesize)
  (setq eat-serial--parity parity)
  (setq eat-serial--stopbits stopbits)
  (setq eat-serial--flowcontrol flowcontrol))

(defun eat-serial--configure-process
    (process speed bytesize parity stopbits flowcontrol)
  "Apply serial configuration values to PROCESS and store them."
  (serial-process-configure :process process
                            :speed speed
                            :bytesize bytesize
                            :parity parity
                            :stopbits stopbits
                            :flowcontrol flowcontrol)
  (eat-serial--set-configuration speed bytesize parity stopbits flowcontrol))

(defun eat-serial--apply-configuration
    (speed bytesize parity stopbits flowcontrol)
  "Apply serial settings, or store them until reconnect.

SPEED, BYTESIZE, PARITY, STOPBITS, and FLOWCONTROL are the same
values accepted by `serial-process-configure'."
  (unless eat-serial--port
    (user-error "This buffer is not an eat-serial buffer"))
  (let ((process (and (eat-serial--live-process-p) eat-serial--process)))
    (if process
        (eat-serial--configure-process process speed bytesize parity
                                       stopbits flowcontrol)
      (eat-serial--set-configuration speed bytesize parity
                                     stopbits flowcontrol))
    (force-mode-line-update)
    (message "Configured %s as %s %s%s"
             eat-serial--port
             (eat-serial--speed-string)
             (eat-serial--configuration-summary)
             (if process "" " (pending reconnect)"))))

;;;###autoload
(defun eat-serial-set-speed (speed)
  "Configure the current Eat serial buffer to use SPEED."
  (interactive
   (list (read-number "Speed: " (or eat-serial--speed
                                      eat-serial-default-speed))))
  (eat-serial--apply-configuration speed
                                   eat-serial--bytesize
                                   eat-serial--parity
                                   eat-serial--stopbits
                                   eat-serial--flowcontrol))

(defun eat-serial-set-framing (bytesize parity stopbits)
  "Configure serial BYTESIZE, PARITY, and STOPBITS."
  (interactive
   (list (string-to-number
          (eat-serial--read-choice
           "Byte size" '("8" "7")
           (number-to-string (or eat-serial--bytesize 8))))
         (pcase (eat-serial--read-choice
                 "Parity" '("none" "odd" "even")
                 (pcase eat-serial--parity
                   ('odd "odd")
                   ('even "even")
                   (_ "none")))
           ("odd" 'odd)
           ("even" 'even)
           (_ nil))
         (string-to-number
          (eat-serial--read-choice
           "Stop bits" '("1" "2")
           (number-to-string (or eat-serial--stopbits 1))))))
  (eat-serial--apply-configuration eat-serial--speed
                                   bytesize
                                   parity
                                   stopbits
                                   eat-serial--flowcontrol))

(defun eat-serial-set-flowcontrol (flowcontrol)
  "Configure serial FLOWCONTROL."
  (interactive
   (list (pcase (eat-serial--read-choice
                 "Flow control" '("none" "hw" "sw")
                 (pcase eat-serial--flowcontrol
                   ('hw "hw")
                   ('sw "sw")
                   (_ "none")))
           ("hw" 'hw)
           ("sw" 'sw)
           (_ nil))))
  (eat-serial--apply-configuration eat-serial--speed
                                   eat-serial--bytesize
                                   eat-serial--parity
                                   eat-serial--stopbits
                                   flowcontrol))

(defun eat-serial--clear-process-state (&optional state)
  "Forget the current process and set connection STATE."
  (setq eat-serial--process nil)
  (setq eat-serial--connection-state (or state 'disconnected))
  (eat-serial--set-terminal-process nil)
  (force-mode-line-update))

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
    (let ((old-process eat-serial--process))
      (eat-serial--clear-process-state 'disconnected)
      (delete-process old-process)))
  (setq eat-serial--codec-state
        (eat-serial-codec-make-state eat-serial-invalid-byte-policy))
  (setq eat-serial--connection-state 'connecting)
  (condition-case err
      (let ((process (apply #'make-serial-process
                            (eat-serial--process-arguments))))
        (when (fboundp 'eat--adjust-process-window-size)
          (process-put process 'adjust-window-size-function
                       #'eat--adjust-process-window-size))
        (setq eat-serial--process process)
        (setq eat-serial--connection-state 'connected)
        (set-marker (process-mark process) (point-max))
        (eat-serial--install-terminal-functions process)
        (force-mode-line-update)
        process)
    (error
     (eat-serial--clear-process-state 'disconnected)
     (signal (car err) (cdr err)))))

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
  (let ((buffer (get-buffer-create (eat-serial--buffer-name port)))
        (requested-speed (or speed eat-serial-default-speed)))
    (with-current-buffer buffer
      (eat-serial--setup-buffer port requested-speed)
      (if (eat-serial--live-process-p)
          (unless (equal eat-serial--speed requested-speed)
            (eat-serial--configure-process eat-serial--process
                                           requested-speed
                                           eat-serial--bytesize
                                           eat-serial--parity
                                           eat-serial--stopbits
                                           eat-serial--flowcontrol)
            (force-mode-line-update)
            (message "Configured %s at %s"
                     eat-serial--port eat-serial--speed))
        (setq eat-serial--speed requested-speed)
        (eat-serial--open-process)))
    (pop-to-buffer-same-window buffer)
    (with-current-buffer buffer
      (eat-serial--resize-terminal-to-window))))

;;;###autoload
(defun eat-serial-reconnect ()
  "Close and reopen the serial process for the current Eat serial buffer."
  (interactive)
  (unless eat-serial--port
    (user-error "This buffer is not an eat-serial buffer"))
  (eat-serial--delete-foreign-buffer-processes)
  (eat-serial--open-process)
  (message "Reconnected %s at %s" eat-serial--port eat-serial--speed))

;;;###autoload
(defun eat-serial-disconnect ()
  "Delete the serial process without killing the current buffer."
  (interactive)
  (if (eat-serial--live-process-p)
      (let ((process eat-serial--process))
        (eat-serial--clear-process-state 'disconnected)
        (delete-process process)
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

When a serial process is live, SPEED, BYTESIZE, PARITY, STOPBITS,
and FLOWCONTROL are passed to `serial-process-configure'.  When the
buffer is disconnected, store the settings for the next reconnect."
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
  (unless eat-serial--port
    (user-error "This buffer is not an eat-serial buffer"))
  (eat-serial--apply-configuration speed bytesize parity stopbits flowcontrol))

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

;;;###autoload
(defun eat-serial-copy-port-name ()
  "Copy the current serial port name to the kill ring."
  (interactive)
  (unless eat-serial--port
    (user-error "This buffer is not an eat-serial buffer"))
  (kill-new eat-serial--port)
  (message "Copied serial port %s" eat-serial--port))

(defun eat-serial--connection-menu ()
  "Return the mode-line connection menu."
  (let ((map (make-sparse-keymap "eat-serial")))
    (define-key map [copy-port]
      '(menu-item "Copy port name" eat-serial-copy-port-name
                  :enable eat-serial--port))
    (define-key map [send-byte]
      '(menu-item "Send raw byte..." eat-serial-send-byte
                  :enable (eat-serial--live-process-p)))
    (define-key map [send-break]
      '(menu-item "Send break" eat-serial-send-break
                  :enable (eat-serial--live-process-p)))
    (define-key map [separator-1] '(menu-item "--"))
    (define-key map [configure]
      '(menu-item "Configure..." eat-serial-configure
                  :enable eat-serial--port))
    (define-key map [disconnect]
      '(menu-item "Disconnect" eat-serial-disconnect
                  :enable (eat-serial--live-process-p)))
    (define-key map [reconnect]
      '(menu-item "Reconnect" eat-serial-reconnect
                  :enable eat-serial--port))
    map))

(defun eat-serial--speed-menu ()
  "Return the mode-line speed menu."
  (let* ((speeds (cl-delete-duplicates
                  (delq nil (copy-sequence
                             (cons eat-serial--speed
                                   eat-serial-speed-history)))
                  :test #'equal))
         (speeds (sort speeds #'>))
         (map (make-sparse-keymap "Speed (b/s)")))
    (define-key map [other]
      '(menu-item "Other..." eat-serial-set-speed
                  :enable eat-serial--port))
    (define-key map [separator-1] '(menu-item "--"))
    (dolist (speed speeds)
      (define-key
       map
       (vector (make-symbol (format "speed-%s" speed)))
       `(menu-item
         ,(format "%s" speed)
         (lambda ()
           (interactive)
           (eat-serial-set-speed ,speed))
         :button (:radio . (equal eat-serial--speed ,speed)))))
    map))

(defun eat-serial--config-menu ()
  "Return the mode-line serial configuration menu."
  (let ((map (make-sparse-keymap "Serial configuration")))
    (define-key map [configure]
      '(menu-item "Configure all..." eat-serial-configure
                  :enable eat-serial--port))
    (define-key map [separator-1] '(menu-item "--"))
    (dolist (preset '(("8N1" 8 nil 1)
                      ("7E1" 7 even 1)
                      ("7O1" 7 odd 1)))
      (pcase-let ((`(,label ,bytesize ,parity ,stopbits) preset))
        (define-key
         map
         (vector (make-symbol (format "preset-%s" label)))
         `(menu-item
           ,(format "Preset %s" label)
           (lambda ()
             (interactive)
             (eat-serial-set-framing ,bytesize ',parity ,stopbits))
           :button (:radio . (and (equal eat-serial--bytesize ,bytesize)
                                  (eq eat-serial--parity ',parity)
                                  (equal eat-serial--stopbits ,stopbits)))))))
    (define-key map [separator-2] '(menu-item "--"))
    (dolist (bytesize '(8 7))
      (define-key
       map
       (vector (make-symbol (format "bytesize-%s" bytesize)))
       `(menu-item
         ,(format "%s data bits" bytesize)
         (lambda ()
           (interactive)
           (eat-serial-set-framing ,bytesize
                                   eat-serial--parity
                                   eat-serial--stopbits))
         :button (:radio . (equal eat-serial--bytesize ,bytesize)))))
    (define-key map [separator-3] '(menu-item "--"))
    (dolist (parity '((nil "No parity")
                      (even "Even parity")
                      (odd "Odd parity")))
      (pcase-let ((`(,value ,label) parity))
        (define-key
         map
         (vector (make-symbol (format "parity-%s" value)))
         `(menu-item
           ,label
           (lambda ()
             (interactive)
             (eat-serial-set-framing eat-serial--bytesize
                                     ',value
                                     eat-serial--stopbits))
           :button (:radio . (eq eat-serial--parity ',value))))))
    (define-key map [separator-4] '(menu-item "--"))
    (dolist (stopbits '(1 2))
      (define-key
       map
       (vector (make-symbol (format "stopbits-%s" stopbits)))
       `(menu-item
         ,(format "%s stop bit%s" stopbits (if (= stopbits 1) "" "s"))
         (lambda ()
           (interactive)
           (eat-serial-set-framing eat-serial--bytesize
                                   eat-serial--parity
                                   ,stopbits))
         :button (:radio . (equal eat-serial--stopbits ,stopbits)))))
    (define-key map [separator-5] '(menu-item "--"))
    (dolist (flow '((nil "No flow control")
                    (hw "Hardware flow control (RTS/CTS)")
                    (sw "Software flow control (XON/XOFF)")))
      (pcase-let ((`(,value ,label) flow))
        (define-key
         map
         (vector (make-symbol (format "flow-%s" value)))
         `(menu-item
           ,label
           (lambda ()
             (interactive)
             (eat-serial-set-flowcontrol ',value))
           :button (:radio . (eq eat-serial--flowcontrol ',value))))))
    map))

(defun eat-serial-mode-line-connection-menu (event)
  "Show the mode-line connection menu for EVENT."
  (interactive "e")
  (eat-serial--popup-mode-line-menu event (eat-serial--connection-menu)))

(defun eat-serial-mode-line-speed-menu (event)
  "Show the mode-line speed menu for EVENT."
  (interactive "e")
  (eat-serial--popup-mode-line-menu event (eat-serial--speed-menu)))

(defun eat-serial-mode-line-config-menu (event)
  "Show the mode-line configuration menu for EVENT."
  (interactive "e")
  (eat-serial--popup-mode-line-menu event (eat-serial--config-menu)))

(provide 'eat-serial)

;;; eat-serial.el ends here
