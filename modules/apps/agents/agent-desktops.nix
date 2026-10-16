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
        # Upstream ships desktop installers for macOS and Windows only; the Linux
        # form is the `od` daemon, which opens the workspace in the browser.
        pkgs.selfPackages.open-design
      ];
    };
}
