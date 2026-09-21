<!--
SPDX-FileCopyrightText: © 2026 mindfulmonk <mindfulmonk@users.noreply.github.com>
SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
SPDX-License-Identifier: MIT
-->

# claude-clipboard-ssh

Image paste over SSH for Claude Code, by speaking
[OSC 5522](https://sw.kovidgoyal.net/kitty/clipboard/) to kitty or ghostty on
the user's local machine. No patches to Claude Code itself.

This is a Zig port of [mindfulmonk/claude-clipboard-ssh][upstream], which
worked out the protocol and the architecture; see [`BLOG.md`](BLOG.md) for
that write-up. The port adds Nix packaging, a test suite, and an install
layout that does not require the `xclip` stub to shadow the real one
system-wide.

[upstream]: https://github.com/mindfulmonk/claude-clipboard-ssh

## What this is

Claude Code shells out to `xclip` to read the system clipboard on Linux. That
works locally, but over SSH there is no display server on the remote box and
the paste silently fails. Upstream
[claude-code#42712](https://github.com/anthropics/claude-code/issues/42712)
tracks it; it is closed as "not planned".

Two programs work around it:

- **`claude-wrap`** — a pty proxy around `claude`. It enables `CSI ? 5522 h`
  on the outer terminal, intercepts the OSC 5522 paste-event packets that
  ghostty and kitty send, fetches the clipboard data, writes it to a cache
  directory, and then sends Ctrl+V to the inner `claude` so its normal
  clipboard flow fires.
- **`xclip`, `wl-paste`, `wl-copy`** — drop-in stubs that serve from that
  cache. `claude-wrap` puts their directory at the front of the `PATH` it
  hands the child, so they shadow the real tools for Claude Code and for
  nothing else — and only when the wrapper is actually bridging.

  All three, not just `xclip`: Claude Code probes with either
  `xclip -t TARGETS -o` or `wl-paste -l` depending on what it finds, and its
  image fetch is a chain across both. Shadowing one lets it take a path that
  bypasses the cache and concludes the clipboard is empty.

Together they let you paste screenshots into a `claude` session running over
SSH.

## Install

### With Nix

```sh
nix profile install github:jcollie/claude-clipboard-ssh
```

or as a flake input, with `packages.<system>.claude-clipboard-ssh`. The
package installs `bin/claude-wrap` and
`libexec/claude-clipboard-ssh/xclip`. Nothing shadows the system `xclip`:
the stub is not on your `PATH`, only on the one `claude` is given.

### With home-manager

The flake exposes `homeModules.default`, which installs the two programs and
wires them to `programs.claude-code`. Enable it in the home configuration of
any machine you run `claude` on, whether that is over SSH or local.

```nix
{
  inputs.claude-clipboard-ssh.url = "github:jcollie/claude-clipboard-ssh";

  # ... in your home configuration:
  imports = [ inputs.claude-clipboard-ssh.homeModules.default ];

  programs.claude-code.enable = true;
  programs.claude-clipboard-ssh.enable = true;
}
```

That is the whole configuration. `claude-wrap` is told to run exactly the
`claude` that `programs.claude-code` installed, by way of its
`finalPackage` — so the wrapper does not have to guess, which is otherwise
the fragile part: left alone it searches `~/.local/share/claude/versions`,
`~/.claude/local` and then the `PATH`. `claude` is also aliased to
`claude-wrap` in every enabled shell, which is safe as a blanket alias
because the wrapper `exec`s straight through on a terminal without OSC 5522.

| Option | Default | |
| --- | --- | --- |
| `enable` | `false` | |
| `package` | this flake's | The package to install. |
| `claudePackage` | `pkgs.claude-code` | Where to find `claude` when `programs.claude-code` installs none. Not added to `home.packages`. |
| `claudeBin` | from the above | The `claude` to run, exported as `CLAUDE_WRAP_CLAUDE_BIN`. `null` lets the wrapper search. |
| `installAsClaude` | `false` | Install the wrapper *as* `claude`; see below. |
| `aliasClaude` | `!installAsClaude` | Alias `claude` to `claude-wrap` in bash, zsh and fish. |
| `kittyClipboardControl` | `false` | Set kitty's `clipboard_control` to allow reads without a prompt. Only meaningful on the machine you sit at. |

#### Keeping the unwrapped `claude` off the PATH

An alias only covers interactive shells. A script, a `command claude`, a
non-interactive shell — each reaches the real binary and skips the bridge.
`installAsClaude` closes that off: the `claude` on your PATH becomes the
wrapper, and the unwrapped binary is reachable only by store path.

```nix
programs.claude-code = {
  enable = true;
  package = null;          # manage the config, install nothing on PATH
  settings.theme = "auto";
};

programs.claude-clipboard-ssh = {
  enable = true;
  installAsClaude = true;  # `claude` on PATH is the wrapper
};
```

`programs.claude-code` still writes settings, agents, commands and MCP
servers; it just stops adding its own `claude` alongside the wrapper's, which
would leave the winner up to the order of two profile directories. Setting
`package = null` is required rather than forced, so the module says what is
wrong instead of quietly overriding what you wrote. `claudePackage` (default
`pkgs.claude-code`) is what the wrapper then runs, by absolute path.

The wrapper refuses to exec anything that resolves to itself, so being on the
PATH under the name it searches for cannot make it recurse.

If `programs.claude-code` is not installing a package — it is nullable, for
people who use it only to write settings — the module says so as a warning
and leaves the wrapper to search. Set `claudeBin` to be explicit instead.

### From source

```sh
git clone https://github.com/jcollie/claude-clipboard-ssh.git
cd claude-clipboard-ssh
nix develop -c zig build
```

Other clone URLs are in [Where this lives](#where-this-lives).

`zig-out/bin/claude-wrap` finds its stub relative to its own location, so the
build tree can be run in place. To install by hand, copy both programs into
one directory — `claude-wrap` falls back to looking beside itself:

```sh
mkdir -p ~/.local/bin
cp zig-out/bin/claude-wrap ~/.local/bin/
cp zig-out/libexec/claude-clipboard-ssh/* ~/.local/bin/
```

That layout does put fake clipboard tools on your own `PATH`, which is why
the Nix package does not use it.

### On a macOS remote

Nothing extra. Claude Code on darwin reads images from the NSPasteboard with
`osascript` rather than shelling out to `xclip`, so `claude-wrap` writes
pasted images straight there and the stub is never consulted.

### Terminal configuration

Recommended on the machine you are sitting at, to silence kitty's
per-paste confirmation dialog. In `~/.config/kitty/kitty.conf`:

```
clipboard_control write-clipboard write-primary read-clipboard read-primary
```

Without it kitty prompts on every paste, and a slow prompt can push the round
trip past ghostty's five-second password lifetime.

## Usage

SSH into the remote box from kitty or ghostty, then:

```sh
claude-wrap
```

It passes every argument through to `claude`. On a terminal that does not
implement OSC 5522 it `exec`s `claude` directly and adds no pty and no
overhead, so it is safe to alias:

```sh
alias claude=claude-wrap
```

Paste a screenshot the way you would locally. It attaches.

### Which key pastes

With `claude-wrap` running, both work: the terminal's own paste shortcut
(`Ctrl+Shift+V` on Linux, `Cmd+V` on macOS) and Claude Code's `Ctrl+V`.
Making those agree everywhere is most of the point of the wrapper.

Without it, only `Ctrl+V` does. The reason is worth knowing, because it is
what a broken setup looks like:

- The terminal's shortcut asks the *terminal* to paste, and a terminal pastes
  **text**. With only an image on the clipboard there is no text, so nothing
  is written and Claude Code never learns a paste happened. (ghostty marks
  its binding `performable`, so the keystroke does then pass through — but as
  `Ctrl+Shift+V`, which Claude Code does not read as a paste.)
- `Ctrl+V` is unbound in the terminal, so it reaches Claude Code, which reads
  the clipboard itself.

With the wrapper, mode 5522 changes the first case: the terminal turns its
paste shortcut into a paste *event* instead of pasting text, the wrapper
answers it, and then sends Claude Code a `Ctrl+V` of its own. So the shortcut
you already have muscle memory for is the one that works.

### Environment

| Variable | Effect |
| --- | --- |
| `CLAUDE_WRAP_CLAUDE_BIN` | Use this `claude` instead of searching for one. |
| `CLAUDE_CLIPBOARD_SHIM_DIR` | Use this directory for the `xclip` stub. |
| `CLAUDE_WRAP_DISABLE` | Do not bridge; `exec` `claude` unchanged. |
| `XDG_RUNTIME_DIR` | Where the clipboard cache lives (resolved via known-folders). |
| `XDG_STATE_HOME` | Where `claude-wrap.log` and `xclip-shim.log` are appended. |

## Architecture

```
[kitty OR ghostty]  <--tty-->  [claude-wrap]  <--pty-->  [real claude]
                                   | writes bytes
                                   v
                          $XDG_RUNTIME_DIR/xclip-shim-<uid>/
                                   ^
                                   | reads bytes
                    [xclip / wl-paste stubs]  <-- claude shells out
```

ghostty's OSC 5522 is per-paste authenticated: when the user pastes, the
terminal hands the foreground application a single-use password and gives it
five seconds to ask for the bytes. An application that does not speak the
protocol, and shells out to `xclip` some time later, cannot participate —
by then the password is gone. So something has to be reading stdin at the
moment of the gesture, which is what the proxy is for. kitty's version of the
protocol has the same shape without the password, so one mechanism covers
both terminals.

Ctrl+V, not a synthesised bracketed paste, is what makes Claude Code go and
read the clipboard; bracketed paste is treated as ordinary text input.

## Development

```sh
nix develop            # zig 0.16, reuse, zon2nix
zig build              # all five programs into zig-out
zig build test         # unit tests and the scanner property test
zig build check        # compile everything without running it
zig build fmt          # zig fmt --check
reuse lint             # licensing compliance
```

`zig build` also produces three debug tools in `zig-out/bin`, which the Nix
package deliberately does not install:

- `ccssh-probe` — raw OSC 52 / OSC 5522 sender and receiver, no `claude`.
- `ccssh-ghostty-test` — the paste exchange in isolation; writes what it
  fetches to a file.
- `ccssh-dump-paste` — hexdumps every byte the terminal sends on a paste.

Zig dependencies are declared in `build.zig.zon` and mirrored for Nix in
`build.zig.zon.nix`. Regenerate the latter after any dependency change:

```sh
nix develop -c zon2nix --16 --nix=build.zig.zon.nix build.zig.zon
```

## Compatibility

- Linux and macOS remotes, x86-64 and aarch64.
- **No C library dependency on Linux.** `posix_openpt`, `grantpt`,
  `unlockpt` and `ptsname` are not system calls — each is a short libc
  function around an `open` and one or two ioctls, and the programs issue
  those ioctls themselves. The Linux binaries are therefore static and can
  be copied to a remote box that has nothing installed. (Darwin still links
  libSystem, because its syscall ABI is private and that is the only
  supported way in.)
- kitty out of the box.
- ghostty 1.3.x and later, which ships the kitty clipboard protocol and
  registers mode 5522 as `kitty_paste_events`. (An earlier
  [PR #12030](https://github.com/ghostty-org/ghostty/pull/12030) was closed
  unmerged; the feature arrived separately.) ghostty's `clipboard-read`
  defaults to `ask`, but a paste event carries a one-time password, so the
  follow-up read is granted without a prompt.
- Any other terminal: falls back to `exec`ing `claude`.

**The wrapper engages whenever the terminal speaks OSC 5522**, local or
remote, because the alternative is the same keystroke behaving differently
depending on where `claude` happens to be running. `CLAUDE_WRAP_DISABLE=1`
turns it off.

What makes that safe is that every failure path still lands the paste. Mode
5522 stops the terminal sending pasted text, so a bridge that gives up
silently loses it. Instead the wrapper invalidates its cache and sends Claude
Code a `Ctrl+V`, which makes Claude Code run its own clipboard read — and the
stubs hand over to the real `xclip` or `wl-paste` when the cache has nothing
to say. So on a local session a paste the bridge could not handle is still
served, by the clipboard that was there all along.

## Known limitations

- **Depends on Ctrl+V being Claude Code's paste binding**, which is
  [documented behavior](https://code.claude.com/docs/en/interactive-mode).
  If that changes, the wrapper needs the keystroke updated. See the note
  above on why the terminal's own paste shortcut is not the same thing.
- **No image write.** `xclip -i` and `wl-copy` fall back to OSC 52, which is
  text-only. Claude Code does not appear to need image writes.
- **One MIME type per paste in ghostty**, because the password is single-use.
  An image beats a URL if both are on the clipboard.
- **No tmux or screen support.** OSC 5522 does not pass through a
  multiplexer's byte filter by default.

## Where this lives

The same history, in four places. GitHub is where the CI runs and where
issues and pull requests are read.

| | |
| --- | --- |
| GitHub | <https://github.com/jcollie/claude-clipboard-ssh> |
| Forgejo | <https://git.jcollie.dev/jeff/claude-clipboard-ssh> |
| Tangled | <https://tangled.org/jcollie.dev/claude-clipboard-ssh> |
| Radicle | `rad:z2GK8VisdkuFiMErcbvp8wGyRWoKW` |

```sh
git clone https://github.com/jcollie/claude-clipboard-ssh.git
git clone https://git.jcollie.dev/jeff/claude-clipboard-ssh.git
rad clone rad:z2GK8VisdkuFiMErcbvp8wGyRWoKW
```

A Radicle repository is findable only by its ID, so the line above is the
one thing a reader needs in order to seed or clone it.

## License

MIT. See [`LICENSES/MIT.txt`](LICENSES/MIT.txt). The project follows the
[REUSE](https://reuse.software/) specification; `reuse lint` passes.

Copyright © 2026 mindfulmonk and Jeffrey C. Ollie.

## References cited

- Anthropic. *Interactive mode*. Claude Code documentation.
  <https://code.claude.com/docs/en/interactive-mode>. Documents Ctrl+V as the
  paste binding, which is the keystroke `claude-wrap` synthesizes.
- Free Software Foundation Europe. *REUSE Specification, Version 3.3*. 2024.
  <https://reuse.software/spec-3.3/>.
- Goyal, Kovid. *Copying all data types to the clipboard*. kitty
  documentation. <https://sw.kovidgoyal.net/kitty/clipboard/>. The OSC 5522
  protocol definition.
- Jarred-Sumner. "terminal: implement kitty clipboard protocol read path (OSC
  5522)." *ghostty* pull request 12030, 1 April 2026.
  <https://github.com/ghostty-org/ghostty/pull/12030>. Closed unmerged; the
  feature reached ghostty by another route.
- MichielMAnalytics. "Support OSC 52/5522 clipboard for image paste over SSH."
  *claude-code* issue 42712, 2 April 2026.
  <https://github.com/anthropics/claude-code/issues/42712>. Closed as not
  planned; the reason this project exists.
- mindfulmonk. *claude-clipboard-ssh*. GitHub, 23 May 2026.
  <https://github.com/mindfulmonk/claude-clipboard-ssh>. The Python original
  this project is a port of.
- ziglibs. *known-folders: access to well-known folders across several
  operating systems*. GitHub.
  <https://github.com/ziglibs/known-folders>.

These are held in the Zotero collection `claude-clipboard-ssh`.
