// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! What `claude-wrap` does when something is dropped on the terminal.
//!
//! A local drop pastes the dropped file's path, and Claude Code turns a
//! pasted image path into an attachment. Over SSH that path names a file on
//! the wrong machine. So the wrapper declares its machine id, and when the
//! terminal says the drop came from elsewhere it asks for each file's
//! *contents*, mirrors them -- directories and symlinks included -- into a
//! private directory on this side, and pastes those paths instead. A drop
//! from this same machine skips all of that and pastes the paths as they are.
//!
//! The conversation is one request at a time. That is simpler than keeping
//! several in flight, and it stays well clear of the terminal's limit on
//! queued requests, which ends the drop when it is exceeded.
//!
//! Nothing is written to a descriptor here: what is meant for the terminal
//! accumulates in `to_terminal` and what is meant for `claude` in
//! `to_child`, and the proxy flushes both after every packet. That is what
//! lets a test drive a whole drop with recorded packets and look at the
//! result.

const std = @import("std");
const root = @import("root.zig");
const dnd = @import("dnd.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const Packet = root.Packet;

/// The types a drop is accepted as, most wanted first. A list of files is
/// the point of the exercise; text dragged out of some other program is
/// worth taking too, and is pasted as it stands.
const wanted_mimes = [_][]const u8{ "text/uri-list", "text/plain" };

pub const Drop = struct {
    gpa: Allocator,
    io: Io,
    log: *const root.Logger,

    /// Where this wrapper mirrors remote drops,
    /// `<runtime>/claude-wrap-drops-<uid>/<pid>`, each drop in a numbered
    /// directory beneath it. Removed by `cleanup`.
    base: []const u8,
    /// The number of the last drop's directory.
    seq: u32 = 0,

    state: State = .idle,

    /// Escape codes for the terminal, for the caller to flush.
    to_terminal: std.ArrayList(u8) = .empty,
    /// Bytes for `claude`, for the caller to flush.
    to_child: std.ArrayList(u8) = .empty,

    /// The one-based index, in the drop's MIME list, of the type requested.
    list_index: i32 = 0,
    /// Whether that type is `text/plain` rather than `text/uri-list`.
    list_is_text: bool = false,
    /// Whether the terminal marked the URI list `X=1`: the files are on its
    /// machine, not ours, and have to be fetched.
    remote: bool = false,

    /// The work still to do, oldest first, which makes directories come out
    /// breadth first as the specification recommends.
    jobs: std.ArrayList(Job) = .empty,
    /// The request whose reply is arriving.
    current: ?Job = null,
    /// Waiting for the first packet of the current reply, which is the one
    /// that says what it is.
    first: bool = true,
    /// What the current reply is: `X`, which is 0 for a file, 1 for a
    /// symlink and a directory handle otherwise.
    kind: i32 = 0,
    /// Something went wrong with the current reply; read it to the end and
    /// throw it away.
    failed: bool = false,
    /// The file the current reply is being written into.
    file: ?Io.File = null,
    offset: u64 = 0,
    /// The URI list, a symlink's target, or a directory listing.
    buf: std.ArrayList(u8) = .empty,

    /// This drop's directory, once it has one.
    dir: ?[]u8 = null,
    /// Top-level names already used in `dir`.
    names: std.ArrayList([]u8) = .empty,
    /// What will be pasted: escaped paths separated by spaces, or text.
    paste: std.ArrayList(u8) = .empty,

    /// The reply has to keep moving. An idle deadline, renewed by every
    /// packet, rather than one for the whole drop, because a large file
    /// legitimately takes a long time.
    deadline: i96 = 0,

    pub const State = enum {
        /// No drop in progress. Moves are answered, drops are taken.
        idle,
        /// Asked for the URI list (or the text).
        awaiting_list,
        /// Working through the files.
        fetching,
    };

    const Job = struct {
        what: union(enum) {
            /// The n'th URI of the list.
            uri: i32,
            /// An entry of a directory the terminal has open.
            entry: struct { handle: i32, index: i32 },
            /// Done with a directory; the terminal can let it go.
            close: i32,
        },
        /// Where it lands. Empty for `close`.
        dest: []u8,
        /// One of the dropped items themselves, whose path is pasted, rather
        /// than something found inside a dropped directory.
        top: bool = false,
    };

    pub fn init(gpa: Allocator, io: Io, log: *const root.Logger, base: []const u8) !Drop {
        return .{ .gpa = gpa, .io = io, .log = log, .base = try gpa.dupe(u8, base) };
    }

    pub fn deinit(d: *Drop) void {
        d.reset();
        d.to_terminal.deinit(d.gpa);
        d.to_child.deinit(d.gpa);
        d.jobs.deinit(d.gpa);
        d.buf.deinit(d.gpa);
        d.names.deinit(d.gpa);
        d.paste.deinit(d.gpa);
        d.gpa.free(d.base);
        d.* = undefined;
    }

    /// Remove every file this wrapper fetched.
    pub fn cleanup(d: *Drop) void {
        Io.Dir.cwd().deleteTree(d.io, d.base) catch |e|
            d.log.print("removing {s} failed: {t}", .{ d.base, e });
    }

    /// Whether `deadline` means anything right now.
    pub fn busy(d: *const Drop) bool {
        return d.state != .idle;
    }

    /// Back to idle, dropping everything about the drop in progress.
    fn reset(d: *Drop) void {
        if (d.current) |j| d.freeJob(j);
        d.current = null;
        for (d.jobs.items) |j| d.freeJob(j);
        d.jobs.clearRetainingCapacity();
        if (d.file) |f| f.close(d.io);
        d.file = null;
        if (d.dir) |p| d.gpa.free(p);
        d.dir = null;
        for (d.names.items) |n| d.gpa.free(n);
        d.names.clearRetainingCapacity();
        d.buf.clearRetainingCapacity();
        d.paste.clearRetainingCapacity();
        d.state = .idle;
        d.deadline = 0;
        d.remote = false;
        d.list_is_text = false;
    }

    fn freeJob(d: *Drop, j: Job) void {
        d.gpa.free(j.dest);
    }

    fn touch(d: *Drop) void {
        d.deadline = Io.Clock.awake.now(d.io).nanoseconds + root.data_response_timeout_ns;
    }

    /// Act on one OSC 72 packet from the terminal.
    ///
    /// Never fails: a drop that goes wrong is abandoned, and the proxy
    /// carries on forwarding keystrokes regardless.
    pub fn handle(d: *Drop, p: Packet) void {
        d.step(p) catch |e| d.abandon(e);
    }

    /// The reply stopped coming. Keep what landed and paste it.
    pub fn timeout(d: *Drop) void {
        d.log.print("drop: the terminal went quiet; giving up on the rest", .{});
        d.discardPartial();
        d.conclude() catch |e| d.abandon(e);
    }

    /// Something failed that is not the terminal's doing -- out of memory,
    /// say, or no way to make the drop directory. Decline the drop and go
    /// back to waiting for the next one.
    fn abandon(d: *Drop, e: anyerror) void {
        d.log.print("drop: abandoned: {t}", .{e});
        const was_busy = d.busy();
        d.discardPartial();
        d.reset();
        if (was_busy) dnd.appendCommand(d.gpa, &d.to_terminal, "t=r:o=0", null) catch {};
    }

    fn step(d: *Drop, p: Packet) !void {
        switch (dnd.eventType(p)) {
            'm' => try d.onMove(p),
            'M' => try d.onDrop(p),
            'r', 'R' => switch (d.state) {
                .idle => {},
                .awaiting_list => try d.onListReply(p),
                .fetching => try d.onFetchReply(p),
            },
            else => {},
        }
    }

    // ------------------------------------------------------------ moves

    /// Say whether a drop here would be taken. Only the first move of a
    /// drag carries the list of types on offer, and only that one needs an
    /// answer; `x=-1` is the drag leaving, which needs none.
    fn onMove(d: *Drop, p: Packet) !void {
        if ((dnd.intField(p, "x") catch 0) == -1) return;
        const offered = p.payload orelse return;
        if (offered.len == 0) return;

        if (d.state != .idle) {
            // One drop at a time.
            try dnd.appendCommand(d.gpa, &d.to_terminal, "t=m:o=0", null);
            return;
        }

        var wanted: std.ArrayList(u8) = .empty;
        defer wanted.deinit(d.gpa);
        for (wanted_mimes) |want| {
            var it = root.mimeListIterator(offered);
            while (it.next()) |m| {
                if (!std.ascii.eqlIgnoreCase(root.baseMime(m), want)) continue;
                if (wanted.items.len > 0) try wanted.append(d.gpa, ' ');
                try wanted.appendSlice(d.gpa, m);
                break;
            }
        }
        if (wanted.items.len == 0) {
            try dnd.appendCommand(d.gpa, &d.to_terminal, "t=m:o=0", null);
        } else {
            try dnd.appendCommand(d.gpa, &d.to_terminal, "t=m:o=1", wanted.items);
        }
    }

    // ------------------------------------------------------------- drop

    fn onDrop(d: *Drop, p: Packet) !void {
        if (d.state != .idle) {
            d.log.print("drop: another drop arrived mid-transfer; ignoring it", .{});
            return;
        }
        d.reset();

        const offered = p.payload orelse "";
        const choice: ?struct { index: i32, text: bool } = blk: {
            for (wanted_mimes) |want| {
                var it = root.mimeListIterator(offered);
                var i: i32 = 1;
                while (it.next()) |m| : (i += 1) {
                    if (std.ascii.eqlIgnoreCase(root.baseMime(m), want))
                        break :blk .{ .index = i, .text = !std.mem.eql(u8, want, "text/uri-list") };
                }
            }
            break :blk null;
        };
        const c = choice orelse {
            d.log.print("drop: nothing usable among: {s}", .{offered});
            try dnd.appendCommand(d.gpa, &d.to_terminal, "t=r:o=0", null);
            return;
        };

        d.list_index = c.index;
        d.list_is_text = c.text;
        d.first = true;
        d.state = .awaiting_list;
        d.touch();
        d.log.print("drop: requesting {s}", .{if (c.text) "text/plain" else "text/uri-list"});
        try dnd.appendCommandFmt(d.gpa, &d.to_terminal, "t=r:x={d}", .{c.index}, null);
    }

    fn onListReply(d: *Drop, p: Packet) !void {
        if ((dnd.intField(p, "x") catch return) != d.list_index) return;
        if ((dnd.intField(p, "y") catch return) != 0) return;
        if ((dnd.intField(p, "Y") catch return) != 0) return;
        d.touch();

        if (dnd.eventType(p) == 'R') {
            d.log.print("drop: the terminal refused the list: {s}", .{p.payload orelse ""});
            try d.conclude();
            return;
        }

        if (d.first) {
            d.first = false;
            d.remote = (dnd.intField(p, "X") catch 0) == 1;
        }
        if (!dnd.isEnd(p)) {
            root.appendDecodedChunk(d.gpa, &d.buf, p.payload.?) catch |e|
                d.log.print("drop: undecodable chunk: {t}", .{e});
            return;
        }

        if (d.list_is_text) {
            try d.paste.appendSlice(d.gpa, d.buf.items);
            try d.conclude();
            return;
        }
        try d.planList();
    }

    /// Turn the URI list into a paste, or into the work to fetch it.
    fn planList(d: *Drop) !void {
        d.log.print("drop: {s} list of {d} bytes", .{ if (d.remote) "remote" else "local", d.buf.items.len });

        var it: dnd.UriList = .init(d.buf.items);
        var n: i32 = 0;
        while (it.next()) |uri| {
            n += 1;
            const path = dnd.filePath(d.gpa, uri) catch |e| switch (e) {
                error.NotFile => {
                    // A link dragged out of a browser, say. Paste it as it
                    // is; escaping a URL would only mangle it.
                    try d.separate();
                    try d.paste.appendSlice(d.gpa, uri);
                    continue;
                },
                error.Invalid => {
                    d.log.print("drop: skipping unreadable uri {s}", .{uri});
                    continue;
                },
                error.OutOfMemory => return error.OutOfMemory,
            };
            defer d.gpa.free(path);

            if (!d.remote) {
                try d.separate();
                try dnd.appendShellEscaped(d.gpa, &d.paste, path);
                continue;
            }

            const dir = d.dir orelse try d.makeDropDir();
            const name = try d.topName(path);
            try d.jobs.append(d.gpa, .{
                .what = .{ .uri = n },
                .dest = try std.fs.path.join(d.gpa, &.{ dir, name }),
                .top = true,
            });
        }

        d.buf.clearRetainingCapacity();
        d.state = .fetching;
        try d.advance();
    }

    /// `<base>/<n>`, made fresh for this drop so that two drops of files
    /// with the same name cannot collide. Every level is private.
    fn makeDropDir(d: *Drop) ![]u8 {
        if (std.fs.path.dirname(d.base)) |parent| try d.mkdirPrivate(parent);
        try d.mkdirPrivate(d.base);
        while (true) {
            d.seq += 1;
            const p = try std.fmt.allocPrint(d.gpa, "{s}/{d}", .{ d.base, d.seq });
            Io.Dir.cwd().createDir(d.io, p, .fromMode(0o700)) catch |e| switch (e) {
                error.PathAlreadyExists => {
                    d.gpa.free(p);
                    continue;
                },
                else => {
                    d.gpa.free(p);
                    return e;
                },
            };
            d.dir = p;
            return p;
        }
    }

    fn mkdirPrivate(d: *Drop, path: []const u8) !void {
        Io.Dir.cwd().createDir(d.io, path, .fromMode(0o700)) catch |e| switch (e) {
            error.PathAlreadyExists => {},
            else => return e,
        };
    }

    /// The name a dropped item gets in the drop directory: its own, made
    /// unique within this drop by a numeric prefix if two items share one.
    fn topName(d: *Drop, path: []const u8) ![]const u8 {
        const own = dnd.safeName(std.fs.path.basename(path)) orelse "dropped";
        var candidate = try d.gpa.dupe(u8, own);
        var k: usize = 1;
        while (d.nameTaken(candidate)) {
            k += 1;
            d.gpa.free(candidate);
            candidate = try std.fmt.allocPrint(d.gpa, "{d}-{s}", .{ k, own });
        }
        errdefer d.gpa.free(candidate);
        try d.names.append(d.gpa, candidate);
        return candidate;
    }

    fn nameTaken(d: *const Drop, name: []const u8) bool {
        for (d.names.items) |n| if (std.mem.eql(u8, n, name)) return true;
        return false;
    }

    fn separate(d: *Drop) !void {
        if (d.paste.items.len > 0) try d.paste.append(d.gpa, ' ');
    }

    // ----------------------------------------------------------- fetching

    /// Send the next request, or finish if there is none.
    fn advance(d: *Drop) !void {
        while (d.jobs.items.len > 0) {
            const j = d.jobs.orderedRemove(0);
            switch (j.what) {
                .close => |h| {
                    try dnd.appendCommandFmt(d.gpa, &d.to_terminal, "t=r:Y={d}", .{h}, null);
                    d.freeJob(j);
                    continue;
                },
                .uri => |n| try dnd.appendCommandFmt(
                    d.gpa,
                    &d.to_terminal,
                    "t=r:x={d}:y={d}",
                    .{ d.list_index, n },
                    null,
                ),
                .entry => |e| try dnd.appendCommandFmt(
                    d.gpa,
                    &d.to_terminal,
                    "t=r:Y={d}:x={d}",
                    .{ e.handle, e.index },
                    null,
                ),
            }
            d.current = j;
            d.first = true;
            d.failed = false;
            d.kind = 0;
            d.offset = 0;
            d.buf.clearRetainingCapacity();
            d.touch();
            return;
        }
        try d.conclude();
    }

    /// Whether a reply is for the request in flight. Replies are matched on
    /// their keys rather than assumed to be in order.
    fn matches(d: *const Drop, j: Job, p: Packet) bool {
        const x = dnd.intField(p, "x") catch return false;
        const y = dnd.intField(p, "y") catch return false;
        const Y = dnd.intField(p, "Y") catch return false;
        return switch (j.what) {
            .uri => |n| x == d.list_index and y == n and Y == 0,
            .entry => |e| Y == e.handle and x == e.index,
            .close => false,
        };
    }

    fn onFetchReply(d: *Drop, p: Packet) !void {
        const j = d.current orelse return;
        if (!d.matches(j, p)) return;
        d.touch();

        if (dnd.eventType(p) == 'R') {
            d.log.print("drop: fetching {s} failed: {s}", .{ j.dest, p.payload orelse "" });
            d.discardPartial();
            try d.finishJob(false);
            return;
        }

        if (d.first) {
            d.first = false;
            d.kind = dnd.intField(p, "X") catch 0;
            if (d.kind == 0) {
                d.file = Io.Dir.cwd().createFile(d.io, j.dest, .{ .exclusive = true }) catch |e| blk: {
                    d.log.print("drop: creating {s} failed: {t}", .{ j.dest, e });
                    d.failed = true;
                    break :blk null;
                };
            }
        }

        if (!dnd.isEnd(p)) {
            if (d.failed) return;
            const raw = root.b64DecodeAlloc(d.gpa, p.payload.?) catch |e| {
                d.log.print("drop: undecodable chunk for {s}: {t}", .{ j.dest, e });
                d.discardPartial();
                d.failed = true;
                return;
            };
            defer d.gpa.free(raw);
            if (d.file) |f| {
                f.writePositionalAll(d.io, raw, d.offset) catch |e| {
                    d.log.print("drop: writing {s} failed: {t}", .{ j.dest, e });
                    d.discardPartial();
                    d.failed = true;
                    return;
                };
                d.offset += raw.len;
            } else {
                try d.buf.appendSlice(d.gpa, raw);
            }
            return;
        }

        if (d.failed) {
            // A directory still has to be let go of, even though nothing was
            // made of it.
            if (d.kind > 1) try d.jobs.append(d.gpa, .{ .what = .{ .close = d.kind }, .dest = &.{} });
            try d.finishJob(false);
            return;
        }

        switch (d.kind) {
            0 => {
                d.file.?.close(d.io);
                d.file = null;
                try d.finishJob(true);
            },
            1 => {
                const ok = if (Io.Dir.cwd().symLink(d.io, d.buf.items, j.dest, .{})) true else |e| blk: {
                    d.log.print("drop: symlinking {s} failed: {t}", .{ j.dest, e });
                    break :blk false;
                };
                try d.finishJob(ok);
            },
            else => |dir_handle| {
                const ok = if (Io.Dir.cwd().createDir(d.io, j.dest, .fromMode(0o755))) true else |e| blk: {
                    d.log.print("drop: creating {s} failed: {t}", .{ j.dest, e });
                    break :blk false;
                };
                if (ok) {
                    var entries: dnd.DirEntries = .init(d.buf.items);
                    while (entries.next()) |entry| {
                        const name = dnd.safeName(entry.name) orelse continue;
                        try d.jobs.append(d.gpa, .{
                            .what = .{ .entry = .{ .handle = dir_handle, .index = entry.index } },
                            .dest = try std.fs.path.join(d.gpa, &.{ j.dest, name }),
                        });
                    }
                }
                try d.jobs.append(d.gpa, .{ .what = .{ .close = dir_handle }, .dest = &.{} });
                try d.finishJob(ok);
            },
        }
    }

    /// A file that did not arrive whole is not left behind looking as
    /// though it had.
    fn discardPartial(d: *Drop) void {
        const f = d.file orelse return;
        f.close(d.io);
        d.file = null;
        if (d.current) |j| Io.Dir.cwd().deleteFile(d.io, j.dest) catch {};
    }

    fn finishJob(d: *Drop, ok: bool) !void {
        const j = d.current.?;
        d.current = null;
        defer d.freeJob(j);
        if (ok and j.top) {
            try d.separate();
            try dnd.appendShellEscaped(d.gpa, &d.paste, j.dest);
        }
        try d.advance();
    }

    // ------------------------------------------------------------ the end

    /// Tell the terminal the drop is over, and hand `claude` whatever came
    /// of it. Whatever landed is pasted even if the rest did not, so one
    /// unreadable file does not cost the others.
    fn conclude(d: *Drop) !void {
        const took = d.paste.items.len > 0;
        try dnd.appendCommand(d.gpa, &d.to_terminal, if (took) "t=r:o=1" else "t=r:o=0", null);
        if (took) {
            d.log.print("drop: pasting {d} bytes", .{d.paste.items.len});
            try d.to_child.appendSlice(d.gpa, "\x1b[200~");
            try d.to_child.appendSlice(d.gpa, d.paste.items);
            try d.to_child.appendSlice(d.gpa, "\x1b[201~");
        }
        d.reset();
    }
};

// ------------------------------------------------------------------- tests

const testing = std.testing;

/// A drop driven by hand, with the terminal's side of the conversation
/// written out as it would arrive.
const Harness = struct {
    tmp: testing.TmpDir,
    base: []u8,
    log: root.Logger,
    drop: Drop,

    fn init(h: *Harness) !void {
        const gpa = testing.allocator;
        h.tmp = testing.tmpDir(.{});
        const abs = try h.tmp.dir.realPathFileAlloc(testing.io, ".", gpa);
        defer gpa.free(abs);
        h.base = try std.fs.path.join(gpa, &.{ abs, "drops", "1234" });
        h.log = .{ .gpa = gpa, .path = null };
        h.drop = try .init(gpa, testing.io, &h.log, h.base);
    }

    fn deinit(h: *Harness) void {
        h.drop.deinit();
        testing.allocator.free(h.base);
        h.tmp.cleanup();
    }

    fn feed(h: *Harness, osc: []const u8) !void {
        h.drop.handle(dnd.parse72(osc).?);
    }

    /// What the drop has said to the terminal since last asked.
    fn expectSent(h: *Harness, want: []const u8) !void {
        try testing.expectEqualStrings(want, h.drop.to_terminal.items);
        h.drop.to_terminal.clearRetainingCapacity();
    }

    fn read(h: *Harness, rel: []const u8) ![]u8 {
        const p = try std.fs.path.join(testing.allocator, &.{ h.base, rel });
        defer testing.allocator.free(p);
        return Io.Dir.cwd().readFileAlloc(testing.io, p, testing.allocator, .unlimited);
    }
};

fn b64(comptime s: []const u8) []const u8 {
    const E = std.base64.standard.Encoder;
    comptime var out: [E.calcSize(s.len)]u8 = undefined;
    _ = comptime E.encode(&out, s);
    const final = out;
    return &final;
}

test "a move is answered with the types a drop would be taken as" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();

    try h.feed("\x1b]72;t=m:x=3:y=4:X=30:Y=40:o=3;image/png text/plain;charset=utf-8 text/uri-list\x1b\\");
    try h.expectSent("\x1b]72;t=m:o=1;text/uri-list text/plain;charset=utf-8\x1b\\");

    // Later moves carry no list and want no answer; nor does leaving.
    try h.feed("\x1b]72;t=m:x=4:y=4:X=31:Y=40:o=3\x1b\\");
    try h.feed("\x1b]72;t=m:x=-1:y=-1\x1b\\");
    try h.expectSent("");

    try h.feed("\x1b]72;t=m:x=0:y=0:o=1;image/png\x1b\\");
    try h.expectSent("\x1b]72;t=m:o=0\x1b\\");
}

test "a local drop pastes the paths it names" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();

    try h.feed("\x1b]72;t=M:x=1:y=1;text/plain text/uri-list\x1b\\");
    try h.expectSent("\x1b]72;t=r:x=2\x1b\\");

    try h.feed("\x1b]72;t=r:x=2:m=0;" ++ comptime b64("file:///home/me/a%20b.png\r\n") ++ "\x1b\\");
    try h.feed("\x1b]72;t=r:x=2:m=0;" ++ comptime b64("https://example.com/?q=1\r\n") ++ "\x1b\\");
    try h.feed("\x1b]72;t=r:x=2\x1b\\");

    try h.expectSent("\x1b]72;t=r:o=1\x1b\\");
    try testing.expectEqualStrings(
        "\x1b[200~/home/me/a\\ b.png https://example.com/?q=1\x1b[201~",
        h.drop.to_child.items,
    );
    try testing.expect(!h.drop.busy());
}

test "a remote drop mirrors files, directories and symlinks, and pastes the copies" {
    const gpa = testing.allocator;
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();

    try h.feed("\x1b]72;t=M:x=1:y=1;text/uri-list\x1b\\");
    try h.expectSent("\x1b]72;t=r:x=1\x1b\\");

    // X=1 on the list: the files are on the terminal's machine.
    try h.feed("\x1b]72;t=r:x=1:X=1:m=0;" ++ comptime b64(
        "file:///pics/shot.png\r\nfile:///src/proj/\r\nfile:///other/shot.png\r\nfile:///gone\r\n",
    ) ++ "\x1b\\");
    try h.feed("\x1b]72;t=r:x=1:X=1\x1b\\");
    try h.expectSent("\x1b]72;t=r:x=1:y=1\x1b\\");

    // A file, in two pieces, each encoded on its own.
    try h.feed("\x1b]72;t=r:x=1:y=1:m=0;" ++ comptime b64("\x89PNG") ++ "\x1b\\");
    try h.feed("\x1b]72;t=r:x=1:y=1:m=0;" ++ comptime b64("rest") ++ "\x1b\\");
    try h.feed("\x1b]72;t=r:x=1:y=1\x1b\\");
    try h.expectSent("\x1b]72;t=r:x=1:y=2\x1b\\");

    // A directory with a file, a symlink, a hostile name and the trailing
    // NUL; a breadth-first walk asks for its entries next, then lets it go.
    try h.feed("\x1b]72;t=r:x=1:y=2:X=7:m=0;" ++ comptime b64("main.zig\x00link\x00..\x00") ++ "\x1b\\");
    try h.feed("\x1b]72;t=r:x=1:y=2:X=7\x1b\\");
    try h.expectSent("\x1b]72;t=r:x=1:y=3\x1b\\");

    // The second shot.png must not land on the first.
    try h.feed("\x1b]72;t=r:x=1:y=3:m=0;" ++ comptime b64("two") ++ "\x1b\\");
    try h.feed("\x1b]72;t=r:x=1:y=3\x1b\\");
    try h.expectSent("\x1b]72;t=r:x=1:y=4\x1b\\");

    // One that cannot be read costs only itself.
    try h.feed("\x1b]72;t=R:x=1:y=4;ENOENT:no such file\x1b\\");
    try h.expectSent("\x1b]72;t=r:Y=7:x=1\x1b\\");

    try h.feed("\x1b]72;t=r:Y=7:x=1:m=0;" ++ comptime b64("const std = @import(\"std\");\n") ++ "\x1b\\");
    try h.feed("\x1b]72;t=r:Y=7:x=1\x1b\\");
    try h.expectSent("\x1b]72;t=r:Y=7:x=2\x1b\\");

    try h.feed("\x1b]72;t=r:Y=7:x=2:X=1:m=0;" ++ comptime b64("main.zig") ++ "\x1b\\");
    try h.feed("\x1b]72;t=r:Y=7:x=2:X=1\x1b\\");
    try h.expectSent("\x1b]72;t=r:Y=7\x1b\\\x1b]72;t=r:o=1\x1b\\");

    const shot = try h.read("1/shot.png");
    defer gpa.free(shot);
    try testing.expectEqualStrings("\x89PNGrest", shot);
    const two = try h.read("1/2-shot.png");
    defer gpa.free(two);
    try testing.expectEqualStrings("two", two);
    const main = try h.read("1/proj/main.zig");
    defer gpa.free(main);
    try testing.expectEqualStrings("const std = @import(\"std\");\n", main);
    const via_link = try h.read("1/proj/link");
    defer gpa.free(via_link);
    try testing.expectEqualStrings(main, via_link);

    const paste = try std.fmt.allocPrint(
        gpa,
        "\x1b[200~{0s}/1/shot.png {0s}/1/proj {0s}/1/2-shot.png\x1b[201~",
        .{h.base},
    );
    defer gpa.free(paste);
    try testing.expectEqualStrings(paste, h.drop.to_child.items);
    try testing.expect(!h.drop.busy());

    h.drop.cleanup();
    try testing.expectError(error.FileNotFound, Io.Dir.cwd().access(testing.io, h.base, .{}));
}

test "a drop of plain text pastes the text" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();

    try h.feed("\x1b]72;t=M;text/plain;charset=utf-8 image/png\x1b\\");
    try h.expectSent("\x1b]72;t=r:x=1\x1b\\");
    try h.feed("\x1b]72;t=r:x=1:m=0;" ++ comptime b64("some words") ++ "\x1b\\");
    try h.feed("\x1b]72;t=r:x=1\x1b\\");
    try h.expectSent("\x1b]72;t=r:o=1\x1b\\");
    try testing.expectEqualStrings("\x1b[200~some words\x1b[201~", h.drop.to_child.items);
}

test "a refused list, or a drop with nothing usable, is declined" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();

    try h.feed("\x1b]72;t=M;image/png\x1b\\");
    try h.expectSent("\x1b]72;t=r:o=0\x1b\\");

    try h.feed("\x1b]72;t=M;text/uri-list\x1b\\");
    try h.expectSent("\x1b]72;t=r:x=1\x1b\\");
    try h.feed("\x1b]72;t=R:x=1;EPERM:cannot drop into self window\x1b\\");
    try h.expectSent("\x1b]72;t=r:o=0\x1b\\");
    try testing.expectEqualStrings("", h.drop.to_child.items);
    try testing.expect(!h.drop.busy());
}

test "a stalled transfer keeps what landed and discards the partial file" {
    const gpa = testing.allocator;
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();

    try h.feed("\x1b]72;t=M;text/uri-list\x1b\\");
    try h.feed("\x1b]72;t=r:x=1:X=1:m=0;" ++ comptime b64("file:///a\nfile:///b\n") ++ "\x1b\\");
    try h.feed("\x1b]72;t=r:x=1:X=1\x1b\\");
    try h.feed("\x1b]72;t=r:x=1:y=1:m=0;" ++ comptime b64("A") ++ "\x1b\\");
    try h.feed("\x1b]72;t=r:x=1:y=1\x1b\\");
    try h.feed("\x1b]72;t=r:x=1:y=2:m=1;" ++ comptime b64("half") ++ "\x1b\\");
    h.drop.to_terminal.clearRetainingCapacity();

    h.drop.timeout();
    try h.expectSent("\x1b]72;t=r:o=1\x1b\\");
    const paste = try std.fmt.allocPrint(gpa, "\x1b[200~{s}/1/a\x1b[201~", .{h.base});
    defer gpa.free(paste);
    try testing.expectEqualStrings(paste, h.drop.to_child.items);

    const b = try std.fs.path.join(gpa, &.{ h.base, "1", "b" });
    defer gpa.free(b);
    try testing.expectError(error.FileNotFound, Io.Dir.cwd().access(testing.io, b, .{}));
}

test "reference every declaration so lazy analysis cannot hide a broken one" {
    testing.refAllDecls(@This());
    testing.refAllDecls(Drop);
}
