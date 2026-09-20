// SPDX-FileCopyrightText: © 2026 mindfulmonk <mindfulmonk@users.noreply.github.com>
// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! A raw OSC 52 / OSC 5522 sender and receiver, with no claude involved.
//!
//!     ccssh-probe 52
//!         Ask for the text clipboard over OSC 52 and decode the reply.
//!
//!     ccssh-probe 5522 [mime,mime,...] [save-prefix]
//!         Ask for clipboard data over OSC 5522 -- kitty's passwordless
//!         form, so this exercises kitty rather than ghostty -- reassemble
//!         the chunked reply per MIME type, and optionally write each to
//!         `<prefix>.<mime with the slash as an underscore>`.
//!
//!     ccssh-probe raw '<bytes>'
//!         Send arbitrary bytes and hexdump whatever comes back. `\xNN`,
//!         `\e`, `\n`, `\r`, `\t` and `\\` are understood.
//!
//! Everything goes to `/dev/tty` in raw mode, so it works with stdout piped.

const std = @import("std");
const ccssh = @import("ccssh");
const common = @import("common.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;

const usage =
    \\usage: ccssh-probe 52
    \\       ccssh-probe 5522 [mime,mime,...] [save-prefix]
    \\       ccssh-probe raw '<bytes with \xNN escapes>'
    \\
;

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();

    const argv = try init.minimal.args.toSlice(arena);

    var err_buf: [4096]u8 = undefined;
    var err = Io.File.stderr().writerStreaming(io, &err_buf);
    defer err.interface.flush() catch {};

    if (argv.len < 2) {
        try err.interface.writeAll(usage);
        return 2;
    }

    var tty = try common.Tty.open();
    defer tty.close();

    const mode = argv[1];
    if (std.mem.eql(u8, mode, "52")) {
        return probe52(io, gpa, &tty, &err.interface);
    } else if (std.mem.eql(u8, mode, "5522")) {
        const mimes: []const u8 = if (argv.len > 2) argv[2] else "image/png";
        const prefix: ?[]const u8 = if (argv.len > 3) argv[3] else null;
        return probe5522(io, gpa, &tty, &err.interface, mimes, prefix);
    } else if (std.mem.eql(u8, mode, "raw")) {
        if (argv.len < 3) {
            try err.interface.writeAll(usage);
            return 2;
        }
        const bytes = try unescape(arena, argv[2]);
        tty.write(bytes);
        const resp = try common.drain(io, gpa, tty.fd, .{});
        defer gpa.free(resp);
        try err.interface.print("\r\n<-- {d} bytes\r\n", .{resp.len});
        try common.hexdump(&err.interface, resp, 512);
        return 0;
    }

    try err.interface.print("unknown mode: {s}\r\n{s}", .{ mode, usage });
    return 2;
}

fn probe52(io: Io, gpa: Allocator, tty: *common.Tty, w: *Io.Writer) !u8 {
    tty.write("\x1b]52;c;?\x1b\\");
    const resp = try common.drain(io, gpa, tty.fd, .{});
    defer gpa.free(resp);

    try w.print("\r\n<-- {d} bytes\r\n", .{resp.len});
    try common.hexdump(w, resp, 512);

    var it: common.OscIterator = .{ .buf = resp };
    while (it.next()) |osc| {
        // Strip the ESC ] and the terminator to get at "52;c;<base64>".
        const body = oscBody(osc);
        if (!std.mem.startsWith(u8, body, "52;")) continue;
        var parts = std.mem.splitScalar(u8, body, ';');
        _ = parts.next(); // "52"
        _ = parts.next(); // selection
        const b64 = parts.rest();
        const text = ccssh.b64DecodeAlloc(gpa, b64) catch |e| {
            try w.print("  base64 decode failed: {t}\r\n", .{e});
            continue;
        };
        defer gpa.free(text);
        try w.print("  clipboard text: \"{f}\"\r\n", .{std.zig.fmtString(text)});
    }
    return 0;
}

fn probe5522(
    io: Io,
    gpa: Allocator,
    tty: *common.Tty,
    w: *Io.Writer,
    mime_list: []const u8,
    save_prefix: ?[]const u8,
) !u8 {
    // kitty takes a space-separated list of types, base64'd as one blob.
    const blob = try gpa.dupe(u8, mime_list);
    defer gpa.free(blob);
    for (blob) |*ch| {
        if (ch.* == ',') ch.* = ' ';
    }
    const b64 = try ccssh.b64EncodeAlloc(gpa, blob);
    defer gpa.free(b64);

    var req: std.ArrayList(u8) = .empty;
    defer req.deinit(gpa);
    try req.print(gpa, "\x1b]5522;type=read;{s}\x1b\\", .{b64});
    try w.print("\r\n--> {d} bytes requesting: {s}\r\n", .{ req.items.len, blob });
    tty.write(req.items);

    const resp = try common.drain(io, gpa, tty.fd, .{});
    defer gpa.free(resp);
    try w.print("<-- {d} bytes\r\n", .{resp.len});

    // Accumulate the chunked payload per MIME type.
    var by_mime: std.StringArrayHashMapUnmanaged(std.ArrayList(u8)) = .empty;
    defer {
        for (by_mime.keys()) |k| gpa.free(k);
        for (by_mime.values()) |*v| v.deinit(gpa);
        by_mime.deinit(gpa);
    }
    var chunks: usize = 0;

    var it: common.OscIterator = .{ .buf = resp };
    while (it.next()) |osc| {
        const packet = ccssh.parse5522(osc) orelse continue;
        const status = packet.field("status") orelse "";
        if (!std.mem.eql(u8, status, "DATA")) {
            try w.print("  status: {s}\r\n", .{packet.meta});
            continue;
        }
        const payload = packet.payload orelse continue;
        const m64 = packet.field("mime") orelse "";
        const mime = ccssh.b64DecodeAlloc(gpa, m64) catch continue;
        const raw = ccssh.b64DecodeAlloc(gpa, payload) catch {
            gpa.free(mime);
            continue;
        };
        defer gpa.free(raw);
        chunks += 1;

        const entry = try by_mime.getOrPut(gpa, mime);
        if (entry.found_existing) gpa.free(mime) else entry.value_ptr.* = .empty;
        try entry.value_ptr.appendSlice(gpa, raw);
    }

    try w.print("--- {d} DATA chunks, {d} MIME types\r\n", .{ chunks, by_mime.count() });
    for (by_mime.keys(), by_mime.values()) |mime, buf| {
        try w.print("    {s}: {d} bytes\r\n", .{ mime, buf.items.len });
        const prefix = save_prefix orelse continue;
        const safe = try ccssh.mimeToFileName(gpa, mime);
        defer gpa.free(safe);
        const path = try std.fmt.allocPrint(gpa, "{s}.{s}", .{ prefix, safe });
        defer gpa.free(path);
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = buf.items });
        try w.print("      -> saved {s}\r\n", .{path});
    }
    return 0;
}

/// The payload of an OSC sequence: no introducer, no terminator.
fn oscBody(osc: []const u8) []const u8 {
    var body = osc[ccssh.osc_introducer.len..];
    if (std.mem.endsWith(u8, body, ccssh.st)) {
        body = body[0 .. body.len - ccssh.st.len];
    } else if (std.mem.endsWith(u8, body, ccssh.bel)) {
        body = body[0 .. body.len - ccssh.bel.len];
    }
    return body;
}

/// Turn the backslash escapes a shell will not produce into real bytes, so
/// an escape sequence can be given on the command line.
fn unescape(arena: Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] != '\\' or i + 1 >= s.len) {
            try out.append(arena, s[i]);
            continue;
        }
        i += 1;
        switch (s[i]) {
            'e' => try out.append(arena, 0x1b),
            'n' => try out.append(arena, '\n'),
            'r' => try out.append(arena, '\r'),
            't' => try out.append(arena, '\t'),
            'a' => try out.append(arena, 0x07),
            '\\' => try out.append(arena, '\\'),
            'x' => {
                if (i + 2 >= s.len) return error.BadEscape;
                try out.append(arena, try std.fmt.parseUnsigned(u8, s[i + 1 ..][0..2], 16));
                i += 2;
            },
            else => return error.BadEscape,
        }
    }
    return out.toOwnedSlice(arena);
}

test "unescape understands the escapes the usage promises" {
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectEqualStrings("\x1b]52;c;?\x1b\\", try unescape(arena, "\\e]52;c;?\\e\\\\"));
    try std.testing.expectEqualStrings("\x00\xff", try unescape(arena, "\\x00\\xff"));
    try std.testing.expectError(error.BadEscape, unescape(arena, "\\q"));
}

test "oscBody strips both terminators" {
    try std.testing.expectEqualStrings("52;c;QQ==", oscBody("\x1b]52;c;QQ==\x1b\\"));
    try std.testing.expectEqualStrings("52;c;QQ==", oscBody("\x1b]52;c;QQ==\x07"));
}

test "reference every declaration so lazy analysis cannot hide a broken one" {
    std.testing.refAllDecls(@This());
}
