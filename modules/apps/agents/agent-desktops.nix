{ inputs, ... }:
{
  flake.modules.homeManager.agent-desktops =
    { config, pkgs, ... }:
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

      # OpenDesign's BYOK connection test and chat dispatch refuse provider
      # base URLs whose DNS answer is internal (RFC1918, ULA, CGNAT) unless the
      # operator names the host in OD_ALLOWED_INTERNAL_HOSTS. The magpie
      # gateway is reached over Tailscale, so it resolves into exactly that
      # space; without the allowlist every test ends as "Internal IPs blocked",
      # which the UI reports as a 403 ("访问被拒绝"). The daemon sidecar
      # inherits this session variable from the desktop application.
      home.sessionVariables.OD_ALLOWED_INTERNAL_HOSTS = config.constants.getTailnetFqdn "nsphere-magpie-api";
    };
}
