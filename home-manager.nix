# SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
# SPDX-License-Identifier: MIT

# A home-manager module for claude-clipboard-ssh.
#
# It installs the two programs and, when `programs.claude-code` is managing
# Claude Code, tells `claude-wrap` exactly which `claude` to run. That is the
# whole point of the integration: left to itself the wrapper has to guess,
# searching ~/.local/share/claude/versions and then the PATH, and a store
# path from `programs.claude-code.finalPackage` is not a guess.

{ self }:

{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.programs.claude-clipboard-ssh;
  claudeCode = config.programs.claude-code;

  # True when claude-code is both enabled and actually installing a package.
  # `programs.claude-code.package` is nullable: someone may use that module
  # only to write settings, with claude installed by other means.
  claudeCodeProvidesPackage = claudeCode.enable && claudeCode.package != null;
in
{
  options.programs.claude-clipboard-ssh = {
    enable = lib.mkEnableOption ''
      claude-clipboard-ssh, which lets Claude Code paste images by speaking
      OSC 5522 to kitty or ghostty, whether `claude` is running locally or
      over SSH.

      Over SSH it is what makes image paste possible at all, since the remote
      box has no display to read a clipboard from. Locally it is what makes
      the terminal's own paste shortcut work -- Ctrl+Shift+V, or Cmd+V on
      macOS -- which otherwise does nothing for an image
    '';

    package = lib.mkOption {
      type = lib.types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.claude-clipboard-ssh;
      defaultText = lib.literalExpression "claude-clipboard-ssh.packages.\${system}.claude-clipboard-ssh";
      description = ''
        The claude-clipboard-ssh package to install. It provides
        {command}`claude-wrap` in `bin` and the {command}`xclip` stub in
        `libexec`, which is deliberately not on any PATH -- the wrapper puts
        it on the one it hands the child {command}`claude`.
      '';
    };

    claudeBin = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default =
        if claudeCodeProvidesPackage then "${claudeCode.finalPackage}/bin/claude" else null;
      defaultText = lib.literalExpression ''
        "''${config.programs.claude-code.finalPackage}/bin/claude"
          when programs.claude-code is enabled with a package, else null
      '';
      description = ''
        The {command}`claude` executable {command}`claude-wrap` should run,
        exported as {env}`CLAUDE_WRAP_CLAUDE_BIN`.

        Taken from {option}`programs.claude-code.finalPackage` by default, so
        the wrapper runs the same Claude Code that module installed --
        plugins, wrappers and all -- rather than searching for one. Set to
        `null` to let the wrapper search on its own.
      '';
    };

    aliasClaude = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Alias {command}`claude` to {command}`claude-wrap` in every enabled
        shell.

        Safe as a blanket alias: on a terminal without OSC 5522 the wrapper
        {manpage}`execve(2)`s the real {command}`claude` and adds no pty and
        no overhead. The alias affects interactive shells only, so scripts
        calling {command}`claude` still get the unwrapped one.
      '';
    };

    kittyClipboardControl = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Set {option}`programs.kitty.settings.clipboard_control` to permit
        clipboard reads without a confirmation dialog.

        Off by default because it is only meaningful on the machine you are
        **sitting at**, and this module is otherwise for the remote one. If a
        single home configuration covers both, turning this on saves a prompt
        on every paste -- and a slow prompt can push the round trip past
        ghostty's five-second password lifetime, which fails the paste.

        Applied with {option}`lib.mkDefault`, so your own setting wins.
      '';
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      home.packages = [ cfg.package ];

      warnings = lib.optional (cfg.claudeBin == null) ''
        programs.claude-clipboard-ssh is enabled but no `claude` executable
        is pinned, because programs.claude-code is not installing one. The
        wrapper will fall back to searching ~/.local/share/claude/versions,
        ~/.claude/local and then the PATH. Set
        programs.claude-clipboard-ssh.claudeBin to be explicit about it.
      '';
    }

    (lib.mkIf (cfg.claudeBin != null) {
      home.sessionVariables.CLAUDE_WRAP_CLAUDE_BIN = cfg.claudeBin;
    })

    (lib.mkIf cfg.aliasClaude {
      programs.bash.shellAliases.claude = "claude-wrap";
      programs.zsh.shellAliases.claude = "claude-wrap";
      programs.fish.shellAliases.claude = "claude-wrap";
    })

    (lib.mkIf cfg.kittyClipboardControl {
      programs.kitty.settings.clipboard_control =
        lib.mkDefault "write-clipboard write-primary read-clipboard read-primary";
    })
  ]);
}
