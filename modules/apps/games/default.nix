{ inputs, ... }:
{
  flake.modules.aspects.games.imports = with inputs.self.modules.aspects; [
    games-hardware
    steam
  ];
}
