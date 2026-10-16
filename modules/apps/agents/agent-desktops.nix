{ inputs, ... }:
{
  flake.modules.aspects.agent-desktops.imports = [ inputs.self.modules.aspects.agent-upstream ];

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
        pkgs.selfPackages.magpie
        pkgs.selfPackages.agent-orchestrator
        # Upstream ships desktop installers for macOS and Windows only; this is
        # that Electron application, assembled for Linux. The daemon package
        # (`pkgs.selfPackages.open-design`) serves the same workspace in a
        # browser, for a session that wants no window.
        pkgs.selfPackages.open-design-desktop
      ];
    };
}
