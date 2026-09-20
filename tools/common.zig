// SPDX-FileCopyrightText: © 2026 mindfulmonk <mindfulmonk@users.noreply.github.com>
// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Shared plumbing for the debug tools.
//!
//! These all do the same thing: take over `/dev/tty` in raw mode, write an
//! escape sequence at it, and report what comes back. They go to the tty
//! directly rather than through stdin/stdout so that they still work with
//! their output piped somewhere.

const std = @import("std");
const ccssh = @import("ccssh");

const posix = std.posix;
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// The controlling terminal, in raw mode, restored on `close`.
pub const Tty = struct {
    fd: posix.fd_t,
    raw: ?ccssh.pty.RawMode,

    pub fn open() !Tty {
        const fd = ccssh.sys.open("/dev/tty", .{ .ACCMODE = .RDWR, .NOCTTY = true }, 0) catch
            return error.NoControllingTerminal;
        return .{ .fd = fd, .raw = ccssh.pty.RawMode.enable(fd) catch null };
    }

    pub fn close(t: *Tty) void {
        if (t.raw) |r| r.restore();
        ccssh.sys.close(t.fd);
        t.* = undefined;
    }

    pub fn write(t: Tty, bytes: []const u8) void {
        ccssh.writeAllFd(t.fd, bytes) catch {};
    }

    /// Write to the terminal with CRLF line endings, since raw mode has
    /// turned off the output processing that would otherwise supply the CR.
    pub fn say(t: Tty, comptime fmt: []const u8, args: anytype) void {
        var buf: [1024]u8 = undefined;
        var w: Io.Writer = .fixed(&buf);
        w.print("\r\n" ++ fmt ++ "\r\n", args) catch return;
        t.write(w.buffered());
    }
};

pub const DrainOptions = struct {
    /// How long to wait for the terminal to say anything at all. Generous,
    /// because a clipboard-permission dialog on the user's machine happens
    /// inside this window.
    first_byte_ms: i32 = 30_000,
    /// Once bytes are flowing, a gap this long means the reply is over.
    idle_ms: i32 = 1_000,
    /// Absolute cap, whatever else happens.
    hard_ms: i64 = 60_000,
};

/// Read until the terminal stops talking. Caller owns the returned memory.
pub fn drain(io: Io, gpa: Allocator, fd: posix.fd_t, opts: DrainOptions) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);

    const start = Io.Clock.awake.now(io).nanoseconds;
    var chunk: [64 * 1024]u8 = undefined;

    while (true) {
        const elapsed_ms = @divTrunc(Io.Clock.awake.now(io).nanoseconds - start, std.time.ns_per_ms);
        if (elapsed_ms >= opts.hard_ms) break;

        const wait: i32 = if (buf.items.len > 0) opts.idle_ms else opts.first_byte_ms;
        var fds = [_]posix.pollfd{.{ .fd = fd, .events = posix.POLL.IN, .revents = 0 }};
        const ready = posix.poll(&fds, wait) catch break;
        if (ready == 0) break; // timed out: idle, or never answered

        const n = posix.read(fd, &chunk) catch break;
        if (n == 0) break;
        try buf.appendSlice(gpa, chunk[0..n]);
    }
    return buf.toOwnedSlice(gpa);
}

/// Classic 16-bytes-per-row hexdump, CRLF-terminated for a raw terminal.
pub fn hexdump(w: *Io.Writer, bytes: []const u8, max: usize) !void {
    const shown = bytes[0..@min(bytes.len, max)];
    var i: usize = 0;
    while (i < shown.len) : (i += 16) {
        const row = shown[i..@min(i + 16, shown.len)];
        try w.print("  {x:0>4}  ", .{i});
        for (row) |b| try w.print("{x:0>2} ", .{b});
        for (row.len..16) |_| try w.writeAll("   ");
        try w.writeAll(" ");
        for (row) |b| try w.writeByte(if (b >= 32 and b < 127) b else '.');
        try w.writeAll("\r\n");
    }
    if (bytes.len > shown.len) try w.print("  ... ({d} more bytes)\r\n", .{bytes.len - shown.len});
}

/// Iterate the complete OSC sequences in a buffer, ignoring anything else.
pub const OscIterator = struct {
    buf: []const u8,
    index: usize = 0,

    pub fn next(it: *OscIterator) ?[]const u8 {
        switch (ccssh.findCompleteOsc(it.buf, it.index)) {
            .complete => |span| {
                it.index = span.end;
                return it.buf[span.start..span.end];
            },
            else => return null,
        }
    }
};

test "hexdump renders a short row" {
    var buf: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try hexdump(&w, "AB\x00", 16);
    // offset, three bytes, padding out to sixteen columns, gap, ASCII.
    const expected = "  0000  " ++ "41 42 00 " ++ ("   " ** 13) ++ " " ++ "AB." ++ "\r\n";
    try std.testing.expectEqualStrings(expected, w.buffered());
}

test "OscIterator finds each complete sequence" {
    var it: OscIterator = .{ .buf = "x\x1b]5522;a\x1b\\y\x1b]52;c;Q\x07z" };
    try std.testing.expectEqualStrings("\x1b]5522;a\x1b\\", it.next().?);
    try std.testing.expectEqualStrings("\x1b]52;c;Q\x07", it.next().?);
    try std.testing.expect(it.next() == null);
}

test "reference every declaration so lazy analysis cannot hide a broken one" {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(Tty);
}
