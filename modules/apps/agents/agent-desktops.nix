{ inputs, ... }:
{
  # Tern's browser pane is a WebKitGTK view, and WebKit's network process takes
  # its TLS backend from a GIO module. It cannot come from the tern package's
  # wrapper: Tern registers itself with the path of the binary it runs from,
  # which is the wrapped executable the wrapper execs, so the desktop entry and
  # the `~/.local/bin/tern` link both launch it without that environment. The
  # session carries the module directory instead, and NixOS's own module for
  # this composes with the dconf module's list rather than replacing it.
  flake.modules.nixos.agent-desktops = {
    services.gnome.glib-networking.enable = true;
  };

  flake.modules.homeManager.agent-desktops =
    { pkgs, ... }:
    let
      llmAgents = inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system};
    in
    {
      home.packages = [
        llmAgents."grok-bot"
        pkgs.selfPackages.paseo-desktop
        pkgs.selfPackages.deepseek-harness-desktop
        pkgs.selfPackages.tern
        pkgs.selfPackages.magpie
        pkgs.selfPackages.clawd-on-desk

        # Clawd watches the coding agents through hooks it registers in their
        # configuration, and every hook it writes is a Node script it runs as
        # `node <hook> <event>`. It resolves that `node` from a list of paths
        # that a NixOS machine does not have (/usr/bin/node, Homebrew, nvm and
        # the other version managers under $HOME) and then from a login shell,
        # and falls back to the bare name — which is a hook that fails at every
        # event on a machine that has no Node at all. Clawd's own doctor
        # reports it and offers a repair, but the repair cannot invent the
        # interpreter either.
        pkgs.nodejs
      ];
    };
}
