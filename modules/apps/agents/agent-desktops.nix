{ inputs, ... }:
{
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
        pkgs.selfPackages.open-design-desktop
      ];
    };
}
