// SPDX-FileCopyrightText: © 2026 mindfulmonk <mindfulmonk@users.noreply.github.com>
// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! The OSC 5522 paste exchange in isolation: no proxy, no pty, no claude.
//!
//! Enables mode 5522 on the controlling terminal, waits for a paste, takes
//! the password, asks for the best MIME type on offer and writes the bytes
//! to a file. If this works and `claude-wrap` does not, the problem is in
//! the wrapper rather than in the terminal.
//!
//!     ccssh-ghostty-test [output-path]        (default: ./ghostty-clip)

const std = @import("std");
const ccssh = @import("ccssh");
const common = @import("common.zig");

const Io = std.Io;

const overall_timeout_ms: i64 = 120_000;

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();

    const argv = try init.minimal.args.toSlice(arena);
    const out_path: []const u8 = if (argv.len > 1) argv[1] else "ghostty-clip";

    var tty = try common.Tty.open();
    defer tty.close();

    tty.write("\x1b[?5522h");
    defer tty.write("\x1b[?5522l");
    tty.say("Mode 5522 enabled. Paste something now.", .{});

    var password: ?[]u8 = null;
    defer if (password) |p| gpa.free(p);
    var mimes: std.ArrayList([]u8) = .empty;
    defer {
        for (mimes.items) |m| gpa.free(m);
        mimes.deinit(gpa);
    }
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(gpa);

    var state: enum { idle, collecting, awaiting } = .idle;
    const start = Io.Clock.awake.now(io).nanoseconds;

    while (true) {
        const elapsed = @divTrunc(Io.Clock.awake.now(io).nanoseconds - start, std.time.ns_per_ms);
        if (elapsed >= overall_timeout_ms) {
            tty.say("Timed out after {d}s.", .{@divTrunc(overall_timeout_ms, 1000)});
            return 1;
        }

        const chunk = try common.drain(io, gpa, tty.fd, .{ .first_byte_ms = 30_000, .idle_ms = 500 });
        defer gpa.free(chunk);
        if (chunk.len == 0) continue;

        var it: common.OscIterator = .{ .buf = chunk };
        while (it.next()) |osc| {
            const packet = ccssh.parse5522(osc) orelse continue;
            const status = packet.field("status") orelse "";

            switch (state) {
                .idle => {
                    if (!std.mem.eql(u8, status, "OK")) continue;
                    if (packet.field("password")) |pw| password = try gpa.dupe(u8, pw);
                    tty.say("paste event; password={}", .{password != null});
                    state = .collecting;
                },
                .collecting => {
                    if (std.mem.eql(u8, status, "DATA")) {
                        const m64 = packet.field("mime") orelse continue;
                        const m = ccssh.b64DecodeAlloc(gpa, m64) catch continue;
                        tty.say("  offered: {s}", .{m});
                        try mimes.append(gpa, m);
                    } else if (std.mem.eql(u8, status, "DONE")) {
                        const idx = ccssh.chooseMime(mimes.items) orelse {
                            tty.say("No usable MIME type on the clipboard.", .{});
                            return 1;
                        };
                        const chosen = mimes.items[idx];
                        tty.say("requesting {s}", .{chosen});
                        const m64 = try ccssh.b64EncodeAlloc(gpa, chosen);
                        defer gpa.free(m64);
                        var req: std.ArrayList(u8) = .empty;
                        defer req.deinit(gpa);
                        if (password) |pw| {
                            try req.print(gpa, "\x1b]5522;type=read:mime={s}:password={s}\x1b\\", .{ m64, pw });
                        } else {
                            try req.print(gpa, "\x1b]5522;type=read;{s}\x1b\\", .{m64});
                        }
                        tty.write(req.items);
                        state = .awaiting;
                    }
                },
                .awaiting => {
                    if (std.mem.eql(u8, status, "OK")) continue;
                    if (std.mem.eql(u8, status, "DATA")) {
                        if (packet.payload) |p| try data.appendSlice(gpa, p);
                    } else if (std.mem.eql(u8, status, "DONE")) {
                        const raw = try ccssh.b64DecodeAlloc(gpa, data.items);
                        defer gpa.free(raw);
                        try Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = raw });
                        tty.say("Saved {d} bytes to {s}", .{ raw.len, out_path });
                        return 0;
                    } else {
                        tty.say("Terminal refused the read: {s}", .{status});
                        return 1;
                    }
                },
            }
        }
    }
}

test "reference every declaration so lazy analysis cannot hide a broken one" {
    std.testing.refAllDecls(@This());
}
