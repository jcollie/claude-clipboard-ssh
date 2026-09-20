# SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
# SPDX-License-Identifier: MIT

{
  description = "Image paste over SSH for Claude Code, by speaking OSC 5522 to kitty or ghostty";

  inputs = {
    nixpkgs = {
      url = "https://channels.nixos.org/nixos-unstable/nixexprs.tar.xz";
    };
    zon2nix = {
      url = "github:jcollie/zon2nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      nixpkgs,
      zon2nix,
      ...
    }:
    let
      inherit (nixpkgs) lib;
      makePackages = system: import nixpkgs { inherit system; };
      forAllSystems = lib.genAttrs lib.systems.flakeExposed;

      fuzzableZig =
        pkgs:
        let
          library = pkgs.runCommand "zig-0.16.0-lib-fuzz-fix" { } ''
            cp -rs --no-preserve=mode ${pkgs.zig_0_16}/lib/zig $out
            chmod -R u+w $out
            rm $out/compiler/test_runner.zig
            cp --no-preserve=mode \
              ${pkgs.zig_0_16}/lib/zig/compiler/test_runner.zig \
              $out/compiler/test_runner.zig
            substituteInPlace $out/compiler/test_runner.zig \
              --replace-fail \
                'std.debug.writeStackTrace(trace, stderr)' \
                'std.debug.writeErrorReturnTrace(trace, stderr)'
          '';
        in
        pkgs.symlinkJoin {
          name = "zig-0.16.0-fuzzable";
          paths = [ pkgs.zig_0_16 ];
          nativeBuildInputs = [ pkgs.makeWrapper ];
          postBuild = ''
            wrapProgram $out/bin/zig --set ZIG_LIB_DIR ${library}
          '';
        };
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = makePackages system;
        in
        rec {
          claude-clipboard-ssh = pkgs.callPackage ./package.nix { };
          default = claude-clipboard-ssh;
          zig-deps = pkgs.callPackage ./build.zig.zon.nix { };
        }
      );

      devShells = forAllSystems (
        system:
        let
          pkgs = makePackages system;
        in
        {
          default = pkgs.mkShell {
            name = "claude-clipboard-ssh";
            nativeBuildInputs = [
              (fuzzableZig pkgs)
              pkgs.reuse
            ]
            ++ lib.optional (zon2nix.packages ? ${system}) (pkgs.symlinkJoin {
              name = "zon2nix";
              paths = [ zon2nix.packages.${system}.zon2nix ];
              nativeBuildInputs = [ pkgs.makeWrapper ];
              postBuild = ''
                wrapProgram $out/bin/zon2nix \
                  --prefix PATH : ${lib.makeBinPath [ pkgs.zig_0_16 ]}
              '';
            });
          };
        }
      );
    };
}
