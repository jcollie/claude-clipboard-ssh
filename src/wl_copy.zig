// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! A drop-in `wl-copy` that sets the clipboard over OSC 52.
//!
//! The counterpart to the `wl-paste` stub. Writes have no cache to go
//! through -- the wrapper does not intercept that direction -- so this does
//! what the `xclip -i` path does and hands the bytes to the terminal with
//! OSC 52, which is text-only. Claude Code does not appear to need image
//! writes.
//!
//! Without this, a `wl-copy` on the remote box either fails for want of a
//! display or, worse, succeeds against a clipboard nobody is looking at.

const std = @import("std");
const ccssh = @import("ccssh");

const Io = std.Io;

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const env = init.environ_map;

    var log = ccssh.Logger.init(io, gpa, env, "xclip-shim.log");
    defer log.deinit();

    const argv = try init.minimal.args.toSlice(arena);

    var primary = false;
    var clear = false;
    var trailing: std.ArrayList([]const u8) = .empty;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "-p") or std.mem.eql(u8, a, "--primary")) {
            primary = true;
        } else if (std.mem.eql(u8, a, "-c") or std.mem.eql(u8, a, "--clear")) {
            clear = true;
        } else if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help") or
            std.mem.eql(u8, a, "-v") or std.mem.eql(u8, a, "--version"))
        {
            var buf: [128]u8 = undefined;
            var out = Io.File.stdout().writerStreaming(io, &buf);
            try out.interface.writeAll("wl-copy-stub (OSC 52 writer for claude-wrap)\n");
            try out.interface.flush();
            return 0;
        } else if (std.mem.eql(u8, a, "-n") or std.mem.eql(u8, a, "--trim-newline") or
            std.mem.eql(u8, a, "-o") or std.mem.eql(u8, a, "--paste-once") or
            std.mem.eql(u8, a, "-f") or std.mem.eql(u8, a, "--foreground"))
        {
            // Accepted and irrelevant: OSC 52 has no notion of any of them.
        } else if (std.mem.eql(u8, a, "-t") or std.mem.eql(u8, a, "--type") or
            std.mem.eql(u8, a, "-s") or std.mem.eql(u8, a, "--seat"))
        {
            i += 1;
        } else if (!std.mem.startsWith(u8, a, "-")) {
            try trailing.append(arena, a);
        }
    }

    const selection: []const u8 = if (primary) "primary" else "clipboard";

    if (clear) {
        log.print("wl-copy: clearing {s}", .{selection});
        try ccssh.writeOsc52ToTty(gpa, "", selection);
        return 0;
    }

    // Text given as arguments, space-separated, else stdin -- the same
    // precedence real wl-copy uses.
    const data: []u8 = if (trailing.items.len > 0)
        try std.mem.join(gpa, " ", trailing.items)
    else
        try ccssh.readAllStdin(io, gpa);
    defer gpa.free(data);

    log.print("wl-copy: {d} bytes to {s} via OSC 52", .{ data.len, selection });
    try ccssh.writeOsc52ToTty(gpa, data, selection);
    return 0;
}

test "reference every declaration so lazy analysis cannot hide a broken one" {
    std.testing.refAllDecls(@This());
}
