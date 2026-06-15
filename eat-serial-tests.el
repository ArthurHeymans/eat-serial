;;; eat-serial-tests.el --- Tests for eat-serial -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:

(require 'ert)
(require 'eat-serial-codec)

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
           "��")))

(ert-deftest eat-serial-codec-random-bytes-do-not-signal ()
  (let ((state (eat-serial-codec-make-state)))
    (dotimes (_ 64)
      (let ((chunk (make-string 32 0)))
        (dotimes (index (length chunk))
          (aset chunk index (random 256)))
        (should (stringp (eat-serial-codec-decode state chunk)))))
    (should (stringp (eat-serial-codec-flush state)))))

(provide 'eat-serial-tests)

;;; eat-serial-tests.el ends here
