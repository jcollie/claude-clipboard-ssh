// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! The one property that has to hold for the OSC scanner: no byte is ever
//! lost or duplicated.
//!
//! The scanner sits between the user's keyboard and `claude`, splitting a
//! stream that arrives in arbitrary `read()`-sized chunks into bytes to
//! forward and OSC 5522 packets to consume. Every byte it mis-slices is a
//! keystroke that `claude` never sees, or an escape sequence delivered
//! twice -- both silent. So: feed the scanner a stream in chunks, collect
//! what it forwards and what it consumes in order, add whatever it is still
//! holding back, and require the result to be the input again, exactly.

const std = @import("std");
const ccssh = @import("ccssh");

const Allocator = std.mem.Allocator;

/// What one pass of the scanner did with a stream.
const Split = struct {
    /// Forwarded bytes and consumed packets, concatenated in the order the
    /// scanner dealt with them. This is what must equal the input.
    replay: std.ArrayList(u8) = .empty,
    /// Each OSC 5522 sequence the scanner claimed.
    packets: std.ArrayList([]u8) = .empty,

    fn deinit(s: *Split, gpa: Allocator) void {
        s.replay.deinit(gpa);
        for (s.packets.items) |p| gpa.free(p);
        s.packets.deinit(gpa);
    }
};

/// Drive the scanner exactly the way `proxy()` does, but over a stream cut
/// into `chunk` pieces rather than whatever the kernel happened to hand us.
fn split(gpa: Allocator, input: []const u8, chunks: []const usize) !Split {
    var result: Split = .{};
    errdefer result.deinit(gpa);

    var in_buf: std.ArrayList(u8) = .empty;
    defer in_buf.deinit(gpa);

    var offset: usize = 0;
    var chunk_index: usize = 0;
    while (offset < input.len) {
        const want = if (chunks.len == 0) input.len else chunks[chunk_index % chunks.len];
        chunk_index += 1;
        const take = @min(if (want == 0) 1 else want, input.len - offset);
        try in_buf.appendSlice(gpa, input[offset..][0..take]);
        offset += take;

        var cursor: usize = 0;
        scan: while (cursor < in_buf.items.len) {
            switch (ccssh.findCompleteOsc(in_buf.items, cursor)) {
                .none => {
                    try result.replay.appendSlice(gpa, in_buf.items[cursor..]);
                    cursor = in_buf.items.len;
                },
                .partial => |start| {
                    try result.replay.appendSlice(gpa, in_buf.items[cursor..start]);
                    cursor = start;
                    break :scan;
                },
                .complete => |span| {
                    try result.replay.appendSlice(gpa, in_buf.items[cursor..span.start]);
                    const osc = in_buf.items[span.start..span.end];
                    cursor = span.end;
                    if (ccssh.parse5522(osc) == null) {
                        // Not ours; the proxy forwards it untouched.
                        try result.replay.appendSlice(gpa, osc);
                    } else {
                        try result.packets.append(gpa, try gpa.dupe(u8, osc));
                        try result.replay.appendSlice(gpa, osc);
                    }
                },
            }
        }

        const rest = in_buf.items.len - cursor;
        std.mem.copyForwards(u8, in_buf.items[0..rest], in_buf.items[cursor..]);
        in_buf.shrinkRetainingCapacity(rest);
    }

    // Whatever is still held back at end of stream is, by definition, not
    // yet delivered -- but it is still part of the input.
    try result.replay.appendSlice(gpa, in_buf.items);
    return result;
}

fn expectConserved(gpa: Allocator, input: []const u8, chunks: []const usize) !void {
    var s = try split(gpa, input, chunks);
    defer s.deinit(gpa);

    try std.testing.expectEqualSlices(u8, input, s.replay.items);

    // Anything claimed as ours really is one of ours, and is a complete
    // sequence rather than a fragment.
    for (s.packets.items) |p| {
        try std.testing.expect(std.mem.startsWith(u8, p, "\x1b]5522;"));
        try std.testing.expect(std.mem.endsWith(u8, p, "\x1b\\") or std.mem.endsWith(u8, p, "\x07"));
        try std.testing.expect(ccssh.parse5522(p) != null);
    }
}

/// Bytes chosen so that random strings actually produce OSC sequences
/// rather than uniform noise that never contains an ESC.
const interesting = [_]u8{ 0x1b, ']', '\\', 0x07, ';', ':', '5', '2', '=', 'a', 'A', 0, 0xff, '\n' };

test "byte conservation over pseudorandom streams and chunkings" {
    const gpa = std.testing.allocator;
    var prng: std.Random.DefaultPrng = .init(0x5522);
    const rand = prng.random();

    var input: [512]u8 = undefined;
    var chunks: [8]usize = undefined;

    for (0..2000) |_| {
        const len = rand.uintLessThan(usize, input.len);
        for (input[0..len]) |*b| {
            // Mostly interesting bytes, sometimes anything at all.
            b.* = if (rand.boolean())
                interesting[rand.uintLessThan(usize, interesting.len)]
            else
                rand.int(u8);
        }
        for (&chunks) |*ch| ch.* = 1 + rand.uintLessThan(usize, 64);
        try expectConserved(gpa, input[0..len], &chunks);
    }
}

test "byte conservation with a real transcript at every chunk boundary" {
    const gpa = std.testing.allocator;
    // A ghostty paste, as it arrives: the event, two advertisements, DONE,
    // then the acknowledgement and the chunked payload -- with ordinary
    // keystrokes and an unrelated OSC mixed in.
    const transcript =
        "hello" ++
        "\x1b]5522;type=read:status=OK:password=cGFzc3dvcmQ=\x1b\\" ++
        "\x1b]5522;type=read:status=DATA:mime=aW1hZ2UvcG5n\x1b\\" ++
        "\x1b]5522;type=read:status=DATA:mime=dGV4dC9wbGFpbg==\x1b\\" ++
        "\x1b]5522;type=read:status=DONE\x1b\\" ++
        "\x1b]0;a window title\x07" ++
        "\x1b[200~typed\x1b[201~" ++
        "\x1b]5522;status=DATA;iVBORw0KGgo=\x1b\\" ++
        "\x1b]5522;status=DONE\x1b\\" ++
        "trailing\x1b";

    // Every possible single split point, then every fixed chunk width.
    for (1..transcript.len) |at| {
        try expectConserved(gpa, transcript, &.{ at, transcript.len });
    }
    for (1..40) |width| {
        try expectConserved(gpa, transcript, &.{width});
    }

    // And with the whole thing in one read, the packets are all found.
    var s = try split(gpa, transcript, &.{transcript.len});
    defer s.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 6), s.packets.items.len);
}

test "a stream that is only a partial sequence is held, not dropped" {
    const gpa = std.testing.allocator;
    try expectConserved(gpa, "\x1b", &.{1});
    try expectConserved(gpa, "\x1b]", &.{1});
    try expectConserved(gpa, "\x1b]5522;status=", &.{ 3, 3 });
}

test "fuzz the scanner" {
    try std.testing.fuzz({}, fuzzOne, .{});
}

fn fuzzOne(_: void, smith: *std.testing.Smith) anyerror!void {
    const gpa = std.testing.allocator;

    // Smith reads a four-byte little-endian length before the content, and
    // yields an empty slice rather than clamping if that length exceeds the
    // buffer -- so the buffer size is part of the contract with the corpus.
    var buf: [4096]u8 = undefined;
    const len = smith.slice(&buf);

    // Chunk widths come from the same input, so the fuzzer can search over
    // read boundaries as well as over content.
    var chunks: [4]usize = undefined;
    for (&chunks) |*ch| ch.* = smith.value(u8) % 64 + 1;

    try expectConserved(gpa, buf[0..len], &chunks);
}
