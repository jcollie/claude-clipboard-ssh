<!--
SPDX-FileCopyrightText: © 2026 mindfulmonk <mindfulmonk@users.noreply.github.com>
SPDX-License-Identifier: MIT
-->

Adding a data point from a third-party integration I built on top of this PR.

I wanted to make Claude Code's image-paste work when SSH'd from ghostty into
a Linux box. Claude Code shells out to `xclip` to read the clipboard, which
obviously can't reach the Mac side. With this PR's mode 5522 it's now
possible to bridge that gap — but the auth model means the bridge has to be
a PTY proxy sitting in front of the TUI, not a shim called by the TUI.

What I had to build:

- A small PTY-proxy that wraps `claude` and sends `CSI ? 5522 h` on startup.
- A state machine on stdin: when ghostty's `status=OK:password=<b64>` arrives,
  collect the advertised MIMEs, pick one (PNG preferred), fire
  `type=read:mime=...:password=...` back, accumulate the chunked data
  response.
- Cache the decoded bytes to disk.
- Synthesize a `\x16` (Ctrl+V) into the wrapped app's pty so it triggers its
  own xclip flow against an `xclip` shim that just serves the cache.

A few small things that came up in implementation that might be useful
feedback:

1. **The `// TODO: implement non-password-authenticated reads with user
   prompt` in `src/Surface.zig:6318` is the gap that forced the wrapper
   pattern.** Without that path, any app that doesn't natively speak OSC
   5522 (which is currently *every* app, until adoption picks up) can't
   participate at all. The PTY-proxy workaround works for `claude` because
   it's a TUI we can wrap, but it wouldn't compose for arbitrary CLI tools
   the user runs from their shell. The user-prompt path would unblock the
   simpler model where a tiny shim calls OSC 5522 directly without a
   capability token.

2. **The 5-second password timeout is correct per spec, and was easy to hit
   on slow SSH PTYs** when fetching multi-megabyte images. A 2 MB image in
   4 KB chunks is ~500 packets; over a throttled SSH PTY that can be more
   than 5 seconds wall-clock. We mitigate by picking exactly one preferred
   MIME (single-use means we can't fetch both PNG and TIFF anyway), but it
   might be worth either documenting the throughput consideration or
   raising the limit slightly when the kernel reports the channel is slow.

3. **Distinguishing the kitty and ghostty variants of the protocol** turned
   out to be cleanly doable from the wrapper's perspective: kitty's
   passwordless `status=OK` vs ghostty's `status=OK:password=<b64>`. That's
   a nice property of the field-based design — the same state machine
   handles both with a single conditional.

4. **For closed-source TUIs we don't control**, the wrapper has to invent
   a trigger to nudge the app into looking for the just-cached clipboard
   data. For Claude Code, that turned out to be the `\x16` (Ctrl+V)
   keystroke — bracketed-paste injection isn't enough, the app's paste
   *keybinding* is what triggers its xclip flow. Not a ghostty issue per
   se, just an interesting data point about how this PR's design interacts
   with the broader ecosystem.

Full source, write-up, and the standalone protocol probes I used for
debugging are at
[mindfulmonk/claude-clipboard-ssh](https://github.com/mindfulmonk/claude-clipboard-ssh).

For anyone who wants to try this PR before it's merged, a ghostty build
artifact from this branch is available at
[this CI run](https://github.com/mindfulmonk/ghostty/actions/runs/26341212311).

Excited to see this land. If the unauthenticated-with-prompt path gets
prioritized, the wrapper pattern goes away and integration gets a lot
simpler for the long tail of CLI tools.
