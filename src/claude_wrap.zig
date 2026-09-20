// SPDX-FileCopyrightText: © 2026 mindfulmonk <mindfulmonk@users.noreply.github.com>
// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! A pty proxy that lets Claude Code paste images over SSH.
//!
//!     [kitty or ghostty] <--tty--> [claude-wrap] <--pty--> [real claude]
//!
//! ghostty's OSC 5522 is per-paste authenticated: when the user pastes, the
//! terminal hands the foreground application a single-use password and gives
//! it five seconds to ask for the bytes. An application that does not speak
//! the protocol -- and shells out to `xclip` some time later -- cannot
//! participate, because by then the password is gone. So something has to be
//! reading stdin at the moment of the gesture, and that something is this.
//!
//! On a paste it captures the password, picks the best MIME type on offer,
//! fetches it, writes the bytes where the `xclip` stub will find them, and
//! then sends `claude` a Ctrl+V. The keystroke, not a synthesised bracketed
//! paste, is what triggers Claude Code's clipboard read -- bracketed paste
//! is treated as ordinary text input.
//!
//! kitty's version of the protocol has the same shape without the password,
//! so one mechanism covers both terminals. On any other terminal the wrapper
//! execs `claude` directly and adds nothing at all.

const std = @import("std");
const builtin = @import("builtin");
const ccssh = @import("ccssh");
const pty = ccssh.pty;
const sys = ccssh.sys;

const posix = std.posix;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const native_os = builtin.os.tag;

/// Where the paste conversation is up to.
const State = enum {
    /// Waiting for a paste event.
    idle,
    /// Got the password (or noted its absence); collecting the advertised
    /// MIME types until DONE.
    collecting_paste,
    /// Asked for one MIME type; accumulating the chunked reply.
    awaiting_data,
};

/// The master descriptor, for the SIGWINCH handler. An atomic because the
/// handler can fire while the main flow is closing it.
var g_master_fd: std.atomic.Value(i32) = .init(-1);

/// `std.posix.poll` retries `EINTR` internally and never surfaces the
/// signal, so a flag checked by the loop would not be seen until the next
/// keystroke. Both ioctls are bare syscalls and async-signal-safe, so the
/// resize is simply done here.
fn onWinch(_: posix.SIG) callconv(.c) void {
    const master = g_master_fd.load(.acquire);
    if (master < 0) return;
    if (pty.getWinsize(posix.STDIN_FILENO)) |ws| pty.setWinsize(master, ws);
}

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const env = init.environ_map;

    var log = ccssh.Logger.init(io, gpa, env, "claude-wrap.log");
    defer log.deinit();

    const argv_vec: []const [*:0]const u8 = init.minimal.args.vector;

    const real = try findRealClaude(io, arena, env) orelse {
        try fail(io, "claude-wrap: cannot find the real claude binary\n");
        return 127;
    };
    log.print("real claude: {s}", .{real});

    // The stub has to be on the PATH `claude` searches, and ahead of any
    // real xclip. Prepending it here rather than installing it into a bin
    // directory is what keeps the shadowing scoped to this process tree.
    if (try ccssh.findShimDir(io, arena, env)) |shim_dir| {
        const old_path = env.get("PATH") orelse "";
        try env.put("PATH", try std.fmt.allocPrint(arena, "{s}:{s}", .{ shim_dir, old_path }));
        log.print("shim dir: {s}", .{shim_dir});
    } else {
        log.print("no shim dir found; image paste will not work", .{});
    }

    // Nothing to intercept on a terminal without OSC 5522, so get out of the
    // way completely rather than holding claude in a pty for no reason.
    if (!ccssh.isSupportedTerminal(env)) {
        log.print("not ghostty or kitty; exec'ing claude directly", .{});
        const slice_argv = try arena.alloc([]const u8, argv_vec.len);
        slice_argv[0] = real;
        for (argv_vec[1..], 1..) |a, i| slice_argv[i] = std.mem.span(a);
        const e = std.process.replace(io, .{ .argv = slice_argv, .environ_map = env });
        log.print("exec failed: {t}", .{e});
        return 127;
    }
    log.print("terminal: ghostty={} kitty={}", .{ ccssh.isGhostty(env), ccssh.isKitty(env) });

    // argv[0] becomes the real path; everything the user typed passes through.
    const child_argv = try arena.allocSentinel(?[*:0]const u8, argv_vec.len, null);
    child_argv[0] = real.ptr;
    for (argv_vec[1..], 1..) |a, i| child_argv[i] = a;

    const envp_block = try env.createPosixBlock(gpa, .{});
    defer envp_block.deinit(gpa);

    const child = try pty.forkExec(real.ptr, child_argv.ptr, envp_block.slice.ptr);
    g_master_fd.store(child.master, .release);
    log.print("forked claude pid={d}", .{child.pid});

    if (pty.getWinsize(posix.STDIN_FILENO)) |ws| pty.setWinsize(child.master, ws);
    var winch: posix.Sigaction = .{
        .handler = .{ .handler = onWinch },
        .mask = posix.sigemptyset(),
        .flags = posix.SA.RESTART,
    };
    posix.sigaction(posix.SIG.WINCH, &winch, null);

    // From here on the terminal is ours, so every exit path has to hand it
    // back -- including the ones the Python left it raw on.
    const raw: ?pty.RawMode = pty.RawMode.enable(posix.STDIN_FILENO) catch null;
    defer if (raw) |r| r.restore();

    ccssh.writeAllFd(posix.STDOUT_FILENO, "\x1b[?5522h") catch {};
    log.print("enabled mode 5522", .{});
    // Leaving mode 5522 on would surprise whatever runs in this terminal next.
    defer ccssh.writeAllFd(posix.STDOUT_FILENO, "\x1b[?5522l") catch {};

    proxy(io, gpa, env, &log, child.master) catch |e| log.print("proxy ended: {t}", .{e});

    g_master_fd.store(-1, .release);
    sys.close(child.master);

    return reap(child.pid);
}

fn fail(io: Io, msg: []const u8) !void {
    var buf: [256]u8 = undefined;
    var w = Io.File.stderr().writerStreaming(io, &buf);
    try w.interface.writeAll(msg);
    try w.interface.flush();
}

/// Wait for `claude` and take its exit status as our own.
fn reap(pid: posix.pid_t) u8 {
    const status = sys.waitpid(pid) catch return 0; // already reaped
    if (posix.W.IFEXITED(status)) return @intCast(posix.W.EXITSTATUS(status));
    return 1;
}

// ------------------------------------------------------- finding claude

/// Locate the real `claude`.
///
/// The versioned install directories come first, newest version wins, then a
/// PATH scan that skips our own directory so a wrapper installed as `claude`
/// cannot find itself.
///
/// Caller owns the returned memory (an arena, in practice).
fn findRealClaude(io: Io, arena: Allocator, env: *const std.process.Environ.Map) !?[:0]const u8 {
    if (env.get("CLAUDE_WRAP_CLAUDE_BIN")) |p| {
        if (p.len > 0) return try arena.dupeZ(u8, p);
    }

    if (env.get("HOME")) |home| {
        const roots = [_][]const u8{ ".local/share/claude/versions", ".claude/local" };
        for (roots) |rel| {
            const dirpath = try std.fs.path.join(arena, &.{ home, rel });
            if (try newestExecutableIn(io, arena, dirpath)) |p| return p;
        }
    }

    var self_buf: [std.fs.max_path_bytes]u8 = undefined;
    const self_dir: ?[]const u8 = blk: {
        const n = std.process.executableDirPath(io, &self_buf) catch break :blk null;
        break :blk self_buf[0..n];
    };

    const path = env.get("PATH") orelse return null;
    var it = std.mem.splitScalar(u8, path, ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        if (self_dir) |sd| if (std.mem.eql(u8, dir, sd)) continue;
        const cand = try std.fs.path.joinZ(arena, &.{ dir, "claude" });
        if (isExecutableFile(io, cand)) return cand;
    }
    return null;
}

/// The newest-versioned executable *file* in a directory of version
/// directories, or null.
///
/// Two things the Python got wrong: it sorted the names lexicographically,
/// so `0.9.10` lost to `0.9.9`, and it accepted a directory as a candidate
/// because `os.access(dir, X_OK)` is true for directories.
fn newestExecutableIn(io: Io, arena: Allocator, dirpath: []const u8) !?[:0]const u8 {
    var dir = Io.Dir.cwd().openDir(io, dirpath, .{ .iterate = true }) catch return null;
    defer dir.close(io);

    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(arena);

    var it = dir.iterate();
    while (try it.next(io)) |e| try names.append(arena, try arena.dupe(u8, e.name));

    std.mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return ccssh.compareVersionNames(a, b) == .lt;
        }
    }.lessThan);

    var i = names.items.len;
    while (i > 0) {
        i -= 1;
        const cand = try std.fs.path.joinZ(arena, &.{ dirpath, names.items[i] });
        if (isExecutableFile(io, cand)) return cand;
    }
    return null;
}

/// A regular file with an execute bit set.
///
/// This is a mode check rather than `access(X_OK)`, which is a libc call
/// and not a syscall of its own. The difference only shows on a file the
/// caller cannot actually execute despite the bit being set -- someone
/// else's `0o700` binary -- and the exec that follows reports that anyway.
/// The `kind` test is the part that matters: the Python accepted a
/// *directory* here, because `os.access` says a directory is executable.
fn isExecutableFile(io: Io, path: [:0]const u8) bool {
    const st = Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    if (st.kind != .file) return false;
    if (!@TypeOf(st.permissions).has_executable_bit) return true;
    return st.permissions.toMode() & 0o111 != 0;
}

// ------------------------------------------------------------- the proxy

/// Forward bytes both ways, intercepting OSC 5522 on the way in.
///
/// Output is passed through verbatim. Input is scanned for complete OSC
/// sequences: ours are consumed and drive the state machine, everything else
/// -- including other OSCs -- reaches `claude` untouched. A sequence split
/// across two reads is held back in `in_buf` until the rest arrives, which
/// matters because a large paste arrives in dozens of chunks and no read
/// lands on a packet boundary.
fn proxy(
    io: Io,
    gpa: Allocator,
    env: *const std.process.Environ.Map,
    log: *const ccssh.Logger,
    master: posix.fd_t,
) !void {
    var paste: Paste = .{ .gpa = gpa };
    defer paste.deinit();

    var in_buf: std.ArrayList(u8) = .empty;
    defer in_buf.deinit(gpa);
    var fwd: std.ArrayList(u8) = .empty;
    defer fwd.deinit(gpa);

    var rbuf: [64 * 1024]u8 = undefined;

    while (true) {
        var timeout_ms: i32 = -1;
        if (paste.state == .awaiting_data) {
            const now = Io.Clock.awake.now(io).nanoseconds;
            if (now >= paste.deadline) {
                // Tell claude something rather than leaving it waiting.
                log.print("data response timed out; abandoning paste", .{});
                paste.reset();
                ccssh.writeAllFd(master, "\x1b[200~\x1b[201~") catch {};
                continue;
            }
            timeout_ms = @intCast(@divTrunc(paste.deadline - now, std.time.ns_per_ms) + 1);
        }

        var fds = [_]posix.pollfd{
            .{ .fd = posix.STDIN_FILENO, .events = posix.POLL.IN, .revents = 0 },
            .{ .fd = master, .events = posix.POLL.IN, .revents = 0 },
        };
        _ = posix.poll(&fds, timeout_ms) catch continue;

        // claude -> terminal, verbatim. HUP and ERR as well as IN, or the
        // loop spins once the child has exited.
        const hangup = posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR;
        if (fds[1].revents & hangup != 0) {
            const n = posix.read(master, &rbuf) catch return;
            if (n == 0) return;
            ccssh.writeAllFd(posix.STDOUT_FILENO, rbuf[0..n]) catch return;
        }

        // terminal -> claude, filtered.
        if (fds[0].revents & hangup != 0) {
            const n = posix.read(posix.STDIN_FILENO, &rbuf) catch return;
            if (n == 0) return;
            try in_buf.appendSlice(gpa, rbuf[0..n]);

            fwd.clearRetainingCapacity();
            var cursor: usize = 0;
            scan: while (cursor < in_buf.items.len) {
                switch (ccssh.findCompleteOsc(in_buf.items, cursor)) {
                    .none => {
                        try fwd.appendSlice(gpa, in_buf.items[cursor..]);
                        cursor = in_buf.items.len;
                    },
                    .partial => |start| {
                        try fwd.appendSlice(gpa, in_buf.items[cursor..start]);
                        cursor = start;
                        break :scan;
                    },
                    .complete => |span| {
                        try fwd.appendSlice(gpa, in_buf.items[cursor..span.start]);
                        const osc = in_buf.items[span.start..span.end];
                        cursor = span.end;
                        const packet = ccssh.parse5522(osc) orelse {
                            try fwd.appendSlice(gpa, osc); // someone else's OSC
                            continue :scan;
                        };
                        try paste.handle(io, env, log, master, packet);
                    },
                }
            }
            if (fwd.items.len > 0) ccssh.writeAllFd(master, fwd.items) catch return;

            // Carry the unparsed tail forward. The ranges overlap, so this
            // cannot be @memcpy.
            const rest = in_buf.items.len - cursor;
            std.mem.copyForwards(u8, in_buf.items[0..rest], in_buf.items[cursor..]);
            in_buf.shrinkRetainingCapacity(rest);
        }
    }
}

/// The paste state machine.
const Paste = struct {
    gpa: Allocator,
    state: State = .idle,
    /// Present for ghostty, absent for kitty -- which is how the two are
    /// told apart, since the packets are otherwise the same shape.
    password: ?[]u8 = null,
    mimes: std.ArrayList([]u8) = .empty,
    data: std.ArrayList(u8) = .empty,
    mime: ?[]u8 = null,
    deadline: i96 = 0,

    fn deinit(p: *Paste) void {
        p.clear();
        p.mimes.deinit(p.gpa);
        p.data.deinit(p.gpa);
    }

    fn clear(p: *Paste) void {
        if (p.password) |v| p.gpa.free(v);
        p.password = null;
        if (p.mime) |v| p.gpa.free(v);
        p.mime = null;
        for (p.mimes.items) |m| p.gpa.free(m);
        p.mimes.clearRetainingCapacity();
        p.data.clearRetainingCapacity();
    }

    fn reset(p: *Paste) void {
        p.clear();
        p.state = .idle;
        p.deadline = 0;
    }

    fn handle(
        p: *Paste,
        io: Io,
        env: *const std.process.Environ.Map,
        log: *const ccssh.Logger,
        master: posix.fd_t,
        packet: ccssh.Packet,
    ) !void {
        const status = packet.field("status") orelse "";
        const gpa = p.gpa;

        switch (p.state) {
            .idle => {
                if (!std.mem.eql(u8, status, "OK")) return;
                p.clear();
                if (packet.field("password")) |pw| p.password = try gpa.dupe(u8, pw);
                log.print("paste event; password={}", .{p.password != null});
                p.state = .collecting_paste;
            },

            .collecting_paste => {
                if (std.mem.eql(u8, status, "DATA")) {
                    const m64 = packet.field("mime") orelse return;
                    const m = ccssh.b64DecodeAlloc(gpa, m64) catch |e| {
                        log.print("undecodable mime advertisement: {t}", .{e});
                        return;
                    };
                    try p.mimes.append(gpa, m);
                    return;
                }
                if (!std.mem.eql(u8, status, "DONE")) return;

                const idx = ccssh.chooseMime(p.mimes.items) orelse {
                    log.print("no usable MIME type offered", .{});
                    ccssh.writeAllFd(master, "\x1b[200~\x1b[201~") catch {};
                    p.reset();
                    return;
                };
                const chosen = p.mimes.items[idx];
                log.print("requesting {s}", .{chosen});
                try sendReadRequest(gpa, chosen, p.password);
                p.mime = try gpa.dupe(u8, chosen);
                p.data.clearRetainingCapacity();
                p.deadline = Io.Clock.awake.now(io).nanoseconds + ccssh.data_response_timeout_ns;
                p.state = .awaiting_data;
            },

            .awaiting_data => {
                // The data response opens with its own OK, which is only an
                // acknowledgement -- the password came with the paste event.
                if (std.mem.eql(u8, status, "OK")) return;

                if (std.mem.eql(u8, status, "DATA")) {
                    if (packet.payload) |chunk| try p.data.appendSlice(gpa, chunk);
                    return;
                }

                if (std.mem.eql(u8, status, "DONE")) {
                    const mime = p.mime orelse "";
                    const raw = ccssh.b64DecodeAlloc(gpa, p.data.items) catch |e| {
                        log.print("undecodable clipboard payload: {t}", .{e});
                        ccssh.writeAllFd(master, "\x1b[200~\x1b[201~") catch {};
                        p.reset();
                        return;
                    };
                    defer gpa.free(raw);
                    log.print("received {d} bytes of {s}", .{ raw.len, mime });

                    cacheWrite(io, gpa, env, mime, raw) catch |e|
                        log.print("cache write failed: {t}", .{e});

                    if (std.mem.startsWith(u8, ccssh.baseMime(mime), "text/")) {
                        // Text goes in as a real bracketed paste.
                        ccssh.writeAllFd(master, "\x1b[200~") catch {};
                        ccssh.writeAllFd(master, raw) catch {};
                        ccssh.writeAllFd(master, "\x1b[201~") catch {};
                    } else {
                        if (native_os == .macos)
                            loadMacClipboard(io, gpa, raw, mime, log) catch {};
                        // Ctrl+V: the keystroke is what makes Claude Code go
                        // and read the clipboard. A bracketed paste would
                        // just be typed in as text.
                        ccssh.writeAllFd(master, "\x16") catch {};
                    }
                    p.reset();
                    return;
                }

                // EPERM, ENOSYS, EBUSY, EIO, EINVAL -- the paste is not happening.
                log.print("terminal refused the read: {s}", .{status});
                ccssh.writeAllFd(master, "\x1b[200~\x1b[201~") catch {};
                p.reset();
            },
        }
    }
};

/// Ask the terminal for one MIME type. ghostty wants the password in the
/// metadata; kitty takes the base64 type as the payload and has no password.
fn sendReadRequest(gpa: Allocator, mime: []const u8, password: ?[]const u8) !void {
    const m64 = try ccssh.b64EncodeAlloc(gpa, mime);
    defer gpa.free(m64);

    var seq: std.ArrayList(u8) = .empty;
    defer seq.deinit(gpa);
    if (password) |pw| {
        try seq.print(gpa, "\x1b]5522;type=read:mime={s}:password={s}\x1b\\", .{ m64, pw });
    } else {
        try seq.print(gpa, "\x1b]5522;type=read;{s}\x1b\\", .{m64});
    }
    ccssh.writeAllFd(posix.STDOUT_FILENO, seq.items) catch {};
}

/// Replace the cache with exactly what this paste produced. Everything else
/// is removed first, so a stale entry from an earlier paste can never be
/// served alongside a fresh one.
fn cacheWrite(
    io: Io,
    gpa: Allocator,
    env: *const std.process.Environ.Map,
    mime: []const u8,
    data: []const u8,
) !void {
    // Store under the base type: the stub looks up `text/plain`, and an
    // entry called `text/plain;charset=utf-8` is one it can never find.
    // The full advertised string still goes on the wire, because that is
    // what the terminal offered us.
    const key = ccssh.baseMime(mime);

    const dirpath = try ccssh.cacheDirPath(io, gpa, env);
    defer gpa.free(dirpath);

    Io.Dir.cwd().createDirPath(io, dirpath) catch {};
    var dir = try Io.Dir.cwd().openDir(io, dirpath, .{ .iterate = true });
    defer dir.close(io);
    dir.setPermissions(io, .fromMode(0o700)) catch {};

    var it = dir.iterate();
    while (try it.next(io)) |e| dir.deleteFile(io, e.name) catch {};

    const name = try ccssh.mimeToFileName(gpa, key);
    defer gpa.free(name);
    try dir.writeFile(io, .{
        .sub_path = name,
        .data = data,
        .flags = .{ .permissions = .fromMode(0o600) },
    });
    // Written last: its mtime is what the stub checks, so it must not be
    // fresh before the payload beside it is complete.
    try dir.writeFile(io, .{
        .sub_path = ".ts",
        .data = "",
        .flags = .{ .permissions = .fromMode(0o600) },
    });
}

/// On a Mac remote, Claude Code reads images from the NSPasteboard with
/// osascript and never looks at the xclip cache, so put them there instead.
/// This does overwrite the remote Mac's clipboard, which on a box you are
/// ssh'd into is almost always what you want.
fn loadMacClipboard(
    io: Io,
    gpa: Allocator,
    data: []const u8,
    mime: []const u8,
    log: *const ccssh.Logger,
) !void {
    const base = ccssh.baseMime(mime);
    const flavor: []const u8 =
        if (std.mem.eql(u8, base, "image/png"))
            "\u{ab}class PNGf\u{bb}"
        else if (std.mem.eql(u8, base, "image/jpeg"))
            "\u{ab}class JPEG\u{bb}"
        else if (std.mem.eql(u8, base, "image/tiff"))
            "\u{ab}class TIFF\u{bb}"
        else {
            log.print("no pasteboard flavor for {s}", .{mime});
            return;
        };

    var name_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&name_buf, "/tmp/claude-wrap-paste-{d}.bin", .{sys.getpid()});
    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = path,
        .data = data,
        .flags = .{ .permissions = .fromMode(0o600) },
    });
    defer Io.Dir.cwd().deleteFile(io, path) catch {};

    const script = try std.fmt.allocPrint(
        gpa,
        "set the clipboard to (read POSIX file \"{s}\" as {s})",
        .{ path, flavor },
    );
    defer gpa.free(script);

    const res = std.process.run(gpa, io, .{
        .argv = &.{ "osascript", "-e", script },
        // ghostty's password expires at five seconds and we have already
        // spent some of that fetching; three is all this is worth waiting.
        .timeout = .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(3) } },
    }) catch |e| {
        log.print("osascript failed: {t}", .{e});
        return;
    };
    defer gpa.free(res.stdout);
    defer gpa.free(res.stderr);
    log.print("osascript: {any}", .{res.term});
}

test "reference every declaration so lazy analysis cannot hide a broken one" {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(Paste);
}
