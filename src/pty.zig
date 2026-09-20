// SPDX-FileCopyrightText: © 2026 mindfulmonk <mindfulmonk@users.noreply.github.com>
// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Pseudo-terminal allocation and raw mode, with no C library involved.
//!
//! `posix_openpt`, `grantpt`, `unlockpt` and `ptsname` are not system calls;
//! each is a short libc function wrapping an `open` and one or two ioctls,
//! and those ioctls are what this does directly. On Linux that leaves the
//! programs with no libc dependency at all -- the build links none, and the
//! binaries come out static. On Darwin the kernel's syscall ABI is private
//! and libSystem is the only supported entry point, so libc is linked there
//! whatever we do; the ioctls below are still the same ones Apple's libc
//! would have issued on our behalf.

const std = @import("std");
const builtin = @import("builtin");
const sys = @import("sys.zig");

const posix = std.posix;
const native_os = builtin.os.tag;

const is_darwin = switch (native_os) {
    .macos, .ios, .tvos, .watchos, .visionos, .driverkit => true,
    else => false,
};

/// BSD-style ioctl request encoding, which is how Darwin numbers these.
/// Linux's are computed by `std.os.linux.T` already.
const darwin_ioc = struct {
    const VOID: u32 = 0x2000_0000;
    const OUT: u32 = 0x4000_0000;
    const PARM_MASK: u32 = 0x1fff;

    fn io(group: u32, num: u32) u32 {
        return VOID | (group << 8) | num;
    }
    fn ior(group: u32, num: u32, len: u32) u32 {
        return OUT | ((len & PARM_MASK) << 16) | (group << 8) | num;
    }
};

/// Make the calling process's controlling terminal this descriptor.
pub const TIOCSCTTY: u32 = switch (native_os) {
    .linux => @intCast(std.os.linux.T.IOCSCTTY),
    // _IO('t', 97)
    else => if (is_darwin) darwin_ioc.io('t', 97) else @compileError("unsupported os"),
};

/// Missing from `std.c.T` on Darwin in 0.16, which defines only `IOCGWINSZ`.
pub const TIOCSWINSZ: u32 = switch (native_os) {
    .linux => @intCast(std.os.linux.T.IOCSWINSZ),
    // _IOW('t', 103, struct winsize)
    else => if (is_darwin) 0x8008_7467 else @compileError("unsupported os"),
};

pub const TIOCGWINSZ: u32 = switch (native_os) {
    .linux => @intCast(std.os.linux.T.IOCGWINSZ),
    // _IOR('t', 104, struct winsize)
    else => if (is_darwin) 0x4008_7468 else @compileError("unsupported os"),
};

/// Linux: clear the slave's lock. Darwin spells the same idea `TIOCPTYUNLK`.
const TIOCSPTLCK: u32 = if (native_os == .linux) @intCast(std.os.linux.T.IOCSPTLCK) else 0;
/// Linux: read back the slave's number, which names `/dev/pts/<n>`.
const TIOCGPTN: u32 = if (native_os == .linux) @intCast(std.os.linux.T.IOCGPTN) else 0;

/// Darwin's equivalents of `grantpt`, `unlockpt` and `ptsname`. These are
/// exactly what Apple's libc issues for those three functions.
const TIOCPTYGRANT: u32 = darwin_ioc.io('t', 84);
const TIOCPTYUNLK: u32 = darwin_ioc.io('t', 82);
/// _IOC(IOC_OUT, 't', 83, 128): writes the slave path into a 128-byte buffer.
const TIOCPTYGNAME: u32 = darwin_ioc.ior('t', 83, darwin_slave_name_len);
const darwin_slave_name_len = 128;

pub const Error = error{
    OpenPtFailed,
    GrantPtFailed,
    UnlockPtFailed,
    PtsNameFailed,
    ForkFailed,
};

pub const Child = struct {
    master: posix.fd_t,
    pid: posix.pid_t,
};

/// Storage for the slave device path, which is short and fixed-shape on
/// both platforms, so there is no reason to allocate for it.
const SlavePath = struct {
    buf: [darwin_slave_name_len]u8,

    fn path(p: *const SlavePath) [*:0]const u8 {
        return @ptrCast(&p.buf);
    }
};

/// Open the multiplexer and unlock a slave, returning the master and the
/// slave's path.
fn openPt(out: *SlavePath) Error!posix.fd_t {
    const master = sys.open(
        "/dev/ptmx",
        .{ .ACCMODE = .RDWR, .NOCTTY = true },
        0,
    ) catch return error.OpenPtFailed;
    errdefer sys.close(master);

    @memset(&out.buf, 0);

    if (native_os == .linux) {
        // On a devpts mount the kernel already gives the slave the right
        // owner and mode, which is why glibc's `grantpt` has nothing left
        // to do and there is nothing to call here.
        var unlock: c_int = 0;
        sys.ioctl(master, TIOCSPTLCK, @intFromPtr(&unlock)) catch return error.UnlockPtFailed;

        var number: c_uint = 0;
        sys.ioctl(master, TIOCGPTN, @intFromPtr(&number)) catch return error.PtsNameFailed;

        _ = std.fmt.bufPrintZ(&out.buf, "/dev/pts/{d}", .{number}) catch return error.PtsNameFailed;
    } else if (is_darwin) {
        sys.ioctl(master, TIOCPTYGRANT, 0) catch return error.GrantPtFailed;
        sys.ioctl(master, TIOCPTYUNLK, 0) catch return error.UnlockPtFailed;
        sys.ioctl(master, TIOCPTYGNAME, @intFromPtr(&out.buf)) catch return error.PtsNameFailed;
        // The kernel writes a NUL-terminated path; refuse anything else
        // rather than run off the end of the buffer.
        if (std.mem.indexOfScalar(u8, &out.buf, 0) == null) return error.PtsNameFailed;
    } else {
        @compileError("unsupported os");
    }

    return master;
}

/// Allocate a pty, fork, and in the child become a session leader with the
/// slave as controlling terminal before exec'ing `exe`.
///
/// The ordering is load-bearing: `setsid` must come before the slave is
/// opened, or the child keeps the terminal it inherited; `TIOCSCTTY` must
/// come after, because only a session leader with no controlling terminal
/// can acquire one. The master is opened `O_NOCTTY` and the slave
/// deliberately is not.
///
/// Returns only in the parent; the child either execs or exits.
pub fn forkExec(
    exe: [*:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
) Error!Child {
    var slave_path: SlavePath = undefined;
    const master = try openPt(&slave_path);
    errdefer sys.close(master);

    const pid = sys.fork() catch return error.ForkFailed;
    if (pid == 0) {
        // Async-signal-safe calls only, from here until execve.
        sys.close(master);
        sys.setsid() catch sys.exitProcess(127);
        const slave = sys.open(slave_path.path(), .{ .ACCMODE = .RDWR }, 0) catch
            sys.exitProcess(127);
        sys.ioctl(slave, TIOCSCTTY, 0) catch sys.exitProcess(127);
        sys.dup2(slave, posix.STDIN_FILENO) catch sys.exitProcess(127);
        sys.dup2(slave, posix.STDOUT_FILENO) catch sys.exitProcess(127);
        sys.dup2(slave, posix.STDERR_FILENO) catch sys.exitProcess(127);
        if (slave > posix.STDERR_FILENO) sys.close(slave);
        sys.execve(exe, argv, envp) catch {};
        sys.exitProcess(127);
    }
    return .{ .master = master, .pid = pid };
}

pub fn getWinsize(fd: posix.fd_t) ?posix.winsize {
    var ws: posix.winsize = undefined;
    sys.ioctl(fd, TIOCGWINSZ, @intFromPtr(&ws)) catch return null;
    return ws;
}

pub fn setWinsize(fd: posix.fd_t, ws: posix.winsize) void {
    sys.ioctl(fd, TIOCSWINSZ, @intFromPtr(&ws)) catch {};
}

/// Saved terminal settings, so the shell the user came from is handed back
/// the way it was lent.
pub const RawMode = struct {
    fd: posix.fd_t,
    orig: posix.termios,

    /// There is no `cfmakeraw` in Zig's std, so this is it, written out.
    /// The flag words are packed structs of booleans in 0.16, not bitmasks,
    /// and `CSIZE` is an enum field rather than two bits.
    pub fn enable(fd: posix.fd_t) !RawMode {
        const orig = try posix.tcgetattr(fd);
        var raw = orig;
        raw.iflag.IGNBRK = false;
        raw.iflag.BRKINT = false;
        raw.iflag.PARMRK = false;
        raw.iflag.ISTRIP = false;
        raw.iflag.INLCR = false;
        raw.iflag.IGNCR = false;
        raw.iflag.ICRNL = false;
        raw.iflag.IXON = false;
        raw.oflag.OPOST = false;
        raw.lflag.ECHO = false;
        raw.lflag.ECHONL = false;
        raw.lflag.ICANON = false;
        raw.lflag.ISIG = false;
        raw.lflag.IEXTEN = false;
        raw.cflag.CSIZE = .CS8;
        raw.cflag.PARENB = false;
        raw.cc[@intFromEnum(posix.V.MIN)] = 1;
        raw.cc[@intFromEnum(posix.V.TIME)] = 0;
        try posix.tcsetattr(fd, .FLUSH, raw);
        return .{ .fd = fd, .orig = orig };
    }

    pub fn restore(r: RawMode) void {
        posix.tcsetattr(r.fd, .DRAIN, r.orig) catch {};
    }
};

test "the Darwin ioctl encodings match the numbers in sys/ttycom.h" {
    // Spelled out because they are computed for a platform the tests may
    // not be running on, and a wrong one fails as an opaque ENOTTY.
    try std.testing.expectEqual(@as(u32, 0x2000_7454), darwin_ioc.io('t', 84)); // TIOCPTYGRANT
    try std.testing.expectEqual(@as(u32, 0x2000_7452), darwin_ioc.io('t', 82)); // TIOCPTYUNLK
    try std.testing.expectEqual(@as(u32, 0x4080_7453), darwin_ioc.ior('t', 83, 128)); // TIOCPTYGNAME
    try std.testing.expectEqual(@as(u32, 0x2000_7461), darwin_ioc.io('t', 97)); // TIOCSCTTY
    try std.testing.expectEqual(@as(u32, 0x4008_7468), darwin_ioc.ior('t', 104, 8)); // TIOCGWINSZ
}

test "a pty can be allocated, and its slave path names a real device" {
    var slave: SlavePath = undefined;
    const master = openPt(&slave) catch |e| {
        // No /dev/ptmx in the sandbox is a reason to skip, not to fail.
        if (e == error.OpenPtFailed) return error.SkipZigTest;
        return e;
    };
    defer sys.close(master);

    const path = std.mem.sliceTo(&slave.buf, 0);
    try std.testing.expect(path.len > 0);
    try std.testing.expect(std.mem.startsWith(u8, path, "/dev/"));

    const st = try std.Io.Dir.cwd().statFile(std.testing.io, path, .{});
    try std.testing.expectEqual(std.Io.File.Kind.character_device, st.kind);
}

test "reference every declaration so lazy analysis cannot hide a broken one" {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(RawMode);
}
