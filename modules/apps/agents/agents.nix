{ inputs, ... }:
{
  flake.modules.aspects.agents.imports = with inputs.self.modules.aspects; [
    herdr
    agent-desktops
    pi
  ];
}
