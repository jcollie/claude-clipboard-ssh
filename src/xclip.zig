// SPDX-FileCopyrightText: © 2026 mindfulmonk <mindfulmonk@users.noreply.github.com>
// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! A drop-in `xclip` that serves from the cache `claude-wrap` writes.
//!
//! Claude Code reads the clipboard on Linux by shelling out: first
//! `xclip -selection clipboard -t TARGETS -o` to discover what is on offer,
//! then `-t <mime> -o` for the bytes. Over SSH the real xclip has no display
//! to ask. This answers both out of `$XDG_RUNTIME_DIR/xclip-shim-<uid>/`,
//! which the wrapper has just filled by doing the OSC 5522 exchange with the
//! terminal on the user's own machine.
//!
//! It contains no OSC 5522 logic of its own -- by the time Claude Code asks,
//! the user gesture that authorised the read is long over. That race is the
//! whole reason the wrapper exists.
//!
//! Clipboard *writes* (`-i`) have no cache to go through and fall back to
//! OSC 52 over `/dev/tty`, which is text-only.

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
    const args = ccssh.parseXclipArgs(argv);

    var out_buf: [64 * 1024]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(io, &out_buf);

    if (args.help) {
        try stdout.interface.writeAll("xclip-stub (cache server for claude-wrap)\n");
        try stdout.interface.flush();
        return 0;
    }

    if (args.action == .in) {
        try ccssh.execRealTool(io, arena, env, "xclip", argv);
        const data = try ccssh.readAllStdin(io, gpa);
        defer gpa.free(data);
        log.print("clipboard write: {d} bytes via OSC 52", .{data.len});
        try ccssh.writeOsc52ToTty(gpa, data, args.selection);
        return 0;
    }

    var cache = (try ccssh.Cache.open(io, gpa, env)) orelse {
        // Nothing cached: hand over to the real xclip if this machine has
        // one, rather than confidently reporting an empty clipboard and
        // steering Claude Code away from a clipboard that works.
        log.print("cache stale or missing; deferring to the real xclip", .{});
        try ccssh.execRealTool(io, arena, env, "xclip", argv);
        return 1;
    };
    defer cache.close(io);

    if (std.mem.eql(u8, args.target, "TARGETS")) {
        const mimes = try cache.listMimes(io, gpa);
        defer {
            for (mimes) |m| gpa.free(m);
            gpa.free(mimes);
        }
        // The shape real xclip uses: the pseudo-targets first, then the X11
        // text aliases if there is any text, then the types themselves.
        try stdout.interface.writeAll("TARGETS\nTIMESTAMP\nMULTIPLE\n");
        for (mimes) |m| {
            if (std.mem.eql(u8, m, "text/plain")) {
                try stdout.interface.writeAll("UTF8_STRING\nSTRING\nTEXT\n");
                break;
            }
        }
        for (mimes) |m| try stdout.interface.print("{s}\n", .{m});
        try stdout.interface.flush();
        log.print("TARGETS: {d} entries", .{mimes.len});
        return 0;
    }

    const mime = ccssh.targetToMime(args.target);
    const data = (try cache.read(io, gpa, mime)) orelse {
        log.print("no cache entry for {s}", .{mime});
        return 1;
    };
    defer gpa.free(data);

    log.print("served {s}: {d} bytes", .{ mime, data.len });
    try stdout.interface.writeAll(data);
    try stdout.interface.flush();
    return 0;
}

test "reference every declaration so lazy analysis cannot hide a broken one" {
    std.testing.refAllDecls(@This());
}
