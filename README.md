<p align="center">
  <img src="image.jpg" alt="eat-serial logo" width="512">
</p>

# eat-serial

`eat-serial` is an Eat-backed replacement for `serial-term`: it uses Eat's
terminal renderer and input modes, but connects them to `make-serial-process`
and a byte-safe streaming UTF-8 decoder.

## Requirements

- Emacs 30.1 or newer with serial process support
- Eat on `load-path`

For local development against a checkout of Eat:

```elisp
(add-to-list 'load-path "~/src/emacs-eat")
(add-to-list 'load-path "~/src/eat-serial")
(require 'eat-serial)
```

## Usage

Run:

```text
M-x eat-serial
```

The command prompts for a port and speed, creates a buffer named like
`*eat-serial /dev/ttyUSB0*`, and starts in Eat semi-char mode by default.

Useful serial commands:

- `C-c C-s r` — reconnect
- `C-c C-s d` — disconnect without killing the buffer
- `C-c C-s c` — configure speed/byte size/parity/stop bits/flow control
- `C-c C-s b` — send a serial break
- `C-c C-s x` — send one raw byte
- `C-c C-k` — disconnect

Eat mode switching keybindings are preserved:

- `C-c C-e` — Emacs mode from semi-char/line
- `C-c C-j` — semi-char mode
- `C-c M-d` — char mode
- `C-c C-l` — line mode

## Byte handling

The serial process is opened with `:coding 'no-conversion`.  Incoming raw bytes
are decoded by `eat-serial-codec` before they are passed to Eat.

Customizable behavior:

- `eat-serial-default-speed` (default `115200`)
- `eat-serial-default-coding-system` (default `utf-8-unix` for input sent to the device)
- `eat-serial-invalid-byte-policy` (`replacement`, `hex`, or `latin-1`)
- `eat-serial-default-input-mode` (`semi-char`, `char`, `line`, or `emacs`)
- `eat-serial-buffer-name-format`

Malformed bytes never signal an error.  Split UTF-8 sequences are buffered
across process filter calls.

## Tests

```sh
emacs -Q --batch -L . -l eat-serial-tests.el -f ert-run-tests-batch-and-exit
```

That command always runs the codec tests.  Integration tests for the Eat-backed
process lifecycle run when Eat is also on `load-path`:

```sh
emacs -Q --batch -L . -L ~/src/emacs-eat -l eat-serial-tests.el \
  -f ert-run-tests-batch-and-exit
```

To byte-compile the adapter against a local Eat checkout:

```sh
emacs -Q --batch -L . -L ~/src/emacs-eat -f batch-byte-compile \
  eat-serial-codec.el eat-serial.el eat-serial-tests.el
```

## Serial break support

Emacs does not expose a portable Lisp primitive for serial break.  By default,
`eat-serial-send-break` uses a best-effort Python `termios.tcsendbreak` helper
that opens the same port path separately.  Customize
`eat-serial-send-break-function` if your platform needs a different mechanism.
