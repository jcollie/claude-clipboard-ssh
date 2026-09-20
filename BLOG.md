<!--
SPDX-FileCopyrightText: © 2026 mindfulmonk <mindfulmonk@users.noreply.github.com>
SPDX-License-Identifier: MIT
-->

# Image paste over SSH for Claude Code, via OSC 5522

I wanted to paste screenshots into Claude Code while SSH'd into a Linux box
from my Mac. Locally it works — Cmd+V, image attaches, the model sees it.
Over SSH from kitty? Nothing. Over SSH from ghostty? Also nothing. Closed as
"not planned" upstream ([claude-code#42712][1]).

So I built it. Here's the trip report. The TL;DR is: a 170-line shim and a
500-line PTY-proxy wrapper, working in both kitty and ghostty, no patches to
Claude Code itself.

[1]: https://github.com/anthropics/claude-code/issues/42712

## How Claude Code reads the clipboard on Linux

Same way most Linux TUIs do: shell out to `xclip`. Roughly:

```sh
xclip -selection clipboard -t TARGETS -o | grep -E 'image/(png|jpeg|...)'
xclip -selection clipboard -t image/png -o > /tmp/claude-501/claude_cli_latest_screenshot.png
```

The first call discovers what MIME types are on the clipboard. If an image
type matches, the second call grabs the bytes. Then Claude attaches the
file. Done.

On a remote Linux box over SSH, `xclip` has no X server to talk to. Fails.

## OSC 5522 in kitty: ambient capability

kitty has a clipboard escape protocol called [OSC 5522][2]. From a TUI app
over SSH:

```
ESC ] 5522 ; type=read ; <base64(mime-types)> ESC \
```

kitty (on the *local* Mac) reads its actual clipboard, base64-encodes the
bytes, sends them back in chunked DATA packets, terminated by status=DONE.
It travels transparently through SSH because it's just bytes on the PTY.

[2]: https://sw.kovidgoyal.net/kitty/clipboard/

Whether kitty is willing to satisfy the request depends on the
`clipboard_control` config. Default is `read-clipboard-ask` which prompts
the user. Set it to `read-clipboard` to just allow it.

So for kitty, the fix is straightforward: write an `xclip` that speaks OSC
5522. PATH-shadow the real one. Claude doesn't know the difference.

### Race protection

There's an annoying race. Claude Code is reading the PTY in raw mode in its
event loop. We spawn `xclip` (our shim) as a subprocess. Our shim opens
`/dev/tty` and writes the OSC. kitty responds — but the bytes go to *whoever
reads the PTY first*. That's often Claude's main loop, not us.

You can't fix this from a subprocess in general — see the upstream issue —
but you can mostly fix it for this specific case by stopping the parent
during the OSC exchange:

```python
def freeze_parents():
    # Walk /proc/*/stat for processes sharing our tty_nr.
    # SIGSTOP each ancestor (and any sibling worker sharing the tty).
    # SIGCONT after we're done.
```

The `tty_nr` filter matters — sshd has its own tty and we'd be wedged if we
stopped it. With the SIGSTOP in place, kitty's reply goes only to us.

### TARGETS / fetch caching

Empirically kitty doesn't love being asked twice for the same paste. Claude
calls `xclip -t TARGETS -o` then `xclip -t image/png -o`. The second
ad-hoc call against kitty would return `OK + DONE` with no data. So we
fetch *everything* during the TARGETS pass and write each MIME to a small
cache directory, served on the follow-up call:

```
$XDG_RUNTIME_DIR/xclip-shim-<uid>/
  image_png
  text_plain
  .ts            # mtime is the cache freshness signal
```

60-second TTL. Cheap and reliable.

### Don't probe for TIFF

macOS screenshots come on the clipboard as both PNG and TIFF. Asking for
TIFF in the MIME probe means kitty ships ~1.7 MB of uncompressed pixel data
over the PTY. SSH PTYs are slow enough to push the round-trip past
usable. Just request PNG, JPEG, GIF, etc.

That's kitty. Worked end-to-end. Image attached. Vision model described it
correctly. Good times.

## Then ghostty

ghostty also has OSC 5522 support — [ghostty-org/ghostty#12030][3]. It's
implemented differently in a way that matters.

[3]: https://github.com/ghostty-org/ghostty/pull/12030

In ghostty, OSC 5522 is **per-paste authenticated**:

1. The TUI app sends `CSI ? 5522 h` to enable mode 5522.
2. When the user pastes (only then), ghostty unsolicited sends a packet:
   ```
   ESC ] 5522 ; type=read:status=OK:password=<b64 16 random bytes> ESC \
   ESC ] 5522 ; type=read:status=DATA:mime=<b64 mime1> ESC \
   ESC ] 5522 ; type=read:status=DATA:mime=<b64 mime2> ESC \
   ESC ] 5522 ; type=read:status=DONE ESC \
   ```
3. The app has 5 seconds to fire back
   `OSC 5522; type=read:mime=<b64>:password=<b64> ST` to fetch one MIME.
4. ghostty validates the password (timing-safe), streams the bytes, then
   invalidates it. Single-use.

Without a password, reads return `ENOSYS`. There's a `// TODO: implement
non-password-authenticated reads with user prompt` in `src/Surface.zig`
that punts the unauthenticated path.

The security model is nice. It scopes capability to a specific paste action
the user just performed. A random subprocess can't just slurp the clipboard.

But it also means our shim approach is structurally wrong:

- The shim runs *after* Claude was told to paste.
- By then, ghostty has already delivered the password packet... to Claude's
  stdin. Claude doesn't speak OSC 5522, so the bytes get discarded as noise.
- Five seconds later the password expires. Game over.

You can't fix this with the shim alone. Someone has to be reading stdin
*at paste time*, and that someone has to understand the protocol.

## The wrapper

The someone is a PTY proxy:

```
[ghostty] ←tty→ [claude-wrap] ←pty→ [real claude]
```

`claude-wrap` is a small Python program that:

1. Forks `claude` into a new pseudo-terminal (`pty.fork()`).
2. Sends `CSI ? 5522 h` to the outer terminal (ghostty), so it switches to
   the OSC 5522 paste mode.
3. Sits in a `select()` loop forwarding bytes in both directions.
4. **On the inbound direction (ghostty → claude), it sniffs for OSC 5522
   packets** and runs a three-state machine:
   - IDLE → COLLECTING_PASTE on `status=OK:password=...`
   - COLLECTING_PASTE accumulates `status=DATA:mime=...` advertisements
   - On `status=DONE`, picks the best MIME (PNG > JPEG > GIF > ...) and
     immediately fires the `type=read:mime=...:password=...` request back
     at ghostty.
   - AWAITING_DATA collects the data chunks. On `status=DONE`, base64-decodes
     and writes to the cache directory.
5. **And then — this is the load-bearing trick — sends `\x16` (Ctrl+V) to
   Claude's PTY.**

Why Ctrl+V? Because that's Claude's paste keybinding. I initially tried
synthesizing bracketed-paste sequences (`\x1b[200~...\x1b[201~`) with
various bodies — empty, a single space, a fake file path. Claude treated
all of them as text input. The bracketed-paste path does NOT trigger
Claude's xclip flow. The paste *keystroke* does.

After the Ctrl+V, Claude runs the normal xclip dance. Our shim sees the
cache is fresh (we just wrote to it 100ms ago), and serves the bytes.
Claude attaches the image. The model sees it.

### State machine details

A few things worth pointing out:

- We use the `password=` field to disambiguate between ghostty (sends
  password) and kitty (doesn't). Kitty also has a mode 5522 paste-event
  feature, but the OK packet has no password.
- The data response from ghostty starts with its own `status=OK` (just an
  ACK, no password). The state machine ignores that — it's only
  meaningful in IDLE.
- The password timeout (5s) is enforced on our side too. If the data
  response doesn't come back, we send an empty bracketed paste so Claude
  doesn't hang waiting.
- The proxy holds a small buffer for partial OSCs spanning multiple reads.
  Big payloads come in dozens of chunks and you can't rely on each
  `read()` to land on an OSC boundary.

## Unifying kitty and ghostty

Once the wrapper worked for ghostty, I noticed kitty's mode 5522 also
sends paste-event packets. Same overall shape, just no password. So I
refactored:

- The wrapper handles both — password if present, passwordless otherwise.
- The shim shrunk from ~500 lines to ~170. It's now just argv parsing
  plus "dump from cache." No SIGSTOP. No `id=` matching. No race
  protection. The wrapper already won that race.

Two terminals, one mechanism, one tiny shim that's basically `cat`.

## Things that fought me

- **The kitty `clipboard_control = read-clipboard-ask` popup**. The first
  paste timed out at 2s because the popup blocked round-trip longer than
  that. Bumping the timeout fixed it; turning off `-ask` made it
  invisible.
- **Focus-out events (`\x1b[O`) and mouse-tracking bytes**. The popup
  steals focus, and those events arrive in the same buffer as our OSC
  response. Without an `id=` field on the request, my idle-timeout
  heuristic kept thinking the focus event was the start of the real
  response and exiting too soon.
- **Stale responses from previous requests**. When a request times out,
  kitty was still going to send the data. The bytes would land in the
  next subprocess's buffer. The `id=` field in the OSC 5522 metadata
  sorts this out — every request includes a fresh random id and we
  filter responses against it.
- **Bracketed paste isn't a paste**. I assumed for too long that
  synthesizing `\x1b[200~...\x1b[201~` would make Claude check xclip.
  No, that's just text input. The actual trigger is the Ctrl+V *key*.

## Where it doesn't work yet

- The wrapper holds Claude in a PTY. Some terminal escape sequences may
  not pass through perfectly. I haven't seen breakage in practice but
  it's a real risk.
- ghostty's password is single-use, so the wrapper has to pick exactly
  one MIME to fetch per paste. If you have an image + URL on your
  clipboard, only the image comes through.
- `xclip -i` (clipboard write) falls back to OSC 52, which is text-only.
  No image-write support. Claude Code doesn't seem to need it.
- The whole thing depends on Ctrl+V being Claude Code's paste keybinding
  ([documented here](https://code.claude.com/docs/en/interactive-mode)).
  If Anthropic ever changes it, the wrapper needs the keystroke updated.

## Closing

The interesting architectural takeaway is the **trust model split**:

- kitty grants an *ambient capability* — once `clipboard_control` is set,
  any app over SSH can read the clipboard whenever.
- ghostty grants a *scoped capability* — only in response to a specific
  user action, only once, only for 5 seconds.

ghostty's model is the more secure one. It also makes third-party
integration much harder, because you have to be in the dataflow at the
moment of the user gesture, not at the moment of the API call. The PTY
wrapper exists precisely to bridge that gap for an app that doesn't
speak the protocol itself.

The fix would be either (1) Claude Code speaks the protocol natively, or
(2) ghostty implements the "unauthenticated reads with user prompt" path
its TODO mentions. Either eliminates the wrapper entirely. Until then,
the wrapper works fine.
