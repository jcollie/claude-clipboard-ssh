# SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
# SPDX-License-Identifier: MIT

{
  lib,
  stdenv,
  callPackage,
  zig_0_16,
}:

let
  # Generated from build.zig.zon by zon2nix; regenerate with
  #   nix develop -c zon2nix --16 --nix=build.zig.zon.nix build.zig.zon
  zigDeps = callPackage ./build.zig.zon.nix { };
in
stdenv.mkDerivation (finalAttrs: {
  pname = "claude-clipboard-ssh";
  version = "0.1.0";

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./build.zig
      ./build.zig.zon
      ./src
      # `doCheck` runs `zig build test`, so the tests are part of the source
      # the package is built from, not an extra.
      ./tests
      ./tools
    ];
  };

  nativeBuildInputs = [ zig_0_16 ];

  zigBuildFlags = [
    "--system"
    "${zigDeps}"
    "-Dshim-dir=${placeholder "out"}/libexec/claude-clipboard-ssh"
    # The debug tools are for hacking on the protocol, not for using it.
    # They are still built (and tested) here, just not installed.
    "-Dtools=false"
  ];

  zigCheckFlags = finalAttrs.zigBuildFlags;

  doCheck = true;

  meta = {
    description = "Image paste over SSH for Claude Code, by speaking OSC 5522 to kitty or ghostty";
    homepage = "https://github.com/jcollie/claude-clipboard-ssh";
    license = lib.licenses.mit;
    mainProgram = "claude-wrap";
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
  };
})
