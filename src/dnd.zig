// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! The kitty drag-and-drop protocol, OSC 72: the parts a drop target needs.
//!
//! A program that declares its machine id with `t=a:x=1` and turns out to be
//! on another machine than the terminal -- which is to say, over SSH -- can
//! ask for the *contents* of the files dropped on it, not just their paths.
//! This file is the pure half of that: parsing packets and the text formats
//! they carry, naming things safely, and spelling a path for a paste. The
//! conversation itself is in `drop.zig`.
//!
//! Specification: https://sw.kovidgoyal.net/kitty/dnd-protocol/

const std = @import("std");
const builtin = @import("builtin");
const root = @import("root.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const Packet = root.Packet;

/// The OSC number.
pub const code = "72";

/// Parse a complete OSC sequence as an OSC 72 packet, or return null if it
/// is some other OSC.
pub fn parse72(osc: []const u8) ?Packet {
    return root.parseOsc(osc, code);
}

/// An integer metadata key. Every key in this protocol defaults to zero when
/// absent, and zero is a meaningful value for several of them -- `X=0` is a
/// regular file -- so absence and zero are deliberately the same answer.
pub fn intField(p: Packet, key: []const u8) error{InvalidInteger}!i32 {
    const v = p.field(key) orelse return 0;
    return std.fmt.parseInt(i32, v, 10) catch error.InvalidInteger;
}

/// The event type, `t`, which defaults to `a`.
pub fn eventType(p: Packet) u8 {
    const t = p.field("t") orelse return 'a';
    return if (t.len == 1) t[0] else 0;
}

/// The end of one reply is a packet with no payload. `m=0` alone is *not*
/// the end: a terminal hands its data over as it gets it, closing each piece
/// with `m=0`, and only the empty packet after the last piece says there is
/// no more.
pub fn isEnd(p: Packet) bool {
    const payload = p.payload orelse return true;
    return payload.len == 0;
}

/// Append one OSC 72 escape code to `out`.
pub fn appendCommand(gpa: Allocator, out: *std.ArrayList(u8), meta: []const u8, payload: ?[]const u8) !void {
    try out.appendSlice(gpa, root.osc_introducer ++ code ++ ";");
    try out.appendSlice(gpa, meta);
    if (payload) |p| {
        try out.append(gpa, ';');
        try out.appendSlice(gpa, p);
    }
    try out.appendSlice(gpa, root.st);
}

/// Append an OSC 72 escape code whose metadata is formatted.
pub fn appendCommandFmt(
    gpa: Allocator,
    out: *std.ArrayList(u8),
    comptime fmt: []const u8,
    args: anytype,
    payload: ?[]const u8,
) !void {
    var buf: [128]u8 = undefined;
    try appendCommand(gpa, out, try std.fmt.bufPrint(&buf, fmt, args), payload);
}

// ----------------------------------------------------------- text/uri-list

/// The URIs of a `text/uri-list` (RFC 2483).
///
/// File requests name a URI by its position in this list, so it has to be
/// split exactly the way the terminal splits it or every request asks for
/// the wrong file. kitty and ghostty both split on CR *or* LF, trim trailing
/// spaces and tabs, and skip blank lines and `#` comments, so this does too.
pub const UriList = struct {
    it: std.mem.TokenIterator(u8, .any),

    pub fn init(list: []const u8) UriList {
        return .{ .it = std.mem.tokenizeAny(u8, list, "\r\n") };
    }

    pub fn next(u: *UriList) ?[]const u8 {
        while (u.it.next()) |line| {
            const uri = std.mem.trimEnd(u8, line, " \t");
            if (uri.len == 0 or uri[0] == '#') continue;
            return uri;
        }
        return null;
    }
};

pub const PathError = error{
    /// Not a `file:` URI. It is pasted as it stands instead.
    NotFile,
    /// A `file:` URI without an absolute path, with a bad escape, or naming
    /// a path with a NUL in it.
    Invalid,
} || Allocator.Error;

/// The path a `file://` URI names, percent-decoded and without any query or
/// fragment. The host is ignored: on a local drop it names this machine, and
/// on a remote one it is the terminal's business, not ours.
///
/// Caller owns the returned memory.
pub fn filePath(gpa: Allocator, uri: []const u8) PathError![]u8 {
    const prefix = "file://";
    if (uri.len < prefix.len or !std.ascii.eqlIgnoreCase(uri[0..prefix.len], prefix))
        return error.NotFile;
    const rest = uri[prefix.len..];
    const slash = std.mem.findScalar(u8, rest, '/') orelse return error.Invalid;

    var encoded = rest[slash..];
    if (std.mem.findAny(u8, encoded, "?#")) |end| encoded = encoded[0..end];
    return percentDecode(gpa, encoded);
}

/// Undo `%XX` escapes. A NUL is rejected rather than decoded, since nothing
/// that contains one can be a path.
///
/// Caller owns the returned memory.
pub fn percentDecode(gpa: Allocator, encoded: []const u8) PathError![]u8 {
    var out: std.ArrayList(u8) = try .initCapacity(gpa, encoded.len);
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < encoded.len) {
        if (encoded[i] == '%') {
            if (i + 3 > encoded.len) return error.Invalid;
            const b = std.fmt.parseInt(u8, encoded[i + 1 ..][0..2], 16) catch return error.Invalid;
            out.appendAssumeCapacity(b);
            i += 3;
        } else {
            out.appendAssumeCapacity(encoded[i]);
            i += 1;
        }
    }
    if (std.mem.findScalar(u8, out.items, 0) != null) return error.Invalid;
    return out.toOwnedSlice(gpa);
}

// ------------------------------------------------------------- directories

/// The entries of a directory listing: names separated -- in practice,
/// each followed -- by a NUL.
///
/// Entries are requested by their one-based position in this list, so empty
/// pieces are still counted, not skipped: the trailing NUL makes one at the
/// end, and skipping a piece anywhere else would shift every request after
/// it onto the wrong entry. `safeName` is what turns the empty ones away.
pub const DirEntries = struct {
    it: std.mem.SplitIterator(u8, .scalar),
    index: i32 = 0,

    pub const Entry = struct { index: i32, name: []const u8 };

    pub fn init(listing: []const u8) DirEntries {
        return .{ .it = std.mem.splitScalar(u8, listing, 0) };
    }

    pub fn next(d: *DirEntries) ?Entry {
        const name = d.it.next() orelse return null;
        d.index += 1;
        return .{ .index = d.index, .name = name };
    }
};

/// A name the terminal gave us, if it is safe to create in a directory of
/// ours: one path component, and not one that climbs out. The terminal is
/// not an adversary, but a directory entry called `../../.bashrc` is still
/// not something to write wherever it says.
pub fn safeName(name: []const u8) ?[]const u8 {
    if (name.len == 0) return null;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return null;
    if (std.mem.findAny(u8, name, "/\x00") != null) return null;
    return name;
}

// --------------------------------------------------------------- pasting

/// Append a path to a paste, backslash-escaping what a shell would read
/// specially. The set is ghostty's own for a dropped file, so a drop that
/// came through the wrapper reads exactly like one that did not.
pub fn appendShellEscaped(gpa: Allocator, out: *std.ArrayList(u8), path: []const u8) !void {
    for (path) |b| {
        switch (b) {
            '\\', '"', '\'', '$', '`', '*', '?', ' ', '|', '(', ')' => try out.append(gpa, '\\'),
            else => {},
        }
        try out.append(gpa, b);
    }
}

// ------------------------------------------------------------- machine id

/// `1:` and the hex HMAC-SHA256 of the OS machine id, keyed with
/// `tty-dnd-protocol-machine-id`. The terminal compares it with its own to
/// decide whether we are on another machine, and only then serves the
/// contents of the dropped files.
pub const MachineId = [66]u8;

/// The machine id for a raw OS machine id. Trailing whitespace -- the
/// newline at the end of `/etc/machine-id` -- is not part of it.
pub fn machineId(raw: []const u8) MachineId {
    const Hmac = std.crypto.auth.hmac.sha2.HmacSha256;
    var mac: [Hmac.mac_length]u8 = undefined;
    Hmac.create(&mac, std.mem.trimEnd(u8, raw, &std.ascii.whitespace), "tty-dnd-protocol-machine-id");
    var id: MachineId = undefined;
    id[0..2].* = "1:".*;
    id[2..].* = std.fmt.bytesToHex(mac, .lower);
    return id;
}

/// What a terminal must read as "some other machine": it does not know
/// version 0, and the specification says an unknown version is a mismatch.
/// Sent when the real id cannot be read, so a drop over SSH still fetches
/// the files. The cost is that a local drop fetches them too, which is
/// slower but no less correct.
pub const unknown_machine_id = "0:unknown";

/// This machine's id as the protocol spells it, or `unknown_machine_id`.
///
/// Caller owns the returned memory.
pub fn localMachineId(io: Io, gpa: Allocator) ![]u8 {
    var buf: [256]u8 = undefined;
    const raw: ?[]const u8 = switch (builtin.os.tag) {
        .macos => try macPlatformUuid(io, gpa, &buf),
        else => linuxMachineId(io, &buf),
    };
    if (raw) |r| {
        const id = machineId(r);
        return gpa.dupe(u8, &id);
    }
    return gpa.dupe(u8, unknown_machine_id);
}

/// `/etc/machine-id`, or D-Bus's copy of it on a system old enough to keep
/// only that.
fn linuxMachineId(io: Io, buf: []u8) ?[]const u8 {
    for ([_][]const u8{ "/etc/machine-id", "/var/lib/dbus/machine-id" }) |path| {
        const data = Io.Dir.cwd().readFile(io, path, buf) catch continue;
        const id = std.mem.trim(u8, data, &std.ascii.whitespace);
        if (id.len > 0) return id;
    }
    return null;
}

/// `IOPlatformUUID`, out of `ioreg`, the same way the wrapper already uses
/// `osascript` rather than linking a framework for one value.
fn macPlatformUuid(io: Io, gpa: Allocator, buf: []u8) !?[]const u8 {
    const res = std.process.run(gpa, io, .{
        .argv = &.{ "ioreg", "-rd1", "-c", "IOPlatformExpertDevice" },
        .timeout = .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(2) } },
    }) catch return null;
    defer gpa.free(res.stdout);
    defer gpa.free(res.stderr);
    const uuid = parseIoregUuid(res.stdout) orelse return null;
    if (uuid.len > buf.len) return null;
    @memcpy(buf[0..uuid.len], uuid);
    return buf[0..uuid.len];
}

/// The value in a line of the form `"IOPlatformUUID" = "…"`.
fn parseIoregUuid(out: []const u8) ?[]const u8 {
    const key = "\"IOPlatformUUID\" = \"";
    const start = (std.mem.find(u8, out, key) orelse return null) + key.len;
    const len = std.mem.findScalar(u8, out[start..], '"') orelse return null;
    if (len == 0) return null;
    return out[start..][0..len];
}

// ------------------------------------------------------------------- tests

const testing = std.testing;

test "parse72 splits metadata from payload, with either terminator" {
    const p = parse72("\x1b]72;t=M:x=3:y=4;text/uri-list text/plain\x1b\\").?;
    try testing.expectEqual('M', eventType(p));
    try testing.expectEqual(3, try intField(p, "x"));
    try testing.expectEqualStrings("text/uri-list text/plain", p.payload.?);

    const q = parse72("\x1b]72;t=r:x=1\x07").?;
    try testing.expectEqual('r', eventType(q));
    try testing.expect(q.payload == null);
    try testing.expect(isEnd(q));

    try testing.expect(parse72("\x1b]5522;status=OK\x1b\\") == null);
    // OSC 7 is not OSC 72.
    try testing.expect(parse72("\x1b]7;file:///tmp\x1b\\") == null);
}

test "intField treats absence as zero and refuses garbage" {
    const p = parse72("\x1b]72;t=r:x=2:Y=-7:X=bogus;QQ==\x1b\\").?;
    try testing.expectEqual(2, try intField(p, "x"));
    try testing.expectEqual(-7, try intField(p, "Y"));
    try testing.expectEqual(0, try intField(p, "y"));
    try testing.expectError(error.InvalidInteger, intField(p, "X"));
    try testing.expectEqual('a', eventType(parse72("\x1b]72;x=1\x1b\\").?));
}

test "isEnd is an empty payload, whatever m says" {
    try testing.expect(isEnd(parse72("\x1b]72;t=r:x=1:m=0;\x1b\\").?));
    try testing.expect(!isEnd(parse72("\x1b]72;t=r:x=1:m=0;QQ==\x1b\\").?));
    try testing.expect(!isEnd(parse72("\x1b]72;t=r:x=1:m=1;QQ==\x1b\\").?));
}

test "appendCommand writes a complete escape code" {
    const gpa = testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try appendCommand(gpa, &out, "t=A", null);
    try appendCommandFmt(gpa, &out, "t=r:x={d}:y={d}", .{ 1, 2 }, null);
    try appendCommand(gpa, &out, "t=a:x=1", "1:abc");
    try testing.expectEqualStrings(
        "\x1b]72;t=A\x1b\\\x1b]72;t=r:x=1:y=2\x1b\\\x1b]72;t=a:x=1;1:abc\x1b\\",
        out.items,
    );
}

test "UriList splits the way the terminal counts" {
    const list = "# comment\r\nfile:///a  \r\n\r\n \r\nhttps://b\nfile:///c";
    var it: UriList = .init(list);
    try testing.expectEqualStrings("file:///a", it.next().?);
    try testing.expectEqualStrings("https://b", it.next().?);
    try testing.expectEqualStrings("file:///c", it.next().?);
    try testing.expect(it.next() == null);
}

test "filePath decodes, drops the host, and turns other schemes away" {
    const gpa = testing.allocator;
    const a = try filePath(gpa, "file:///home/me/My%20Pictures/a.png");
    defer gpa.free(a);
    try testing.expectEqualStrings("/home/me/My Pictures/a.png", a);

    const b = try filePath(gpa, "FILE://laptop/tmp/x?query#frag");
    defer gpa.free(b);
    try testing.expectEqualStrings("/tmp/x", b);

    try testing.expectError(error.NotFile, filePath(gpa, "https://example.com/a.png"));
    try testing.expectError(error.Invalid, filePath(gpa, "file://host-without-path"));
    try testing.expectError(error.Invalid, filePath(gpa, "file:///bad%2"));
    try testing.expectError(error.Invalid, filePath(gpa, "file:///bad%zz"));
    try testing.expectError(error.Invalid, filePath(gpa, "file:///nul%00here"));
}

test "DirEntries counts every piece, including the empty one at the end" {
    var it: DirEntries = .init("a.png\x00sub\x00\x00b\x00");
    try testing.expectEqualDeep(DirEntries.Entry{ .index = 1, .name = "a.png" }, it.next().?);
    try testing.expectEqualDeep(DirEntries.Entry{ .index = 2, .name = "sub" }, it.next().?);
    try testing.expectEqualDeep(DirEntries.Entry{ .index = 3, .name = "" }, it.next().?);
    try testing.expectEqualDeep(DirEntries.Entry{ .index = 4, .name = "b" }, it.next().?);
    try testing.expectEqualDeep(DirEntries.Entry{ .index = 5, .name = "" }, it.next().?);
    try testing.expect(it.next() == null);
}

test "safeName keeps a name inside its directory" {
    try testing.expectEqualStrings("a b.png", safeName("a b.png").?);
    try testing.expectEqualStrings("..hidden", safeName("..hidden").?);
    try testing.expect(safeName("") == null);
    try testing.expect(safeName(".") == null);
    try testing.expect(safeName("..") == null);
    try testing.expect(safeName("../etc") == null);
    try testing.expect(safeName("a/b") == null);
    try testing.expect(safeName("a\x00b") == null);
}

test "appendShellEscaped escapes exactly ghostty's set" {
    const gpa = testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try appendShellEscaped(gpa, &out, "/tmp/it's a (test)?*$`|\"\\.png");
    try testing.expectEqualStrings("/tmp/it\\'s\\ a\\ \\(test\\)\\?\\*\\$\\`\\|\\\"\\\\.png", out.items);

    out.clearRetainingCapacity();
    try appendShellEscaped(gpa, &out, "/plain/path-with_safe.chars~&;");
    try testing.expectEqualStrings("/plain/path-with_safe.chars~&;", out.items);
}

test "machineId matches an independently computed HMAC" {
    // python3 -c 'import hmac,hashlib; print(hmac.new(
    //   b"tty-dnd-protocol-machine-id",
    //   b"0123456789abcdef0123456789abcdef", hashlib.sha256).hexdigest())'
    const want = "1:a81b6c3c9d37b0caa4a9c6b7de41059238bc101829db2975223b93d39d663b08";
    try testing.expectEqualStrings(want, &machineId("0123456789abcdef0123456789abcdef\n"));
}

test "parseIoregUuid finds the platform UUID" {
    const out =
        \\+-o J316sAP  <class IOPlatformExpertDevice, id 0x100000213>
        \\    {
        \\      "IOPlatformSerialNumber" = "XXXXXXXXXX"
        \\      "IOPlatformUUID" = "12345678-9ABC-DEF0-1234-56789ABCDEF0"
        \\    }
    ;
    try testing.expectEqualStrings("12345678-9ABC-DEF0-1234-56789ABCDEF0", parseIoregUuid(out).?);
    try testing.expect(parseIoregUuid("nothing here") == null);
}
