# eat-serial implementation plan

Goal: replace `serial-term` with a serial terminal that keeps Eat-like input modes/keybindings and is byte-safe when serial output contains UTF-8 or malformed/non-ASCII bytes.

I inspected:

- `~/src/emacs-eat/eat.el`: Eat already has the desired semi-char/char/emacs/line modes and a public-ish terminal API (`eat-term-make`, `eat-term-process-output`, `eat-term-input-event`, `eat-term-redisplay`). Its UI mode/keymaps are in `eat-mode`, with process-specific glue in internal functions.
- Emacs 30.2 built-in `serial-term`: it creates a `make-serial-process` with `:coding 'no-conversion`, enters `term-mode`, then uses `term-emulate-terminal` as the process filter. That leaves serial bytes mostly raw and is a likely source of bad behavior once multibyte UTF-8 or arbitrary high-bit bytes arrive.

## Recommended plan: Eat-backed serial adapter

This is the fastest path to a usable package: keep Eat's renderer, terminal parser, input translator, and mode/keybinding UX, but replace the PTY subprocess layer with a `make-serial-process` layer and a robust serial byte decoder.

### Package shape

Files:

- `eat-serial.el` — public commands, major-mode setup, serial process lifecycle.
- `eat-serial-codec.el` — streaming byte decoder/encoder and tests for invalid/split UTF-8.
- `eat-serial-tests.el` — ERT tests.
- `README.md` — usage and keybindings.
- `COPYING` — required if reusing/linking GPL Eat code; Eat and Emacs are GPL-family.

Dependencies:

- Required: Emacs with `make-serial-process`, Eat available on `load-path`.
- Initial development can depend on the local checkout `~/src/emacs-eat`; packaging should use `(require 'eat)` and document how to install Eat.

### User-facing commands

- `M-x eat-serial`:
  - prompts for port and speed like `serial-term`;
  - creates/switches to `*eat-serial /dev/ttyUSB0*`;
  - starts in semi-char mode by default.
- `M-x eat-serial-reconnect`:
  - closes and reopens the same port with current settings.
- `M-x eat-serial-disconnect`:
  - deletes the serial process without killing the buffer.
- `M-x eat-serial-configure`:
  - changes speed and serial params through `serial-process-configure`.
- `M-x eat-serial-send-break` and `M-x eat-serial-send-byte`:
  - useful for embedded targets and recovery.

Custom variables:

- `eat-serial-default-speed` default `115200`.
- `eat-serial-default-coding-system` default `utf-8-unix`.
- `eat-serial-invalid-byte-policy` default `replacement`, alternatives `hex` and `latin-1`.
- `eat-serial-default-input-mode` default `semi-char`.
- `eat-serial-buffer-name-format` default `"*eat-serial %p*"`.
- `eat-serial-read-chunk-latency` can reuse Eat's latency variables initially.

### Reusing Eat without forking it

The adapter can initialize an Eat buffer manually:

1. Create/switch buffer.
2. Call `eat-mode`.
3. Create `eat-terminal` with `(eat-term-make buffer (point))`.
4. Set terminal parameters:
   - `input-function` -> `eat-serial--send-input`;
   - `eat--process`, `eat--input-process`, `eat--output-process` -> serial process;
   - cursor/mouse/bell/selection callbacks can initially reuse Eat internals if available.
5. Enter `eat-semi-char-mode`, `eat-char-mode`, `eat-line-mode`, or `eat-emacs-mode` according to `eat-serial-default-input-mode`.
6. Process serial output with our filter, then feed decoded text to `eat-term-process-output` and `eat-term-redisplay`.

Risk: some convenient Eat glue functions are internal (`eat--set-cursor`, `eat--grab-mouse`, `eat--send-string`, output queue helpers). For the first version, use them behind a compatibility shim and pin/test against the local Eat checkout. If that proves too brittle, move to Plan B or vendor the small UI glue layer.

### Byte-safe serial input pipeline

`make-serial-process` should still use raw/no-conversion I/O:

```elisp
(make-serial-process
 :port port
 :speed speed
 :coding 'no-conversion
 :noquery t
 :filter #'eat-serial--filter
 :sentinel #'eat-serial--sentinel)
```

The filter must not hand raw high-bit bytes straight to Eat. It should:

1. Receive a unibyte string of raw bytes.
2. Append it to a per-buffer decoder state.
3. Decode complete UTF-8 sequences into Emacs characters.
4. Preserve ASCII control bytes used by terminals (`ESC`, BEL, BS, TAB, LF, CR, etc.).
5. Keep incomplete multibyte prefixes pending across process-filter calls.
6. For malformed bytes, never signal an error:
   - `replacement`: emit `U+FFFD`;
   - `hex`: emit a visible marker like `<E2>`;
   - `latin-1`: map byte `#x80..#xff` directly.
7. Feed the resulting multibyte string to Eat.

Acceptance cases:

- `"hello \xE2\x98\x83\n"` displays `hello ☃`.
- Split chunks `"\xE2"`, `"\x98"`, `"\x83"` display one `☃`, not three replacement chars.
- Invalid `"\xE2x"` displays replacement/hex and continues.
- Binary-ish output with NUL/high-bit bytes does not throw or lock Emacs.
- ESC sequences split across chunks still work because Eat already maintains parser state.

### Output/input encoding

Eat's key translator produces Emacs strings containing ASCII control/escape sequences and occasionally Unicode text (paste, input method, `insert-char`). Before sending to the serial process:

1. Encode the string with `eat-serial-default-coding-system` (`utf-8-unix` by default).
2. Use raw `process-send-string`; because process coding is `no-conversion`, the bytes go out unchanged.
3. Chunk long writes as Eat does, so pasting a large block does not starve serial output.

Special commands (`eat-serial-send-byte`, break, reset toggles) should bypass text encoding and write exact bytes/control operations.

### Eat-like modes/keybindings to preserve

Keep these from Eat as-is for muscle memory:

- Semi-char default:
  - most terminal-ish keys go to serial;
  - `C-q` sends next key literally;
  - `C-y` / `M-y` paste to terminal;
  - `C-c C-k` kill/disconnect process;
  - `C-c C-e` emacs mode;
  - `C-c M-d` char mode;
  - `C-c C-l` line mode.
- Emacs mode:
  - normal Emacs keys;
  - `C-c C-j` semi-char;
  - `C-c M-d` char;
  - `C-c C-l` line;
  - `C-c C-k` disconnect.
- Char mode:
  - all supported keys to serial;
  - `C-M-m` / `M-RET` back to semi-char.
- Line mode:
  - editable local input line;
  - `RET` sends the line;
  - history keys from Eat;
  - mode switches matching Eat.

Add serial-specific bindings under `C-c C-s ...` or `C-c C-z ...` to avoid conflicting with Eat muscle memory:

- `C-c C-s r` reconnect;
- `C-c C-s d` disconnect;
- `C-c C-s c` configure speed;
- `C-c C-s b` send break;
- `C-c C-s x` send raw byte.

### Implementation phases

#### Phase 0 — skeleton

- Add package headers and `(require 'eat)`.
- Add `eat-serial` command that opens a serial process and shows an Eat buffer.
- Reuse Eat keymaps/mode switching.
- Implement basic disconnect/reconnect.

Done when: ASCII serial logs display and keyboard input reaches the device.

#### Phase 1 — robust codec

- Implement `eat-serial-codec.el` streaming UTF-8 decoder.
- Add ERT tests for valid UTF-8, split sequences, malformed bytes, NUL, C1 bytes, and mixed ESC sequences.
- Make output coding configurable.

Done when: non-ASCII serial logs no longer break or corrupt parser state.

#### Phase 2 — UX polish

- Mode-line display: port, speed, connection state, current Eat input mode.
- Serial config menu or transient-like command using `serial-process-configure`.
- Optional timestamping for plain log lines, disabled by default because it can interfere with terminal applications.
- Optional logging to file of raw bytes and/or decoded display text.

Done when: it feels better than `serial-term` for day-to-day firmware logs.

#### Phase 3 — hardening

- Add stress tests that feed random bytes through the codec and Eat parser; no errors allowed.
- Add manual test script using a PTY pair (`socat -d -d pty,raw,echo=0 pty,raw,echo=0`) when available, so development does not require hardware.
- Test against common embedded output:
  - U-Boot menus;
  - Linux boot logs;
  - ANSI color logs;
  - UTF-8 symbols;
  - accidental binary dumps.

Done when: malformed serial traffic is boring.

#### Phase 4 — packaging

- Add README usage examples for Doom/straight.el/local checkout.
- Add package metadata.
- Document that Eat is required and that the package intentionally uses a small compatibility shim around Eat internals until Eat exposes a serial backend API.

## Alternative plan A: patch/fork Eat with a serial backend

Instead of a separate adapter package, add an `eat-serial` entry point directly to a fork of Eat.

Pros:

- Lowest duplication; can directly call Eat internals.
- Modes/keybindings stay exactly identical.
- Less adapter friction around mode-line, cursor, mouse, and output queue.

Cons:

- Maintains a fork or carries a patch series against a slow-moving upstream.
- Harder to package independently.
- Serial-specific codec/config might not be wanted upstream.

Implementation is essentially: refactor `eat-exec` so process creation is backend-specific, then add a serial backend that uses `make-serial-process` and the byte-safe codec.

This is attractive if the local `~/src/emacs-eat` fork is already where the user wants to iterate.

## Alternative plan B: improve built-in `serial-term` with Eat-like keymaps

Keep Emacs `term.el` rendering and only replace the keymaps plus output coding.

Pros:

- Very small initial patch.
- No Eat dependency.
- Less licensing/packaging complexity beyond Emacs GPL code.

Cons:

- Still stuck with `term-emulate-terminal` behavior and performance.
- Hard to get all Eat modes exactly right.
- Less confidence for malformed UTF-8 and modern terminal sequences.

This is only worth doing as a quick stopgap. It does not meet the “similar modes and keybinds as Eat” goal as cleanly as the Eat-backed adapter.

## Alternative plan C: serial monitor, not full terminal

Build a simple comint/special-mode style serial monitor:

- append decoded text to a buffer;
- interpret only color SGR and basic CR/LF;
- no full-screen terminal emulation;
- Eat-like semi-char/emacs modes for input.

Pros:

- Most robust for firmware logs and binary junk.
- Simple model; easy timestamping/logging/filtering.
- No full VT parser edge cases.

Cons:

- Not a `serial-term` replacement for menus, curses apps, U-Boot UI, etc.
- Eat keybindings can be mimicked, but terminal behavior cannot.

This could be a later optional `eat-serial-log-mode`, but it should not be the first implementation if the desired target is a terminal replacement.

## Recommendation

Start with the Eat-backed serial adapter. It gives the desired UX quickly and isolates the real missing piece: byte-safe serial decoding/encoding. Keep the adapter thin, but put the codec under tests from day one. If Eat internals become too brittle, either upstream a backend hook into Eat or pivot to a maintained Eat fork with the serial backend included.
