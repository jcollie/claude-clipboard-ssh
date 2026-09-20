// SPDX-FileCopyrightText: © 2026 mindfulmonk <mindfulmonk@users.noreply.github.com>
// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Dump every byte the terminal sends on a paste.
//!
//! Run it, paste, then press Enter. It hexdumps what arrived and points out
//! the markers that matter. This is how you find out what trigger a TUI
//! application actually expects -- it is what established that Claude Code
//! responds to the Ctrl+V keystroke and not to a synthesised bracketed
//! paste.

const std = @import("std");
const common = @import("common.zig");

const Io = std.Io;

const markers = [_]struct { bytes: []const u8, name: []const u8 }{
    .{ .bytes = "\x1b[200~", .name = "bracketed-paste start" },
    .{ .bytes = "\x1b[201~", .name = "bracketed-paste end" },
    .{ .bytes = "\x1b]5522", .name = "OSC 5522" },
    .{ .bytes = "\x1b]52;", .name = "OSC 52" },
    .{ .bytes = "\x16", .name = "Ctrl+V" },
};

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;

    var tty = try common.Tty.open();
    defer tty.close();

    tty.say("Ready. Paste, then press Enter to dump and exit.", .{});

    const captured = try common.drain(io, gpa, tty.fd, .{
        .first_byte_ms = 60_000,
        // Long enough that a slow clipboard dialog does not look like the
        // end of the paste.
        .idle_ms = 2_000,
    });
    defer gpa.free(captured);

    var out_buf: [64 * 1024]u8 = undefined;
    var out = Io.File.stderr().writerStreaming(io, &out_buf);
    const w = &out.interface;

    try w.print("\r\n=== {d} bytes captured ===\r\n", .{captured.len});
    try common.hexdump(w, captured, 4096);

    for (markers) |m| {
        if (std.mem.indexOf(u8, captured, m.bytes)) |at|
            try w.print("  found {s} at offset {d}\r\n", .{ m.name, at });
    }
    try w.flush();
    return 0;
}

test "reference every declaration so lazy analysis cannot hide a broken one" {
    std.testing.refAllDecls(@This());
}
