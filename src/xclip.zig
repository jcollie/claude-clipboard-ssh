// SPDX-FileCopyrightText: © 2026 mindfulmonk <mindfulmonk@users.noreply.github.com>
// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! A drop-in `xclip` that serves from the cache `claude-wrap` writes.
//!
//! Claude Code reads the clipboard on Linux by shelling out to `xclip`:
//! first `-t TARGETS -o` to discover what is on offer, then `-t <mime> -o`
//! for the bytes. Over SSH the real xclip has no display to ask. This
//! program answers both calls out of `$XDG_RUNTIME_DIR/xclip-shim-<uid>/`,
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

const posix = std.posix;
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
        var in_buf: [64 * 1024]u8 = undefined;
        var stdin = Io.File.stdin().readerStreaming(io, &in_buf);
        const data = try stdin.interface.allocRemaining(gpa, .unlimited);
        defer gpa.free(data);
        log.print("clipboard write: {d} bytes via OSC 52", .{data.len});
        const fd = ccssh.sys.open("/dev/tty", .{ .ACCMODE = .WRONLY, .NOCTTY = true }, 0) catch return 0;
        defer ccssh.sys.close(fd);
        try ccssh.writeOsc52(gpa, fd, data, args.selection);
        return 0;
    }

    const dirpath = try ccssh.cacheDirPath(io, gpa, env);
    defer gpa.free(dirpath);

    if (!cacheFresh(io, dirpath)) {
        log.print("cache stale or missing at {s}", .{dirpath});
        return 1;
    }

    var dir = Io.Dir.cwd().openDir(io, dirpath, .{ .iterate = true }) catch {
        log.print("cannot open cache dir {s}", .{dirpath});
        return 1;
    };
    defer dir.close(io);

    if (std.mem.eql(u8, args.target, "TARGETS")) {
        try listTargets(io, gpa, &dir, &stdout.interface, &log);
        try stdout.interface.flush();
        return 0;
    }

    const mime = ccssh.targetToMime(args.target);
    const name = try ccssh.mimeToFileName(gpa, mime);
    defer gpa.free(name);

    const data = dir.readFileAlloc(io, name, gpa, .unlimited) catch {
        log.print("no cache entry for {s}", .{mime});
        return 1;
    };
    defer gpa.free(data);

    log.print("served {s}: {d} bytes", .{ mime, data.len });
    try stdout.interface.writeAll(data);
    try stdout.interface.flush();
    return 0;
}

/// Answer `-t TARGETS -o` with what the cache actually holds, in the shape
/// real xclip uses: the three pseudo-targets first, then the X11 text
/// aliases if there is any text, then the MIME types themselves.
fn listTargets(
    io: Io,
    gpa: std.mem.Allocator,
    dir: *Io.Dir,
    out: *Io.Writer,
    log: *const ccssh.Logger,
) !void {
    var mimes: std.ArrayList([]u8) = .empty;
    defer {
        for (mimes.items) |m| gpa.free(m);
        mimes.deinit(gpa);
    }

    var it = dir.iterate();
    while (try it.next(io)) |e| {
        // `.ts` is the freshness marker, not a payload.
        if (e.name.len == 0 or e.name[0] == '.') continue;
        const st = dir.statFile(io, e.name, .{}) catch continue;
        if (st.size == 0) continue;
        try mimes.append(gpa, try ccssh.fileNameToMime(gpa, e.name));
    }

    try out.writeAll("TARGETS\nTIMESTAMP\nMULTIPLE\n");
    for (mimes.items) |m| {
        if (std.mem.eql(u8, m, "text/plain")) {
            try out.writeAll("UTF8_STRING\nSTRING\nTEXT\n");
            break;
        }
    }
    for (mimes.items) |m| try out.print("{s}\n", .{m});

    log.print("TARGETS: {d} entries", .{mimes.items.len});
}

/// The wrapper touches `.ts` after every write; its mtime is the whole of
/// the freshness signal. Wall-clock, because that is what a file mtime is.
fn cacheFresh(io: Io, dirpath: []const u8) bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const ts = std.fmt.bufPrint(&buf, "{s}/.ts", .{dirpath}) catch return false;
    const st = Io.Dir.cwd().statFile(io, ts, .{}) catch return false;
    const now = Io.Clock.real.now(io).nanoseconds;
    return now - st.mtime.nanoseconds < ccssh.cache_ttl_ns;
}

test "reference every declaration so lazy analysis cannot hide a broken one" {
    std.testing.refAllDecls(@This());
}
