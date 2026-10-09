{ inputs, ... }:
{
  flake.modules.aspects.agent-desktops.imports = [ inputs.self.modules.aspects.agent-upstream ];

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
        pkgs.selfPackages.agent-orchestrator
      ];
    };
}
