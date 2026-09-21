// SPDX-FileCopyrightText: © 2026 mindfulmonk <mindfulmonk@users.noreply.github.com>
// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Everything `claude-wrap`, the `xclip` stub and the debug tools share.
//!
//! The split is deliberate: all the logic that can be wrong lives here as
//! pure functions over byte slices, so it can be tested without a terminal,
//! a pseudo-terminal or a clock. The programs themselves are then mostly
//! plumbing.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const known_folders = @import("known-folders");

const posix = std.posix;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const native_os = builtin.os.tag;

/// Pseudo-terminal allocation and raw mode. Re-exported here so the debug
/// tools can drive a raw `/dev/tty` without reaching across directories for
/// it.
pub const pty = @import("pty.zig");

/// The system calls this project makes, wrapped so they work with or
/// without libc.
pub const sys = @import("sys.zig");

/// How long a cache directory written by the wrapper stays valid. The stub
/// refuses to serve anything older, so a paste that happened minutes ago
/// cannot be handed to `claude` as though it were the current clipboard.
pub const cache_ttl_ns: i96 = 60 * std.time.ns_per_s;

/// ghostty invalidates a paste password five seconds after issuing it, so
/// there is no point waiting longer than that for the data to come back.
pub const data_response_timeout_ns: i96 = 5 * std.time.ns_per_s;

// ---------------------------------------------------------------- cache dir

/// The directory the wrapper writes clipboard bytes into and the stub reads
/// them out of. Both programs must agree, which is the only invariant that
/// matters here -- the particular directory is not important.
///
/// `known-folders` resolves `.runtime` to `XDG_RUNTIME_DIR` on Linux and to
/// `~/Library/Application Support` on macOS. On Linux with no
/// `XDG_RUNTIME_DIR` set it yields null, hence the two further rungs.
///
/// Caller owns the returned memory.
pub fn cacheDirPath(io: Io, gpa: Allocator, env: *const std.process.Environ.Map) ![]u8 {
    const uid = sys.getuid();
    const base: []const u8 = blk: {
        if (try known_folders.getPath(io, gpa, env, .runtime)) |p| break :blk p;
        if (env.get("TMPDIR")) |p| if (p.len > 0) break :blk try gpa.dupe(u8, p);
        break :blk try gpa.dupe(u8, "/tmp");
    };
    defer gpa.free(base);
    return std.fmt.allocPrint(gpa, "{s}/xclip-shim-{d}", .{ base, uid });
}

/// A MIME type becomes a file name by turning the *first* slash into an
/// underscore, so `image/png` is stored as `image_png`. Only the first, so
/// that a subtype containing an underscore survives the round trip.
pub fn mimeToFileName(gpa: Allocator, mime: []const u8) Allocator.Error![]u8 {
    const out = try gpa.dupe(u8, mime);
    if (std.mem.findScalar(u8, out, '/')) |i| out[i] = '_';
    return out;
}

/// The inverse of `mimeToFileName`.
pub fn fileNameToMime(gpa: Allocator, name: []const u8) Allocator.Error![]u8 {
    const out = try gpa.dupe(u8, name);
    if (std.mem.findScalar(u8, out, '_')) |i| out[i] = '/';
    return out;
}

/// The clipboard cache, as the stubs see it.
///
/// Opening one succeeds only if the cache is fresh, so a caller that gets a
/// `Cache` can serve from it and a caller that gets `null` knows to report an
/// empty clipboard rather than a stale one.
pub const Cache = struct {
    dir: Io.Dir,

    /// Null when the cache is missing, unreadable or older than the TTL.
    pub fn open(io: Io, gpa: Allocator, env: *const std.process.Environ.Map) !?Cache {
        const dirpath = try cacheDirPath(io, gpa, env);
        defer gpa.free(dirpath);
        if (!isFresh(io, dirpath)) return null;
        const dir = Io.Dir.cwd().openDir(io, dirpath, .{ .iterate = true }) catch return null;
        return .{ .dir = dir };
    }

    pub fn close(c: *Cache, io: Io) void {
        c.dir.close(io);
        c.* = undefined;
    }

    /// The wrapper touches `.ts` after every write, and its mtime is the
    /// whole of the freshness signal. Wall clock, because that is what a
    /// file mtime is.
    fn isFresh(io: Io, dirpath: []const u8) bool {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const ts = std.fmt.bufPrint(&buf, "{s}/.ts", .{dirpath}) catch return false;
        const marker = Io.Dir.cwd().statFile(io, ts, .{}) catch return false;
        return Io.Clock.real.now(io).nanoseconds - marker.mtime.nanoseconds < cache_ttl_ns;
    }

    /// The MIME types held, newest paste only. Caller owns the list and its
    /// strings.
    pub fn listMimes(c: Cache, io: Io, gpa: Allocator) ![][]u8 {
        var out: std.ArrayList([]u8) = .empty;
        errdefer {
            for (out.items) |m| gpa.free(m);
            out.deinit(gpa);
        }
        var it = c.dir.iterate();
        while (try it.next(io)) |e| {
            // `.ts` is the freshness marker, not a payload.
            if (e.name.len == 0 or e.name[0] == '.') continue;
            const entry = c.dir.statFile(io, e.name, .{}) catch continue;
            if (entry.size == 0) continue;
            try out.append(gpa, try fileNameToMime(gpa, e.name));
        }
        return out.toOwnedSlice(gpa);
    }

    /// Drop the freshness marker, so the stubs treat the cache as empty and
    /// hand over to the real clipboard tool instead. Used when an exchange
    /// fails: without it, a paste that went wrong within the TTL would be
    /// answered with the *previous* paste's contents.
    pub fn invalidate(io: Io, gpa: Allocator, env: *const std.process.Environ.Map) void {
        const dirpath = cacheDirPath(io, gpa, env) catch return;
        defer gpa.free(dirpath);
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const ts = std.fmt.bufPrint(&buf, "{s}/.ts", .{dirpath}) catch return;
        Io.Dir.cwd().deleteFile(io, ts) catch {};
    }

    /// The bytes held for one MIME type, or null. Matched on the base type,
    /// so a request for `text/plain` finds what a
    /// `text/plain;charset=utf-8` paste stored.
    pub fn read(c: Cache, io: Io, gpa: Allocator, mime: []const u8) !?[]u8 {
        const name = try mimeToFileName(gpa, baseMime(mime));
        defer gpa.free(name);
        return c.dir.readFileAlloc(io, name, gpa, .unlimited) catch null;
    }
};

/// Hand over to the real clipboard tool of this name, if there is one.
///
/// The stubs shadow `xclip`, `wl-paste` and `wl-copy` for the process tree
/// `claude` runs in, and a stub that answers "nothing" is worse than no stub
/// at all: Claude Code probes whichever of those tools exists and takes a
/// different path depending on the answer, so a confident empty reply steers
/// it away from a clipboard that would have worked. That matters most when
/// the wrapper is bridging a *local* session, where a real clipboard is
/// sitting right there.
///
/// So when the cache has nothing to say, exec the real tool with the same
/// arguments and let it answer. Exec rather than reimplement: the real tool's
/// flags and exit statuses are then exactly right, because they are its own.
///
/// Returns only when there is no real tool to hand over to.
pub fn execRealTool(
    io: Io,
    arena: Allocator,
    env: *const std.process.Environ.Map,
    name: []const u8,
    argv: []const []const u8,
) !void {
    var self_buf: [std.fs.max_path_bytes]u8 = undefined;
    const self_dir: ?[]const u8 = blk: {
        const n = std.process.executableDirPath(io, &self_buf) catch break :blk null;
        break :blk self_buf[0..n];
    };

    const path = env.get("PATH") orelse return;
    var it = std.mem.splitScalar(u8, path, ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        // Skipping our own directory is what stops this being a fork bomb.
        if (self_dir) |sd| if (std.mem.eql(u8, dir, sd)) continue;

        const candidate = try std.fs.path.joinZ(arena, &.{ dir, name });
        const stat = Io.Dir.cwd().statFile(io, candidate, .{}) catch continue;
        if (stat.kind != .file) continue;
        if (@TypeOf(stat.permissions).has_executable_bit and
            stat.permissions.toMode() & 0o111 == 0) continue;

        const real_argv = try arena.alloc([]const u8, argv.len);
        real_argv[0] = candidate;
        for (argv[1..], 1..) |a, i| real_argv[i] = a;
        // `replace` returns only its error set, and only on failure.
        std.process.replace(io, .{ .argv = real_argv, .environ_map = env }) catch {};
        return; // exec failed; nothing else to try
    }
}

// ------------------------------------------------------------- OSC scanning

pub const osc_introducer = "\x1b]";
pub const st = "\x1b\\";
pub const bel = "\x07";

pub const OscSpan = struct { start: usize, end: usize };

/// What `findCompleteOsc` found.
///
/// `partial` carries the index the incomplete sequence starts at, so the
/// caller knows exactly how much of its buffer it must hold back for the
/// next read. Getting that boundary wrong loses user keystrokes, which is
/// why this is a three-way answer rather than an optional.
pub const ScanResult = union(enum) {
    complete: OscSpan,
    partial: usize,
    none,
};

/// Find the first complete OSC sequence at or after `from`.
///
/// An OSC runs from `ESC ]` to either `ESC \` (the string terminator) or a
/// bare BEL, and the returned span covers the terminator as well as the
/// introducer.
///
/// A buffer ending in a lone `ESC` reports `.partial`, because the `]` may
/// simply be in the next read. The Python this replaces forwarded that ESC
/// and then leaked the following `]5522;...` to `claude` as literal text.
pub fn findCompleteOsc(buf: []const u8, from: usize) ScanResult {
    var i = from;
    while (i < buf.len) : (i += 1) {
        if (buf[i] != 0x1b) continue;
        // A trailing ESC might be the start of an OSC we have not seen all of.
        if (i + 1 == buf.len) return .{ .partial = i };
        if (buf[i + 1] != ']') continue;

        var j = i + 2;
        while (j < buf.len) : (j += 1) {
            if (buf[j] == 0x07) return .{ .complete = .{ .start = i, .end = j + 1 } };
            if (buf[j] == 0x1b and j + 1 < buf.len and buf[j + 1] == '\\')
                return .{ .complete = .{ .start = i, .end = j + 2 } };
        }
        return .{ .partial = i };
    }
    return .none;
}

// -------------------------------------------------------- OSC 5522 packets

/// A parsed OSC 5522 packet. Every slice points into the buffer it was
/// parsed from, so a `Packet` does not outlive that buffer and nothing here
/// allocates.
pub const Packet = struct {
    meta: []const u8,
    payload: ?[]const u8,

    /// Look up a `key=value` field in the colon-separated metadata.
    pub fn field(p: Packet, key: []const u8) ?[]const u8 {
        var it = std.mem.splitScalar(u8, p.meta, ':');
        while (it.next()) |item| {
            const eq = std.mem.findScalar(u8, item, '=') orelse continue;
            if (std.mem.eql(u8, std.mem.trim(u8, item[0..eq], " \t"), key))
                return std.mem.trim(u8, item[eq + 1 ..], " \t");
        }
        return null;
    }
};

/// Parse a complete OSC sequence as an OSC 5522 packet, or return null if it
/// is some other OSC (which the proxy then forwards untouched).
pub fn parse5522(osc: []const u8) ?Packet {
    if (!std.mem.startsWith(u8, osc, "\x1b]5522;")) return null;
    var body = osc[osc_introducer.len..];
    if (std.mem.endsWith(u8, body, st)) {
        body = body[0 .. body.len - st.len];
    } else if (std.mem.endsWith(u8, body, bel)) {
        body = body[0 .. body.len - bel.len];
    }
    const rest = body["5522;".len..];
    // "5522;<meta>" or "5522;<meta>;<payload>"
    if (std.mem.findScalar(u8, rest, ';')) |semi|
        return .{ .meta = rest[0..semi], .payload = rest[semi + 1 ..] };
    return .{ .meta = rest, .payload = null };
}

/// The pseudo-type that means "tell me what is on offer" rather than naming
/// a representation. A paste event advertises its types as the payload of a
/// single DATA packet carrying this as its `mime`.
pub const targets_mime = ".";

/// The human-readable program name sent alongside a password. ghostty
/// discards a password that arrives without one -- "specifying a password
/// without a human friendly name is the same as not specifying a password"
/// -- so this is required, not decoration.
pub const program_name = "claude-wrap";

/// Split a whitespace-separated MIME list, which is how both the advertised
/// types and a read request's requested types are carried.
pub fn mimeListIterator(list: []const u8) std.mem.TokenIterator(u8, .any) {
    return std.mem.tokenizeAny(u8, list, " \t\r\n");
}

/// Collect the MIME types one DATA packet of a paste event advertises.
///
/// Two shapes have to be understood. A paste event lists everything in a
/// single packet whose `mime` is the targets pseudo-type and whose payload
/// is the whitespace-separated list; a terminal may instead name one type
/// per packet in the `mime` field. Reading only the second shape finds just
/// "." and concludes the clipboard holds nothing usable, which is how a
/// working paste turns into a discarded one.
///
/// Appends to `out`, which owns the added strings.
pub fn collectAdvertisedMimes(
    gpa: Allocator,
    packet: Packet,
    out: *std.ArrayList([]u8),
) !void {
    const m64 = packet.field("mime") orelse return;
    const mime = try b64DecodeAlloc(gpa, m64);

    if (!std.mem.eql(u8, mime, targets_mime)) {
        try out.append(gpa, mime); // one type, named in the field
        return;
    }
    defer gpa.free(mime);

    const list64 = packet.payload orelse return;
    const list = try b64DecodeAlloc(gpa, list64);
    defer gpa.free(list);

    var it = mimeListIterator(list);
    while (it.next()) |one| try out.append(gpa, try gpa.dupe(u8, one));
}

// ------------------------------------------------------------ MIME choice

/// Most to least wanted. TIFF is deliberately absent: a macOS screenshot is
/// on the clipboard as both PNG and TIFF, and the TIFF is ~1.7 MB of
/// uncompressed pixels, which is slow enough over an SSH pty to push the
/// round trip past ghostty's five-second password lifetime.
pub const preferred_mimes = [_][]const u8{
    "image/png",
    "image/jpeg",
    "image/gif",
    "image/webp",
    "image/bmp",
    "text/plain",
    "text/uri-list",
    "text/html",
};

/// The type without its parameters, so `text/plain;charset=utf-8` matches a
/// preference written as `text/plain`.
pub fn baseMime(m: []const u8) []const u8 {
    const semi = std.mem.findScalar(u8, m, ';') orelse m.len;
    return std.mem.trim(u8, m[0..semi], " \t");
}

/// Index into `advertised` of the most preferred MIME type, or null if none
/// of them is one we know what to do with.
pub fn chooseMime(advertised: []const []const u8) ?usize {
    for (preferred_mimes) |pref| {
        for (advertised, 0..) |adv, i| {
            if (std.ascii.eqlIgnoreCase(baseMime(adv), baseMime(pref))) return i;
        }
    }
    return null;
}

// ---------------------------------------------------------------- base64

pub const B64Error = std.base64.Error || Allocator.Error;

/// Decode base64, tolerating missing padding.
///
/// ghostty sends unpadded base64 and kitty sends it padded. The standard
/// decoder rejects a length that is not a multiple of four; the no-pad
/// decoder rejects a literal `=`. Trimming first and then using the no-pad
/// decoder accepts both.
///
/// Caller owns the returned memory.
pub fn b64DecodeAlloc(gpa: Allocator, src: []const u8) B64Error![]u8 {
    const trimmed = std.mem.trimEnd(u8, src, "=");
    const dec = std.base64.standard_no_pad.Decoder;
    const out = try gpa.alloc(u8, try dec.calcSizeForSlice(trimmed));
    errdefer gpa.free(out);
    try dec.decode(out, trimmed);
    return out;
}

/// Encode base64 with padding, which is what ghostty expects in a `mime=`
/// field. Caller owns the returned memory.
pub fn b64EncodeAlloc(gpa: Allocator, src: []const u8) Allocator.Error![]u8 {
    const enc = std.base64.standard.Encoder;
    const out = try gpa.alloc(u8, enc.calcSize(src.len));
    _ = enc.encode(out, src);
    return out;
}

// ------------------------------------------------------- xclip CLI parsing

pub const Action = enum { in, out };

pub const XclipArgs = struct {
    action: Action = .in,
    selection: []const u8 = "primary",
    target: []const u8 = "UTF8_STRING",
    help: bool = false,
};

/// Parse the subset of xclip's command line that Claude Code actually uses.
/// Defaults match real xclip: no `-o` means `-i`, and the default selection
/// is the primary one.
pub fn parseXclipArgs(argv: []const []const u8) XclipArgs {
    var r: XclipArgs = .{};
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "-o") or std.mem.eql(u8, a, "-out")) {
            r.action = .out;
        } else if (std.mem.eql(u8, a, "-i") or std.mem.eql(u8, a, "-in")) {
            r.action = .in;
        } else if (std.mem.eql(u8, a, "-selection") or std.mem.eql(u8, a, "-sel")) {
            i += 1;
            if (i < argv.len) r.selection = argv[i];
        } else if (std.mem.eql(u8, a, "-t") or std.mem.eql(u8, a, "-target")) {
            i += 1;
            if (i < argv.len) r.target = argv[i];
        } else if (std.mem.eql(u8, a, "-d") or std.mem.eql(u8, a, "-display") or
            std.mem.eql(u8, a, "-l") or std.mem.eql(u8, a, "-loops"))
        {
            i += 1; // takes an argument we do not care about
        } else if (std.mem.eql(u8, a, "-version") or std.mem.eql(u8, a, "-h") or
            std.mem.eql(u8, a, "-help"))
        {
            r.help = true;
        }
    }
    return r;
}

/// The X11 target names Claude Code may ask for that all mean "the text".
pub fn targetToMime(target: []const u8) []const u8 {
    if (std.mem.eql(u8, target, "UTF8_STRING") or
        std.mem.eql(u8, target, "STRING") or
        std.mem.eql(u8, target, "TEXT")) return "text/plain";
    return target;
}

// --------------------------------------------------------- terminal sniffing

pub fn isGhostty(env: *const std.process.Environ.Map) bool {
    if (env.get("GHOSTTY_RESOURCES_DIR")) |v| if (v.len > 0) return true;
    if (env.get("TERM_PROGRAM")) |v| if (std.ascii.indexOfIgnoreCase(v, "ghostty") != null) return true;
    if (env.get("TERM")) |v| if (std.ascii.indexOfIgnoreCase(v, "ghostty") != null) return true;
    return false;
}

pub fn isKitty(env: *const std.process.Environ.Map) bool {
    if (env.get("KITTY_WINDOW_ID")) |v| if (v.len > 0) return true;
    if (env.get("KITTY_PID")) |v| if (v.len > 0) return true;
    if (env.get("TERM")) |v| if (std.ascii.indexOfIgnoreCase(v, "kitty") != null) return true;
    return false;
}

/// Only kitty and ghostty implement OSC 5522. On anything else the wrapper
/// gets out of the way entirely rather than adding a pty for no reason.
pub fn isSupportedTerminal(env: *const std.process.Environ.Map) bool {
    return isGhostty(env) or isKitty(env);
}

// ------------------------------------------------------- shim discovery

/// The directory holding the `xclip` stub, which the wrapper prepends to the
/// PATH it hands the child `claude`.
///
/// Three sources, in order: an explicit environment override; the path baked
/// in at build time, which is how the Nix package knows where it put itself;
/// and finally a guess from the running executable's own location, covering
/// both a `nix build` result run in place and the hand-rolled install where
/// everything was copied into `~/.local/bin`.
///
/// Caller owns the returned memory.
pub fn findShimDir(io: Io, gpa: Allocator, env: *const std.process.Environ.Map) !?[]u8 {
    if (env.get("CLAUDE_CLIPBOARD_SHIM_DIR")) |dir|
        if (dir.len > 0) return try gpa.dupe(u8, dir);

    if (build_options.shim_dir) |dir| return try gpa.dupe(u8, dir);

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = std.process.executableDirPath(io, &buf) catch return null;
    const exe_dir = buf[0..n];

    // An installed layout: <prefix>/bin/claude-wrap next to
    // <prefix>/libexec/claude-clipboard-ssh/xclip.
    if (std.fs.path.dirname(exe_dir)) |prefix| {
        const candidate = try std.fs.path.join(gpa, &.{ prefix, build_options.shim_subdir });
        errdefer gpa.free(candidate);
        if (Io.Dir.cwd().access(io, candidate, .{})) |_| return candidate else |_| {}
        gpa.free(candidate);
    }

    // The manual install: both programs copied into the same directory.
    return try gpa.dupe(u8, exe_dir);
}

// --------------------------------------------------------- version ordering

/// Order two version-like directory names by their numeric components.
///
/// A plain lexicographic sort puts `0.9.10` before `0.9.9`, which is how the
/// Python picked the wrong `claude` whenever a minor number reached double
/// digits. Components that are not numbers are compared as text, so a name
/// like `1.2.3-beta` still orders sensibly against `1.2.3`.
pub fn compareVersionNames(a: []const u8, b: []const u8) std.math.Order {
    var ia = std.mem.splitScalar(u8, a, '.');
    var ib = std.mem.splitScalar(u8, b, '.');
    while (true) {
        const ca = ia.next();
        const cb = ib.next();
        if (ca == null and cb == null) return .eq;
        // A shorter version is the older one: 1.2 precedes 1.2.1.
        if (ca == null) return .lt;
        if (cb == null) return .gt;
        const na = std.fmt.parseUnsigned(u64, ca.?, 10) catch null;
        const nb = std.fmt.parseUnsigned(u64, cb.?, 10) catch null;
        if (na != null and nb != null) {
            switch (std.math.order(na.?, nb.?)) {
                .eq => continue,
                else => |o| return o,
            }
        }
        switch (std.mem.order(u8, ca.?, cb.?)) {
            .eq => continue,
            else => |o| return o,
        }
    }
}

// ------------------------------------------------------------- raw fd I/O

/// Write every byte to a raw descriptor.
///
/// `std.posix.write` is gone in 0.16 and `Io.File.writeStreamingAll` wants a
/// nonblocking flag we do not control on an inherited descriptor, so the
/// proxy talks to its descriptors through the syscall directly.
pub const writeAllFd = sys.writeAll;

/// Read stdin to end. Caller owns the returned memory.
pub fn readAllStdin(io: Io, gpa: Allocator) ![]u8 {
    var buf: [64 * 1024]u8 = undefined;
    var stdin = Io.File.stdin().readerStreaming(io, &buf);
    return stdin.interface.allocRemaining(gpa, .unlimited);
}

/// Set the clipboard by writing OSC 52 at the controlling terminal. Silently
/// does nothing without one, which is the same as the write not landing --
/// there is no channel to report it on.
pub fn writeOsc52ToTty(gpa: Allocator, data: []const u8, selection: []const u8) !void {
    const fd = sys.open("/dev/tty", .{ .ACCMODE = .WRONLY, .NOCTTY = true }, 0) catch return;
    defer sys.close(fd);
    try writeOsc52(gpa, fd, data, selection);
}

/// Write an OSC 52 clipboard-set sequence to a descriptor.
pub fn writeOsc52(gpa: Allocator, fd: posix.fd_t, data: []const u8, selection: []const u8) !void {
    const sel: u8 = if (std.mem.eql(u8, selection, "clipboard")) 'c' else 'p';
    const b64 = try b64EncodeAlloc(gpa, data);
    defer gpa.free(b64);
    var seq: std.ArrayList(u8) = .empty;
    defer seq.deinit(gpa);
    try seq.print(gpa, "\x1b]52;{c};{s}\x1b\\", .{ sel, b64 });
    writeAllFd(fd, seq.items) catch {};
}

// ----------------------------------------------------------------- logging

/// An append-only debug log under `$XDG_STATE_HOME`.
///
/// Every operation is best-effort: a program that cannot write its log still
/// has a job to do, and the one thing worse than no diagnostics is a paste
/// that fails because the log directory is read-only.
pub const Logger = struct {
    gpa: Allocator,
    path: ?[:0]u8,

    pub fn init(io: Io, gpa: Allocator, env: *const std.process.Environ.Map, basename: []const u8) Logger {
        return .{ .gpa = gpa, .path = resolve(io, gpa, env, basename) catch null };
    }

    fn resolve(io: Io, gpa: Allocator, env: *const std.process.Environ.Map, basename: []const u8) !?[:0]u8 {
        const dir: []u8 = blk: {
            if (env.get("XDG_STATE_HOME")) |v| if (v.len > 0) break :blk try gpa.dupe(u8, v);
            const home = env.get("HOME") orelse return null;
            break :blk try std.fmt.allocPrint(gpa, "{s}/.local/state", .{home});
        };
        defer gpa.free(dir);
        Io.Dir.cwd().createDirPath(io, dir) catch {};
        return try std.fmt.allocPrintSentinel(gpa, "{s}/{s}", .{ dir, basename }, 0);
    }

    pub fn deinit(l: *Logger) void {
        if (l.path) |p| l.gpa.free(p);
        l.* = undefined;
    }

    /// One `open` and one `write` per line: below `PIPE_BUF` an append-mode
    /// write is atomic, so the wrapper and the stub can share a log without
    /// interleaving each other mid-line and without any locking.
    pub fn print(l: *const Logger, comptime fmt: []const u8, args: anytype) void {
        const path = l.path orelse return;
        const fd = sys.open(path.ptr, .{
            .ACCMODE = .WRONLY,
            .CREAT = true,
            .APPEND = true,
            .CLOEXEC = true,
        }, 0o600) catch return;
        defer sys.close(fd);
        var buf: [4096]u8 = undefined;
        var w: Io.Writer = .fixed(&buf);
        w.print("[pid={d}] ", .{sys.getpid()}) catch return;
        w.print(fmt, args) catch {};
        w.writeByte('\n') catch {};
        writeAllFd(fd, w.buffered()) catch {};
    }
};

// ------------------------------------------------------------------- tests

test "mime names round-trip through the cache file name" {
    const gpa = std.testing.allocator;
    const f = try mimeToFileName(gpa, "image/png");
    defer gpa.free(f);
    try std.testing.expectEqualStrings("image_png", f);

    const m = try fileNameToMime(gpa, "image_png");
    defer gpa.free(m);
    try std.testing.expectEqualStrings("image/png", m);

    // Only the first separator is rewritten, so an underscore in the subtype
    // survives.
    const g = try mimeToFileName(gpa, "application/vnd.foo_bar");
    defer gpa.free(g);
    try std.testing.expectEqualStrings("application_vnd.foo_bar", g);
    const n = try fileNameToMime(gpa, g);
    defer gpa.free(n);
    try std.testing.expectEqualStrings("application/vnd.foo_bar", n);
}

test "findCompleteOsc locates a terminated sequence" {
    const buf = "abc\x1b]5522;status=OK\x1b\\rest";
    const r = findCompleteOsc(buf, 0);
    try std.testing.expectEqual(@as(usize, 3), r.complete.start);
    try std.testing.expectEqualStrings("\x1b]5522;status=OK\x1b\\", buf[r.complete.start..r.complete.end]);
}

test "findCompleteOsc accepts BEL as a terminator" {
    const buf = "\x1b]52;c;QQ==\x07tail";
    const r = findCompleteOsc(buf, 0);
    try std.testing.expectEqual(@as(usize, 0), r.complete.start);
    try std.testing.expectEqualStrings("\x1b]52;c;QQ==\x07", buf[r.complete.start..r.complete.end]);
}

test "findCompleteOsc holds back an unfinished sequence" {
    try std.testing.expectEqual(@as(usize, 2), findCompleteOsc("ab\x1b]5522;stat", 0).partial);
    // A trailing bare ESC is held back too: the ']' may be in the next read.
    try std.testing.expectEqual(@as(usize, 3), findCompleteOsc("abc\x1b", 0).partial);
    try std.testing.expect(findCompleteOsc("hello", 0) == .none);
    // An ESC that is not an OSC introducer is ordinary forwarded input.
    try std.testing.expect(findCompleteOsc("\x1b[200~x", 0) == .none);
}

test "parse5522 splits metadata from payload" {
    const p = parse5522("\x1b]5522;status=DATA:mime=aW1hZ2UvcG5n;AAAA\x07").?;
    try std.testing.expectEqualStrings("DATA", p.field("status").?);
    try std.testing.expectEqualStrings("aW1hZ2UvcG5n", p.field("mime").?);
    try std.testing.expectEqualStrings("AAAA", p.payload.?);
    try std.testing.expect(p.field("password") == null);

    const q = parse5522("\x1b]5522;status=DONE\x1b\\").?;
    try std.testing.expectEqualStrings("DONE", q.field("status").?);
    try std.testing.expect(q.payload == null);

    // Some other OSC is not ours.
    try std.testing.expect(parse5522("\x1b]52;c;AAA\x1b\\") == null);
}

test "chooseMime prefers images and ignores charset parameters" {
    const adv = [_][]const u8{ "text/plain;charset=utf-8", "image/png" };
    try std.testing.expectEqual(@as(?usize, 1), chooseMime(&adv));

    const text_only = [_][]const u8{"text/plain;charset=utf-8"};
    try std.testing.expectEqual(@as(?usize, 0), chooseMime(&text_only));

    const unknown = [_][]const u8{"application/x-foo"};
    try std.testing.expectEqual(@as(?usize, null), chooseMime(&unknown));
}

test "base64 decoding tolerates missing padding" {
    const gpa = std.testing.allocator;
    const a = try b64DecodeAlloc(gpa, "aGVsbG8");
    defer gpa.free(a);
    try std.testing.expectEqualStrings("hello", a);

    const b = try b64DecodeAlloc(gpa, "aGVsbG8=");
    defer gpa.free(b);
    try std.testing.expectEqualStrings("hello", b);

    const e = try b64EncodeAlloc(gpa, "hello");
    defer gpa.free(e);
    try std.testing.expectEqualStrings("aGVsbG8=", e);
}

test "parseXclipArgs understands the calls Claude Code makes" {
    const targets = [_][]const u8{ "xclip", "-selection", "clipboard", "-t", "TARGETS", "-o" };
    const a = parseXclipArgs(&targets);
    try std.testing.expectEqual(Action.out, a.action);
    try std.testing.expectEqualStrings("clipboard", a.selection);
    try std.testing.expectEqualStrings("TARGETS", a.target);

    const fetch = [_][]const u8{ "xclip", "-selection", "clipboard", "-t", "image/png", "-o" };
    try std.testing.expectEqualStrings("image/png", parseXclipArgs(&fetch).target);

    // No -o means a write, as in real xclip.
    const write = [_][]const u8{ "xclip", "-selection", "clipboard" };
    try std.testing.expectEqual(Action.in, parseXclipArgs(&write).action);

    try std.testing.expectEqualStrings("text/plain", targetToMime("UTF8_STRING"));
    try std.testing.expectEqualStrings("image/png", targetToMime("image/png"));
}

test "baseMime is what the cache is keyed on" {
    // The wire may offer parameters; the cache must not inherit them, or
    // the stub's lookup of `text/plain` misses the entry entirely.
    try std.testing.expectEqualStrings("text/plain", baseMime("text/plain;charset=utf-8"));
    try std.testing.expectEqualStrings("text/plain", baseMime(" text/plain ; charset=utf-8"));
    try std.testing.expectEqualStrings("image/png", baseMime("image/png"));

    const gpa = std.testing.allocator;
    const name = try mimeToFileName(gpa, baseMime("text/plain;charset=utf-8"));
    defer gpa.free(name);
    try std.testing.expectEqualStrings("text_plain", name);
}

test "mimeListIterator splits the advertisement the way the terminal writes it" {
    var it = mimeListIterator("text/plain;charset=utf-8 image/png text/html\n");
    try std.testing.expectEqualStrings("text/plain;charset=utf-8", it.next().?);
    try std.testing.expectEqualStrings("image/png", it.next().?);
    try std.testing.expectEqualStrings("text/html", it.next().?);
    try std.testing.expect(it.next() == null);
}

test "collectAdvertisedMimes reads a real ghostty paste-event listing" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList([]u8) = .empty;
    defer {
        for (out.items) |m| gpa.free(m);
        out.deinit(gpa);
    }

    // Exactly what ghostty writes: the targets pseudo-type in `mime`
    // (base64 "."), the list in the payload, and `pw` -- not `password`.
    const listing = "\x1b]5522;type=read:status=DATA:mime=Lg==:pw=b3RwCg==;" ++
        "dGV4dC9wbGFpbjtjaGFyc2V0PXV0Zi04IGltYWdlL3BuZwo=\x1b\\";
    const packet = parse5522(listing).?;
    try std.testing.expectEqualStrings("b3RwCg==", packet.field("pw").?);
    try std.testing.expect(packet.field("password") == null);

    try collectAdvertisedMimes(gpa, packet, &out);
    try std.testing.expectEqual(@as(usize, 2), out.items.len);
    try std.testing.expectEqualStrings("text/plain;charset=utf-8", out.items[0]);
    try std.testing.expectEqualStrings("image/png", out.items[1]);

    // And the image wins the preference, as it must for a screenshot.
    const view = try gpa.alloc([]const u8, out.items.len);
    defer gpa.free(view);
    for (out.items, 0..) |m, i| view[i] = m;
    try std.testing.expectEqual(@as(?usize, 1), chooseMime(view));
}

test "collectAdvertisedMimes also accepts one type per packet" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList([]u8) = .empty;
    defer {
        for (out.items) |m| gpa.free(m);
        out.deinit(gpa);
    }
    const one = "\x1b]5522;type=read:status=DATA:mime=aW1hZ2UvcG5n\x1b\\";
    try collectAdvertisedMimes(gpa, parse5522(one).?, &out);
    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expectEqualStrings("image/png", out.items[0]);
}

test "compareVersionNames orders numerically, not lexicographically" {
    try std.testing.expectEqual(std.math.Order.lt, compareVersionNames("0.9.9", "0.9.10"));
    try std.testing.expectEqual(std.math.Order.gt, compareVersionNames("1.10.0", "1.9.0"));
    try std.testing.expectEqual(std.math.Order.eq, compareVersionNames("1.2.3", "1.2.3"));
    try std.testing.expectEqual(std.math.Order.lt, compareVersionNames("1.2", "1.2.1"));
    try std.testing.expectEqual(std.math.Order.lt, compareVersionNames("1.2.3-beta", "1.2.3-rc"));
}

test "terminal sniffing" {
    const gpa = std.testing.allocator;
    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();

    try std.testing.expect(!isSupportedTerminal(&env));

    try env.put("TERM", "xterm-ghostty");
    try std.testing.expect(isGhostty(&env));
    try std.testing.expect(!isKitty(&env));
    try std.testing.expect(isSupportedTerminal(&env));

    try env.put("TERM", "xterm-kitty");
    try std.testing.expect(isKitty(&env));
    try std.testing.expect(!isGhostty(&env));
}

test "reference every declaration so lazy analysis cannot hide a broken one" {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(Logger);
    std.testing.refAllDecls(Packet);
}
