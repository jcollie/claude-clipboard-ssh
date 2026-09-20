// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! The handful of system calls this project needs, wrapped once.
//!
//! Zig 0.16 moved most of `std.posix` behind `std.Io`, and what it left
//! behind does not include `fork`, `setsid`, `execve`, `dup2`, `ioctl`,
//! `write`, `close` or `waitpid`. Those still exist in `std.posix.system`,
//! which resolves to `std.c` when libc is linked and to `std.os.linux` when
//! it is not -- so writing them out here in the shape `std.posix` uses
//! internally (`system.f()` then `switch (errno(rc))`) is what lets the
//! Linux build make raw syscalls and need no libc at all.
//!
//! Three calls have genuinely different signatures between the two
//! backends and are branched on explicitly; everything else is uniform.

const std = @import("std");
const builtin = @import("builtin");

const posix = std.posix;
const system = posix.system;
const native_os = builtin.os.tag;

/// True when `std.posix.system` is `std.c`. On Darwin this is always the
/// case: the kernel's syscall ABI is private and libSystem is the only
/// supported way in, so a libc-free Darwin build is not a thing to aim for.
pub const use_libc = builtin.link_libc;

pub const Error = error{SystemCallFailed};

pub const fd_t = posix.fd_t;
pub const pid_t = posix.pid_t;

fn check(rc: anytype) Error!void {
    return switch (posix.errno(rc)) {
        .SUCCESS => {},
        else => error.SystemCallFailed,
    };
}

pub fn open(path: [*:0]const u8, flags: posix.O, mode: posix.mode_t) Error!fd_t {
    while (true) {
        const rc = system.open(path, flags, mode);
        switch (posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            else => return error.SystemCallFailed,
        }
    }
}

pub fn close(fd: fd_t) void {
    // Deliberately unchecked: there is nothing useful to do about a failed
    // close, and retrying one risks closing a descriptor another thread has
    // since been handed.
    _ = system.close(fd);
}

/// Write every byte, retrying short writes and `EINTR`.
pub fn writeAll(fd: fd_t, bytes: []const u8) error{WriteFailed}!void {
    var i: usize = 0;
    while (i < bytes.len) {
        const rc = system.write(fd, bytes.ptr + i, bytes.len - i);
        switch (posix.errno(rc)) {
            .SUCCESS => {},
            .INTR => continue,
            // EPIPE or EIO on a dead pty; the caller unwinds.
            else => return error.WriteFailed,
        }
        const n: usize = @intCast(rc);
        if (n == 0) return error.WriteFailed;
        i += n;
    }
}

/// `arg` is either a small integer or `@intFromPtr` of the struct the
/// request expects.
pub fn ioctl(fd: fd_t, request: u32, arg: usize) Error!void {
    // `std.c.ioctl` is variadic and takes a signed request; the Linux one
    // takes an unsigned request and an explicit argument word.
    const rc = if (use_libc)
        system.ioctl(fd, @as(c_int, @bitCast(request)), arg)
    else
        system.ioctl(fd, request, arg);
    return check(rc);
}

pub fn fork() Error!pid_t {
    const rc = system.fork();
    try check(rc);
    return @intCast(rc);
}

pub fn setsid() Error!void {
    return check(system.setsid());
}

pub fn dup2(old: fd_t, new: fd_t) Error!void {
    while (true) {
        const rc = system.dup2(old, new);
        switch (posix.errno(rc)) {
            .SUCCESS => return,
            .INTR => continue,
            else => return error.SystemCallFailed,
        }
    }
}

/// Replace this process image. Returns only if the exec failed, which is
/// why the success case is `noreturn`.
pub fn execve(
    path: [*:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
) Error!noreturn {
    _ = system.execve(path, argv, envp);
    return error.SystemCallFailed;
}

/// Terminate without running any atexit handler or flushing anything. The
/// only correct way out of a forked child that could not exec.
pub fn exitProcess(code: u8) noreturn {
    if (use_libc) std.c._exit(code) else std.os.linux.exit_group(code);
}

pub fn getuid() posix.uid_t {
    return system.getuid();
}

pub fn getpid() pid_t {
    return system.getpid();
}

/// Wait for one child and return its raw wait status.
pub fn waitpid(pid: pid_t) Error!u32 {
    while (true) {
        var status: u32 = 0;
        const rc = blk: {
            if (use_libc) {
                var s: c_int = 0;
                const r = std.c.waitpid(pid, &s, 0);
                status = @bitCast(s);
                break :blk r;
            }
            break :blk std.os.linux.wait4(pid, &status, 0, null);
        };
        switch (posix.errno(rc)) {
            .SUCCESS => return status,
            .INTR => continue,
            else => return error.SystemCallFailed,
        }
    }
}

test "reference every declaration so lazy analysis cannot hide a broken one" {
    std.testing.refAllDecls(@This());
}
