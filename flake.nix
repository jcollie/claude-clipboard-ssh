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
    # Only so that `nix flake check` can evaluate the home-manager module
    # against the real thing. Nothing in the package depends on it.
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      zon2nix,
      home-manager,
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

      homeModules = {
        claude-clipboard-ssh = import ./home-manager.nix { inherit self; };
        default = self.homeModules.claude-clipboard-ssh;
      };

      overlays.default = final: _prev: {
        claude-clipboard-ssh = final.callPackage ./package.nix { };
      };

      # A home-manager module that does not evaluate is the usual way one of
      # these breaks, and nothing else here would catch it. `claude-code` is
      # unfree, so this pkgs instance says so.
      checks = lib.genAttrs (lib.filter (lib.hasSuffix "-linux") lib.systems.flakeExposed) (
        system:
        let
          pkgs = import nixpkgs {
            inherit system;
            config.allowUnfree = true;
          };
          homeConfig =
            module:
            (home-manager.lib.homeManagerConfiguration {
              inherit pkgs;
              modules = [
                self.homeModules.default
                {
                  home = {
                    username = "test";
                    homeDirectory = "/home/test";
                    stateVersion = "24.11";
                  };
                }
                module
              ];
            }).activationPackage;
        in
        {
          # The integration that matters: claude-wrap is pointed at the very
          # claude that programs.claude-code installed.
          home-manager-with-claude-code = homeConfig {
            programs.claude-code = {
              enable = true;
              settings.theme = "dark";
            };
            programs.claude-clipboard-ssh.enable = true;
            programs.fish.enable = true;
          };

          # claude-code managing settings but installing nothing:
          # `programs.claude-code.package` is nullable, and in that case
          # `finalPackage` has no value at all, so reading it unguarded is an
          # eval error rather than a null.
          home-manager-claude-code-without-package = homeConfig {
            programs.claude-code = {
              enable = true;
              package = null;
              settings.theme = "dark";
            };
            programs.claude-clipboard-ssh.enable = true;
          };

          # And it still evaluates when claude-code is not in use at all.
          home-manager-without-claude-code = homeConfig {
            programs.claude-clipboard-ssh = {
              enable = true;
              claudeBin = "/home/test/.local/bin/claude";
            };
            programs.bash.enable = true;
          };
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
