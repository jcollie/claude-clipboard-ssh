// SPDX-FileCopyrightText: © 2026 mindfulmonk <mindfulmonk@users.noreply.github.com>
// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

const std = @import("std");

/// Where the `xclip` stub is installed, relative to the install prefix. The
/// wrapper prepends this directory to the PATH it hands the child `claude`,
/// so the stub shadows the real xclip for that process tree and nothing else
/// -- which is why it is not in `bin/`.
const shim_subdir = "libexec/claude-clipboard-ssh";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Baked into the wrapper so a packaged build knows where its own stub
    // landed without having to guess. Nix passes
    // `-Dshim-dir=${placeholder "out"}/libexec/claude-clipboard-ssh`; a
    // developer build leaves it null and the wrapper derives the path from
    // `std.process.executableDirPath` instead.
    const shim_dir = b.option(
        []const u8,
        "shim-dir",
        "Absolute path of the directory holding the xclip stub (default: derived at run time)",
    );

    // The debug tools are for a person chasing a terminal problem, not for
    // anyone running `claude`, so the package leaves them out. A plain
    // `zig build` still puts them in `zig-out/bin`.
    const with_tools = b.option(
        bool,
        "tools",
        "Install the debug tools alongside the wrapper (default: true)",
    ) orelse true;

    const options = b.addOptions();
    options.addOption(?[]const u8, "shim_dir", shim_dir);
    options.addOption([]const u8, "shim_subdir", shim_subdir);
    const build_options = options.createModule();

    // The package is named `known_folders`; the module inside it is named
    // `known-folders`. Both spellings matter.
    const known_folders = b.dependency("known_folders", .{
        .target = target,
        .optimize = optimize,
    }).module("known-folders");

    // Everything the five programs share: the OSC 5522 framing scanner and
    // packet parser, the clipboard cache layout, the debug log, the terminal
    // sniffing, the shim-directory discovery.
    const ccssh = b.addModule("ccssh", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "build_options", .module = build_options },
            .{ .name = "known-folders", .module = known_folders },
        },
    });

    const test_step = b.step("test", "Run the unit tests");
    const check_step = b.step("check", "Compile everything without running it");

    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = ccssh })).step);
    check_step.dependOn(&b.addTest(.{ .root_module = ccssh }).step);

    // The OSC framing scanner is the one function whose mistakes are silent
    // and costly -- every byte it mis-slices is a keystroke the user typed
    // that `claude` never sees -- so it gets a property test of its own.
    const fuzz_mod = b.createModule(.{
        .root_source_file = b.path("tests/fuzz.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "ccssh", .module = ccssh }},
    });
    const fuzz_tests = b.addTest(.{ .root_module = fuzz_mod });
    test_step.dependOn(&b.addRunArtifact(fuzz_tests).step);
    check_step.dependOn(&fuzz_tests.step);

    // A program is a name, a root source file, and where it is installed.
    const Program = struct {
        name: []const u8,
        root: []const u8,
        /// `.default` is `bin/`; the stub goes to libexec instead.
        dest_dir: std.Build.Step.InstallArtifact.Options.Dir = .default,
        /// Whether this program is one of the debug tools, which are
        /// installed only when `-Dtools` is on.
        tool: bool = false,
    };

    const programs = [_]Program{
        .{ .name = "claude-wrap", .root = "src/claude_wrap.zig" },
        // All three clipboard tools Claude Code may reach for, because
        // shadowing only one of them lets it take a path that bypasses the
        // cache and reports an empty clipboard.
        .{
            .name = "xclip",
            .root = "src/xclip.zig",
            .dest_dir = .{ .override = .{ .custom = shim_subdir } },
        },
        .{
            .name = "wl-paste",
            .root = "src/wl_paste.zig",
            .dest_dir = .{ .override = .{ .custom = shim_subdir } },
        },
        .{
            .name = "wl-copy",
            .root = "src/wl_copy.zig",
            .dest_dir = .{ .override = .{ .custom = shim_subdir } },
        },
        // The debug tools. Note they must never land in the libexec
        // directory: that directory is prepended to the PATH the child
        // `claude` runs with, and nothing belongs there that is not
        // deliberately shadowing a command.
        .{ .name = "ccssh-probe", .root = "tools/probe.zig", .tool = true },
        .{ .name = "ccssh-ghostty-test", .root = "tools/ghostty_test.zig", .tool = true },
        .{ .name = "ccssh-dump-paste", .root = "tools/dump_paste.zig", .tool = true },
    };

    for (programs) |program| {
        const mod = b.createModule(.{
            .root_source_file = b.path(program.root),
            .target = target,
            .optimize = optimize,
            // `null` is "no opinion": nothing here calls a C library
            // function, so the Linux builds link no libc and come out
            // static, while Darwin still gets libSystem, which it must
            // have because its syscall ABI is private.
            .link_libc = null,
            .imports = &.{
                .{ .name = "ccssh", .module = ccssh },
                .{ .name = "build_options", .module = build_options },
            },
        });

        const exe = b.addExecutable(.{ .name = program.name, .root_module = mod });
        if (with_tools or !program.tool) {
            const install = b.addInstallArtifact(exe, .{ .dest_dir = program.dest_dir });
            b.getInstallStep().dependOn(&install.step);
        }
        check_step.dependOn(&exe.step);

        const unit_tests = b.addTest(.{ .root_module = mod });
        test_step.dependOn(&b.addRunArtifact(unit_tests).step);
        check_step.dependOn(&unit_tests.step);
    }

    // `zig fmt --check` as a build step, so CI and a local `zig build fmt`
    // disagree about nothing. Explicit paths rather than `.`, so the step is
    // immune to `zig-pkg/` and `zig-out/` being present.
    const fmt = b.addFmt(.{
        .paths = &.{ "build.zig", "src", "tests", "tools" },
        .check = true,
    });
    const fmt_step = b.step("fmt", "Check that the Zig sources are formatted");
    fmt_step.dependOn(&fmt.step);
    check_step.dependOn(&fmt.step);
}
