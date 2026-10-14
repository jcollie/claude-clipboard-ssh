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

  # The package actually installed: `claude-wrap`, and with `installAsClaude`
  # also `claude`, each carrying the path of the real binary baked in.
  #
  # Baked in rather than exported through home.sessionVariables, because an
  # exported store path goes stale. hm-session-vars is read once per login,
  # and from there the value is copied into the systemd user manager's
  # environment and inherited by everything it starts -- a terminal, and so
  # every shell opened in it. After a switch to a new claude-code, all of
  # those kept handing the wrapper the old store path until the next logout.
  # A path in the wrapper script changes the moment the generation does.
  #
  # `--set`, not `--set-default`, for the same reason: a stale
  # CLAUDE_WRAP_CLAUDE_BIN inherited from a session that predates this module
  # would otherwise still win. To run a different `claude`, set `claudeBin`.
  #
  # Both names are wrapped, so the alias and `installAsClaude` behave alike.
  # With `installAsClaude` the real `claude` is off the PATH, so this is the
  # wrapper's only route to it; with the alias it saves a search that would
  # look in ~/.local/share/claude/versions before the PATH.
  wrappedPackage = pkgs.runCommandLocal "claude-clipboard-ssh-wrapped" {
    nativeBuildInputs = [ pkgs.makeWrapper ];
  } (''
    makeWrapper ${cfg.package}/bin/claude-wrap $out/bin/claude-wrap \
      --set CLAUDE_WRAP_CLAUDE_BIN ${cfg.claudeBin}
  '' + lib.optionalString cfg.installAsClaude ''
    makeWrapper ${cfg.package}/bin/claude-wrap $out/bin/claude \
      --set CLAUDE_WRAP_CLAUDE_BIN ${cfg.claudeBin}
  '');
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

    claudePackage = lib.mkOption {
      type = lib.types.nullOr lib.types.package;
      default = pkgs.claude-code;
      defaultText = lib.literalExpression "pkgs.claude-code";
      description = ''
        Where to find `claude` when {option}`programs.claude-code` is not
        installing it -- which is the case when its `package` is `null`,
        including the {option}`installAsClaude` arrangement below.

        Only the path is used. The package is not added to
        {option}`home.packages`, so this does not put `claude` back on the
        PATH.
      '';
    };

    installAsClaude = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Install the wrapper *as* `claude`, so the name on the PATH is the
        wrapper and the unwrapped binary is reachable only by store path.

        This replaces the shell alias, and with it the ways around the alias:
        a script, a `command claude`, a non-interactive shell. What the
        wrapper runs is {option}`claudePackage`, by absolute path.

        Requires {option}`programs.claude-code.package` to be `null`, so that
        module does not also put its own `claude` on the PATH. The assertion
        will say so rather than silently overriding what you wrote.
      '';
    };

    claudeBin = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default =
        if claudeCodeProvidesPackage then
          "${claudeCode.finalPackage}/bin/claude"
        else if cfg.claudePackage != null then
          "${cfg.claudePackage}/bin/claude"
        else
          null;
      defaultText = lib.literalExpression ''
        "''${config.programs.claude-code.finalPackage}/bin/claude" when
        programs.claude-code installs one, else "''${claudePackage}/bin/claude",
        else null
      '';
      description = ''
        The {command}`claude` executable {command}`claude-wrap` should run,
        baked into the installed wrapper. It is deliberately not exported as
        a session variable: a store path held in a login session's
        environment outlives the generation it came from.

        Taken from {option}`programs.claude-code.finalPackage` by default, so
        the wrapper runs the same Claude Code that module installed --
        plugins, wrappers and all -- rather than searching for one. Set to
        `null` to let the wrapper search on its own.
      '';
    };

    aliasClaude = lib.mkOption {
      type = lib.types.bool;
      default = !cfg.installAsClaude;
      defaultText = lib.literalExpression "!config.programs.claude-clipboard-ssh.installAsClaude";
      description = ''
        Alias {command}`claude` to {command}`claude-wrap` in every enabled
        shell. Off by default when {option}`installAsClaude` is on, which
        makes the alias redundant.

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
      home.packages = [ (if cfg.claudeBin != null then wrappedPackage else cfg.package) ];

      assertions = [
        {
          assertion = cfg.installAsClaude -> !claudeCodeProvidesPackage;
          message = ''
            programs.claude-clipboard-ssh.installAsClaude puts the wrapper on
            the PATH as `claude`, but programs.claude-code is also installing
            its own `claude` there, and which one wins is down to the order of
            two profile directories.

            Set `programs.claude-code.package = null;` -- that module will
            still manage settings, agents and the rest, and
            programs.claude-clipboard-ssh.claudePackage (default
            pkgs.claude-code) is what the wrapper will run.
          '';
        }
        {
          assertion = cfg.installAsClaude -> cfg.claudeBin != null;
          message = ''
            programs.claude-clipboard-ssh.installAsClaude needs to know which
            `claude` to run, because it keeps the real one off the PATH where
            the wrapper could otherwise have searched for it. Set
            programs.claude-clipboard-ssh.claudePackage (or claudeBin).
          '';
        }
      ];

      warnings = lib.optional (cfg.claudeBin == null) ''
        programs.claude-clipboard-ssh is enabled but no `claude` executable
        is pinned, because programs.claude-code is not installing one. The
        wrapper will fall back to searching ~/.local/share/claude/versions,
        ~/.claude/local and then the PATH. Set
        programs.claude-clipboard-ssh.claudeBin to be explicit about it.
      '';
    }

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
