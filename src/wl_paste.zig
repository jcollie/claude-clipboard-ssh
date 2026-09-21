// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! A drop-in `wl-paste` that serves from the same cache as the `xclip` stub.
//!
//! Shadowing `xclip` alone is not enough. Claude Code probes with either
//! `xclip -t TARGETS -o` or `wl-paste -l` depending on what it finds, and
//! its image fetch is a chain -- `wl-paste --type image/png ... || xclip
//! -selection clipboard -t image/bmp ... || wl-paste --type ...` -- so
//! whichever tool it reaches for has to answer from the same place. A real
//! `wl-paste` on the remote box has no Wayland display to ask and fails,
//! which is indistinguishable from an empty clipboard and quietly bypasses
//! the cache the wrapper just filled.
//!
//! Only what Claude Code actually invokes is implemented: `-l`, `--type`,
//! bare (text), `-n` and `-p`.

const std = @import("std");
const ccssh = @import("ccssh");

const Io = std.Io;

const usage =
    \\wl-paste-stub (cache server for claude-wrap)
    \\  -n, --no-newline      Do not append a newline character.
    \\  -l, --list-types      Instead of pasting, list the offered types.
    \\  -p, --primary         Use the "primary" clipboard.
    \\  -t, --type mime/type  Override the inferred MIME type.
    \\
;

const Args = struct {
    list: bool = false,
    no_newline: bool = false,
    primary: bool = false,
    help: bool = false,
    mime: ?[]const u8 = null,
};

fn parseArgs(argv: []const []const u8) Args {
    var r: Args = .{};
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "-l") or std.mem.eql(u8, a, "--list-types")) {
            r.list = true;
        } else if (std.mem.eql(u8, a, "-n") or std.mem.eql(u8, a, "--no-newline")) {
            r.no_newline = true;
        } else if (std.mem.eql(u8, a, "-p") or std.mem.eql(u8, a, "--primary")) {
            r.primary = true;
        } else if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help") or
            std.mem.eql(u8, a, "-v") or std.mem.eql(u8, a, "--version"))
        {
            r.help = true;
        } else if (std.mem.eql(u8, a, "-t") or std.mem.eql(u8, a, "--type")) {
            i += 1;
            if (i < argv.len) r.mime = argv[i];
        } else if (std.mem.startsWith(u8, a, "--type=")) {
            r.mime = a["--type=".len..];
        } else if (std.mem.eql(u8, a, "-s") or std.mem.eql(u8, a, "--seat") or
            std.mem.eql(u8, a, "-w") or std.mem.eql(u8, a, "--watch"))
        {
            i += 1; // takes an argument we have no use for
        }
    }
    return r;
}

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const env = init.environ_map;

    var log = ccssh.Logger.init(io, gpa, env, "xclip-shim.log");
    defer log.deinit();

    const argv = try init.minimal.args.toSlice(arena);
    const args = parseArgs(argv);

    var out_buf: [64 * 1024]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(io, &out_buf);

    if (args.help) {
        try stdout.interface.writeAll(usage);
        try stdout.interface.flush();
        return 0;
    }

    // Real wl-paste exits 1 when nothing suitable has been copied, which is
    // what the `||` chains in Claude Code are testing for.
    var cache = (try ccssh.Cache.open(io, gpa, env)) orelse {
        log.print("wl-paste: cache stale or missing; deferring to the real one", .{});
        try ccssh.execRealTool(io, arena, env, "wl-paste", argv);
        return 1;
    };
    defer cache.close(io);

    if (args.list) {
        const mimes = try cache.listMimes(io, gpa);
        defer {
            for (mimes) |m| gpa.free(m);
            gpa.free(mimes);
        }
        if (mimes.len == 0) return 1;
        for (mimes) |m| try stdout.interface.print("{s}\n", .{m});
        try stdout.interface.flush();
        log.print("wl-paste -l: {d} entries", .{mimes.len});
        return 0;
    }

    // With no --type, real wl-paste pastes the text representation.
    const mime = args.mime orelse "text/plain";
    const data = (try cache.read(io, gpa, mime)) orelse {
        log.print("wl-paste: no cache entry for {s}", .{mime});
        return 1;
    };
    defer gpa.free(data);

    try stdout.interface.writeAll(data);
    // Real wl-paste appends a newline to text unless told not to, and never
    // to anything else -- a stray byte on a PNG would corrupt it.
    const is_text = std.mem.startsWith(u8, ccssh.baseMime(mime), "text/");
    if (is_text and !args.no_newline and !std.mem.endsWith(u8, data, "\n"))
        try stdout.interface.writeByte('\n');
    try stdout.interface.flush();

    log.print("wl-paste served {s}: {d} bytes", .{ mime, data.len });
    return 0;
}

test "parseArgs covers what Claude Code invokes" {
    const list = [_][]const u8{ "wl-paste", "-l" };
    try std.testing.expect(parseArgs(&list).list);

    const png = [_][]const u8{ "wl-paste", "--type", "image/png" };
    try std.testing.expectEqualStrings("image/png", parseArgs(&png).mime.?);

    const joined = [_][]const u8{ "wl-paste", "--type=image/bmp" };
    try std.testing.expectEqualStrings("image/bmp", parseArgs(&joined).mime.?);

    const bare = [_][]const u8{"wl-paste"};
    const b = parseArgs(&bare);
    try std.testing.expect(!b.list and b.mime == null and !b.no_newline);

    const trimmed = [_][]const u8{ "wl-paste", "-n", "-p" };
    const t = parseArgs(&trimmed);
    try std.testing.expect(t.no_newline and t.primary);
}

test "reference every declaration so lazy analysis cannot hide a broken one" {
    std.testing.refAllDecls(@This());
}
